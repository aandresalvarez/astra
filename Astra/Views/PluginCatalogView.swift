import SwiftUI
import SwiftData
import ASTRACore

enum CatalogFocus: String {
    case all
    case skills
    case connectors
    case tools
    case templates

    var title: String {
        switch self {
        case .all: "Manage Capabilities"
        case .skills: "Manage Capabilities"
        case .connectors: "Manage Capabilities"
        case .tools: "Manage Capabilities"
        case .templates: "Manage Capabilities"
        }
    }

    var subtitle: String {
        switch self {
        case .all: "Approved capabilities for this workspace"
        case .skills: "Approved capabilities with skills"
        case .connectors: "Approved capabilities with connectors"
        case .tools: "Approved capabilities with tools"
        case .templates: "Approved capabilities with templates"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .all: "Search capabilities..."
        case .skills: "Search skill capabilities..."
        case .connectors: "Search connector capabilities..."
        case .tools: "Search tool capabilities..."
        case .templates: "Search template capabilities..."
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "No approved capabilities found"
        case .skills: "No approved skill capabilities found"
        case .connectors: "No approved connector capabilities found"
        case .tools: "No approved tool capabilities found"
        case .templates: "No approved template capabilities found"
        }
    }

    func matches(_ package: PluginPackage) -> Bool {
        switch self {
        case .all:
            true
        case .skills:
            !package.skills.isEmpty
        case .connectors:
            !package.connectors.isEmpty
        case .tools:
            !package.localTools.isEmpty
        case .templates:
            !package.templates.isEmpty
        }
    }
}

enum CapabilityManagementPresentation {
    case modal
    case embedded
}

struct CapabilityGalleryLayout {
    static func columnCount(for presentation: CapabilityManagementPresentation) -> Int {
        1
    }
}

private struct PluginCatalogPresentationState {
    let focusedPackages: [PluginPackage]
    let filteredPackages: [PluginPackage]
    let enabledCount: Int
    let categoryCounts: [String: Int]
    let visibleCategories: [String]
}

private struct CapabilityDetailSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let items: [CapabilityDetailItem]
}

private struct CapabilityDetailItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
}

private struct CapabilityConfigurationLink: Identifiable {
    let id: UUID
    let tab: ConfigureTab
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
}

