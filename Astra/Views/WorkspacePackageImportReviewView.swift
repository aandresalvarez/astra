import AppKit
import SwiftUI
import ASTRAModels

/// Identifiable wrapper so ContentView can drive the review sheet with
/// `.sheet(item:)` from a picked `.astra-share` URL.
struct WorkspacePackageImportRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// Serializes `.sheet(item:)` presentation across a queue of `.astra-share`
/// packages — from a multi-file selection, and/or a later "Import Workspace…"
/// invoked again while a sheet (including a completed-import summary the user
/// left open) is still on screen.
///
/// Swapping the sheet item in place while a sheet is already presented does
/// not reliably replace the presented content, and the sheet view's `@State`
/// (e.g. a completed-import summary) survives regardless — so any new
/// request dismisses whatever is currently shown and is re-presented from
/// the sheet's `onDismiss`, promoted ahead of anything left over from an
/// earlier batch. The request the user just made always wins the
/// interruption; older queued items simply resume after it.
struct WorkspacePackageImportSheetPresentation {
    /// Drives `.sheet(item:)`.
    var presented: WorkspacePackageImportRequest?
    /// Requests waiting to be shown, in presentation order.
    private(set) var queued: [WorkspacePackageImportRequest] = []

    init() {}

    /// Enqueues one or more requests (e.g. every `.astra-share` file from a
    /// single selection). Presents immediately when idle; otherwise
    /// dismisses the current sheet and promotes this batch ahead of the
    /// existing queue, re-presenting once `sheetDismissed()` fires.
    mutating func request(_ requests: [WorkspacePackageImportRequest]) {
        guard !requests.isEmpty else { return }
        if presented == nil, queued.isEmpty {
            presented = requests[0]
            queued = Array(requests.dropFirst())
        } else {
            queued = requests + queued
            presented = nil
        }
    }

    mutating func request(_ request: WorkspacePackageImportRequest) {
        self.request([request])
    }

    /// Call from the sheet's `onDismiss`; promotes the next queued request
    /// into a fresh presentation, if any.
    mutating func sheetDismissed() {
        guard !queued.isEmpty else { return }
        presented = queued.removeFirst()
    }
}

/// Review-flow state for `WorkspacePackageImportReviewView`, extracted so the
/// transitions are testable without SwiftUI.
struct WorkspacePackageImportReviewState {
    private(set) var plan: WorkspacePackageImportPlan?
    private(set) var outcome: WorkspacePackageImportOutcome?
    private(set) var destinationParentURL: URL?
    private(set) var statusMessage = ""
    /// Fingerprint of the package bytes the plan was built from, so the import
    /// can refuse to commit a package that was swapped after review (TOCTOU).
    private(set) var reviewedPackageDigest: String?

    init() {}

    var canImport: Bool { plan?.canImport == true && destinationParentURL != nil }

    mutating func planLoaded(_ plan: WorkspacePackageImportPlan?, packageDigest: String? = nil) {
        self.plan = plan
        self.reviewedPackageDigest = packageDigest
        if plan == nil {
            statusMessage = "This does not look like a valid workspace package."
        }
    }

    /// A failed import's error (for example "destination already exists")
    /// describes the previous inputs; changing the destination invalidates it.
    mutating func destinationChosen(_ url: URL) {
        destinationParentURL = url
        statusMessage = ""
    }

