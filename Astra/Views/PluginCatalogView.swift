import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ASTRACore
import ASTRAModels
import ASTRAPersistence

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

private struct CapabilityImportReview: Identifiable {
    let id = UUID()
    let report: CapabilityPackageValidationReport

    var sourceURL: URL? {
        report.sourceURL
    }
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
    @State private var selectedApprovalFilter: CapabilityCatalogApprovalFilter = .all
    @State private var selectedRiskFilter: CapabilityCatalogRiskFilter = .all
    @State private var showNeedsAttentionOnly = false
    @State private var showEnabledOnly = false
    @State private var installingPackage: PluginPackage?
    @State private var installError: String?
    @State private var removalCandidate: PluginPackage?
    @State private var disableCandidate: PluginPackage?
    @State private var removalError: String?
    @State private var approvalError: String?
    @State private var approvalRecords: [CapabilityApprovalRecord] = []
    @State private var showCreateWizard = false
    @State private var importReview: CapabilityImportReview?
    @State private var importError: String?
    @State private var selectedPackageID: String?
    @State private var showMCPInstallTargetSheet = false
    @State private var pastedMCPInstallTarget = ""
    @State private var mcpInstallRequest: MCPInstallChatRequest?
    @State private var approvalRecordsRefreshTask: Task<Void, Never>?
    @State private var approvalRecordsRefreshGeneration = 0

    private var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    private var catalogPolicyContext: CapabilityCatalogPolicyContext {
        PluginCatalogApprovalState.policyContext(
            workspace: workspace,
            approvalRecords: approvalRecords
        )
    }

    private var isEmbedded: Bool {
        if case .embedded = presentation { return true }
        return false
    }

