import SwiftUI
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
    @Query private var googleAccounts: [GoogleOAuthAccountProfile]

    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var approvalRecords: [CapabilityApprovalRecord] = []
    @State private var prerequisiteScan = PrerequisiteScanSnapshot()
    private var statuses: [String: HealthStatus] { prerequisiteScan.statuses }
    @State private var errorMessage: String?
    @State private var confirming: PluginsSurfaceConfirmation?
    @StateObject private var repairs = PluginRepairCoordinator()
    /// Only the latest health scan may publish; an older one finishing last
    /// would bring back failures a repair already fixed.
    /// A plugin whose setup connects an account goes through its install
    /// flow, which does that.
    @State private var accountSetupPackage: PluginPackage?
    @State private var accountSetupContext: CapabilityCatalogPolicyContext?
    @State private var approvalGeneration = 0
    /// The Keychain side of the Google account, read on refresh rather than
    /// on every render; the profile's own state comes from the store.
    @State private var googleCredentialStatuses: [UUID: GoogleOAuthCredentialStatus] = [:]
    @State private var googleRefreshableAccountIDs: Set<UUID> = []

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

    private var googleAccountConnected: Bool {
        let account = GoogleWorkspaceSetupStateFactory.selectedAccount(from: googleAccounts)
        return GoogleWorkspaceCapability.isAccountConnected(
            account,
            credentialStatus: account.flatMap { googleCredentialStatuses[$0.id] },
            hasRefreshToken: account.map { googleRefreshableAccountIDs.contains($0.id) } ?? false
        )
    }

    /// The rows and their display, built in one pass so every action takes
    /// the same package and activation the row shows.
    private var surface: (state: PluginsSurfaceState, rows: [String: PluginRow]) {
        let context = policyContext
        let currentCapabilities = capabilities
        let googleConnected = googleAccountConnected
        var rows: [String: PluginRow] = [:]
        var inputs: [PluginsSurfacePresentation.Input] = []
        for package in packages {
            let packageState = CapabilityPackageState(package: package, workspace: workspace, capabilities: currentCapabilities)
            let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
            let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace)
            let listing = PluginsSurfacePresentation.listing(for: decision, isEnabled: packageState.isEnabled)
            var input = PluginsSurfacePresentation.Input(
                package: package,
                isEnabled: packageState.isEnabled,
                pendingSteps: packageState.connectorsNeedingAttention.count + packageState.missingConnectors.count
                    + PluginsSurfacePresentation.pendingSetupChecks(for: package, statuses: statuses)
                    + PluginsSurfacePresentation.pendingAccounts(for: package, googleAccountConnected: googleConnected).count,
                isVisible: listing.isVisible,
                isRemovable: Self.isRemovable(package),
                blocker: listing.blocker,
                awaitsUpdate: packageState.awaitsUpdate
            )
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
        // An activation whose plugin the library no longer has is listed
        // too, so it can be removed (`CapabilityUninstaller.forgetMissing`).
        let libraryIDs = Set((catalog.packages + PluginCatalog.builtInPackages).map(\.id))
        for activation in WorkspaceCapabilityActivation.activations(of: workspace)
        where !activation.isDeleted && !libraryIDs.contains(activation.pluginID) && rows[activation.pluginID] == nil {
            let input = PluginsSurfacePresentation.missingInput(pluginID: activation.pluginID, isEnabled: activation.isEnabled)
            inputs.append(input)
            rows[activation.pluginID] = PluginRow(package: input.package, activation: activation, display: PluginsSurfacePresentation.makeState(
                [input], query: ""
            ).allRows.first ?? placeholderRow(input.package))
        }
        return (PluginsSurfacePresentation.makeState(inputs, query: query), rows)
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
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusError)
            }
            PluginStateRecoverySection(onChanged: { errorMessage = nil; onCatalogChanged() }, onError: { errorMessage = $0 })
            let model = surface
            let current = model.state
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        group("Action needed", current.actionNeeded, rows: model.rows)
                        group("Ready", current.ready, rows: model.rows)
                        group("Available", current.available, rows: model.rows)
                        if current.isEmpty {
                            Text(query.isEmpty ? "No plugins yet." : "Nothing matches \u{201C}\(query)\u{201D}.")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .onAppear { revealSelectedPackage(proxy) }
                .onChange(of: selectedPackageID) { _, _ in revealSelectedPackage(proxy) }
            }
        }
        .padding(16)
        .onDisappear { repairs.cancelAll() }
        .sheet(item: $accountSetupPackage) { package in
            CapabilityInstallSheetRouter(
                package: package,
                workspace: workspace,
                policyContext: accountSetupContext ?? policyContext,
                onDismiss: { accountSetupPackage = nil },
                onInstalled: { _ in
                    accountSetupPackage = nil
                    onCatalogChanged()
                    refreshStatuses()
                }
            )
        }
        .onAppear {
            expanded = PluginsSurfacePreferences.expandedPluginIDs(workspaceID: workspace.id)
            refreshApprovalRecords()
            if catalog.packages.isEmpty {
                catalog.loadApprovedCapabilities()
                onCatalogChanged()
            }
            refreshStatuses()
        }
        // A sign-in, reauthorization or revocation stamps the profile.
        .onChange(of: googleAccounts.map(\.updatedAt)) { _, _ in refreshGoogleCredential() }
        // Nor does an access token reaching its expiry: read it again then.
        .task(id: googleCredentialExpiry) { await refreshGoogleCredential(at: googleCredentialExpiry) }
        // Contextual checks (GitHub repository access) describe one checkout:
        // a new working path, from any window, scans again.
        .onChange(of: workspace.resolvedWorkingPath) { _, _ in refreshStatuses() }
        // A CLI's own state (Docker stopped, a logout in Terminal) changes
        // outside ASTRA: coming back to ASTRA scans again.
        .rescansPrerequisitesOnActivation { refreshStatuses() }
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
                    setupRow: { componentRow($0, package: pluginRow.package, isEnabled: row.isEnabled, position: $1) },
                    onEditAccount: { onEditElement(.connectors, $0) },
                    onConfirm: { confirming = $0 },
                    onTurnOff: { disable(pluginRow.package) },
                    onUpdate: { update(pluginRow) },
                    onChanged: { errorMessage = nil; onCatalogChanged() },
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

    /// `position`: the prerequisite this setup component checks, by position.
    private func componentRow(_ component: PluginComponent, package: PluginPackage, isEnabled: Bool, position: Int?) -> some View {
        let checkID = PluginManifestConverter.prerequisiteID(of: component)
        let failing = isEnabled ? position.flatMap { position in failingSetup(for: package).first { $0.position == position } } : nil
        let packageState = isEnabled && component.kind == .connector
            ? CapabilityPackageState(package: package, workspace: workspace, capabilities: capabilities)
            : nil
        // The account bound to this very component, so a renamed account
        // still gets its action and a second one of the service its own.
        let connector = component.connector.flatMap { packageState?.connectorNeedingAttention(for: $0) }
        let missing = component.connector.map { packageState?.isMissing($0) ?? false } ?? false
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
                    // What the button runs is shown before it runs; a repair
                    // that runs nothing says what to do before Check.
                    let guidance = PluginsSurfacePresentation.repairGuidance(repair)
                    Text(guidance.text)
                        .font(guidance.isCommand ? .system(size: 11, design: .monospaced) : Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(repair.verb) { repairs.start(repair, owner: "\(package.id)/\(component.id)") { refreshStatuses() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                    if let message = repairs.statusText(for: repair, owner: "\(package.id)/\(component.id)") {
                        Text(message).font(Stanford.caption(11)).foregroundStyle(.secondary)
                    }
                }
            } else if let connector, packageState?.inactiveSharedConnectors.contains(where: { $0.id == connector.id }) == true {
                // A shared account that is off here: turning it on is the step.
                Button("Turn on") { activate(connector, for: package) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
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
                // Add routes through the install flow that signs in again.
                switch PluginsSurfacePresentation.pendingAccountAction(for: package) {
                case .reconnect:
                    Button("Reconnect") { add(package) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                case .unsupported(let reason):
                    Text(reason)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if failing != nil {
                Text("Not working").font(Stanford.caption(11)).foregroundStyle(Stanford.statusError)
            } else if isEnabled, let checkID, statuses[checkID]?.isNotChecked == true {
                // A check that is not a read-only status command never runs.
                Text("Not checked").font(Stanford.caption(11)).foregroundStyle(.secondary)
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
        let position: Int
        let prerequisite: CLIPrerequisite
        let component: PluginComponent
        let repair: RepairAction?
    }

    /// This setup component's own prerequisite was checked and works.
    private func isUsable(_ component: PluginComponent, package: PluginPackage) -> Bool {
        guard let id = PluginManifestConverter.prerequisiteID(of: component), let status = statuses[id] else { return false }
        return status.isUsable
    }

    /// Each prerequisite with its own component, by position: two may share a
    /// name, or a check ID, and still offer different repairs.
    private func failingSetup(for package: PluginPackage) -> [FailingSetup] {
        PluginManifestConverter.setupComponents(of: package).enumerated().compactMap { position, pair in
            let (prerequisite, component) = pair
            guard let status = statuses[prerequisite.id], !status.isUsable, !status.isNotChecked else { return nil }
            let needsInstall: Bool = { if case .missingBinary = status { return true } else { return false } }()
            return FailingSetup(
                position: position,
                prerequisite: prerequisite,
                component: component,
                repair: RepairAction.from(component, needsInstall: needsInstall)
            )
        }
    }

    private func refreshGoogleCredential() {
        let usesGoogle = packages.contains(where: GoogleWorkspaceCapability.usesGoogleWorkspaceOAuthSetup)
        let account = usesGoogle ? GoogleWorkspaceSetupStateFactory.selectedAccount(from: googleAccounts) : nil
        let vault = GoogleOAuthCredentialVault()
        googleCredentialStatuses = account.map { [$0.id: vault.credentialStatus(for: $0)] } ?? [:]
        googleRefreshableAccountIDs = account.map { vault.hasRefreshToken(for: $0) ? [$0.id] : [] } ?? []
    }

    /// When the cached access token expires; the row may change then.
    private var googleCredentialExpiry: Date? {
        googleCredentialStatuses.values.compactMap { status -> Date? in
            if case .available(let expiresAt, _) = status { return expiresAt }
            return nil
        }.min()
    }

    private func refreshGoogleCredential(at expiry: Date?) async {
        guard let expiry else { return }
        let delay = max(expiry.timeIntervalSinceNow, 0) + 1
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        refreshGoogleCredential()
    }

    private func refreshStatuses() {
        refreshGoogleCredential()
        let enabled = packages.filter {
            !$0.prerequisites.isEmpty
                && CapabilityPackageState(package: $0, workspace: workspace, capabilities: capabilities).isEnabled
        }
        let directory = workspace.resolvedWorkingPath
        let generation = prerequisiteScan.begin()
        Task { @MainActor in
            let cache = PreflightCache()
            var next: [String: HealthStatus] = [:]
            for package in enabled {
                let packageStatuses = await CapabilityHealthService.prerequisiteStatuses(
                    for: package, cache: cache, workingDirectory: directory
                )
                next.merge(packageStatuses) { _, new in new }
            }
            prerequisiteScan.complete(next, generation: generation)
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
            if try CapabilityCatalogActionService.addRoute(for: package) == .connectAccount {
                // The same one-step approval as Add, before the flow enables it.
                accountSetupContext = try CapabilityCatalogActionService().grantPendingApproval(
                    for: package, workspace: workspace, policyContext: policyContext,
                    source: "plugins_add_connect_account", traceID: AuditTrace.make("plugins-add")
                )
                accountSetupPackage = package
                refreshApprovalRecords()
                return
            }
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

    private func activate(_ connector: Connector, for package: PluginPackage) {
        errorMessage = nil
        guard CapabilityCatalogActionService().activateSharedConnector(connector, workspace: workspace, modelContext: modelContext) else {
            errorMessage = "Couldn't turn on \(connector.name) for \(package.name). Try again."
            return
        }
        onCatalogChanged()
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
        let copy = PluginsSurfacePresentation.confirmationCopy(confirmation, account: account,
            packageName: row.package.name, in: workspace, workspaces: reach ?? [])
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(reach == nil ? PluginOperations.OperationError.storeUnreadable.localizedDescription : copy.message)
                .font(Stanford.caption(12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { confirming = nil }
                .controlSize(.small)
            if reach != nil {
                Button(copy.verb, role: .destructive) {
                    confirming = nil
                    switch confirmation {
                    case .remove: remove(row.package, missing: row.display.isMissing)
                    case .deleteAccount: if let account { deleteAccount(account) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Stanford.statusError.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
        errorMessage = nil
        let result = CapabilityCatalogActionService().disable(
            package, workspace: workspace, modelContext: modelContext
        )
        if let problem = result.problem, problem.operationID == nil { errorMessage = problem.localizedDescription }
        else if !result.persisted && result.problem == nil { errorMessage = "Couldn't turn off \(package.name). Try again." }
        onCatalogChanged()
    }

    private func remove(_ package: PluginPackage, missing: Bool = false) {
        errorMessage = nil
        do {
            if missing {
                try CapabilityCatalogActionService().forgetMissing(pluginID: package.id, modelContext: modelContext)
            } else {
                try CapabilityCatalogActionService().remove(package, modelContext: modelContext)
            }
            expanded.remove(package.id)
            catalog.loadApprovedCapabilities(announceLibraryMutations: false)
            onCatalogChanged()
        } catch {
            errorMessage = "Couldn't remove \(package.name): \(error.localizedDescription)"
        }
    }
}
