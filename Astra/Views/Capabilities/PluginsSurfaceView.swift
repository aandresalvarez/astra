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

    /// The rows and their display, built in one pass so every action takes
    /// the same package and activation the row shows.
    private var surface: (state: PluginsSurfaceState, rows: [String: PluginRow]) {
        let context = policyContext
        let currentCapabilities = capabilities
        var rows: [String: PluginRow] = [:]
        var inputs: [PluginsSurfacePresentation.Input] = []
        for package in packages {
            let packageState = CapabilityPackageState(package: package, workspace: workspace, capabilities: currentCapabilities)
            let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
            let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace)
            var input = PluginsSurfacePresentation.Input(
                package: package,
                isEnabled: packageState.isEnabled,
                pendingSteps: packageState.connectorsNeedingAttention.count + failingSetup(for: package).count,
                isVisible: decision.isVisible && (decision.canEnable || packageState.isEnabled || decision.requiresApproval),
                isRemovable: !CapabilityLibrary.trustedBuiltInPackageIDs.contains(package.id)
            )
            input.needsUpdate = activation.map {
                $0.recordedVersion != package.version
                    || $0.knownComponentIDs != PluginUpdateService.componentIDs(of: package)
            } ?? false
            inputs.append(input)
            rows[package.id] = PluginRow(package: package, activation: activation, display: PluginsSurfacePresentation.makeState(
                [input], query: ""
            ).allRows.first ?? placeholderRow(package))
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
            let model = surface
            let current = model.state
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
        }
        .padding(16)
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
                    onTurnOff: { disable(pluginRow.package) },
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
        let failing = isEnabled ? failingSetup(for: package).first { $0.component.name == component.name } : nil
        let connector = isEnabled && component.kind == .connector
            ? CapabilityPackageState(package: package, workspace: workspace, capabilities: capabilities)
                .connectorsNeedingAttention.first { $0.name == component.name }
            : nil
        return HStack(spacing: 8) {
            Text(component.name).font(Stanford.ui(13))
            Text(kindLabel(component.kind)).font(Stanford.caption(11)).foregroundStyle(.secondary)
            Spacer()
            if let failing, let repair = failing.repair {
                if repairs.phase(for: repair) == .waiting {
                    Text("Checking…").font(Stanford.caption(11)).foregroundStyle(.secondary)
                } else {
                    // What the button runs is shown before it runs.
                    if let command = repair.command {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button(repair.verb) { repairs.start(repair) { refreshStatuses() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                }
            } else if let connector {
                Button("Add key") { onEditElement(.connectors, connector.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Stanford.lagunita)
            } else if isEnabled, component.kind == .setup, statuses.isEmpty == false {
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
        let component: PluginComponent
        let repair: RepairAction?
    }

    private func failingSetup(for package: PluginPackage) -> [FailingSetup] {
        let components = PluginManifestConverter.manifest(from: package).components
        return package.prerequisites.compactMap { prerequisite in
            guard let status = statuses[prerequisite.id], !status.isUsable,
                  let component = components.first(where: { $0.kind == .setup && $0.name == prerequisite.displayName })
            else { return nil }
            let needsInstall: Bool = { if case .missingBinary = status { return true } else { return false } }()
            return FailingSetup(component: component, repair: RepairAction.from(component, needsInstall: needsInstall))
        }
    }

    private func refreshStatuses() {
        let enabled = packages.filter {
            !$0.prerequisites.isEmpty
                && CapabilityPackageState(package: $0, workspace: workspace, capabilities: capabilities).isEnabled
        }
        let directory = workspace.resolvedWorkingPath
        Task { @MainActor in
            let cache = PreflightCache()
            var next: [String: HealthStatus] = [:]
            for package in enabled {
                let packageStatuses = await CapabilityHealthService.prerequisiteStatuses(
                    for: package, cache: cache, workingDirectory: directory
                )
                next.merge(packageStatuses) { _, new in new }
            }
            statuses = next
        }
    }

    private func refreshApprovalRecords() {
        Task {
            let records = await Task.detached(priority: .utility) { CapabilityApprovalStore().records() }.value
            approvalRecords = records
        }
    }

    // MARK: - Actions

    private func add(_ row: PluginRow) {
        let package = row.package
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

    private func update(_ row: PluginRow) {
        errorMessage = nil
        do {
            try CapabilityCatalogActionService().update(modelContext: modelContext)
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
        let copy = confirmation.copy(
            name: account?.name ?? row.package.name,
            workspaces: account.map { PluginOperations.workspacesUsing($0).map(\.name) } ?? []
        )
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
                case .remove: remove(row.package)
                case .deleteAccount: if let account { deleteAccount(account) }
                }
            }
            .controlSize(.small)
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