struct PluginCatalogView: View {
    var workspace: Workspace
    var catalog: PluginCatalog
    var focus: CatalogFocus = .all
    var presentation: CapabilityManagementPresentation = .modal
    var focusedPackageID: String?
    var onInstall: ((PluginPackage) -> Void)?
    var onCatalogChanged: (() -> Void)?
    var onPackageFocusChanged: ((String?) -> Void)?
    var onEditElement: ((ConfigureTab, UUID) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.preflightCache) private var preflightCache
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]
    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]

    @State private var searchText = ""
    @State private var selectedCategory: String?
    @State private var installingPackage: PluginPackage?
    @State private var installError: String?
    @State private var removalCandidate: PluginPackage?
    @State private var removalError: String?
    @State private var showCreateWizard = false
    @State private var selectedPackageID: String?

    private var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    private var isEmbedded: Bool {
        if case .embedded = presentation { return true }
        return false
    }

    private var capabilityInventoryPackages: [PluginPackage] {
        CapabilityGalleryInventory.packages(catalogPackages: catalog.packages + PluginCatalog.builtInPackages)
    }

    private var galleryColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
            count: CapabilityGalleryLayout.columnCount(for: presentation)
        )
    }

    private var detailComponentColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 250, maximum: 390), spacing: 10, alignment: .top)
        ]
    }

    private var presentationState: PluginCatalogPresentationState {
        PerformanceTelemetry.measure(
            "catalog_state_build",
            thresholdMilliseconds: 15,
            fields: [
                "catalog_count": String(catalog.packages.count),
                "focus": focus.rawValue,
                "has_query": String(!searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                "category_filter": selectedCategory ?? "none"
            ]
        ) {
            let inventory = capabilityInventoryPackages
            let focused = inventory.filter { focus.matches($0) }
            var categoryCounts: [String: Int] = [:]
            var visibleCategories: [String] = []
            for package in focused {
                categoryCounts[package.category, default: 0] += 1
                if categoryCounts[package.category] == 1 {
                    visibleCategories.append(package.category)
                }
            }

            var filtered = focused
            if let selectedCategory {
                filtered = filtered.filter { $0.category == selectedCategory }
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !query.isEmpty {
                filtered = filtered.filter {
                    $0.name.lowercased().contains(query) ||
                    $0.description.lowercased().contains(query) ||
                    $0.tags.contains { $0.lowercased().contains(query) }
                }
            }

            let enabledCount = focused.reduce(0) { count, package in
                count + (packageState(package).isEnabled ? 1 : 0)
            }

            return PluginCatalogPresentationState(
                focusedPackages: focused,
                filteredPackages: filtered,
                enabledCount: enabledCount,
                categoryCounts: categoryCounts,
                visibleCategories: visibleCategories
            )
        }
    }

    private var activeFocusedPackageID: String? {
        selectedPackageID ?? focusedPackageID
    }

    private func focusedPackage(in packages: [PluginPackage]) -> PluginPackage? {
        guard let activeFocusedPackageID else { return nil }
        return packages.first { $0.id == activeFocusedPackageID }
    }

    private func openPackageEditor(_ packageID: String) {
        selectedPackageID = packageID
        onPackageFocusChanged?(packageID)
    }

    private func closePackageEditor() {
        selectedPackageID = nil
        onPackageFocusChanged?(nil)
    }

    var body: some View {
        let state = presentationState

        VStack(spacing: 0) {
            if let package = focusedPackage(in: state.focusedPackages) {
                packageEditorScreen(package)
            } else if activeFocusedPackageID != nil {
                missingFocusedPackageScreen
            } else {
                if !isEmbedded {
                    header(state)
                }
                searchAndActions
                categoryStrip(state)

                Divider()

                if state.filteredPackages.isEmpty {
                    Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(Stanford.ui(36))
                                .foregroundStyle(.quaternary)
                        Text(focus.emptyTitle)
                            .font(Stanford.body(15))
                            .foregroundStyle(.secondary)
                        if !searchText.isEmpty {
                            Text("Try a different search term")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: galleryColumns, alignment: .leading, spacing: 10) {
                            ForEach(state.filteredPackages) { package in
                                packageCard(package)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
        }
        .frame(width: isEmbedded ? nil : 740, height: isEmbedded ? nil : 600)
        .frame(
            maxWidth: isEmbedded ? .infinity : nil,
            maxHeight: isEmbedded ? .infinity : nil,
            alignment: .topLeading
        )
        .onAppear {
            selectedPackageID = focusedPackageID
            if catalog.packages.isEmpty {
                catalog.loadApprovedCapabilities()
                onCatalogChanged?()
            }
        }
        .onChange(of: focusedPackageID) { _, newValue in
            selectedPackageID = newValue
        }
        .sheet(isPresented: $showCreateWizard) {
            CapabilityCreationWizardView(workspace: workspace) { package, enableHere in
                createCapability(package, enableHere: enableHere)
            }
        }
        .sheet(item: $installingPackage) { package in
            PluginInstallSheet(
                package: package,
                workspace: workspace,
                onDismiss: { installingPackage = nil },
                onInstalled: { pkg in
                    installingPackage = nil
                    onInstall?(pkg)
                    catalog.loadApprovedCapabilities()
                    onCatalogChanged?()
                }
            )
        }
        .alert("Capability could not be installed", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
        }
        .alert("Remove Capability Package?", isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        ), presenting: removalCandidate) { package in
            Button("Cancel", role: .cancel) { removalCandidate = nil }
            Button("Remove", role: .destructive) {
                removalCandidate = nil
                removeCapabilityPackage(package)
            }
        } message: { package in
            Text("This removes \(package.name) from the app-local capability library and disables it in every workspace. Shared resources that are still used by another installed package are kept.")
        }
        .alert("Capability could not be removed", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        )) {
            Button("OK", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    // MARK: - Package Editor

    private func packageEditorScreen(_ package: PluginPackage) -> some View {
        let enabled = packageState(package).isEnabled

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    closePackageEditor()
                } label: {
                    Label("All capabilities", systemImage: "chevron.left")
                        .font(Stanford.body(13).weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Image(systemName: package.icon)
                    .font(Stanford.ui(18, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 36, height: 36)
                    .background(Stanford.lagunita.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name)
                        .font(Stanford.heading(20))
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)
                    Text(package.description.isEmpty ? package.contentSummary : package.description)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if enabled {
                    enabledStatusLabel

                    Button(role: .destructive) {
                        disableCapability(package)
                    } label: {
                        Label("Disable", systemImage: "minus.circle")
                            .font(Stanford.caption(12).weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    installButton(for: package)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                expandedDetail(package, enabled: enabled)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
            }
        }
    }

    private var missingFocusedPackageScreen: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(Stanford.ui(34))
                .foregroundStyle(.quaternary)
            Text("Capability not found")
                .font(Stanford.body(15).weight(.semibold))
            Text("This package may no longer be in the approved capability library.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            Button {
                closePackageEditor()
            } label: {
                Label("All capabilities", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private func header(_ state: PluginCatalogPresentationState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 36, height: 36)
                .background(Stanford.lagunita.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(focus.title)
                    .font(Stanford.heading(20))
                    .foregroundStyle(Stanford.black)
                Text("\(state.focusedPackages.count) available \u{00B7} \(state.enabledCount) enabled \u{00B7} \(focus.subtitle)")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            newCapabilityButton

            if !isEmbedded {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: - Search

    private var searchAndActions: some View {
        HStack(spacing: 10) {
            searchField

            if isEmbedded {
                newCapabilityButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, isEmbedded ? 14 : 0)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Stanford.ui(13))
                .foregroundStyle(.tertiary)
            TextField(focus.searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(Stanford.body(14))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Stanford.ui(13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    private var newCapabilityButton: some View {
        Button {
            showCreateWizard = true
        } label: {
            Label("New Capability", systemImage: "plus")
                .font(Stanford.body(13))
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }

    // MARK: - Category Strip

    private func categoryStrip(_ state: PluginCatalogPresentationState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryChip(nil, label: "All", count: state.focusedPackages.count)
                ForEach(state.visibleCategories, id: \.self) { cat in
                    categoryChip(cat, label: cat, count: state.categoryCounts[cat] ?? 0)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }

    private func categoryChip(_ category: String?, label: String, count: Int) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(Stanford.body(13))
                    .fontWeight(isSelected ? .semibold : .regular)
                Text("\(count)")
                    .font(Stanford.caption(10))
                    .foregroundStyle(isSelected ? Stanford.lagunita.opacity(0.7) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Stanford.lagunita.opacity(0.12) : Color.primary.opacity(0.04))
            .foregroundStyle(isSelected ? Stanford.lagunita : Stanford.black)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? Stanford.lagunita.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Package Card

    private func packageCard(_ package: PluginPackage) -> some View {
        let state = packageState(package)
        let enabled = state.isEnabled
        let needsSetup = requiresSetupFlow(package)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                openPackageEditor(package.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: package.icon)
                        .font(Stanford.ui(18, weight: .medium))
                        .foregroundStyle(enabled ? .secondary : Stanford.lagunita)
                        .frame(width: 36, height: 36)
                        .background((enabled ? Color.secondary : Stanford.lagunita).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(package.name)
                                .font(Stanford.body(14))
                                .fontWeight(.semibold)
                                .foregroundStyle(enabled ? .secondary : Stanford.black)
                                .lineLimit(1)

                            if needsSetup {
                                Image(systemName: "key.fill")
                                    .font(Stanford.ui(10))
                                    .foregroundStyle(Stanford.poppy.opacity(0.7))
                                    .help("Requires configuration")
                            }
                        }

                        Text(package.description)
                            .font(Stanford.caption(12))
                            .foregroundStyle(enabled ? Color.secondary.opacity(0.6) : .secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Text(package.category)
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(enabled ? Stanford.coolGrey.opacity(0.55) : Stanford.coolGrey)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())

                if needsSetup {
                    Text("Setup required")
                        .font(Stanford.caption(10).weight(.medium))
                        .foregroundStyle(Stanford.poppy)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Stanford.poppy.opacity(0.08))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)

                if enabled {
                    HStack(spacing: 8) {
                        enabledStatusLabel

                        Button {
                            disableCapability(package)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "minus.circle")
                                    .font(Stanford.ui(12))
                                Text("Disable")
                                    .font(Stanford.caption(12))
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(Stanford.cardinalRed)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Stanford.cardinalRed.opacity(0.06))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    installButton(for: package)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(enabled ? Color.primary.opacity(0.02) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    enabled ? Color.primary.opacity(0.04) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    private var enabledStatusLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(Stanford.ui(12))
            Text("Enabled")
                .font(Stanford.caption(11).weight(.medium))
        }
        .foregroundStyle(Stanford.paloAltoGreen)
        .fixedSize()
    }

    private func disableCapability(_ package: PluginPackage) {
        let state = packageState(package)
        let traceID = AuditTrace.make("capability-disable")
        AppLogger.breadcrumb(action: "disable_capability_clicked", category: "Capabilities", traceID: traceID, fields: [
            "source": "configure",
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString
        ])
        AppLogger.audit(.capabilityDisableStarted, category: "Capabilities", fields: [
            "source": "disable",
            "trace_id": traceID,
            "package_id": package.id,
            "package_name": package.name,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString,
            "skills_count": String(state.skillIDStrings.count),
            "connectors_count": String(state.connectorIDStrings.count),
            "tools_count": String(state.toolIDStrings.count)
        ])

        let result = CapabilityActivationDisabler().disable(
            package,
            in: workspace,
            capabilities: capabilities,
            modelContext: modelContext,
            availablePackages: capabilityInventoryPackages
        )
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
            "source": "configure",
            "trace_id": traceID,
            "package_id": package.id,
            "package_name": package.name,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString,
            "skills_count": String(state.skillIDStrings.count),
            "connectors_count": String(state.connectorIDStrings.count),
            "tools_count": String(state.toolIDStrings.count),
            "removed_workspace_skills_count": String(result.removedWorkspaceSkillIDs.count),
            "removed_workspace_connectors_count": String(result.removedWorkspaceConnectorIDs.count),
            "enabled_capability_ids": CapabilityAudit.compactNames(workspace.enabledCapabilityIDs)
        ])
        catalog.loadApprovedCapabilities()
        onCatalogChanged?()
    }

    private func installButton(for package: PluginPackage) -> some View {
        let needsSetup = requiresSetupFlow(package)

        return Button {
            if needsSetup {
                AppLogger.breadcrumb(action: "open_capability_setup", category: "Capabilities", fields: [
                    "source": "configure",
                    "package_id": package.id,
                    "package_name": package.name,
                    "workspace_id": workspace.id.uuidString
                ])
                installingPackage = package
            } else {
                installCapability(package)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(Stanford.ui(12))
                Text("Enable")
                    .font(Stanford.caption(12))
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Stanford.lagunita)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(needsSetup ? "Configure and validate \(package.name)" : "Enable \(package.name)")
    }

    private func installCapability(
        _ package: PluginPackage,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:]
    ) {
        let traceID = AuditTrace.make("capability-enable")
        AppLogger.breadcrumb(action: "enable_capability_clicked", category: "Capabilities", traceID: traceID, fields: [
            "source": "configure",
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString,
            "credential_input_count": String(credentialInputs.count),
            "config_input_count": String(configInputs.count),
            "base_url_override_count": String(baseURLOverrides.count)
        ])
        do {
            try CapabilityInstaller().install(
                package,
                into: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides,
                traceID: traceID
            )
            onInstall?(package)
            catalog.loadApprovedCapabilities()
            onCatalogChanged?()
        } catch {
            installError = error.localizedDescription
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": "configure",
                "trace_id": traceID,
                "package_id": package.id,
                "package_name": package.name,
                "package_version": package.version,
                "workspace_id": workspace.id.uuidString,
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }

    private func createCapability(_ package: PluginPackage, enableHere: Bool) {
        let traceID = AuditTrace.make(enableHere ? "capability-create-enable" : "capability-create")
        AppLogger.breadcrumb(action: enableHere ? "create_and_enable_capability_clicked" : "create_capability_clicked", category: "Capabilities", traceID: traceID, fields: [
            "source": enableHere ? "create_and_enable" : "create_install_only",
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString
        ])
        do {
            if enableHere {
                try CapabilityInstaller().install(
                    package,
                    into: workspace,
                    modelContext: modelContext,
                    traceID: traceID
                )
                onInstall?(package)
            } else {
                try CapabilityLibrary().install(package)
            }
            catalog.loadApprovedCapabilities()
            onCatalogChanged?()
        } catch {
            installError = error.localizedDescription
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": enableHere ? "create_and_enable" : "create_install_only",
                "trace_id": traceID,
                "package_id": package.id,
                "package_name": package.name,
                "package_version": package.version,
                "workspace_id": workspace.id.uuidString,
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }

    private func removeCapabilityPackage(_ package: PluginPackage) {
        do {
            _ = try CapabilityUninstaller().remove(package, modelContext: modelContext)
            if activeFocusedPackageID == package.id {
                closePackageEditor()
            }
            catalog.loadApprovedCapabilities()
            onCatalogChanged?()
        } catch {
            removalError = error.localizedDescription
        }
    }

    // MARK: - Prerequisite Section

    private func prerequisiteSection(_ package: PluginPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text("Requirements")
                    .font(Stanford.caption(11))
                    .fontWeight(.semibold)
                    .foregroundStyle(Stanford.lagunita)
                Spacer()
                Text("\(package.prerequisites.count) checks")
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 4) {
                ForEach(package.prerequisites) { prereq in
                    PluginCatalogPrereqBadge(
                        prerequisite: prereq,
                        cache: preflightCache,
                        onStatusChange: { _ in }
                    )
                }
            }
        }
    }

    // MARK: - Expanded Detail

    private func expandedDetail(_ package: PluginPackage, enabled: Bool) -> some View {
        let state = packageState(package)
        let detailSections = capabilityDetailSections(package)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                // Show local checks first when the package declares prerequisites.
                if !package.prerequisites.isEmpty {
                    prerequisiteSection(package)
                }

                capabilityDetailOverview(package)

                if !detailSections.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Capability contents")
                                .font(Stanford.caption(11).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            Spacer()

                            Text(capabilityContentsSummary(package))
                                .font(Stanford.caption(10))
                                .foregroundStyle(.tertiary)
                        }

                        LazyVGrid(columns: detailComponentColumns, alignment: .leading, spacing: 10) {
                            ForEach(detailSections) { section in
                                capabilityDetailSectionCard(section)
                            }
                        }
                    }
                }

                if enabled, onEditElement != nil {
                    capabilityConfigurationLinks(state)
                }

                capabilityRemovalSection(package)

                // Enable button in expanded view too
                if !enabled {
                    HStack {
                        Spacer()
                        installButton(for: package)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func requiresSetupFlow(_ package: PluginPackage) -> Bool {
        package.requiresSetup || !package.prerequisites.isEmpty
    }

    private func capabilityDetailOverview(_ package: PluginPackage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            overviewPill(icon: "person.circle", title: "Source", value: package.author)
            overviewPill(icon: "tag", title: "Version", value: "v\(package.version)")

            if requiresSetupFlow(package) {
                overviewPill(
                    icon: "key.fill",
                    title: "Setup",
                    value: "Required",
                    color: Stanford.poppy
                )
            } else {
                overviewPill(
                    icon: "checkmark.seal",
                    title: "Setup",
                    value: "Ready",
                    color: Stanford.paloAltoGreen
                )
            }

            Spacer(minLength: 0)
        }
    }

    private func overviewPill(
        icon: String,
        title: String,
        value: String,
        color: Color = Stanford.coolGrey
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Stanford.ui(9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(value)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func capabilityContentsSummary(_ package: PluginPackage) -> String {
        let parts: [String] = [
            countPhrase(package.skills.count, singular: "instruction", plural: "instructions"),
            countPhrase(package.connectors.count, singular: "connector", plural: "connectors"),
            countPhrase(package.localTools.count, singular: "tool", plural: "tools"),
            countPhrase(package.browserAdapters.count, singular: "browser adapter", plural: "browser adapters"),
            countPhrase(package.templates.count, singular: "template", plural: "templates")
        ].filter { !$0.hasPrefix("0 ") }

        return parts.isEmpty ? "No declared resources" : parts.joined(separator: " · ")
    }

    private func countPhrase(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private func capabilityDetailSections(_ package: PluginPackage) -> [CapabilityDetailSection] {
        var sections: [CapabilityDetailSection] = []

        if !package.skills.isEmpty {
            sections.append(CapabilityDetailSection(
                id: "skills",
                title: "Instructions",
                subtitle: "Agent behavior and tool permissions",
                icon: "puzzlepiece.extension",
                color: Stanford.lagunita,
                items: package.skills.enumerated().map { index, skill in
                    CapabilityDetailItem(
                        id: "skill-\(index)-\(skill.name)",
                        icon: skill.icon,
                        title: skill.name,
                        detail: "\(skill.allowedTools.count) permission\(skill.allowedTools.count == 1 ? "" : "s")"
                    )
                }
            ))
        }

        if !package.connectors.isEmpty {
            sections.append(CapabilityDetailSection(
                id: "connectors",
                title: "Connectors",
                subtitle: "Accounts and external services",
                icon: "bolt.horizontal.circle",
                color: Stanford.paloAltoGreen,
                items: package.connectors.enumerated().map { index, connector in
                    CapabilityDetailItem(
                        id: "connector-\(index)-\(connector.name)",
                        icon: connector.icon,
                        title: connector.name,
                        detail: connectorDetailText(connector)
                    )
                }
            ))
        }

        if !package.localTools.isEmpty {
            sections.append(CapabilityDetailSection(
                id: "tools",
                title: "Local Tools",
                subtitle: "Commands ASTRA can run for this capability",
                icon: "terminal",
                color: Stanford.poppy,
                items: package.localTools.enumerated().map { index, tool in
                    CapabilityDetailItem(
                        id: "tool-\(index)-\(tool.name)",
                        icon: tool.icon,
                        title: tool.name,
                        detail: tool.command
                    )
                }
            ))
        }

        if !package.browserAdapters.isEmpty {
            sections.append(CapabilityDetailSection(
                id: "browser",
                title: "Browser",
                subtitle: "Site-specific browser helpers",
                icon: "globe",
                color: Stanford.sky,
                items: package.browserAdapters.enumerated().map { index, adapter in
                    CapabilityDetailItem(
                        id: "browser-\(index)-\(adapter)",
                        icon: "safari",
                        title: browserAdapterDisplayName(adapter),
                        detail: "site automation"
                    )
                }
            ))
        }

        if !package.templates.isEmpty {
            sections.append(CapabilityDetailSection(
                id: "templates",
                title: "Templates",
                subtitle: "Reusable task flows",
                icon: "rectangle.3.group",
                color: Stanford.cardinalRed,
                items: package.templates.enumerated().map { index, template in
                    CapabilityDetailItem(
                        id: "template-\(index)-\(template.name)",
                        icon: template.icon,
                        title: template.name,
                        detail: templatePhaseSummary(template)
                    )
                }
            ))
        }

        return sections
    }

    private func connectorDetailText(_ connector: PluginConnector) -> String {
        let auth = connector.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if !baseURL.isEmpty {
            return auth.isEmpty ? baseURL : "\(auth) · \(baseURL)"
        }
        return auth.isEmpty ? connector.serviceType : auth
    }

    private func capabilityDetailSectionCard(_ section: CapabilityDetailSection) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: section.icon)
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(section.color)
                    .frame(width: 28, height: 28)
                    .background(section.color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(section.title)
                            .font(Stanford.body(12).weight(.semibold))
                            .foregroundStyle(Stanford.black)
                        Text("\(section.items.count)")
                            .font(Stanford.caption(9).weight(.semibold))
                            .foregroundStyle(section.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(section.color.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    Text(section.subtitle)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(section.items) { item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: item.icon)
                            .font(Stanford.ui(10, weight: .medium))
                            .foregroundStyle(section.color.opacity(0.8))
                            .frame(width: 14, height: 14)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(Stanford.caption(11).weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(item.detail)
                                .font(Stanford.caption(10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(section.color.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func capabilityRemovalSection(_ package: PluginPackage) -> some View {
        let sourceKind = package.sourceMetadata?.kind ?? "local"

        if sourceKind == "built-in" {
            Divider().opacity(0.35)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text("Built-in capabilities stay in the catalog. Disable this capability per workspace when you do not want it active.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if sourceKind == "local" || sourceKind == "remote" {
            Divider().opacity(0.35)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library Package")
                        .font(Stanford.caption(11))
                        .fontWeight(.semibold)
                    Text("Remove from the app-local catalog and detach package-owned resources.")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    removalCandidate = package
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(Stanford.caption(11).weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove \(package.name) from the capability library")
            }
        }
    }

    @ViewBuilder
    private func capabilityConfigurationLinks(_ state: CapabilityPackageState) -> some View {
        let links = capabilityConfigurationLinkItems(state)

        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().opacity(0.35)

                HStack(alignment: .firstTextBaseline) {
                    Text("Configure resources")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer()

                    Text("\(links.count) editable")
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 360), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                    ForEach(links) { link in
                        capabilityConfigurationLinkCard(link)
                    }
                }
            }
        }
    }

    private func capabilityConfigurationLinkItems(_ state: CapabilityPackageState) -> [CapabilityConfigurationLink] {
        let skillLinks = state.linkedSkills.map { skill in
            CapabilityConfigurationLink(
                id: skill.id,
                tab: .skills,
                title: skill.name.isEmpty ? "Untitled Skill" : skill.name,
                subtitle: "Instructions and permissions",
                icon: skill.icon,
                color: ConfigureTab.skills.color
            )
        }

        let connectorLinks = state.linkedConnectors.map { connector in
            CapabilityConfigurationLink(
                id: connector.id,
                tab: .connectors,
                title: connector.name.isEmpty ? "Untitled Connector" : connector.name,
                subtitle: "Account and service",
                icon: connector.icon,
                color: ConfigureTab.connectors.color
            )
        }

        let toolLinks = state.linkedTools.map { tool in
            CapabilityConfigurationLink(
                id: tool.id,
                tab: .tools,
                title: tool.name.isEmpty ? "Untitled Tool" : tool.name,
                subtitle: "Local command",
                icon: tool.icon,
                color: ConfigureTab.tools.color
            )
        }

        return skillLinks + connectorLinks + toolLinks
    }

    private func capabilityConfigurationLinkCard(_ link: CapabilityConfigurationLink) -> some View {
        Button {
            onEditElement?(link.tab, link.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: link.icon)
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(link.color)
                    .frame(width: 24, height: 24)
                    .background(link.color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(link.title)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(link.subtitle)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                        .font(Stanford.ui(11, weight: .semibold))
                    Text("Edit")
                        .font(Stanford.caption(10).weight(.semibold))
                }
                .foregroundStyle(Stanford.lagunita)
                .help("Edit \(link.title)")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        )
    }

    private func browserAdapterDisplayName(_ adapter: String) -> String {
        switch BrowserSiteAdapterID.normalized(adapter) {
        case BrowserSiteAdapterID.googleDrive:
            return "Google Drive browser"
        case BrowserSiteAdapterID.github:
            return "GitHub browser"
        case .some(let normalized):
            return normalized
        case .none:
            return adapter.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func templatePhaseSummary(_ template: PluginTemplate) -> String {
        var phases = ["main"]
        if !template.beforeGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phases.insert("before", at: 0)
        }
        if !template.afterGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phases.append("after")
        }
        return phases.joined(separator: " · ")
    }

    private func packageState(_ package: PluginPackage) -> CapabilityPackageState {
        CapabilityPackageState(
            package: package,
            workspace: workspace,
            capabilities: capabilities
        )
    }
}

// MARK: - Install Setup Sheet

private struct PluginInstallValidationResult: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var passed: Bool
}

private struct PluginInstallValidationSecretStore: SecretStore {
    var credentials: [String: String]

    func load(key: String, entityID _: String) -> String? {
        credentials[key] ?? credentials[key.uppercased()]
    }

    @discardableResult
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool {
        false
    }

    @discardableResult
    func delete(key _: String, entityID _: String) -> Bool {
        false
    }

    func deleteAll(entityID _: String) {}

    func exists(key: String, entityID _: String) -> Bool {
        load(key: key, entityID: "") != nil
    }
}

struct PluginInstallSheet: View {
    let package: PluginPackage
    let workspace: Workspace
    let onDismiss: () -> Void
    let onInstalled: (PluginPackage) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var credentialValues: [String: String] = [:]
    @State private var configValues: [String: String] = [:]
    @State private var baseURLValues: [String: String] = [:]
    @State private var installError: String?
    @State private var validationResults: [PluginInstallValidationResult] = []
    @State private var validationPassed = false
    @State private var isValidatingSetup = false
    @State private var lastValidationTraceID: String?

    private let validationPreflightCache = PreflightCache()

    private var allConnectorHints: [(connector: PluginConnector, credentials: [PluginConnector.CredentialHint], configs: [PluginConnector.ConfigHint])] {
        package.connectors.map { ($0, $0.credentialHints, $0.configHints) }
    }

    private var requiresValidation: Bool {
        package.requiresSetup || !package.prerequisites.isEmpty
    }

    private var hasRequiredEmpty: Bool {
        // At least one credential field should be filled for each connector
        for conn in package.connectors {
            for hint in conn.credentialHints {
                if (credentialValues[hint.key] ?? "").isEmpty {
                    return true
                }
            }
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: package.icon)
                    .font(Stanford.ui(22, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 44, height: 44)
                    .background(Stanford.lagunita.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable \(package.name)")
                        .font(Stanford.heading(18))
                        .foregroundStyle(Stanford.black)
                    Text(package.description)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    setupStepperSection

                    // Configuration fields per connector
                    ForEach(package.connectors, id: \.name) { connector in
                        connectorSetupSection(connector)
                    }

                    validationStatusSection
                }
                .padding(20)
            }

            Divider()

            // Actions
            HStack {
                if requiresValidation {
                    HStack(spacing: 5) {
                        Image(systemName: validationPassed ? "checkmark.circle.fill" : "info.circle")
                            .font(Stanford.ui(12))
                        Text(validationPassed ? "Ready to enable" : "Validate first")
                            .font(Stanford.caption(11))
                    }
                    .foregroundStyle(validationPassed ? Stanford.paloAltoGreen : Stanford.coolGrey)
                } else if hasRequiredEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(Stanford.ui(12))
                        Text("You can fill in credentials later in the Connector editor")
                            .font(Stanford.caption(11))
                    }
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                if requiresValidation {
                    Button {
                        Task { await validateSetup() }
                    } label: {
                        HStack(spacing: 6) {
                            if isValidatingSetup {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.shield")
                            }
                            Text(isValidatingSetup ? "Validating" : "Validate Connection")
                        }
                    }
                    .disabled(isValidatingSetup)
                    .help("Run the same connector and CLI checks ASTRA uses before tasks run.")
                }

                Button("Enable") {
                    installCapability()
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .keyboardShortcut(.defaultAction)
                .disabled(requiresValidation && !validationPassed)
                .help(requiresValidation && !validationPassed
                      ? "Validate the setup successfully before enabling this capability."
                      : "Enable \(package.name)")
            }
            .padding(20)
        }
        .frame(width: 500, height: 560)
        .onAppear {
            // Pre-populate base URLs from connector defaults
            for conn in package.connectors {
                if !conn.baseURL.isEmpty {
                    baseURLValues[conn.name] = conn.baseURL
                }
            }
        }
        .alert("Capability could not be installed", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
        }
    }

    private func installCapability() {
        guard !requiresValidation || validationPassed else {
            installError = "Validate the connection successfully before enabling this capability."
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": "setup_sheet",
                "result": "validation_required",
                "package_id": package.id,
                "package_name": package.name,
                "package_version": package.version,
                "workspace_id": workspace.id.uuidString
            ], level: .warning)
            return
        }
        let traceID = lastValidationTraceID ?? AuditTrace.make("capability-setup")
        AppLogger.breadcrumb(action: "enable_capability_setup_submitted", category: "Capabilities", traceID: traceID, fields: [
            "source": "setup_sheet",
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString,
            "credential_input_count": String(credentialValues.count),
            "config_input_count": String(configValues.count),
            "base_url_override_count": String(baseURLValues.count)
        ])
        do {
            try CapabilityInstaller().install(
                package,
                into: workspace,
                modelContext: modelContext,
                credentialInputs: credentialValues,
                configInputs: configValues,
                baseURLOverrides: baseURLValues,
                traceID: traceID
            )
            onInstalled(package)
        } catch {
            installError = error.localizedDescription
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": "setup_sheet",
                "trace_id": traceID,
                "package_id": package.id,
                "package_name": package.name,
                "package_version": package.version,
                "workspace_id": workspace.id.uuidString,
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }

    private var setupStepperSection: some View {
        HStack(spacing: 8) {
            setupStep(number: "1", title: "Fill", detail: package.connectors.isEmpty ? "No fields" : "Required fields")
            setupStep(number: "2", title: "Validate", detail: package.prerequisites.isEmpty ? "Connection" : "Setup checks")
            setupStep(number: "3", title: "Enable", detail: "Ready for chat")
        }
    }

    private func setupStep(number: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(Stanford.caption(10).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Stanford.lagunita)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(detail)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var validationStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: validationPassed ? "checkmark.seal.fill" : "checkmark.shield")
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(validationPassed ? Stanford.paloAltoGreen : Stanford.lagunita)
                    .frame(width: 26, height: 26)
                    .background((validationPassed ? Stanford.paloAltoGreen : Stanford.lagunita).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Validation")
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                    Text("Run one quick check before enabling.")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            if validationResults.isEmpty {
                Text("Fill required fields, then validate.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 1) {
                    ForEach(validationResults) { result in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(Stanford.ui(12, weight: .semibold))
                                .foregroundStyle(result.passed ? Stanford.paloAltoGreen : Stanford.cardinalRed)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(Stanford.caption(12).weight(.semibold))
                                    .foregroundStyle(Stanford.black)
                                Text(result.detail)
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
                .background(Stanford.fog.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(validationPassed ? Stanford.paloAltoGreen.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @MainActor
    private func validateSetup() async {
        guard !isValidatingSetup else { return }
        let traceID = AuditTrace.make("capability-validate")
        isValidatingSetup = true
        validationPassed = false
        lastValidationTraceID = traceID
        validationResults = []
        AppLogger.breadcrumb(action: "validate_capability_setup_clicked", category: "Capabilities", traceID: traceID, fields: [
            "source": "setup_sheet",
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString,
            "credential_input_count": String(filledCredentialInputCount),
            "config_input_count": String(filledConfigInputCount),
            "base_url_override_count": String(baseURLValues.count)
        ])
        AppLogger.audit(.validationStarted, category: "Capabilities", fields: [
            "source": "setup_sheet",
            "trace_id": traceID,
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString
        ])

        var results: [PluginInstallValidationResult] = []

        for prerequisite in package.prerequisites {
            let status = await validationPreflightCache.status(for: prerequisite)
            results.append(validationResult(for: prerequisite, status: status))
        }

        for connector in package.connectors {
            results += await validateConnector(connector, traceID: traceID)
        }

        if results.isEmpty {
            results.append(PluginInstallValidationResult(
                title: "Setup check",
                detail: "No external connection test is required for this capability.",
                passed: true
            ))
        }

        validationResults = results
        validationPassed = results.allSatisfy(\.passed)
        isValidatingSetup = false

        AppLogger.audit(validationPassed ? .validationPassed : .validationFailed, category: "Capabilities", fields: [
            "source": "setup_sheet",
            "trace_id": traceID,
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString,
            "result": validationPassed ? "passed" : "failed",
            "check_count": String(results.count),
            "failed_count": String(results.filter { !$0.passed }.count)
        ], level: validationPassed ? .info : .warning)
    }

    @MainActor
    private func validateConnector(_ pluginConnector: PluginConnector, traceID: String) async -> [PluginInstallValidationResult] {
        var results: [PluginInstallValidationResult] = []

        let missingCredentials = pluginConnector.credentialHints.compactMap { hint -> String? in
            let value = credentialValues[hint.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? hint.key : nil
        }
        if !missingCredentials.isEmpty {
            results.append(PluginInstallValidationResult(
                title: "\(pluginConnector.name) credentials",
                detail: "Missing \(missingCredentials.joined(separator: ", ")). Add the required values, then validate again.",
                passed: false
            ))
            return results
        }

        guard shouldRunConnectionTest(for: pluginConnector) else {
            if package.prerequisites.isEmpty {
                results.append(PluginInstallValidationResult(
                    title: "\(pluginConnector.name) setup",
                    detail: "No network connection test is defined for this connector. Required fields are present.",
                    passed: true
                ))
            }
            return results
        }

        let baseURL = resolvedBaseURL(for: pluginConnector)
        if isPlaceholderBaseURL(baseURL) {
            results.append(PluginInstallValidationResult(
                title: "\(pluginConnector.name) base URL",
                detail: "Replace the placeholder Base URL with your real service URL.",
                passed: false
            ))
            return results
        }

        let connector = validationConnector(from: pluginConnector)
        let store = PluginInstallValidationSecretStore(credentials: credentialValues)
        let testResult = await connector.testConnection(
            store: store,
            source: "capability_setup_validation",
            workspaceID: workspace.id,
            packageID: package.id,
            traceID: traceID
        )

        results.append(PluginInstallValidationResult(
            title: "\(pluginConnector.name) connection",
            detail: testResult.1,
            passed: testResult.0
        ))
        return results
    }

    private func validationConnector(from pluginConnector: PluginConnector) -> Connector {
        let connector = Connector(
            name: pluginConnector.name,
            serviceType: pluginConnector.serviceType,
            icon: pluginConnector.icon,
            connectorDescription: pluginConnector.description,
            baseURL: resolvedBaseURL(for: pluginConnector),
            authMethod: pluginConnector.authMethod
        )
        connector.notes = pluginConnector.notes
        connector.credentialKeys = pluginConnector.credentialHints.map(\.key)
        connector.credentialValues = Array(repeating: "", count: connector.credentialKeys.count)
        connector.configKeys = pluginConnector.configHints.map(\.key)
        connector.configValues = connector.configKeys.map { configValues[$0] ?? "" }
        if connector.isStanfordOutlookMail {
            connector.applyStanfordOutlookDefaults()
        }
        return connector
    }

    private func shouldRunConnectionTest(for connector: PluginConnector) -> Bool {
        if connector.serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gcloud" {
            return false
        }
        if !resolvedBaseURL(for: connector).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return connector.authMethod != "none" || !connector.credentialHints.isEmpty
    }

    private func resolvedBaseURL(for connector: PluginConnector) -> String {
        baseURLValues[connector.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? connector.baseURL
    }

    private func isPlaceholderBaseURL(_ value: String) -> Bool {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.isEmpty || lower.contains("yourcompany.") || lower.contains("your-company.")
    }

    private func validationResult(for prerequisite: CLIPrerequisite, status: HealthStatus) -> PluginInstallValidationResult {
        switch status {
        case .healthy(let path, let version):
            PluginInstallValidationResult(
                title: prerequisite.displayName,
                detail: "\(path) \(version.trimmingCharacters(in: .whitespacesAndNewlines))".trimmingCharacters(in: .whitespacesAndNewlines),
                passed: true
            )
        case .missingBinary:
            PluginInstallValidationResult(
                title: prerequisite.displayName,
                detail: "Not installed. \(prerequisite.installHint)",
                passed: false
            )
        case .unauthenticated(let detail):
            PluginInstallValidationResult(
                title: prerequisite.displayName,
                detail: "Needs login: \(detail). \(prerequisite.authHint ?? "")",
                passed: false
            )
        case .unresponsive(let detail):
            PluginInstallValidationResult(
                title: prerequisite.displayName,
                detail: "Did not respond: \(detail)",
                passed: false
            )
        }
    }

    private var filledCredentialInputCount: Int {
        credentialValues.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var filledConfigInputCount: Int {
        configValues.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private func resetValidation() {
        validationPassed = false
        lastValidationTraceID = nil
        validationResults = []
    }

    // MARK: - Connector Setup Section

    private func connectorSetupSection(_ connector: PluginConnector) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Connector header
            HStack(spacing: 8) {
                Image(systemName: connector.icon)
                    .font(Stanford.ui(14, weight: .medium))
                    .foregroundStyle(Stanford.paloAltoGreen)
                    .frame(width: 26, height: 26)
                    .background(Stanford.paloAltoGreen.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(connector.name)
                    .font(Stanford.body(14))
                    .fontWeight(.semibold)

                Text(connector.authMethod.replacingOccurrences(of: "_", with: " "))
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
            }

            // Base URL
            if !connector.baseURL.isEmpty {
                if isPlaceholderBaseURL(connector.baseURL) {
                    baseURLField(for: connector)
                } else {
                    DisclosureGroup {
                        baseURLField(for: connector)
                            .padding(.top, 4)
                    } label: {
                        Text("Advanced")
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Credentials
            if !connector.credentialHints.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: "key.fill")
                            .font(Stanford.ui(10))
                            .foregroundStyle(Stanford.poppy)
                        Text("Credentials")
                            .font(Stanford.caption(11))
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text("stored in Keychain")
                            .font(Stanford.caption(10))
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(connector.credentialHints, id: \.key) { hint in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hint.key)
                                .font(Stanford.ui(12, design: .monospaced))
                                .fontWeight(.medium)
                            SecureField(credentialPlaceholder(for: hint), text: Binding(
                                get: { credentialValues[hint.key] ?? "" },
                                set: {
                                    credentialValues[hint.key] = $0
                                    resetValidation()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(13, design: .monospaced))
                            .help(hint.hint)
                        }
                    }
                }
                .padding(12)
                .background(Stanford.poppy.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Stanford.poppy.opacity(0.12), lineWidth: 1)
                )
            }

            // Config
            if !connector.configHints.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(Stanford.ui(10))
                            .foregroundStyle(Stanford.lagunita)
                        Text("Configuration")
                            .font(Stanford.caption(11))
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(connector.configHints, id: \.key) { hint in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hint.key)
                                .font(Stanford.ui(12, design: .monospaced))
                                .fontWeight(.medium)
                            TextField(configPlaceholder(for: hint), text: Binding(
                                get: { configValues[hint.key] ?? "" },
                                set: {
                                    configValues[hint.key] = $0
                                    resetValidation()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(13, design: .monospaced))
                            .help(hint.hint)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func baseURLField(for connector: PluginConnector) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Base URL")
                .font(Stanford.caption(11))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            TextField(connector.baseURL, text: Binding(
                get: { baseURLValues[connector.name] ?? connector.baseURL },
                set: {
                    baseURLValues[connector.name] = $0
                    resetValidation()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(Stanford.ui(13, design: .monospaced))
        }
    }

    private func credentialPlaceholder(for hint: PluginConnector.CredentialHint) -> String {
        let key = hint.key.lowercased()
        if key.contains("email") {
            return "name@company.com"
        }
        if key.contains("token") || key.contains("key") {
            return "Paste API token"
        }
        return hint.hint
    }

    private func configPlaceholder(for hint: PluginConnector.ConfigHint) -> String {
        let key = hint.key.lowercased()
        if hint.isList || key.contains("projects") {
            return "ENG, OPS"
        }
        if key.contains("region") {
            return "us-central1"
        }
        if key.contains("project") {
            return "Project ID"
        }
        return hint.hint
    }
}
