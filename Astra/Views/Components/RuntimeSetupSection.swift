import SwiftUI
import ASTRACore

/// The onboarding wizard's Runtime step body: one hero card that owns all
/// detail and remediation for the selected runtime, and one compact
/// grouped catalog where every other runtime is a single line with one
/// action. Replaces the old stack of banner + chooser + status rows +
/// callout that rendered the same blocker in up to five places.
struct RuntimeSetupSection: View {
    @ObservedObject var model: RuntimeSetupModel
    @Environment(\.openURL) private var openURL

    @State private var showDetails = false
    @State private var showNotInstalled = false
    @State private var didSeedDisclosures = false
    @State private var copiedCommand: String?
    @State private var showInstallLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroCard

            HStack {
                Text("Other runtimes")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(Stanford.coolGrey)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    model.refresh(force: true)
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                        .font(Stanford.caption(12))
                }
                .disabled(model.isRefreshing)
                .accessibilityLabel("Re-check all runtimes")
            }

            catalog
        }
        .onAppear(perform: seedDisclosures)
        .onChange(of: model.hasCompletedInitialRefresh) {
            seedDisclosures()
        }
    }

    // MARK: - Hero card

    private var heroRow: RuntimeProviderRowPresentation {
        row(for: model.selectedRuntime)
    }

    private var heroCard: some View {
        let presentation = heroRow
        let tint = color(for: presentation.state)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if model.isRefreshing || presentation.state == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: symbol(for: presentation.state))
                        .font(Stanford.ui(18, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(Stanford.heading(16))
                        .foregroundStyle(Stanford.black)
                    Text(heroSubtitle(for: presentation))
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.coolGrey)
                        .lineLimit(2)
                }
                Spacer()
                StatusPill(
                    icon: chipIcon(for: presentation.state),
                    label: chipLabel(for: presentation.state),
                    color: tint,
                    help: presentation.subtitle
                )
            }

            if !remediationViewIsEmpty {
                Divider().opacity(0.45)
                remediationView
            }

            if model.installState?.runtime == model.selectedRuntime || installResultConcernsHero {
                installStatusView
            }

            DisclosureGroup(isExpanded: $showDetails) {
                detailsContent
                    .padding(.top, 8)
            } label: {
                Label("Details for support", systemImage: "chevron.right.circle")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.coolGrey)
            }
            .accessibilityLabel("Details for support")
        }
        .padding(16)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentation.title), \(chipLabel(for: presentation.state))")
    }

    private func heroSubtitle(for presentation: RuntimeProviderRowPresentation) -> String {
        if case .healthy(_, let version) = model.status(for: presentation.id) {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Installed" : "Installed — \(trimmed)"
        }
        return presentation.subtitle
    }

    // MARK: - Remediation row

    /// One sentence + one primary action + the copyable command. The only
    /// rendering of the selected runtime's blocker on the whole step.
    @ViewBuilder
    private var remediationView: some View {
        if let session = model.authSession, session.runtime == model.selectedRuntime {
            signInWaitingRow(session)
        } else {
            switch model.heroStatus {
            case .needsSignIn(let runtime), .readyUnverified(let runtime, _):
                signInOfferRow(runtime)
            case .needsInstall(let runtime):
                installOfferRow(runtime)
            case .blocked(_, let detail):
                blockedRow(detail)
            case .checking, .ready, .installing, .signingIn:
                EmptyView()
            }
        }
    }

    private var remediationViewIsEmpty: Bool {
        if model.authSession?.runtime == model.selectedRuntime { return false }
        switch model.heroStatus {
        case .needsSignIn, .readyUnverified, .needsInstall, .blocked: return false
        case .checking, .ready, .installing, .signingIn: return true
        }
    }

    private func signInOfferRow(_ runtime: AgentRuntimeID) -> some View {
        let remediation = model.remediation(for: runtime).auth
        let isUnverified = isReadyUnverified

        return VStack(alignment: .leading, spacing: 8) {
            Text(isUnverified
                 ? "If you have not signed in to \(runtime.displayName) yet, do it now — the account is confirmed on your first task."
                 : "Sign in to \(runtime.displayName) to continue.")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.black)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    model.signIn(runtime)
                } label: {
                    Label("Sign In…", systemImage: "person.crop.circle.badge.checkmark")
                        .font(Stanford.caption(12).weight(.semibold))
                }
                .accessibilityLabel("Sign in to \(runtime.displayName)")

                if case .manualRecheck = remediation.verification {
                    Button {
                        Task { await model.refreshReadiness() }
                    } label: {
                        Label("Verify", systemImage: "checkmark.seal")
                            .font(Stanford.caption(12))
                    }
                    .disabled(model.isCheckingReadiness)
                    .accessibilityLabel("Verify \(runtime.displayName) sign-in")
                    .help("Runs a short live check against \(runtime.displayName).")
                }

                copyableCommand(display: remediation.displayCommand, copy: remediation.terminalCommand)
            }
            if let instruction = remediation.instruction {
                Text(instruction)
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func installOfferRow(_ runtime: AgentRuntimeID) -> some View {
        let displayCommand = model.installPlanDisplayCommand(for: runtime)
        let installURL = RuntimeRemediationCatalog.installURL(for: runtime)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Install \(runtime.displayName) to continue — or pick another runtime below.")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.black)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let displayCommand {
                    Button {
                        model.install(runtime)
                    } label: {
                        Label("Install", systemImage: "square.and.arrow.down")
                            .font(Stanford.caption(12).weight(.semibold))
                    }
                    .disabled(model.installState != nil)
                    .accessibilityLabel("Install \(runtime.displayName)")
                    copyableCommand(display: displayCommand)
                } else if let installURL {
                    Button {
                        openURL(installURL)
                    } label: {
                        Label("Open Install Page", systemImage: "arrow.up.forward.square")
                            .font(Stanford.caption(12).weight(.semibold))
                    }
                    .accessibilityLabel("Open the \(runtime.displayName) install page")
                }
            }
            if displayCommand == nil {
                Text(AgentRuntimeAdapterRegistry.descriptor(for: runtime).installHint)
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func blockedRow(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail)
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.black)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Provider settings live in Settings → Runtimes.")
                .font(Stanford.caption(10))
                .foregroundStyle(Stanford.coolGrey)
        }
    }

    private func signInWaitingRow(_ session: RuntimeSetupModel.AuthSessionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(session.statusText)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.black)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.lastObservation.isEmpty {
                Text("Checked \(session.elapsedSeconds)s ago — \(session.lastObservation)")
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Check Now") { model.checkAuthNow() }
                    .font(Stanford.caption(12))
                    .accessibilityLabel("Check sign-in status now")
                Button("Cancel") { model.cancelSignIn() }
                    .font(Stanford.caption(12))
                    .accessibilityLabel("Cancel sign-in")
                copyableCommand(
                    display: model.remediation(for: session.runtime).auth.displayCommand,
                    copy: model.remediation(for: session.runtime).auth.terminalCommand
                )
            }
        }
    }

    // MARK: - Install progress / result

    private var installResultConcernsHero: Bool {
        model.installResult?.runtime == model.selectedRuntime
    }

    @ViewBuilder
    private var installStatusView: some View {
        if let installState = model.installState, installState.runtime == model.selectedRuntime {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installing \(installState.runtime.displayName)…")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    if let command = installState.displayCommand {
                        Text(command)
                            .font(Stanford.mono(10))
                            .foregroundStyle(Stanford.coolGrey)
                    }
                }
                Spacer()
                Button("Cancel") { model.cancelInstall() }
                    .font(Stanford.caption(11))
                    .accessibilityLabel("Cancel install")
            }
            .padding(9)
            .background(Stanford.lagunita.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let result = model.installResult, result.runtime == model.selectedRuntime {
            installResultRow(result)
        }
    }

    private func installResultRow(_ result: RuntimeCLIInstallResult) -> some View {
        let tint = result.succeeded ? Stanford.paloAltoGreen : Stanford.poppy
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.summary)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = result.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Stanford.caption(10))
                            .foregroundStyle(Stanford.coolGrey)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            if let log = result.fullLog, !log.isEmpty {
                DisclosureGroup(isExpanded: $showInstallLog) {
                    ScrollView {
                        Text(log)
                            .font(Stanford.mono(10))
                            .foregroundStyle(Stanford.coolGrey)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                } label: {
                    Text("Show output")
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                }
            }
        }
        .padding(9)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Details disclosure

    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = model.readinessReport {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 230), spacing: 8),
                        GridItem(.flexible(minimum: 230), spacing: 8)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(report.checks) { check in
                        readinessTile(check)
                    }
                }
            }

            pathRow("\(model.selectedRuntime.displayName) path", status: model.status(for: model.selectedRuntime))
            pathRow("GitHub path", status: model.githubStatus)

            githubLine
        }
    }

    private var githubLine: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isGitHubReady ? "checkmark.circle.fill" : "circle.dashed")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(model.isGitHubReady ? Stanford.paloAltoGreen : Stanford.coolGrey)
                .frame(width: 16)
            Text(githubSummary)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.coolGrey)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("GitHub CLI: \(githubSummary)")
    }

    private var githubSummary: String {
        if model.isGitHubReady { return "Optional: GitHub CLI for repo workflows — ready" }
        if case .healthy = model.githubStatus {
            return "Optional: GitHub CLI installed — run `gh auth login` for repo workflows"
        }
        return "Optional: GitHub CLI for repo workflows — not installed"
    }

    private func readinessTile(_ check: RuntimeReadinessCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: readinessSymbol(for: check.state))
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(readinessColor(for: check.state))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                    .lineLimit(1)
                Text(check.detail)
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineLimit(2)
                if let remediation = check.remediation, !remediation.isEmpty {
                    Text(remediation)
                        .font(Stanford.caption(10))
                        .foregroundStyle(readinessColor(for: check.state))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(readinessColor(for: check.state).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.title): \(check.detail)")
    }

    @ViewBuilder
    private func pathRow(_ title: String, status: HealthStatus?) -> some View {
        if case .healthy(let path, _) = status {
            HStack(spacing: 8) {
                Text(title)
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(Stanford.coolGrey)
                    .frame(width: 110, alignment: .leading)
                Text(path)
                    .font(Stanford.mono(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Catalog

    private var catalog: some View {
        let rows = AgentRuntimeAdapterRegistry.runtimeIDs
            .filter { $0 != model.selectedRuntime }
            .map(row(for:))
        let sections = RuntimeProviderListPresentation.sections(rows: rows)

        return VStack(spacing: 0) {
            ForEach(sections.ready) { row in
                catalogRow(row)
                rowDivider
            }
            ForEach(sections.needsAttention) { row in
                catalogRow(row)
                rowDivider
            }
            if !sections.notInstalled.isEmpty {
                DisclosureGroup(isExpanded: $showNotInstalled) {
                    VStack(spacing: 0) {
                        ForEach(sections.notInstalled) { row in
                            catalogRow(row)
                            if row.id != sections.notInstalled.last?.id {
                                rowDivider
                            }
                        }
                    }
                } label: {
                    Text("Not installed (\(sections.notInstalled.count))")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                        .padding(.vertical, 6)
                }
                .padding(.horizontal, 10)
                .accessibilityLabel("Not installed runtimes: \(sections.notInstalled.count)")
            }
        }
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1)
        )
    }

    private var rowDivider: some View {
        Divider().opacity(0.45).padding(.leading, 34)
    }

    private func catalogRow(_ presentation: RuntimeProviderRowPresentation) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if presentation.state == .installing || presentation.state == .awaitingSignIn {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: symbol(for: presentation.state))
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(color(for: presentation.state))
                    .frame(width: 16)
            }

            Text(presentation.title)
                .font(Stanford.body(12).weight(.semibold))
                .foregroundStyle(presentation.isInstalled ? Stanford.black : Stanford.coolGrey)
                .lineLimit(1)

            Spacer(minLength: 10)

            Text(shortStatus(for: presentation))
                .font(Stanford.caption(10))
                .foregroundStyle(Stanford.coolGrey)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(presentation.subtitle)

            actionButton(for: presentation)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title), \(shortStatus(for: presentation))")
    }

    @ViewBuilder
    private func actionButton(for presentation: RuntimeProviderRowPresentation) -> some View {
        switch presentation.primaryAction {
        case .use:
            Button("Use") { model.select(presentation.id) }
                .font(Stanford.caption(10).weight(.semibold))
                .accessibilityLabel("Use \(presentation.title)")
        case .signIn:
            Button("Sign In…") { model.signIn(presentation.id) }
                .font(Stanford.caption(10).weight(.semibold))
                .disabled(model.authSession != nil)
                .accessibilityLabel("Sign in to \(presentation.title)")
        case .install(let displayCommand):
            Button {
                model.install(presentation.id)
            } label: {
                Label("Install", systemImage: "square.and.arrow.down")
                    .font(Stanford.caption(10).weight(.semibold))
            }
            .disabled(model.installState != nil)
            .help(displayCommand)
            .accessibilityLabel("Install \(presentation.title)")
        case .openInstallPage(let url):
            Button {
                openURL(url)
            } label: {
                Label("Get…", systemImage: "arrow.up.forward.square")
                    .font(Stanford.caption(10).weight(.semibold))
            }
            .help(url.absoluteString)
            .accessibilityLabel("Open the \(presentation.title) install page")
        case .cancelInstall:
            Button("Cancel") { model.cancelInstall() }
                .font(Stanford.caption(10).weight(.semibold))
                .accessibilityLabel("Cancel installing \(presentation.title)")
        case .cancelSignIn:
            Button("Cancel") { model.cancelSignIn() }
                .font(Stanford.caption(10).weight(.semibold))
                .accessibilityLabel("Cancel signing in to \(presentation.title)")
        case .none:
            EmptyView()
        }
    }

    // MARK: - Shared helpers

    private func row(for runtime: AgentRuntimeID) -> RuntimeProviderRowPresentation {
        RuntimeProviderListPresentation.row(
            runtime: runtime,
            descriptor: AgentRuntimeAdapterRegistry.descriptor(for: runtime),
            selectedRuntime: model.selectedRuntime,
            status: model.status(for: runtime),
            isProbing: model.probing.contains(runtime),
            installingRuntime: model.installState?.runtime,
            installCommand: model.installPlanDisplayCommand(for: runtime),
            authState: model.authState(for: runtime),
            signingInRuntime: model.authSession?.runtime,
            installPageURL: RuntimeRemediationCatalog.installURL(for: runtime)
        )
    }

    /// Shows `display`, copies `copy` — they differ when the runnable
    /// command needs env exports the short form omits (Copilot's
    /// COPILOT_HOME), and copying the short form would log the user into
    /// a credential home ASTRA's tasks never read.
    private func copyableCommand(display: String, copy: String? = nil) -> some View {
        let commandToCopy = copy ?? display
        return Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(commandToCopy, forType: .string)
            copiedCommand = commandToCopy
            // @State mutations must happen on the main actor — without
            // this hop SwiftUI logs a runtime warning and races the
            // button's body. Capture the value to compare against.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if copiedCommand == commandToCopy { copiedCommand = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Text(display)
                    .font(Stanford.mono(10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: copiedCommand == commandToCopy ? "checkmark" : "doc.on.doc")
                    .font(Stanford.ui(9))
            }
            .foregroundStyle(Stanford.coolGrey)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Stanford.fog.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Copy command")
        .accessibilityLabel(copiedCommand == commandToCopy ? "Command copied" : "Copy command \(display)")
    }

    private var isReadyUnverified: Bool {
        if case .readyUnverified = model.setupStatus { return true }
        return false
    }

    private func seedDisclosures() {
        // Wait for real probe data — at onAppear every runtime still reads
        // as "not checked", which would seed the disclosure expanded on
        // every machine.
        guard !didSeedDisclosures, model.hasCompletedInitialRefresh else { return }
        didSeedDisclosures = true
        // Collapsed whenever something usable is installed; auto-expanded
        // on a fresh Mac where installing IS the task.
        let anyInstalled = AgentRuntimeAdapterRegistry.runtimeIDs.contains(where: model.isInstalled)
        showNotInstalled = !anyInstalled
    }

    private func shortStatus(for presentation: RuntimeProviderRowPresentation) -> String {
        switch presentation.state {
        case .checking: "Checking…"
        case .installing: "Installing…"
        case .awaitingSignIn: "Waiting for sign-in…"
        case .selectedReady: "Selected"
        case .ready: "Ready"
        case .unverified: presentation.subtitle
        case .unauthenticated: "Installed, signed out"
        case .unresponsive: "Not responding"
        case .missing: "Not installed"
        case .unknown: "Not checked yet"
        }
    }

    private func chipLabel(for state: RuntimeProviderRowState) -> String {
        switch state {
        case .checking: "Checking"
        case .installing: "Installing"
        case .awaitingSignIn: "Signing in"
        case .selectedReady, .ready: "Ready"
        case .unverified: "Set up"
        case .unauthenticated: "Needs sign-in"
        case .unresponsive: "Not responding"
        case .missing: "Not installed"
        case .unknown: "Not checked"
        }
    }

    private func chipIcon(for state: RuntimeProviderRowState) -> String {
        switch state {
        case .checking, .awaitingSignIn: "arrow.triangle.2.circlepath"
        case .installing: "square.and.arrow.down"
        case .selectedReady, .ready: "checkmark.circle.fill"
        case .unverified: "checkmark.circle"
        case .unauthenticated: "person.crop.circle.badge.exclamationmark"
        case .unresponsive: "exclamationmark.octagon.fill"
        case .missing: "arrow.down.circle"
        case .unknown: "circle.dotted"
        }
    }

    private func symbol(for state: RuntimeProviderRowState) -> String {
        switch state {
        case .checking, .awaitingSignIn: "arrow.triangle.2.circlepath"
        case .installing: "square.and.arrow.down"
        case .selectedReady, .ready: "checkmark.circle.fill"
        case .unverified: "checkmark.circle"
        case .unauthenticated, .unresponsive: "exclamationmark.triangle.fill"
        case .missing, .unknown: "circle"
        }
    }

    private func color(for state: RuntimeProviderRowState) -> Color {
        switch state {
        case .checking, .installing, .awaitingSignIn: Stanford.lagunita
        case .selectedReady, .ready, .unverified: Stanford.paloAltoGreen
        case .unauthenticated, .unresponsive: Stanford.poppy
        case .missing, .unknown: Stanford.coolGrey
        }
    }

    private func readinessSymbol(for state: RuntimeReadinessState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private func readinessColor(for state: RuntimeReadinessState) -> Color {
        switch state {
        case .ready: Stanford.paloAltoGreen
        case .warning: Stanford.poppy
        case .blocked: Stanford.cardinalRed
        }
    }
}