    mutating func importFinished(_ result: Result<WorkspacePackageImportOutcome, any Error>) {
        switch result {
        case .success(let outcome):
            self.outcome = outcome
            statusMessage = ""
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }
}

/// Review-before-import for a `.astra-share` portable workspace package:
/// validates the package, shows the readiness plan (what's ready, what needs
/// approval/authentication/setup, what stays disabled), requires an explicit
/// destination folder, and only then runs the transactional import. After a
/// successful import the same sheet shows the post-import checklist.
struct WorkspacePackageImportReviewView: View {
    let packageURL: URL
    var onComplete: (Workspace?) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var state = WorkspacePackageImportReviewState()
    @State private var didLoad = false
    @State private var accessingURL: URL?
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var reviewStagingRoot: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let outcome = state.outcome {
                        outcomeBody(outcome)
                    } else if let plan = state.plan {
                        planBody(plan)
                    } else {
                        Text("Reading package…")
                            .font(Stanford.ui(14))
                            .foregroundStyle(Stanford.textSecondary)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspacePackageImportReviewView")
        .task {
            guard !didLoad else { return }
            didLoad = true
            accessingURL = packageURL.startAccessingSecurityScopedResource() ? packageURL : nil
            // Validation enumerates and hashes an untrusted (bounded) tree; run
            // that filesystem work off the main actor so a large package can't
            // hang the review UI. The report is Sendable.
            let url = packageURL
            // Stage a private bounded snapshot FIRST, then validate THAT — so the
            // decoded plan AND the fingerprint come from immutable bytes an
            // attacker who can write the source can't swap between the decode and
            // the checksum read (the confirm step re-stages and re-binds the
            // fingerprint independently, so importing bytes other than the
            // reviewed snapshot is still rejected).
            let staged: (report: WorkspacePackageValidationReport, stagingRoot: URL?) =
                await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    let stagingRoot = fm.temporaryDirectory
                        .appendingPathComponent("astra-share-review-\(UUID().uuidString.lowercased())", isDirectory: true)
                    let stagedPackage = stagingRoot.appendingPathComponent("package.astra-share", isDirectory: true)
                    do {
                        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                        try PortablePackageSafeFileReader.stageBoundedCopy(from: url, to: stagedPackage)
                        return (WorkspacePackageService().validatePackage(at: stagedPackage), stagingRoot)
                    } catch {
                        // Staging failed (symlink / oversize / unreadable) — the
                        // live-package validation surfaces the same blocker.
                        try? fm.removeItem(at: stagingRoot)
                        return (WorkspacePackageService().validatePackage(at: url), nil)
                    }
                }.value
            // The `.task` may have been cancelled (sheet dismissed) while the
            // detached copy ran — `onDisappear` already fired and saw no staging
            // root to clean. Remove it now so a late-returning copy doesn't leak
            // up to the 500MB review limit into the temp dir.
            if Task.isCancelled {
                if let root = staged.stagingRoot { try? FileManager.default.removeItem(at: root) }
                return
            }
            reviewStagingRoot = staged.stagingRoot
            state.planLoaded(
                WorkspacePackageImportPlanner().plan(from: staged.report),
                packageDigest: staged.report.packageFingerprint
            )
        }
        .onDisappear {
            // Safety net: if the sheet is dismissed while an import is running,
            // cancel it so it unwinds before committing (the coordinator checks
            // cancellation before any domain mutation).
            importTask?.cancel()
            if let root = reviewStagingRoot {
                try? FileManager.default.removeItem(at: root)
                reviewStagingRoot = nil
            }
            accessingURL?.stopAccessingSecurityScopedResource()
            accessingURL = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "shippingbox")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.interactive)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.outcome == nil ? "Import Workspace Package" : "Workspace Imported")
                    .font(Stanford.heading(20))
                    .foregroundStyle(.primary)
                Text(state.plan?.workspaceName ?? packageURL.lastPathComponent)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).font(Stanford.caption(12)).foregroundStyle(.secondary)
            }
            if let outcome = state.outcome {
                Button(action: { onComplete(outcome.workspace) }) {
                    Label("Open Workspace", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("PackageImportOpenWorkspaceButton")
            } else {
                // Cancel: if an import is in flight, cancel the task and let it
                // unwind (the coordinator checks cancellation before committing,
                // so nothing is persisted) rather than closing over a running
                // import that could commit a workspace the user walked away from.
                Button("Cancel") {
                    if let outcome = state.outcome {
                        // Race: the import already committed in the instant before
                        // the button could swap to "Open Workspace". Honor the
                        // committed workspace instead of discarding it.
                        onComplete(outcome.workspace)
                    } else if isImporting {
                        importTask?.cancel()
                    } else {
                        onComplete(nil)
                    }
                }
                .buttonStyle(.borderless)
                Button(action: { startImport() }) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                // Disable while an import is running so repeated clicks can't
                // start concurrent attempts.
                .disabled(!state.canImport || isImporting)
                .help(importHelp)
                .accessibilityIdentifier("PackageImportConfirmButton")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private var importHelp: String {
        if state.plan?.canImport != true { return "Resolve the package blockers first." }
        if state.destinationParentURL == nil { return "Choose a destination folder first." }
        return "Create the workspace and import the package."
    }

    // MARK: - Plan

    @ViewBuilder
    private func planBody(_ plan: WorkspacePackageImportPlan) -> some View {
        section("Destination") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationSummary(plan))
                        .font(Stanford.caption(12))
                        .foregroundStyle(state.destinationParentURL == nil ? Stanford.textSecondary : .primary)
                    Text("The workspace is created inside the folder you choose — never where the package file happens to sit.")
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.textTertiary)
                }
                Spacer()
                Button("Choose…", action: chooseDestination)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("PackageImportChooseDestinationButton")
            }
        }

        if !plan.blockers.isEmpty {
            section("Blockers — this package cannot be imported") {
                ForEach(Array(plan.blockers.enumerated()), id: \.offset) { _, issue in
                    itemRow(
                        name: issue.path,
                        detail: issue.message,
                        status: .incompatible
                    )
                }
            }
        }

        if !plan.apps.isEmpty {
            section("Workspace Apps") { itemRows(plan.apps) }
        }
        if !plan.capabilities.isEmpty {
            section("Capabilities") { itemRows(plan.capabilities) }
        }
        if !plan.packs.isEmpty {
            section("Packs") { itemRows(plan.packs) }
        }
        if !plan.connectors.isEmpty {
            section("Connectors") { itemRows(plan.connectors) }
        }
        if !plan.localTools.isEmpty {
            section("Local Tools") { itemRows(plan.localTools) }
        }
        if !plan.workspaceInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            section("Workspace Instructions") {
                infoRow("Always-on", "This package sets workspace-wide agent instructions applied to every task: \(plan.workspaceInstructions)")
            }
        }
        if !plan.skills.isEmpty {
            section("Skills") { itemRows(plan.skills) }
        }
        if !plan.templates.isEmpty {
            section("Templates") { itemRows(plan.templates) }
        }
        if !plan.accounts.isEmpty {
            section("Accounts") { itemRows(plan.accounts) }
        }
        if !plan.sshConnections.isEmpty {
            section("SSH Connections") { itemRows(plan.sshConnections) }
        }

        section("Security") {
            infoRow("Credentials", "No credential values travel in a package; keys and accounts must be re-authorized here.")
            if plan.quarantinedScheduleCount > 0 {
                infoRow("Routines", "\(plan.quarantinedScheduleCount) enabled routine(s) import disabled until you re-enable them.")
            }
            if plan.droppedMachinePathCount > 0 {
                infoRow("Paths", "\(plan.droppedMachinePathCount) machine-specific path(s) from the exporting machine are not transferred.")
            }
        }
    }

    // MARK: - Outcome

    @ViewBuilder
    private func outcomeBody(_ outcome: WorkspacePackageImportOutcome) -> some View {
        section("Imported") {
            infoRow("Workspace", outcome.workspace.name)
            infoRow("Location", outcome.workspaceRootURL.path)
            infoRow("Resources", "\(outcome.skillCount) skills, \(outcome.connectorCount) connectors, \(outcome.localToolCount) tools")
            if !outcome.appsImported.isEmpty {
                infoRow("Apps", outcome.appsImported.joined(separator: ", "))
            }
            if !outcome.capabilitiesInstalledAsDraft.isEmpty {
                infoRow("Capabilities", "\(outcome.capabilitiesInstalledAsDraft.joined(separator: ", ")) — installed as drafts pending review")
            }
            if !outcome.capabilitiesAlreadyInstalled.isEmpty {
                infoRow("Already installed", outcome.capabilitiesAlreadyInstalled.joined(separator: ", "))
            }
        }
        section("Still needs attention") {
            if outcome.quarantinedScheduleCount > 0 {
                infoRow("Routines", "\(outcome.quarantinedScheduleCount) imported disabled — re-enable them once you've reviewed them.")
            }
            ForEach(outcome.connectorsNeedingCredentials, id: \.self) { name in
                infoRow("Connector", "\(name) needs credentials before it can run.")
            }
            ForEach(outcome.connectorsNeedingConfiguration, id: \.self) { name in
                infoRow("Connector", "\(name) needs its configuration values re-entered before it can run.")
            }
            ForEach(outcome.packsUnavailable, id: \.self) { id in
                infoRow("Pack", "\(id) isn't installed here — the workspace imported without it.")
            }
            ForEach(outcome.googleAccountsRequiringReauth, id: \.self) { email in
                infoRow("Account", "\(email) needs to be signed in on this machine.")
            }
            ForEach(outcome.sshConnectionsRequiringLocalKeys, id: \.self) { label in
                infoRow("SSH", "\(label) references a key path that must exist here.")
            }
            ForEach(outcome.skillsNeedingToolReattachment, id: \.self) { name in
                infoRow("Skill", "\(name) named local tools that imported detached — re-attach them so a template bound to it has the tool.")
            }
            ForEach(outcome.capabilitiesSkippedForConflict, id: \.self) { id in
                infoRow("Capability", "\(id) was skipped — it conflicts with a capability you already have.")
            }
            ForEach(outcome.capabilitiesUnavailable, id: \.self) { id in
                infoRow("Capability", "\(id) isn't installed and approved here — install and approve it, then enable it in this workspace.")
            }
            ForEach(outcome.capabilitiesInstalledAsDraft, id: \.self) { id in
                infoRow("Capability", "\(id) installed as a draft pending governance review — approve it, then enable it in this workspace.")
            }
            if !outcome.droppedMachinePaths.isEmpty {
                infoRow("Paths", "Not transferred: \(outcome.droppedMachinePaths.joined(separator: ", "))")
            }
            if outcome.quarantinedScheduleCount == 0,
               outcome.connectorsNeedingCredentials.isEmpty,
               outcome.connectorsNeedingConfiguration.isEmpty,
               outcome.googleAccountsRequiringReauth.isEmpty,
               outcome.sshConnectionsRequiringLocalKeys.isEmpty,
               outcome.packsUnavailable.isEmpty,
               outcome.capabilitiesSkippedForConflict.isEmpty,
               outcome.capabilitiesUnavailable.isEmpty,
               outcome.capabilitiesInstalledAsDraft.isEmpty,
               outcome.droppedMachinePaths.isEmpty,
               outcome.skillsNeedingToolReattachment.isEmpty {
                infoRow("Nothing", "Everything imported ready to use.")
            }
        }
    }

    // MARK: - Actions

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder the imported workspace will be created in."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            state.destinationChosen(url)
        }
    }

    private func startImport() {
        guard !isImporting else { return }
        isImporting = true
        importTask = Task {
            await runImport()
            isImporting = false
            importTask = nil
        }
    }

    private func runImport() async {
        guard let destinationParentURL = state.destinationParentURL else { return }
        do {
            let outcome = try await WorkspacePackageImportCoordinator().importPackage(
                at: packageURL,
                intoDestinationFolder: destinationParentURL,
                modelContext: modelContext,
                expectedPackageDigest: state.reviewedPackageDigest
            )
            // No post-import cancellation check here: the coordinator gates the
            // commit on `Task.checkCancellation()` internally, and the whole
            // post-staging phase is synchronous on the main actor, so if we have
            // an outcome the import genuinely committed — honor it. A later
            // cancel/commit race is handled in the Cancel button (it opens a
            // committed workspace rather than discarding it).
            state.importFinished(.success(outcome))
        } catch is CancellationError {
            // The user cancelled during staging; the coordinator threw before any
            // commit and rolled back. Leave the review as-is (no outcome).
        } catch {
            state.importFinished(.failure(error))
        }
    }

    private func destinationSummary(_ plan: WorkspacePackageImportPlan) -> String {
        guard let destinationParentURL = state.destinationParentURL else { return "No destination chosen yet." }
        let root = destinationParentURL.appendingPathComponent(
            WorkspacePackageImportCoordinator.directoryName(for: plan.workspaceName)
        )
        return "Creates \(root.path)"
    }

    // MARK: - Rows

    @ViewBuilder
    private func itemRows(_ items: [WorkspacePackageImportPlanItem]) -> some View {
        ForEach(items) { item in
            itemRow(name: item.name, detail: item.detail, status: item.status)
        }
    }

    private func itemRow(name: String, detail: String, status: WorkspacePackageImportItemStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusSymbol(status))
                .font(Stanford.caption(12))
                .foregroundStyle(statusColor(status))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Stanford.caption(12).weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(Stanford.caption(11)).foregroundStyle(Stanford.textSecondary)
            }
            Spacer()
            Text(status.displayLabel).font(Stanford.caption(11)).foregroundStyle(Stanford.textSecondary)
        }
    }

    private func statusSymbol(_ status: WorkspacePackageImportItemStatus) -> String {
        switch status {
        case .ready: "checkmark.circle"
        case .alreadyInstalled: "checkmark.circle.badge.questionmark"
        case .needsApproval: "person.badge.shield.checkmark"
        case .needsAuthentication: "key"
        case .needsLocalSetup: "wrench.and.screwdriver"
        case .missing: "questionmark.circle"
        case .incompatible: "xmark.octagon"
        }
    }

    private func statusColor(_ status: WorkspacePackageImportItemStatus) -> Color {
        switch status {
        case .ready, .alreadyInstalled: Stanford.paloAltoGreen
        case .needsApproval, .needsAuthentication, .needsLocalSetup, .missing: Color.orange
        case .incompatible: Color.red
        }
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Stanford.caption(13).weight(.semibold)).foregroundStyle(.primary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Stanford.caption(12).weight(.medium)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(Stanford.caption(12)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
