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
    @State private var statuses: [String: HealthStatus] = [:]
    @State private var errorMessage: String?
    @State private var confirming: PluginsSurfaceConfirmation?
    @StateObject private var repairs = PluginRepairCoordinator()
    /// Only the latest health scan may publish; an older one finishing last
    /// would bring back failures a repair already fixed.
    @State private var statusGeneration = 0
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

    private var state: PluginsSurfaceState {
        let context = policyContext
        let currentCapabilities = capabilities
        let googleConnected = googleAccountConnected
        return PluginsSurfacePresentation.makeState(packages.map { package in
            let packageState = CapabilityPackageState(package: package, workspace: workspace, capabilities: currentCapabilities)
            let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
            let listing = PluginsSurfacePresentation.listing(for: decision, isEnabled: packageState.isEnabled)
            return PluginsSurfacePresentation.Input(
                package: package,
                isEnabled: packageState.isEnabled,
                pendingSteps: packageState.connectorsNeedingAttention.count + packageState.missingConnectors.count
                    + failingSetup(for: package).count
                    + PluginsSurfacePresentation.pendingAccounts(for: package, googleAccountConnected: googleConnected).count,
                isVisible: listing.isVisible,
                isRemovable: Self.isRemovable(package),
                blocker: listing.blocker
            )
        }, query: query)
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
            let current = state
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        group("Action needed", current.actionNeeded)
                        group("Ready", current.ready)
                        group("Available", current.available)
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
        // Contextual checks (GitHub repository access) describe one checkout:
        // a new working path, from any window, scans again.
        .onChange(of: workspace.resolvedWorkingPath) { _, _ in refreshStatuses() }
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
    private func group(_ title: String, _ rows: [PluginsSurfaceRow]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            ForEach(rows) { row in
                rowView(row)
                    .id(row.id)
                Divider().padding(.leading, 38)
            }
        }
    }

    private func rowView(_ row: PluginsSurfaceRow) -> some View {
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
                    Button("Add") { add(row.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                }
                Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if expanded.contains(row.id), let package = packages.first(where: { $0.id == row.id }) {
                details(package, row: row)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func details(_ package: PluginPackage, row: PluginsSurfaceRow) -> some View {
        let manifest = PluginManifestConverter.manifest(from: package)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(manifest.components.enumerated()), id: \.offset) { _, component in
                componentRow(component, package: package, isEnabled: row.isEnabled)
            }
            if row.isEnabled || row.isRemovable {
                HStack {
                    if row.isEnabled {
                        Toggle("On in this workspace", isOn: Binding(
                            get: { confirming != .turnOff(packageID: package.id) },
                            set: { if !$0 { confirming = .turnOff(packageID: package.id) } }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    Spacer()
                    // Remove reaches every workspace, so it is offered once the
                    // plugin is off here; a plugin off everywhere can still go.
                    if row.isRemovable, !row.isEnabled {
                        Button("Remove", role: .destructive) { confirming = .remove(packageID: package.id) }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
                if let confirming, confirming.packageID == package.id {
                    confirmationRow(confirming, package: package)
                }
            }
        }
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
                Button("Set up") { add(package.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
            } else if accountPending {
                // Add routes through the install flow that signs in again.
                Button("Reconnect") { add(package.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
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

    private func refreshGoogleCredential() {
        let usesGoogle = packages.contains(where: GoogleWorkspaceCapability.usesGoogleWorkspaceOAuthSetup)
        let account = usesGoogle ? GoogleWorkspaceSetupStateFactory.selectedAccount(from: googleAccounts) : nil
        let vault = GoogleOAuthCredentialVault()
        googleCredentialStatuses = account.map { [$0.id: vault.credentialStatus(for: $0)] } ?? [:]
        googleRefreshableAccountIDs = account.map { vault.hasRefreshToken(for: $0) ? [$0.id] : [] } ?? []
    }

    private func refreshStatuses() {
        refreshGoogleCredential()
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

    private func add(_ packageID: String) {
        guard let package = packages.first(where: { $0.id == packageID }) else { return }
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
            expanded.insert(packageID)
            onCatalogChanged()
            refreshStatuses()
        } catch {
            errorMessage = "Couldn't add \(package.name): \(error.localizedDescription)"
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

    private func confirmationRow(_ confirmation: PluginsSurfaceConfirmation, package: PluginPackage) -> some View {
        let copy = confirmation.copy(name: package.name, hasAccounts: !package.connectors.isEmpty)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(copy.message)
                .font(Stanford.caption(12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { confirming = nil }
                .controlSize(.small)
            Button(copy.verb, role: .destructive) {
                confirming = nil
                switch confirmation {
                case .turnOff: disable(package)
                case .remove: remove(package)
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Stanford.statusError.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