    private var capabilityInventoryPackages: [PluginPackage] {
        CapabilityGalleryInventory.managementPackages(
            catalogPackages: catalog.packages + PluginCatalog.builtInPackages,
            capabilities: capabilities,
            workspace: workspace,
            policyContext: catalogPolicyContext
        )
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
            PluginCatalogPresentation.makeState(
                packages: capabilityInventoryPackages,
                focus: focus,
                selectedCategory: selectedCategory,
                approvalFilter: selectedApprovalFilter,
                riskFilter: selectedRiskFilter,
                showsNeedsAttentionOnly: showNeedsAttentionOnly,
                showsEnabledOnly: showEnabledOnly,
                searchText: searchText,
                policyContext: catalogPolicyContext,
                isEnabled: { packageState($0).isEnabled },
                requiresSetup: { requiresSetupFlow($0) }
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
                catalogScopeStrip(state)

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
                        capabilityGroupedList(state)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
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
            refreshApprovalRecords()
            selectedPackageID = focusedPackageID
            if catalog.packages.isEmpty {
                catalog.loadApprovedCapabilities()
                onCatalogChanged?()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .capabilityApprovalsChanged)) { _ in
            refreshApprovalRecords()
        }
        .onDisappear {
            cancelApprovalRecordsRefresh()
        }
        .onChange(of: focusedPackageID) { _, newValue in
            selectedPackageID = newValue
        }
        .sheet(isPresented: $showCreateWizard) {
            CapabilityCreationWizardView(workspace: workspace) { package, enableHere, sourceURL in
                createCapability(package, enableHere: enableHere, sourceURL: sourceURL)
            }
        }
        .sheet(item: $importReview) { review in
            CapabilityImportReviewSheet(
                review: review,
                onCancel: { importReview = nil },
                onImport: { report in
                    importCapability(report)
                }
            )
        }
        .sheet(isPresented: $showMCPInstallTargetSheet) {
            MCPInstallTargetPasteSheet(
                targetText: $pastedMCPInstallTarget,
                onCancel: { showMCPInstallTargetSheet = false },
                onReview: { reviewPastedMCPInstallTarget() }
            )
        }
        .sheet(item: $mcpInstallRequest) { request in
            CapabilityMCPInstallReviewSheet(
                request: request,
                workspace: workspace,
                onCancel: { mcpInstallRequest = nil },
                onInstalled: { package in
                    mcpInstallRequest = nil
                    selectedPackageID = package.id
                    onPackageFocusChanged?(package.id)
                    catalog.loadApprovedCapabilities()
                    onCatalogChanged?()
                }
            )
        }
        .sheet(item: $installingPackage) { package in
            CapabilityInstallSheetRouter(
                package: package,
                workspace: workspace,
                policyContext: catalogPolicyContext,
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
        .alert("Capability could not be imported", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
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
        .confirmationDialog(
            "Disable \(disableCandidate?.name ?? "capability")?",
            isPresented: Binding(
                get: { disableCandidate != nil },
                set: { if !$0 { disableCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: disableCandidate
        ) { package in
            Button("Disable", role: .destructive) {
                disableCandidate = nil
                disableCapability(package)
            }
            Button("Cancel", role: .cancel) { disableCandidate = nil }
        } message: { package in
            Text("This turns off \(package.name) in this workspace and removes the workspace-owned connectors and skills it added, clearing their saved credentials. Re-enabling it later requires entering those credentials again. Resources still used by another enabled capability are kept.")
        }
        .alert("Capability could not be removed", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        )) {
            Button("OK", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
        .alert("Capability approval could not be saved", isPresented: Binding(
            get: { approvalError != nil },
            set: { if !$0 { approvalError = nil } }
        )) {
            Button("OK", role: .cancel) { approvalError = nil }
        } message: {
            Text(approvalError ?? "")
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
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                CapabilityIconView(
                    presentation: .make(for: package),
                    size: 15,
                    color: Stanford.lagunita,
                    weight: .semibold
                )
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(package.name)
                        .font(Stanford.ui(14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(package.description.isEmpty ? package.contentSummary : package.description)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if enabled {
                    enabledStatusLabel

                    Button(role: .destructive) {
                        disableCandidate = package
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(Stanford.ui(14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(focus.title)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(state.focusedPackages.count) available \u{00B7} \(state.enabledCount) enabled \u{00B7} \(focus.subtitle)")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            importCapabilityButton
            newCapabilityMenu

            if !isEmbedded {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Search

    private var searchAndActions: some View {
        HStack(spacing: 10) {
            searchField

            if isEmbedded {
                importCapabilityButton
                newCapabilityMenu
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

    private var newCapabilityMenu: some View {
        Menu {
            Button {
                showCreateWizard = true
            } label: {
                Label(CapabilityCreationPresentation.blankCapabilityTitle, systemImage: "plus")
            }

            Button {
                showMCPInstallTargetSheet = true
            } label: {
                Label(CapabilityCreationPresentation.mcpCapabilityTitle, systemImage: "server.rack")
            }
        } label: {
            Label(CapabilityCreationPresentation.menuTitle, systemImage: "plus")
                .font(Stanford.body(13))
        }
        .menuStyle(.button)
        .fixedSize()
        .help(CapabilityCreationPresentation.menuHelp)
    }

    private var importCapabilityButton: some View {
        Button {
            openCapabilityImportPanel()
        } label: {
            Label(CapabilityImportPresentation.actionTitle, systemImage: "square.and.arrow.down")
                .font(Stanford.body(13))
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Import a local capability package JSON")
    }

    // MARK: - Catalog List

    private func catalogScopeStrip(_ state: PluginCatalogPresentationState) -> some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    catalogScopeChip(
                        label: "All",
                        count: state.focusedPackages.count,
                        isSelected: selectedCategory == nil &&
                            selectedApprovalFilter == .all &&
                            selectedRiskFilter == .all &&
                            !showNeedsAttentionOnly &&
                            !showEnabledOnly
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedCategory = nil
                            selectedApprovalFilter = .all
                            selectedRiskFilter = .all
                            showNeedsAttentionOnly = false
                            showEnabledOnly = false
                        }
                    }

                    catalogScopeChip(
                        label: "Needs attention",
                        count: needsAttentionCount(in: state.focusedPackages),
                        isSelected: showNeedsAttentionOnly
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedCategory = nil
                            showNeedsAttentionOnly = true
                            showEnabledOnly = false
                        }
                    }

                    catalogScopeChip(
                        label: "Enabled",
                        count: state.enabledCount,
                        isSelected: showEnabledOnly
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedCategory = nil
                            showEnabledOnly = true
                            showNeedsAttentionOnly = false
                        }
                    }

                    ForEach(state.visibleCategories, id: \.self) { category in
                        catalogScopeChip(
                            label: category,
                            count: state.categoryCounts[category] ?? 0,
                            isSelected: selectedCategory == category &&
                                !showNeedsAttentionOnly &&
                                !showEnabledOnly
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedCategory = category
                                showNeedsAttentionOnly = false
                                showEnabledOnly = false
                            }
                        }
                    }
                }
            }

            catalogFilterMenu
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func catalogScopeChip(
        label: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(Stanford.caption(12).weight(isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(Stanford.caption(10).weight(.medium))
                    // COL: the count is metadata, never the interactive accent. The
                    // chip's label tint + background carry the selected affordance.
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Stanford.lagunita : Color.primary)
            .background(shape.fill(isSelected ? Stanford.lagunita.opacity(0.10) : Color.primary.opacity(0.03)))
            .overlay {
                shape.stroke(isSelected ? Stanford.lagunita.opacity(0.24) : Color.primary.opacity(0.04), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var catalogFilterMenu: some View {
        Menu {
            Picker("Approval", selection: $selectedApprovalFilter) {
                ForEach(CapabilityCatalogApprovalFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            Picker("Risk", selection: $selectedRiskFilter) {
                ForEach(CapabilityCatalogRiskFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            Divider()
            Toggle("Needs attention", isOn: $showNeedsAttentionOnly)
            Toggle("Enabled only", isOn: $showEnabledOnly)
        } label: {
            Label(catalogFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
                .font(Stanford.caption(12).weight(.medium))
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Filter capabilities by approval, risk, setup, or enabled state")
    }

    private var catalogFilterLabel: String {
        var count = 0
        if selectedApprovalFilter != .all { count += 1 }
        if selectedRiskFilter != .all { count += 1 }
        if showNeedsAttentionOnly { count += 1 }
        if showEnabledOnly { count += 1 }
        return count == 0 ? "Filters" : "Filters \(count)"
    }

    private func needsAttentionCount(in packages: [PluginPackage]) -> Int {
        packages.filter { package in
            let decision = CapabilityCatalogPolicy.decision(for: package, context: catalogPolicyContext)
            return requiresSetupFlow(package) || decision.requiresApproval || !decision.warnings.isEmpty || !decision.blockers.isEmpty
        }.count
    }

    private func capabilityGroupedList(_ state: PluginCatalogPresentationState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(state.categorySections, id: \.category) { section in
                capabilityCategorySection(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func capabilityCategorySection(_ section: CapabilityCatalogCategorySection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
            // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
            HStack(alignment: .top, spacing: 6) {
                Text(section.category)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(section.packages.count)")
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(capabilityCategoryStatusSummary(section))
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                ForEach(Array(section.statusGroups.enumerated()), id: \.element.kind.rawValue) { statusIndex, group in
                    if section.statusGroups.count > 1 {
                        capabilityStatusSubheading(group)
                    }
                    capabilityPackageRows(group.packages)
                    if statusIndex < section.statusGroups.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color.primary.opacity(0.018))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            }
        }
    }

    private func capabilityStatusSubheading(_ group: CapabilityCatalogPackageGroup) -> some View {
        HStack(spacing: 5) {
            Text(group.kind.title)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(.tertiary)
            Text("\(group.packages.count)")
                .font(Stanford.caption(10).weight(.medium))
                .foregroundStyle(.quaternary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private func capabilityPackageRows(_ packages: [PluginPackage]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                capabilityCatalogRow(package)
                if index < packages.count - 1 {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
    }

    private func capabilityCategoryStatusSummary(_ section: CapabilityCatalogCategorySection) -> String {
        section.statusGroups
            .map { "\($0.packages.count) \($0.kind.title.lowercased())" }
            .joined(separator: " · ")
    }

    private func capabilityCatalogRow(_ package: PluginPackage) -> some View {
        let state = packageState(package)
        let enabled = state.isEnabled
        let needsSetup = requiresSetupFlow(package)

        return HStack(alignment: .center, spacing: 12) {
            Button {
                openPackageEditor(package.id)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    capabilityIconTile(package, isEnabled: enabled)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(package.name)
                                .font(Stanford.body(14).weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if needsSetup {
                                Image(systemName: "key.fill")
                                    .font(Stanford.ui(9, weight: .semibold))
                                    .foregroundStyle(Stanford.poppy.opacity(0.72))
                                    .help("Requires configuration")
                            }
                        }

                        Text(package.description.isEmpty ? package.contentSummary : package.description)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(capabilityRowMetadata(package, needsSetup: needsSetup))
                            .font(Stanford.caption(10).weight(.medium))
                            .foregroundStyle(capabilityRowMetadataColor(package, needsSetup: needsSetup))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            packageActionRow(package, enabled: enabled)

            Image(systemName: "chevron.right")
                .font(Stanford.ui(10, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 68, alignment: .center)
    }

    private func capabilityIconTile(_ package: PluginPackage, isEnabled: Bool) -> some View {
        CapabilityIconView(
            presentation: .make(for: package),
            size: 15,
            color: isEnabled ? Stanford.lagunita : .secondary
        )
            .frame(width: 30, height: 30)
            .background((isEnabled ? Stanford.lagunita : Color.secondary).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func capabilityRowMetadata(_ package: PluginPackage, needsSetup _: Bool) -> String {
        // P2: the group heading ("Needs attention" / "Enabled" / "Available" /
        // "Blocked") already carries the attention signal, so the collapsed row
        // keeps only item-specific facts (approval + risk). The full attention /
        // blocker detail lives in the expanded detail status summary.
        let decision = CapabilityCatalogPolicy.decision(for: package, context: catalogPolicyContext)
        var parts: [String] = []
        parts.append(capabilityApprovalLabel(decision.governance.approvalStatus))
        parts.append("\(capabilityRiskLabel(decision.governance.riskLevel)) risk")
        return parts.joined(separator: " · ")
    }

    private func capabilityRowMetadataColor(_ package: PluginPackage, needsSetup _: Bool) -> Color {
        let decision = CapabilityCatalogPolicy.decision(for: package, context: catalogPolicyContext)
        switch decision.governance.riskLevel {
        case .restricted:
            return Stanford.cardinalRed
        case .high:
            return Stanford.poppy
        case .low, .medium:
            return .secondary
        }
    }

    @ViewBuilder
    private func packageActionRow(_ package: PluginPackage, enabled: Bool) -> some View {
        // P3/P5a: collapsed rows stay summaries. An enabled row's state is carried
        // by the "Enabled" group heading, so it shows no trailing control — the row
        // body opens the editor, whose header hosts the destructive "Disable" verb.
        // A not-enabled row keeps a single "Enable" verb (row-level add).
        if !enabled {
            installButton(for: package)
                .fixedSize()
        }
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
        let policyDecision = CapabilityCatalogPolicy.decision(for: package, context: catalogPolicyContext)
        let isBlocked = !policyDecision.canEnable
        let helpText = isBlocked
            ? policyDecision.blockerMessages.joined(separator: "\n")
            : (needsSetup ? "Configure and validate \(package.name)" : "Enable \(package.name)")

        return Button {
            guard !isBlocked else { return }
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
            Label("Enable", systemImage: "plus.circle")
                .font(Stanford.caption(11).weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Stanford.lagunita)
        .disabled(isBlocked)
        .help(helpText)
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
            try CapabilityCatalogActionService().enable(
                package,
                workspace: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides,
                allowCredentialUserInteraction: credentialInputs.values.contains { !$0.isEmpty },
                policyContext: catalogPolicyContext,
                source: "configure",
                traceID: traceID
            )
            onInstall?(package)
            catalog.loadApprovedCapabilities()
            onCatalogChanged?()
        } catch {
            installError = error.localizedDescription
        }
    }

    private func openCapabilityImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Capability"
        panel.prompt = "Review"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }
        prepareCapabilityImportReview(url)
    }

    private func prepareCapabilityImportReview(_ url: URL) {
        let report = CapabilityPackageImporter().validateFile(at: url)
        importReview = CapabilityImportReview(report: report)
    }

    private func reviewPastedMCPInstallTarget() {
        guard let result = MCPInstallChatCommand.installResult(input: "/mcp \(pastedMCPInstallTarget)") else {
            importError = "Paste an MCP npm, uvx, Docker, JSON, or HTTPS target to review."
            return
        }
        guard case .request(let request) = result else {
            if case .failure(let failure) = result {
                importError = failure.message
            }
            return
        }
        showMCPInstallTargetSheet = false
        DispatchQueue.main.async {
            mcpInstallRequest = request
        }
    }

    private func importCapability(_ report: CapabilityPackageValidationReport) {
        let traceID = AuditTrace.make("capability-import")
        guard report.canInstall else {
            importError = report.summary
            AppLogger.audit(
                .capabilityEnableFailed,
                category: "Capabilities",
                fields: CapabilityAudit.importJSONFailureFields(
                    report: report,
                    workspace: workspace,
                    traceID: traceID,
                    result: "validation_blocked"
                ),
                level: .warning
            )
            return
        }
        do {
            let result = try CapabilityPackageImporter().importValidatedPackage(report)
            selectedPackageID = result.package.id
            onPackageFocusChanged?(result.package.id)
            importReview = nil
            catalog.loadApprovedCapabilities()
            onCatalogChanged?()
            AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: [
                "source": "import_json",
                "trace_id": traceID,
                "package_id": result.package.id,
                "package_name": result.package.name,
                "package_version": result.package.version,
                "workspace_id": workspace.id.uuidString
            ])
        } catch {
            importError = error.localizedDescription
            AppLogger.audit(
                .capabilityEnableFailed,
                category: "Capabilities",
                fields: CapabilityAudit.importJSONFailureFields(
                    report: report,
                    workspace: workspace,
                    traceID: traceID,
                    result: "import_failed",
                    errorType: String(describing: type(of: error))
                ),
                level: .error
            )
        }
    }

    private func createCapability(_ package: PluginPackage, enableHere: Bool, sourceURL: URL?) {
        let traceID = AuditTrace.make(enableHere ? "capability-create-enable" : "capability-create")
        AppLogger.breadcrumb(action: enableHere ? "create_and_enable_capability_clicked" : "create_capability_clicked", category: "Capabilities", traceID: traceID, fields: [
            "source": enableHere ? "create_and_enable" : "create_install_only",
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString
        ])
        do {
            let result = try CapabilityCatalogActionService().create(
                package,
                enableHere: enableHere,
                sourceURL: sourceURL,
                workspace: workspace,
                modelContext: modelContext,
                policyContext: catalogPolicyContext,
                traceID: traceID
            )
            if result.approvalRecordChanged {
                refreshApprovalRecords()
            }
            if let installedPackage = result.installedPackage {
                onInstall?(installedPackage)
            }
            catalog.loadApprovedCapabilities()
            onCatalogChanged?()
        } catch {
            installError = error.localizedDescription
        }
    }

    private func removeCapabilityPackage(_ package: PluginPackage) {
        do {
            _ = try CapabilityCatalogActionService().remove(package, modelContext: modelContext)
            if activeFocusedPackageID == package.id {
                closePackageEditor()
            }
            catalog.loadApprovedCapabilities()
            onCatalogChanged?()
        } catch {
            removalError = error.localizedDescription
        }
    }

    /// After approving an updated package version, workspaces that already
    /// have it enabled would otherwise keep running the previous version's
    /// SwiftData definitions until a manual re-enable. Re-running enable
    /// upserts the refreshed skills/connectors/tools in place.
    private func refreshEnabledDefinitionsAfterApproval(
        _ package: PluginPackage,
        status: CapabilityApprovalStatus,
        traceID: String
    ) {
        guard status == .approved,
              workspace.enabledCapabilityIDs.contains(package.id) else { return }
        do {
            _ = try CapabilityCatalogActionService().enable(
                package,
                workspace: workspace,
                modelContext: modelContext,
                policyContext: catalogPolicyContext,
                source: "approval_definition_refresh",
                traceID: traceID
            )
        } catch {
            approvalError = "Approved, but refreshing the enabled definition failed: \(error.localizedDescription)"
        }
    }

    private func saveApproval(_ package: PluginPackage, status: CapabilityApprovalStatus) {
        let traceID = AuditTrace.make("capability-approval")
        do {
            let record = try CapabilityApprovalStore().save(
                package: package,
                status: status,
                approvedBy: "ASTRA local admin",
                reviewNotes: "Updated from the local catalog review controls."
            )
            refreshApprovalRecords()
            catalog.loadApprovedCapabilities()
            refreshEnabledDefinitionsAfterApproval(package, status: status, traceID: traceID)
            onCatalogChanged?()
            AppLogger.audit(.capabilityApprovalChanged, category: "Capabilities", fields: [
                "source": "catalog_review",
                "trace_id": traceID,
                "package_id": package.id,
                "package_name": package.name,
                "package_version": package.version,
                "status": record.status.rawValue,
                "workspace_id": workspace.id.uuidString,
                "digest_prefix": String(record.sourceDigest.prefix(12))
            ])
        } catch {
            approvalError = error.localizedDescription
            AppLogger.audit(.capabilityApprovalChanged, category: "Capabilities", fields: [
                "source": "catalog_review",
                "trace_id": traceID,
                "package_id": package.id,
                "package_name": package.name,
                "package_version": package.version,
                "status": status.rawValue,
                "workspace_id": workspace.id.uuidString,
                "result": "failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }

    private func refreshApprovalRecords() {
        approvalRecordsRefreshTask?.cancel()
        approvalRecordsRefreshGeneration += 1
        let refreshGeneration = approvalRecordsRefreshGeneration
        approvalRecordsRefreshTask = Task {
            let records = await Self.loadApprovalRecords()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard approvalRecordsRefreshGeneration == refreshGeneration else { return }
                approvalRecords = records
                approvalRecordsRefreshTask = nil
            }
        }
    }

    private func cancelApprovalRecordsRefresh() {
        approvalRecordsRefreshGeneration += 1
        approvalRecordsRefreshTask?.cancel()
        approvalRecordsRefreshTask = nil
    }

    private static func loadApprovalRecords() async -> [CapabilityApprovalRecord] {
        await Task.detached(priority: .utility) {
            CapabilityApprovalStore().records()
        }.value
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

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                capabilityDetailStatusSummary(package)
                capabilityAdminReviewSection(package)

                // Show local checks first when the package declares prerequisites.
                if !package.prerequisites.isEmpty {
                    prerequisiteSection(package)
                }

                capabilityDetailOverview(package)

                if !detailSections.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
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

                        VStack(spacing: 0) {
                            ForEach(detailSections) { section in
                                capabilityDetailSectionRows(section)
                            }
                        }
                        .background(Color.primary.opacity(0.018))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
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
        let governance = CapabilityCatalogPolicy.decision(for: package, context: catalogPolicyContext).governance
        let values = [
            "Source \(package.author)",
            "Version v\(package.version)",
            "Approval \(capabilityApprovalLabel(governance.approvalStatus))",
            "Risk \(capabilityRiskLabel(governance.riskLevel))",
            requiresSetupFlow(package) ? "Setup required" : "Setup ready"
        ]

        return Text(values.joined(separator: "  ·  "))
            .font(Stanford.caption(11).weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(values.joined(separator: "\n"))
    }

    private func capabilityDetailStatusSummary(_ package: PluginPackage) -> some View {
        let decision = CapabilityCatalogPolicy.decision(for: package, context: catalogPolicyContext)
        let summary = capabilityRowMetadata(package, needsSetup: requiresSetupFlow(package))
        let messages = decision.blockerMessages + decision.warnings.map(\.message)

        return VStack(alignment: .leading, spacing: 6) {
            Text(summary)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(capabilityRowMetadataColor(package, needsSetup: requiresSetupFlow(package)))

            if !messages.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(messages.prefix(4).enumerated()), id: \.offset) { _, message in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(Stanford.ui(8, weight: .semibold))
                                .foregroundStyle(decision.blockers.isEmpty ? Stanford.poppy.opacity(0.75) : Stanford.poppy)
                                .frame(width: 12)
                            Text(message)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func capabilityContentsSummary(_ package: PluginPackage) -> String {
        CapabilityPackageResourceSummary(package: package).contentSummary(separator: " · ")
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

        if !package.mcpServers.isEmpty {
            sections.append(CapabilityDetailSection(
                id: "mcp",
                title: "MCP Servers",
                subtitle: CapabilityRuntimeSupportPresentation.mcpSupportSubtitle(for: package),
                icon: "server.rack",
                color: Stanford.plum,
                items: package.mcpServers.enumerated().map { index, server in
                    CapabilityDetailItem(
                        id: "mcp-\(index)-\(server.id)",
                        icon: "puzzlepiece.extension",
                        title: server.displayName,
                        detail: mcpServerDetailText(server)
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

    private func mcpServerDetailText(_ server: PluginMCPServer) -> String {
        switch server.transport {
        case .stdio:
            let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return command.isEmpty ? "stdio" : "stdio · \(command)"
        case .http, .sse:
            return [server.transport.rawValue, server.url?.absoluteString ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    private func capabilityAdminReviewSection(_ package: PluginPackage) -> some View {
        let reviewState = PluginCatalogApprovalState.adminReviewState(
            for: package,
            policyContext: catalogPolicyContext,
            approvalRecords: approvalRecords
        )

        return Group {
            if let reviewState {
                let record = reviewState.record
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                            .font(Stanford.ui(10, weight: .semibold))
                            .foregroundStyle(Stanford.lagunita)
                        Text("Catalog review")
                            .font(Stanford.caption(11).weight(.semibold))
                            .foregroundStyle(Stanford.lagunita)
                        Spacer()
                        Text(reviewState.digestLabel)
                            .font(Stanford.caption(10))
                            .foregroundStyle(reviewState.hasVersionRecord && record == nil ? Stanford.poppy : Stanford.coolGrey)
                    }

                    HStack(spacing: 8) {
                        Button {
                            saveApproval(package, status: .approved)
                        } label: {
                            Label("Approve", systemImage: "checkmark.circle")
                        }
                        .disabled(record?.status == .approved)

                        Button {
                            saveApproval(package, status: .deprecated)
                        } label: {
                            Label("Deprecate", systemImage: "clock.badge.exclamationmark")
                        }
                        .disabled(record?.status == .deprecated)

                        Button(role: .destructive) {
                            saveApproval(package, status: .blocked)
                        } label: {
                            Label("Block", systemImage: "xmark.octagon")
                        }
                        .disabled(record?.status == .blocked)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .liquidSurface(
                    cornerRadius: Stanford.railCompactCardCornerRadius,
                    fallbackFill: Color.primary.opacity(0.018),
                    fallbackStrokeOpacity: 0.045
                )
            }
        }
    }

    private func capabilityApprovalLabel(_ status: CapabilityApprovalStatus) -> String {
        switch status {
        case .approved: return "Approved"
        case .draft: return "Draft"
        case .deprecated: return "Deprecated"
        case .blocked: return "Blocked"
        }
    }

    private func capabilityRiskLabel(_ risk: CapabilityRiskLevel) -> String {
        switch risk {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .restricted: return "Restricted"
        }
    }

    private func capabilityDetailSectionRows(_ section: CapabilityDetailSection) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: section.icon)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(section.color)
                    .frame(width: 30, height: 30)
                    .background(section.color.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(section.title)
                            .font(Stanford.body(13).weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(section.items.count)")
                            .font(Stanford.caption(10).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(section.subtitle)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ForEach(section.items) { item in
                Divider()
                    .padding(.leading, 52)
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: item.icon)
                        .font(Stanford.ui(10, weight: .medium))
                        .foregroundStyle(section.color.opacity(0.82))
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(Stanford.caption(12).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
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

                Button {
                    exportPackageSource(package)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(Stanford.caption(11).weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Save \(package.name) as a shareable JSON file (exports as draft; recipients review before use)")

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

    private func exportPackageSource(_ package: PluginPackage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(CapabilityLibrary.safeFileName(for: package.id)).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try CapabilityCatalogActionService().exportSource(package, to: url)
        } catch {
            installError = "Couldn't export \(package.name): \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func capabilityConfigurationLinks(_ state: CapabilityPackageState) -> some View {
        let links = capabilityConfigurationLinkItems(state)

        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().opacity(0.35)

                // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
                // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
                HStack(alignment: .top) {
                    Text("Configure resources")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer()

                    // P4a: a lone editable resource is already rendered expanded
                    // below, so a bare "1 editable" count names nothing worth
                    // counting. Show the count only when it summarizes 2+ items.
                    if links.count > 1 {
                        Text("\(links.count) editable")
                            .font(Stanford.caption(10))
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(links) { link in
                        capabilityConfigurationLinkCard(link)
                    }
                }
                .background(Color.primary.opacity(0.018))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.055), lineWidth: 1)
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

private struct CapabilityImportReviewSheet: View {
    let review: CapabilityImportReview
    let onCancel: () -> Void
    let onImport: (CapabilityPackageValidationReport) -> Void

    private var report: CapabilityPackageValidationReport {
        review.report
    }

    private var package: PluginPackage? {
        report.package
    }

    var body: some View {
        let iconPresentation = package.map(CapabilityIconPresentation.make)
            ?? CapabilityIconPresentation.make(name: "Invalid Capability", fallbackSystemName: "exclamationmark.triangle")

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                CapabilityIconView(
                    presentation: iconPresentation,
                    size: 18,
                    color: report.canInstall ? Stanford.lagunita : Stanford.poppy,
                    weight: .semibold
                )
                    .frame(width: 34, height: 34)
                    .background((report.canInstall ? Stanford.lagunita : Stanford.poppy).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(package?.name ?? "Invalid Capability")
                        .font(Stanford.heading(18))
                    Text(review.sourceURL?.lastPathComponent ?? "Package JSON")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let package {
                        importPackageOverview(package)
                    }
                    importIssueSection(
                        title: "Blockers",
                        empty: "No blockers",
                        issues: report.blockers,
                        color: Stanford.cardinalRed,
                        icon: "xmark.octagon.fill"
                    )
                    importIssueSection(
                        title: "Warnings",
                        empty: "No warnings",
                        issues: report.warnings,
                        color: Stanford.poppy,
                        icon: "exclamationmark.triangle.fill"
                    )
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onImport(report)
                } label: {
                    Label("Import Capability", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .disabled(!report.canInstall)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 640, height: 560)
    }

    private func importPackageOverview(_ package: PluginPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.id)
                        .font(Stanford.ui(12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(CapabilityImportPresentation.overviewDescription(
                        for: package,
                        contentSummary: importContentSummary(package)
                    ))
                        .font(Stanford.body(13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                importChip("v\(package.version)", color: Stanford.coolGrey)
                importChip(package.governance.approvalStatus.rawValue.capitalized, color: Stanford.poppy)
            }

            if CapabilityImportPresentation.shouldShowContentSummary(for: package) {
                Text(importContentSummary(package))
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func importIssueSection(
        title: String,
        empty: String,
        issues: [CapabilityPackageValidationIssue],
        color: Color,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(color)
                Text("\(issues.count)")
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.08))
                    .clipShape(Capsule())
                Spacer()
            }

            if issues.isEmpty {
                Text(empty)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(Stanford.caption(11).weight(.semibold))
                            Text(issue.message)
                                .font(Stanford.caption(10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(color.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    private func importChip(_ title: String, color: Color) -> some View {
        Text(title)
            .font(Stanford.caption(10).weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.08))
            .clipShape(Capsule())
    }

    private func importContentSummary(_ package: PluginPackage) -> String {
        let parts = [
            countPhrase(package.skills.count, singular: "skill", plural: "skills"),
            countPhrase(package.connectors.count, singular: "connector", plural: "connectors"),
            countPhrase(package.localTools.count, singular: "tool", plural: "tools"),
            countPhrase(package.mcpServers.count, singular: "MCP server", plural: "MCP servers"),
            countPhrase(package.browserAdapters.count, singular: "browser adapter", plural: "browser adapters"),
            countPhrase(package.templates.count, singular: "template", plural: "templates")
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? "No installable payload" : parts.joined(separator: ", ")
    }

    private func countPhrase(_ count: Int, singular: String, plural: String) -> String {
        guard count > 0 else { return "" }
        return "\(count) \(count == 1 ? singular : plural)"
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
    let policyContext: CapabilityCatalogPolicyContext
    let onDismiss: () -> Void
    let onInstalled: (PluginPackage) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workspace.name) private var capabilitySetupSourceWorkspaces: [Workspace]
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]
    @State private var credentialValues: [String: String] = [:]
    @State private var configValues: [String: String] = [:]
    @State private var baseURLValues: [String: String] = [:]
    @State private var installError: String?
    @State private var validationResults: [PluginInstallValidationResult] = []
    @State private var validationPassed = false
    @State private var isValidatingSetup = false
    @State private var lastValidationTraceID: String?
    @State private var copiedSetupSourceName: String?

    private let validationPreflightCache = PreflightCache()

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
                CapabilityIconView(
                    presentation: .make(for: package),
                    size: 22,
                    color: Stanford.lagunita,
                    weight: .semibold
                )
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
                VStack(alignment: .leading, spacing: 16) {
                    if !copyableSetupSourceWorkspaces.isEmpty {
                        copySetupSection
                    }

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
                .buttonStyle(.bordered)
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
                    .buttonStyle(.bordered)
                    .tint(Stanford.lagunita)
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
        .frame(width: 560, height: 600)
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
            "config_input_count": String(installConfigValues.count),
            "base_url_override_count": String(baseURLValues.count)
        ])
        do {
            try CapabilityCatalogActionService().enable(
                package,
                workspace: workspace,
                modelContext: modelContext,
                credentialInputs: credentialValues,
                configInputs: installConfigValues,
                baseURLOverrides: baseURLValues,
                allowCredentialUserInteraction: credentialValues.values.contains { !$0.isEmpty },
                policyContext: policyContext,
                source: "setup_sheet",
                traceID: traceID
            )
            onInstalled(package)
        } catch {
            installError = error.localizedDescription
        }
    }

    private var copySetupSection: some View {
        // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
        // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: copiedSetupSourceName == nil ? "square.on.square" : "checkmark.circle.fill")
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(copiedSetupSourceName == nil ? Stanford.lagunita : Stanford.paloAltoGreen)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(copiedSetupSourceName.map { "Copied from \($0)" } ?? "Reuse setup")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(copySetupSourceSummary)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Menu {
                ForEach(copyableSetupSourceWorkspaces, id: \.id) { sourceWorkspace in
                    Button(sourceWorkspace.name) {
                        copySetup(from: sourceWorkspace)
                    }
                }
            } label: {
                Label("Copy From", systemImage: "arrow.down.doc")
                    .font(Stanford.caption(11).weight(.medium))
            }
            .menuStyle(.button)
            .fixedSize()
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var copyableSetupSourceWorkspaces: [Workspace] {
        capabilitySetupSourceWorkspaces.filter { sourceWorkspace in
            sourceWorkspace.id != workspace.id &&
            hasCopyableSetupInputs(from: sourceWorkspace)
        }
    }

    private var copySetupSourceSummary: String {
        let count = copyableSetupSourceWorkspaces.count
        return count == 1 ? "1 workspace has saved setup" : "\(count) workspaces have saved setup"
    }

    private var installConfigValues: [String: String] {
        var values = configValues
        let environmentKeys = package.skills.flatMap(\.environmentKeys)
        for connector in package.connectors {
            let baseURL = resolvedBaseURL(for: connector)
            for key in environmentKeys where CapabilitySetupCopier.shouldMapBaseURL(baseURL, toEnvironmentKey: key, connector: connector) {
                values[key] = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return values
    }

    private func copySetup(from sourceWorkspace: Workspace) {
        let inputs = CapabilitySetupCopier().installationInputs(
            for: package,
            from: sourceWorkspace,
            globalConnectors: globalConnectors
        )
        guard !inputs.credentialInputs.isEmpty || !inputs.configInputs.isEmpty || !inputs.baseURLOverrides.isEmpty else {
            return
        }
        credentialValues.merge(inputs.credentialInputs) { _, copied in copied }
        configValues.merge(inputs.configInputs) { _, copied in copied }
        baseURLValues.merge(inputs.baseURLOverrides) { _, copied in copied }
        copiedSetupSourceName = sourceWorkspace.name
        resetValidation()
    }

    private func hasCopyableSetupInputs(from sourceWorkspace: Workspace) -> Bool {
        let inputs = CapabilitySetupCopier().installationInputs(
            for: package,
            from: sourceWorkspace,
            globalConnectors: globalConnectors
        )
        return !inputs.credentialInputs.isEmpty ||
            !inputs.configInputs.isEmpty ||
            !inputs.baseURLOverrides.isEmpty
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
        installConfigValues.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private func resetValidation() {
        validationPassed = false
        lastValidationTraceID = nil
        validationResults = []
    }

    // MARK: - Connector Setup Section

    private func connectorSetupSection(_ connector: PluginConnector) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: connector.icon)
                    .font(Stanford.ui(14, weight: .medium))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 30, height: 30)
                    .background(Stanford.lagunita.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)
                    if !connector.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(connector.description)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Text(CapabilitySetupPresentation.authMethodLabel(connector.authMethod))
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
            }

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

            if !connector.credentialHints.isEmpty {
                setupInputGroup(
                    title: "Credentials",
                    subtitle: "Stored in Keychain",
                    icon: "key.fill",
                    color: Stanford.poppy
                ) {
                    ForEach(connector.credentialHints, id: \.key) { hint in
                        credentialField(for: hint)
                    }
                }
            }

            if !connector.configHints.isEmpty {
                setupInputGroup(
                    title: "Configuration",
                    subtitle: "Connector settings",
                    icon: "slider.horizontal.3",
                    color: Stanford.lagunita
                ) {
                    ForEach(connector.configHints, id: \.key) { hint in
                        configField(for: hint)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.018))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        )
    }

    private func setupInputGroup<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }

            content()
        }
        .padding(.top, 2)
    }

    private func credentialField(for hint: PluginConnector.CredentialHint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            setupFieldHeader(for: hint.key)
            SecureField(CapabilitySetupPresentation.credentialPlaceholder(for: hint), text: Binding(
                get: { credentialValues[hint.key] ?? "" },
                set: {
                    credentialValues[hint.key] = $0
                    resetValidation()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(Stanford.body(13))
            .help(hint.hint)
        }
    }

    private func configField(for hint: PluginConnector.ConfigHint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            setupFieldHeader(for: hint.key)
            TextField(CapabilitySetupPresentation.configPlaceholder(for: hint), text: Binding(
                get: { configValues[hint.key] ?? "" },
                set: {
                    configValues[hint.key] = $0
                    resetValidation()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(Stanford.body(13))
            .help(hint.hint)
        }
    }

    private func setupFieldHeader(for key: String) -> some View {
        // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
        // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
        HStack(alignment: .top, spacing: 6) {
            Text(CapabilitySetupPresentation.fieldLabel(for: key))
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(Stanford.black)
            if let helper = CapabilitySetupPresentation.fieldHelper(for: key) {
                Text(helper)
                    .font(Stanford.ui(10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func baseURLField(for connector: PluginConnector) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CapabilitySetupPresentation.baseURLLabel(for: connector))
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(Stanford.black)
            TextField(connector.baseURL, text: Binding(
                get: { baseURLValues[connector.name] ?? connector.baseURL },
                set: {
                    baseURLValues[connector.name] = $0
                    resetValidation()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(Stanford.body(13))
        }
    }

}
