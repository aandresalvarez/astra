import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ASTRACore
import ASTRAModels

/// Plugins 2.0: one card, status carried by group headings, one verb per row,
/// rows that expand in place (`docs/design-system/lean-ui-system.md`).
///
/// Configure → Capabilities. Every capability side effect goes through
/// `CapabilityCatalogActionService` (`PluginsSurfaceFitnessTests`); copy and
/// grouping live in `PluginsSurfacePresentation`.
struct PluginsSurfaceView: View {
    var workspace: Workspace
    var catalog: PluginCatalog
    /// A plugin to open on arrival (the rail's plugin links); cleared once shown.
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
    @State private var sources: [PluginSource] = []
    @State private var sourced: [SourcedPlugin] = []
    @State private var fetchingSourceIDs: Set<String> = []
    @State private var isAddingSource = false
    @State private var sourceInput = ""

    private var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    private var policyContext: CapabilityCatalogPolicyContext {
        CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: approvalRecords)
    }

    private var packages: [PluginPackage] {
        CapabilityGalleryInventory.managementPackages(
            catalogPackages: catalog.packages + PluginCatalog.builtInPackages,
            capabilities: capabilities,
            workspace: workspace,
            policyContext: policyContext
        )
    }

    private var state: PluginsSurfaceState {
        let context = policyContext
        let currentCapabilities = capabilities
        let known = Set(packages.map(\.id))
        let fromSources = sourced.filter { !known.contains($0.package.id) }.map { plugin in
            PluginsSurfacePresentation.Input(
                package: plugin.package, isEnabled: false, pendingSteps: 0, isVisible: true, isRemovable: false,
                sourceName: plugin.source.displayName, unsupported: plugin.unsupported, problem: plugin.problem,
                worksOn: worksOn(plugin.package)
            )
        }
        return PluginsSurfacePresentation.makeState(fromSources + packages.map(sourceCandidate).map { package in
            let packageState = CapabilityPackageState(package: package, workspace: workspace, capabilities: currentCapabilities)
            let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
            return PluginsSurfacePresentation.Input(
                package: package,
                isEnabled: packageState.isEnabled,
                pendingSteps: packageState.connectorsNeedingAttention.count + failingSetup(for: package).count,
                isVisible: decision.isVisible && (decision.canEnable || packageState.isEnabled || decision.requiresApproval),
                isRemovable: !CapabilityLibrary.trustedBuiltInPackageIDs.contains(package.id),
                recordedVersion: workspace.capabilityActivation.installedVersion(of: package.id),
                worksOn: worksOn(package)
            )
        }, query: query)
    }

    /// An installed source plugin whose source now offers another version is
    /// shown, and updated, with the fetched definition, so Update appears
    /// once the source moves on.
    private func sourceCandidate(_ package: PluginPackage) -> PluginPackage {
        PluginSourceCatalog.updateCandidate(for: package, among: sourced) ?? package
    }

    private func worksOn(_ package: PluginPackage) -> String? {
        PluginsSurfacePresentation.worksOnSummary(PluginManifestConverter.manifest(from: package).worksOn)
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
                Button("Add source") { isAddingSource.toggle() }
                    .controlSize(.small)
            }
            if isAddingSource {
                HStack {
                    TextField("https://github.com/org/plugins, org/plugins, or a folder path", text: $sourceInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSource)
                    Button("Choose folder…", action: chooseSourceFolder).controlSize(.small)
                    Button("Import file…", action: importPluginFile).controlSize(.small)
                    Button("Add", action: addSource).controlSize(.small)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusError)
            }
            let current = state
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    group("Action needed", current.actionNeeded)
                    group("Ready", current.ready)
                    group("Available", current.available)
                    sourcesSection
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
            refreshApprovalRecords()
            if catalog.packages.isEmpty {
                catalog.loadApprovedCapabilities()
                onCatalogChanged()
            }
            refreshStatuses()
            loadSources()
            revealSelectedPackage()
        }
        .onChange(of: selectedPackageID) { _, _ in revealSelectedPackage() }
        .onReceive(NotificationCenter.default.publisher(for: .capabilityApprovalsChanged)) { _ in
            refreshApprovalRecords()
        }
        .onReceive(NotificationCenter.default.publisher(for: .capabilityCatalogPersistenceChanged)) { notification in
            // A library change (an import, a removal elsewhere) needs
            // a reload; a workspace-scoped change is already observed through
            // the model.
            guard (notification.object as? CapabilityCatalogPersistenceChange)?.workspaceID == nil else { return }
            catalog.loadApprovedCapabilities(announceLibraryMutations: false)
        }
    }

    private func revealSelectedPackage() {
        guard let id = selectedPackageID else { return }
        expanded.insert(id)
        selectedPackageID = nil
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
                if let verb = row.verb {
                    Button(verb == .add ? "Add" : "Update") { verb == .add ? add(row.id) : update(row.id) }
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
            if row.isEnabled {
                HStack {
                    Toggle("On in this workspace", isOn: Binding(
                        get: { confirming != .turnOff(packageID: package.id) },
                        set: { if !$0 { confirming = .turnOff(packageID: package.id) } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Spacer()
                    if row.isRemovable {
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

    // MARK: - Sources

    @ViewBuilder
    private var sourcesSection: some View {
        if !sources.isEmpty {
            Text("Sources")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            ForEach(sources) { source in
                HStack(spacing: 8) {
                    Image(systemName: source.kind == .git ? "arrow.triangle.branch" : "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName).font(Stanford.ui(13, weight: .semibold))
                        Text(source.location)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if fetchingSourceIDs.contains(source.id) {
                        Text("Fetching…").font(Stanford.caption(11)).foregroundStyle(.secondary)
                    } else if source.kind == .git {
                        Button("Update") { fetch(source) }.controlSize(.small)
                    }
                    Button("Remove", role: .destructive) { removeSource(source) }.controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func loadSources() {
        let store = PluginSourceStore()
        sources = store.sources()
        sourced = sources.flatMap { PluginSourceCatalog.plugins(in: $0, store: store) }
    }

    private func addSource() {
        guard let source = PluginSource.make(from: sourceInput) else {
            errorMessage = "Enter an https or ssh git URL, owner/repo, or a folder path."
            return
        }
        errorMessage = nil
        let store = PluginSourceStore()
        do {
            try store.save(store.sources().filter { $0.id != source.id } + [source])
        } catch {
            errorMessage = "Couldn't save the source: \(error.localizedDescription)"
            return
        }
        sourceInput = ""
        isAddingSource = false
        loadSources()
        if source.kind == .git { fetch(source) }
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceInput = url.path
        addSource()
    }

    /// One plugin JSON file rather than a source: it goes into the library as
    /// a draft and then shows under Available.
    private func importPluginFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        errorMessage = nil
        do {
            let package = try CapabilityCatalogActionService().importFile(
                at: url, workspace: workspace, traceID: AuditTrace.make("plugins-import")
            )
            isAddingSource = false
            catalog.loadApprovedCapabilities(announceLibraryMutations: false)
            expanded.insert(package.id)
            onCatalogChanged()
        } catch {
            errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func fetch(_ source: PluginSource) {
        fetchingSourceIDs.insert(source.id)
        Task { @MainActor in
            defer { fetchingSourceIDs.remove(source.id) }
            do {
                let store = PluginSourceStore()
                try await PluginSourceFetcher().fetch(source, store: store)
                var updated = store.sources()
                if let index = updated.firstIndex(where: { $0.id == source.id }) {
                    updated[index].lastFetchedAt = Date()
                    try? store.save(updated)
                }
                loadSources()
            } catch {
                errorMessage = "Couldn't fetch \(source.displayName): \(error)"
            }
        }
    }

    private func removeSource(_ source: PluginSource) {
        try? PluginSourceStore().remove(source)
        loadSources()
    }

    // MARK: - Actions

    private func add(_ packageID: String) {
        guard let package = packages.first(where: { $0.id == packageID })
            ?? sourced.first(where: { $0.package.id == packageID && $0.problem == nil })?.package
        else { return }
        errorMessage = nil
        do {
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

    private func update(_ packageID: String) {
        guard let package = packages.first(where: { $0.id == packageID }).map(sourceCandidate) else { return }
        errorMessage = nil
        do {
            try CapabilityCatalogActionService().update(
                package,
                workspace: workspace,
                modelContext: modelContext,
                policyContext: policyContext,
                traceID: AuditTrace.make("plugins-update")
            )
            onCatalogChanged()
            refreshStatuses()
        } catch {
            errorMessage = "Couldn't update \(package.name): \(error.localizedDescription)"
        }
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
