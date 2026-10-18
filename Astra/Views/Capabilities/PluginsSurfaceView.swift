import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import ASTRACore
import ASTRAModels

/// Plugins 2.0: one card, status carried by group headings, one verb per row,
/// rows that expand in place (`docs/design-system/lean-ui-system.md`).
///
/// Shown in Configure → Capabilities when `PluginsSurfacePreferences` is on.
/// Every capability side effect goes through `CapabilityCatalogActionService`
/// (`PluginsSurfaceFitnessTests`); copy and grouping live in
/// `PluginsSurfacePresentation`.
struct PluginsSurfaceView: View {
    var workspace: Workspace
    var catalog: PluginCatalog
    /// A plugin another surface asked to open (the rail, an MCP install):
    /// its row is expanded and scrolled to, then the request is cleared.
    @Binding var selectedPackageID: String?
    var onCatalogChanged: () -> Void = {}
    var onEditElement: (ConfigureTab, UUID) -> Void = { _, _ in }

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true }) private var globalSkills: [Skill]
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true }) private var globalConnectors: [Connector]
    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true }) private var globalTools: [LocalTool]

    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var approvalRecords: [CapabilityApprovalRecord] = []
    @State private var statuses: [String: HealthStatus] = [:]
    @State private var errorMessage: String?
    @State private var confirming: PluginsSurfaceConfirmation?
    @StateObject private var repairs = PluginRepairCoordinator()
    @State private var showCreateWizard = false
    @State private var importReview: CapabilityImportReview?
    @State private var showMCPPaste = false
    @State private var pastedMCPTarget = ""
    @State private var mcpInstallRequest: MCPInstallChatRequest?
    /// Only the latest health scan may publish; an older one finishing last
    /// would bring back failures a repair already fixed.
    @State private var statusGeneration = 0
    @State private var approvalGeneration = 0
    /// The Keychain side of the Google account, read on refresh rather than
    /// on every render; the profile's own state comes from the store.

    private var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    private var policyContext: CapabilityCatalogPolicyContext {
        PluginCatalogApprovalState.policyContext(workspace: workspace, approvalRecords: approvalRecords)
    }

    private var packages: [PluginPackage] {
        CapabilityGalleryInventory.managementPackages(
            catalogPackages: catalog.packages + PluginCatalog.builtInPackages,
            capabilities: capabilities,
            workspace: workspace,
            policyContext: policyContext
        )
    }

    /// This build signs in to no account (the Google OAuth stack is
    /// deleted), so a required account is always a pending step.
    private var googleAccountConnected: Bool { false }

    /// The rows and their display, built in one pass so every action takes
    /// the same package and activation the row shows, and the accounts none
    /// of the listed rows shows.
    private var surface: (state: PluginsSurfaceState, rows: [String: PluginRow], unusedAccounts: [Connector]) {
        let context = policyContext
        let currentCapabilities = capabilities
        let googleConnected = googleAccountConnected
        var rows: [String: PluginRow] = [:]
        var inputs: [PluginsSurfacePresentation.Input] = []
        for package in packages {
            let packageState = CapabilityPackageState(package: package, workspace: workspace, capabilities: currentCapabilities)
            let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
            let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace)
            var input = PluginsSurfacePresentation.Input(
                package: package,
                isEnabled: packageState.isEnabled,
                pendingSteps: packageState.connectorsNeedingAttention.count + packageState.missingConnectors.count
                    + failingSetup(for: package).count
                    + PluginsSurfacePresentation.pendingAccounts(for: package, googleAccountConnected: googleConnected).count,
                isVisible: decision.isVisible && (decision.canEnable || packageState.isEnabled || decision.requiresApproval),
                isRemovable: Self.isRemovable(package)
            )
            input.unavailableReason = PluginsSurfacePresentation.unavailableReason(for: package)
            input.origin = PluginSourceCoordinator.shared.origin(of: package)
            // Any drift an Update would settle: version, digest, components
            // or templates.
            input.needsUpdate = activation.map {
                PluginUpdateService.needsReconcile($0, to: package)
                    || !PluginTemplateSync.isInSync(package, in: workspace)
            } ?? false
            inputs.append(input)
            rows[package.id] = PluginRow(package: package, activation: activation, display: PluginsSurfacePresentation.makeState(
                [input], query: ""
            ).allRows.first ?? placeholderRow(package))
        }
        let unusedAccounts = PluginsSurfacePresentation.unusedAccounts(
            workspaceConnectors: currentCapabilities.workspaceConnectors,
            sharedConnectors: currentCapabilities.enabledGlobalConnectors,
            listedPackages: inputs.filter(\.isVisible).map(\.package),
            query: query
        )
        return (PluginsSurfacePresentation.makeState(inputs, query: query), rows, unusedAccounts)
    }

    private func placeholderRow(_ package: PluginPackage) -> PluginsSurfaceRow {
        PluginsSurfaceRow(
            id: package.id, name: package.name, icon: package.icon, subtitle: "",
            pendingSteps: 0, isEnabled: false, isRemovable: false, verb: nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plugins")
                    .font(Stanford.ui(15, weight: .semibold))
                Spacer()
                TextField("Search: jira, gmail, bigquery", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Menu("New") {
                    Button("Create a plugin…") { showCreateWizard = true }
                    Button("From an MCP server…") { showMCPPaste = true }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Import file…") { openImportPanel() }
                    .controlSize(.small)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusError)
            }
            let model = surface
            let current = model.state
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        group("Action needed", current.actionNeeded, rows: model.rows)
                        group("Ready", current.ready, rows: model.rows)
                        group("Available", current.available, rows: model.rows)
                        PluginAccountsSection(
                            accounts: model.unusedAccounts,
                            onEditAccount: { onEditElement(.connectors, $0) },
                            onChanged: { onCatalogChanged() },
                            onError: { errorMessage = $0 }
                        )
                        if current.isEmpty && model.unusedAccounts.isEmpty {
                            Text(query.isEmpty ? "No plugins yet." : "Nothing matches \u{201C}\(query)\u{201D}.")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        PluginSourcesSection(workspace: workspace, installed: catalog.packages) {
                            catalog.loadApprovedCapabilities(announceLibraryMutations: false)
                            onCatalogChanged()
                        }
                    }
                }
                .onAppear { revealSelectedPackage(proxy) }
                .onChange(of: selectedPackageID) { _, _ in revealSelectedPackage(proxy) }
            }
        }
        .padding(16)
        .onDisappear { repairs.cancelAll() }
        .onAppear {
            expanded = PluginsSurfacePreferences.expandedPluginIDs(workspaceID: workspace.id)
            refreshApprovalRecords()
            if catalog.packages.isEmpty {
                catalog.loadApprovedCapabilities()
                onCatalogChanged()
            }
            refreshStatuses()
        }
        .onChange(of: expanded) { _, ids in
            PluginsSurfacePreferences.setExpandedPluginIDs(ids, workspaceID: workspace.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .capabilityApprovalsChanged)) { _ in
            refreshApprovalRecords()
        }
        .onReceive(NotificationCenter.default.publisher(for: .capabilityCatalogPersistenceChanged)) { notification in
            // A library change (an install, an import, a removal in another
            // window) reloads this surface's catalog snapshot; a workspace
            // change is observed through the model.
            if (notification.object as? CapabilityCatalogPersistenceChange)?.workspaceID == nil {
                catalog.loadApprovedCapabilities(announceLibraryMutations: false)
            }
            refreshStatuses()
        }
        .sheet(isPresented: $showCreateWizard) {
            CapabilityCreationWizardView(workspace: workspace) { package, enableHere, sourceURL in
                create(package, enableHere: enableHere, sourceURL: sourceURL)
            }
        }
        .sheet(item: $importReview) { review in
            CapabilityImportReviewSheet(
                review: review,
                onCancel: { importReview = nil },
                onImport: { importFile($0) }
            )
        }
        .sheet(isPresented: $showMCPPaste) {
            MCPInstallTargetPasteSheet(
                targetText: $pastedMCPTarget,
                onCancel: { showMCPPaste = false },
                onReview: { reviewPastedMCPTarget() }
            )
        }
        .sheet(item: $mcpInstallRequest) { request in
            CapabilityMCPInstallReviewSheet(
                request: request,
                workspace: workspace,
                onCancel: { mcpInstallRequest = nil },
                onInstalled: { package in
                    mcpInstallRequest = nil
                    catalog.loadApprovedCapabilities(announceLibraryMutations: false)
                    selectedPackageID = package.id
                }
            )
        }
    }

    private func revealSelectedPackage(_ proxy: ScrollViewProxy) {
        guard let id = selectedPackageID else { return }
        expanded.insert(id)
        selectedPackageID = nil
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }

    /// A plugin the library holds and ASTRA did not ship. A row projected
    /// from a standalone skill (`skill.<uuid>`) is not in the library.
    static func isRemovable(_ package: PluginPackage) -> Bool {
        guard !CapabilityLibrary.trustedBuiltInPackageIDs.contains(package.id) else { return false }
        let kind = package.sourceMetadata?.kind
        return !(package.id.hasPrefix("skill.") && (kind == "workspace" || kind == "shared"))
    }

    @ViewBuilder
    private func group(_ title: String, _ displays: [PluginsSurfaceRow], rows: [String: PluginRow]) -> some View {
        if !displays.isEmpty {
            Text(title)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            ForEach(displays) { display in
                if let row = rows[display.id] {
                    rowView(row, display: display)
                        .id(display.id)
                    Divider().padding(.leading, 38)
                }
            }
        }
    }

    private func rowView(_ pluginRow: PluginRow, display row: PluginsSurfaceRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                } label: {
                    HStack(spacing: 10) {
                        CapabilityLeadingIcon(
                            systemImage: row.icon,
                            brand: BrandMark.resolve(id: row.id, name: row.name),
                            pointSize: 16
                        )
                        .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(Stanford.ui(14, weight: .semibold))
                            Text(row.subtitle)
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if row.verb == .add {
                    Button("Add") { add(pluginRow) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                } else if row.verb == .update {
                    Button("Update") { update(pluginRow) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                }
                Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if expanded.contains(row.id) {
                PluginRowDetailsView(
                    row: pluginRow,
                    workspace: workspace,
                    setupRow: { componentRow($0, package: pluginRow.package, isEnabled: row.isEnabled) },
                    onEditAccount: { onEditElement(.connectors, $0) },
                    onConfirm: { confirming = $0 },
                    approvalRecords: approvalRecords,
                    policyContext: policyContext,
                    onTurnOff: { disable(pluginRow.package) },
                    onSetApproval: { setApproval($0, for: pluginRow.package) },
                    onUpdate: { update(pluginRow) },
                    onChanged: { onCatalogChanged() },
                    onError: { errorMessage = $0 }
                )
                .padding(.leading, 38)
                if let confirming, confirming.packageID == row.id {
                    confirmationRow(confirming, row: pluginRow)
                        .padding(.leading, 38)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func componentRow(_ component: PluginComponent, package: PluginPackage, isEnabled: Bool) -> some View {
        let checkID = PluginManifestConverter.prerequisiteID(of: component)
        let failing = isEnabled && checkID != nil ? failingSetup(for: package).first { $0.prerequisite.id == checkID } : nil
        let packageState = isEnabled && component.kind == .connector
            ? CapabilityPackageState(package: package, workspace: workspace, capabilities: capabilities)
            : nil
        // Matched like the package state matches them (service type, aliases),
        // so a renamed account still gets its action.
        let connector = component.connector.flatMap { spec in
            packageState?.connectorsNeedingAttention.first { CapabilityRuntimeResourceMatcher.connectorMatches(spec, connector: $0) }
        }
        let missing = packageState?.missingConnectors.contains { $0.name == component.name } ?? false
        let accountPending = isEnabled && component.requirement.map { requirement in
            PluginsSurfacePresentation.pendingAccounts(for: package, googleAccountConnected: googleAccountConnected)
                .contains { $0.id == requirement.id }
        } == true
        return HStack(spacing: 8) {
            Text(component.name).font(Stanford.ui(13))
            Text(kindLabel(component.kind)).font(Stanford.caption(11)).foregroundStyle(.secondary)
            Spacer()
            if let failing, GitHubRepositoryAccessRepairButton.supports(failing.prerequisite, status: statuses[failing.prerequisite.id]) {
                GitHubRepositoryAccessRepairButton(workingDirectory: workspace.resolvedWorkingPath) { refreshStatuses() }
            } else if let failing, let repair = failing.repair {
                if repairs.phase(for: repair, owner: "\(package.id)/\(component.id)") == .waiting {
                    Text("Checking…").font(Stanford.caption(11)).foregroundStyle(.secondary)
                } else {
                    // What the button runs is shown before it runs.
                    if let command = repair.command {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button(repair.verb) { repairs.start(repair, owner: "\(package.id)/\(component.id)") { refreshStatuses() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                }
            } else if let connector {
                Button("Add key") { onEditElement(.connectors, connector.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
            } else if missing {
                // Its account was deleted: adding again recreates it.
                Button("Set up") { add(package) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
            } else if accountPending {
                Text("Needs a sign-in ASTRA can't do").font(Stanford.caption(11)).foregroundStyle(.secondary)
            } else if failing != nil {
                Text("Not working").font(Stanford.caption(11)).foregroundStyle(Stanford.statusError)
            } else if isEnabled, component.kind == .setup, isUsable(component, package: package) {
                ConfiguredStatusDot()
            }
        }
    }

    private func kindLabel(_ kind: PluginComponent.Kind) -> String {
        switch kind {
        case .skill: "Skill"
        case .connector: "Account"
        case .tool: "CLI tool"
        case .mcp: "MCP server"
        case .template: "Template"
        case .setup: "Setup"
        }
    }

    // MARK: - Health

    private struct FailingSetup {
        let prerequisite: CLIPrerequisite
        let component: PluginComponent
        let repair: RepairAction?
    }

    /// This setup component's own prerequisite was checked and works.
    private func isUsable(_ component: PluginComponent, package: PluginPackage) -> Bool {
        guard let id = PluginManifestConverter.prerequisiteID(of: component), let status = statuses[id] else { return false }
        return status.isUsable
    }

    /// Matched by check identity, not label: two prerequisites may share a name.
    private func failingSetup(for package: PluginPackage) -> [FailingSetup] {
        let components = PluginManifestConverter.manifest(from: package).components
        return package.prerequisites.compactMap { prerequisite in
            guard let status = statuses[prerequisite.id], !status.isUsable,
                  let component = components.first(where: { PluginManifestConverter.prerequisiteID(of: $0) == prerequisite.id })
            else { return nil }
            let needsInstall: Bool = { if case .missingBinary = status { return true } else { return false } }()
            return FailingSetup(
                prerequisite: prerequisite,
                component: component,
                repair: RepairAction.from(component, needsInstall: needsInstall)
            )
        }
    }

    private func refreshStatuses() {
        let enabled = packages.filter {
            !$0.prerequisites.isEmpty
                && CapabilityPackageState(package: $0, workspace: workspace, capabilities: capabilities).isEnabled
        }
        let directory = workspace.resolvedWorkingPath
        statusGeneration += 1
        let generation = statusGeneration
        Task { @MainActor in
            let cache = PreflightCache()
            var next: [String: HealthStatus] = [:]
            for package in enabled {
                let packageStatuses = await CapabilityHealthService.prerequisiteStatuses(
                    for: package, cache: cache, workingDirectory: directory
                )
                next.merge(packageStatuses) { _, new in new }
            }
            guard generation == statusGeneration else { return }
            statuses = next
        }
    }

    private func refreshApprovalRecords() {
        // Only the latest read publishes: an older one finishing last would
        // bring back obsolete approvals.
        approvalGeneration += 1
        let generation = approvalGeneration
        Task {
            let records = await Task.detached(priority: .utility) { CapabilityApprovalStore().records() }.value
            guard generation == approvalGeneration else { return }
            approvalRecords = records
        }
    }

    // MARK: - Actions

    private func add(_ row: PluginRow) {
        add(row.package)
    }

    private func add(_ package: PluginPackage) {
        errorMessage = nil
        do {
            try CapabilityCatalogActionService().add(
                package,
                workspace: workspace,
                modelContext: modelContext,
                policyContext: policyContext,
                traceID: AuditTrace.make("plugins-add")
            )
            expanded.insert(package.id)
            onCatalogChanged()
            refreshStatuses()
        } catch {
            errorMessage = "Couldn't add \(package.name): \(error.localizedDescription)"
        }
    }

    // MARK: - New and import

    private func create(_ package: PluginPackage, enableHere: Bool, sourceURL: URL?) {
        errorMessage = nil
        do {
            let result = try CapabilityCatalogActionService().create(
                package,
                enableHere: enableHere,
                sourceURL: sourceURL,
                workspace: workspace,
                modelContext: modelContext,
                policyContext: policyContext,
                traceID: AuditTrace.make(enableHere ? "capability-create-enable" : "capability-create")
            )
            if result.approvalRecordChanged { refreshApprovalRecords() }
            catalog.loadApprovedCapabilities(announceLibraryMutations: false)
            expanded.insert(package.id)
            onCatalogChanged()
        } catch {
            errorMessage = "Couldn't create \(package.name): \(error.localizedDescription)"
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Plugin"
        panel.prompt = "Review"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importReview = CapabilityImportReview(report: CapabilityPackageImporter().validateFile(at: url))
    }

    private func importFile(_ report: CapabilityPackageValidationReport) {
        errorMessage = nil
        do {
            let result = try CapabilityCatalogActionService().importPlugin(
                report, workspace: workspace, modelContext: modelContext, traceID: AuditTrace.make("capability-import")
            )
            importReview = nil
            catalog.loadApprovedCapabilities(announceLibraryMutations: false)
            expanded.insert(result.package.id)
            onCatalogChanged()
        } catch {
            importReview = nil
            errorMessage = "Couldn't import the plugin: \(error.localizedDescription)"
        }
    }

    private func reviewPastedMCPTarget() {
        guard let result = MCPInstallChatCommand.installResult(input: "/mcp \(pastedMCPTarget)") else {
            errorMessage = "Paste an MCP npm, uvx, Docker, JSON, or HTTPS target to review."
            return
        }
        switch result {
        case .request(let request):
            showMCPPaste = false
            DispatchQueue.main.async { mcpInstallRequest = request }
        case .failure(let failure):
            errorMessage = failure.message
        }
    }

    private func setApproval(_ status: CapabilityApprovalStatus, for package: PluginPackage) {
        errorMessage = nil
        do {
            try CapabilityCatalogActionService().setApprovalStatus(status, for: package, workspace: workspace)
            refreshApprovalRecords()
        } catch {
            errorMessage = "Couldn't update the review of \(package.name): \(error.localizedDescription)"
        }
    }

    private func update(_ row: PluginRow) {
        errorMessage = nil
        do {
            try CapabilityCatalogActionService().update(row.package, modelContext: modelContext)
            onCatalogChanged()
            refreshStatuses()
        } catch {
            errorMessage = "Couldn't update \(row.package.name): \(error.localizedDescription)"
        }
    }

    private func confirmationRow(_ confirmation: PluginsSurfaceConfirmation, row: PluginRow) -> some View {
        let account: Connector? = {
            guard case .deleteAccount(_, let accountID) = confirmation else { return nil }
            return row.activation?.bindings.compactMap(\.account).first { $0.id == accountID }
        }()
        // An unreadable delete scope offers no Delete: the confirmation
        // would not name every workspace the deletion reaches.
        let reach: [String]? = account.map { account in
            (try? PluginOperations.workspacesUsing(account))?.map(\.name)
        } ?? []
        let copy = confirmation.copy(name: account?.name ?? row.package.name, workspaces: reach ?? [])
        return PluginsSurfaceConfirmationRow(
            message: reach == nil ? PluginOperations.OperationError.storeUnreadable.localizedDescription : copy.message,
            verb: reach == nil ? nil : copy.verb,
            onCancel: { confirming = nil },
            onConfirm: {
                confirming = nil
                switch confirmation {
                case .remove: remove(row.package)
                case .deleteAccount: if let account { deleteAccount(account) }
                }
            }
        )
    }

    private func deleteAccount(_ account: Connector) {
        errorMessage = nil
        do {
            try CapabilityCatalogActionService().deleteAccount(account, modelContext: modelContext)
            onCatalogChanged()
        } catch {
            errorMessage = "Couldn't delete \(account.name): \(error.localizedDescription)"
        }
    }

    private func disable(_ package: PluginPackage) {
        let result = CapabilityCatalogActionService().disable(
            package, workspace: workspace, capabilities: capabilities, modelContext: modelContext
        )
        if !result.persisted { errorMessage = "Couldn't turn off \(package.name). Try again." }
        onCatalogChanged()
    }

    private func remove(_ package: PluginPackage) {
        errorMessage = nil
        do {
            try CapabilityCatalogActionService().remove(package, modelContext: modelContext)
            expanded.remove(package.id)
            catalog.loadApprovedCapabilities(announceLibraryMutations: false)
            onCatalogChanged()
        } catch {
            errorMessage = "Couldn't remove \(package.name): \(error.localizedDescription)"
        }
    }
}
