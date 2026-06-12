import ASTRACore
import SwiftData
import SwiftUI

private let workspaceRightRailScrollCoordinateSpace = "workspaceRightRailScrollCoordinateSpace"

private enum RightRailScrollShadowEdge {
    case top
    case bottom
}

private struct RightRailScrollMetrics: Equatable {
    var contentMinY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

private struct RightRailScrollMetricsPreferenceKey: PreferenceKey {
    static var defaultValue = RightRailScrollMetrics()

    static func reduce(value: inout RightRailScrollMetrics, nextValue: () -> RightRailScrollMetrics) {
        value = nextValue()
    }
}

private enum CapabilityRailGroupStyle: Equatable {
    case attention
    case ready
    case draft
}

private enum WorkspaceSetupItem: Hashable {
    case instructions
    case memory
    case folders
    case remoteAccess
    case routines
}

enum WorkspaceSetupChecklistPresentation {
    static let sectionTitle = "Workspace setup"
    static let missingGroupTitle = "Needs setup"
    static let configuredGroupTitle = "Configured"
    static let configuredSummaryTitle = "Configured items"
    static let configuredSummaryActionTitle = "Show all"
    static let configuredSummaryIcon = "checkmark.circle"
    static let supportsInlineExpansion = true
    static let supportsInlineEditing = true
    static let supportsMemoryRemoval = true
    static let supportsFolderRemoval = true
    static let usesCapabilitySummaryRowPattern = true
    static let collapsesConfiguredRowsByDefault = true
    static let showsPerRowStatusInCollapsedState = false
    static let collapsedDisclosureIcon = "chevron.right"
    static let expandedDisclosureIcon = "chevron.down"
    static let detailPreviewLimit = 4

    enum State: Equatable {
        case configured
        case missing

        var label: String {
            switch self {
            case .configured: "Configured"
            case .missing: "Missing"
            }
        }
    }

    static func summary(configured: Int, total: Int) -> String {
        configured == 0 ? "Empty" : "\(configured) of \(total) configured"
    }

    static func configuredPreview(_ names: [String], limit: Int = 3) -> String {
        let cleanNames = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanNames.isEmpty else { return "No configured items" }

        let visible = cleanNames.prefix(limit)
        let remaining = cleanNames.count - visible.count
        let prefix = visible.joined(separator: ", ")
        return remaining > 0 ? "\(prefix) +\(remaining)" : prefix
    }

    static func overflowSummary(
        total: Int,
        visible: Int,
        singular: String,
        plural: String
    ) -> String? {
        let remaining = total - visible
        guard remaining > 0 else { return nil }
        return "\(remaining) more \(remaining == 1 ? singular : plural)"
    }
}

enum WorkspaceContextIconography {
    static let headerIcon = "info.circle"

    static func capabilityIcon(name: String, fallback: String) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("bigquery") {
            return "cylinder.split.1x2"
        }
        if normalized.contains("read-only") || normalized.contains("read only") {
            return "eye"
        }
        if normalized.contains("safe bash") {
            return "terminal"
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "puzzlepiece.extension"
            : fallback
    }
}

struct WorkspaceRightRailView: View {
    let workspace: Workspace
    var selectedTask: AgentTask?
    let onConfigure: () -> Void
    let onEditWorkspace: () -> Void
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    var onManageCapabilities: (() -> Void)?
    var onOpenConfigureTab: ((ConfigureTab, UUID?) -> Void)?
    var onOpenCapabilityPackage: ((String) -> Void)?
    var onTaskCreated: ((AgentTask) -> Void)?
    var onOpenWorkspaceFile: ((String) -> Void)?
    var onNewSSHConnection: (() -> Void)?
    var onEditSSHConnection: ((SSHConnection) -> Void)?
    var sshReloadTrigger: Int = 0
    var isCompact = false
    var onDismiss: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]

    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isIdentityCollapsed = true
    @State private var isCapabilitiesCollapsed = false
    @State private var isContextCollapsed = true
    @State private var isAccessCollapsed = true
    @State private var isSchedulesSectionCollapsed = false
    @State private var sshConnections: [SSHConnection] = []
    @State private var isConnectorsExpanded = false
    @State private var isToolsExpanded = false
    @State private var isTemplatesExpanded = false
    @State private var isConfiguredWorkspaceSetupExpanded = false
    @State private var newMemoryText = ""
    @State private var isMemoryComposerVisible = false
    @State private var expandedWorkspaceSetupItems: Set<WorkspaceSetupItem> = []
    @State private var approvedCapabilityPackages: [PluginPackage] = PluginCatalog.builtInPackages
    @State private var capabilityError: String?
    @State private var capabilityPrerequisiteStatuses: [String: HealthStatus] = [:]
    @State private var scrollMetrics = RightRailScrollMetrics()
    @State private var isReadyCapabilitiesExpanded = false
    @State private var isDraftCapabilitiesExpanded = false
    @State private var hasGitRepositories = false

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        )
    }

    private var catalogPolicyContext: CapabilityCatalogPolicyContext {
        CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            isAdmin: true,
            approvalRecords: CapabilityApprovalStore().records()
        )
    }

    private var workspaceSkills: [Skill] {
        capabilities.workspaceSkills
    }

    private var enabledGlobalSkills: [Skill] {
        capabilities.enabledGlobalSkills
    }

    private var availableSkills: [Skill] {
        capabilities.activeSkills
    }

    private var workspaceTools: [LocalTool] {
        capabilities.activeTools
    }

    private var enabledGlobalConnectors: [Connector] {
        capabilities.enabledGlobalConnectors
    }

    private var workspaceConnectors: [Connector] {
        capabilities.activeConnectors
    }

    private var templates: [TaskTemplate] {
        workspace.templates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: contentListSpacing) {
                        configurePanel
                            .padding(.horizontal, contentPadding)
                            .padding(.top, isCompact ? 6 : 8)
                            .padding(.bottom, contentPadding)
                    }
                    .background {
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: RightRailScrollMetricsPreferenceKey.self,
                                value: RightRailScrollMetrics(
                                    contentMinY: contentProxy.frame(in: .named(workspaceRightRailScrollCoordinateSpace)).minY,
                                    contentHeight: contentProxy.size.height,
                                    viewportHeight: viewport.size.height
                                )
                            )
                        }
                    }
                }
                .coordinateSpace(name: workspaceRightRailScrollCoordinateSpace)
                .onPreferenceChange(RightRailScrollMetricsPreferenceKey.self) { metrics in
                    scrollMetrics = metrics
                }
                .overlay(alignment: .top) {
                    rightRailScrollShadow(edge: .top)
                        .opacity(showsTopRailScrollShadow ? 1 : 0)
                }
                .overlay(alignment: .bottom) {
                    rightRailScrollShadow(edge: .bottom)
                        .opacity(showsBottomRailScrollShadow ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // No background — system inspector material extends behind toolbar; custom fill creates a visible seam.
    }

    private var showsTopRailScrollShadow: Bool {
        scrollMetrics.contentMinY < -2
    }

    private var contentPadding: CGFloat {
        isCompact ? CapabilityRailLayout.compactContentPadding : CapabilityRailLayout.regularContentPadding
    }

    private var contentListSpacing: CGFloat {
        isCompact ? 8 : Stanford.railListSpacing
    }

    private var capabilityGroupSpacing: CGFloat {
        isCompact ? CapabilityRailLayout.compactGroupSpacing : CapabilityRailLayout.regularGroupSpacing
    }

    private var panelSpacing: CGFloat {
        isCompact ? CapabilityRailLayout.compactPanelSpacing : CapabilityRailLayout.regularPanelSpacing
    }

    private var sectionContentSpacing: CGFloat {
        isCompact ? CapabilityRailLayout.compactSectionContentSpacing : CapabilityRailLayout.regularSectionContentSpacing
    }

    private var disclosureAnimation: Animation? {
        AstraMotion.disclosure(reduceMotion: reduceMotion)
    }

    private var showsBottomRailScrollShadow: Bool {
        guard scrollMetrics.contentHeight > scrollMetrics.viewportHeight + 2 else { return false }
        return scrollMetrics.contentHeight + scrollMetrics.contentMinY > scrollMetrics.viewportHeight + 2
    }

    private func rightRailScrollShadow(edge: RightRailScrollShadowEdge) -> some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.11),
                Color.black.opacity(0.04),
                Color.clear
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: 18)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsTopRailScrollShadow)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsBottomRailScrollShadow)
    }

    // MARK: - Workspace Identity Anchor

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: WorkspaceContextIconography.headerIcon)
                .font(Stanford.ui(WorkspaceRightRailPresentation.headerIconFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: WorkspaceRightRailPresentation.headerIconFrame, height: WorkspaceRightRailPresentation.headerIconFrame)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace Context")
                    .font(Stanford.ui(WorkspaceRightRailPresentation.headerTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                Text(workspace.name)
                    .font(Stanford.caption(WorkspaceRightRailPresentation.headerSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Workspace Context")
                .accessibilityLabel("Close Workspace Context")
            }
        }
        .padding(.top, isCompact ? 14 : 12)
        .padding(.horizontal, isCompact ? 18 : 16)
        .padding(.bottom, isCompact ? 14 : 10)
    }

    // MARK: - Unified Configure Panel

    private var configurePanel: some View {
        let snapshot = capabilityRailSnapshot

        return VStack(alignment: .leading, spacing: panelSpacing) {
            if hasGitRepositories {
                floatingContextSection {
                    WorkspaceGitSectionView(
                        workspace: workspace,
                        selectedTask: selectedTask,
                        isCompact: isCompact,
                        onTaskCreated: onTaskCreated,
                        onOpenWorkspaceFile: onOpenWorkspaceFile
                    )
                }
            }

            floatingContextSection {
                workspaceSetupChecklistPanel
            }

            capabilityHealthPanel(snapshot)

        }
        .tint(Stanford.lagunita)
        .onAppear {
            loadSSHConnections()
            refreshApprovedCapabilities()
            refreshCapabilityPrerequisiteStatuses()
            applyConfigureDefaults()
            checkGitRepositories()
        }
        .onChange(of: workspace.primaryPath) {
            loadSSHConnections()
            checkGitRepositories()
        }
        .onChange(of: workspace.additionalPaths) {
            checkGitRepositories()
        }
        .onChange(of: sshReloadTrigger) {
            loadSSHConnections()
            if !sshConnections.isEmpty {
                isAccessCollapsed = false
            }
        }
        .alert("Capability could not be updated", isPresented: Binding(
            get: { capabilityError != nil },
            set: { if !$0 { capabilityError = nil } }
        )) {
            Button("OK", role: .cancel) { capabilityError = nil }
        } message: {
            Text(capabilityError ?? "")
        }
    }

    private func floatingContextSection<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius, style: .continuous)

        return content()
            .padding(isCompact ? CapabilityRailLayout.compactSectionPadding : CapabilityRailLayout.regularSectionPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(floatingSectionFill))
            .overlay {
                shape.stroke(floatingSectionStroke, lineWidth: 1)
            }
    }

    private var floatingSectionFill: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.052)
            : Color.primary.opacity(0.035)
    }

    private var floatingSectionStroke: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.085)
    }

    private func capabilityHealthPanel(_ snapshot: CapabilityRailSnapshot) -> some View {
        floatingContextSection {
            VStack(alignment: .leading, spacing: sectionContentSpacing) {
                rightRailSectionHeader(CapabilityRailSectionPresentation.sectionTitle) {
                    capabilityAddButton
                }

                capabilityList(snapshot)
            }
        }
    }

    private func rightRailSectionHeader<Trailing: View>(
        _ title: String,
        summary: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(Stanford.ui(CapabilityRailLayout.sectionTitleFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if let summary {
                Text(summary)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.055))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)
            trailing()
        }
    }

    @ViewBuilder
    private var capabilityAddButton: some View {
        if let onManageCapabilities {
            Button(action: onManageCapabilities) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(CapabilityRailSectionPresentation.addActionTitle)
                        .font(Stanford.ui(CapabilityRailLayout.sectionActionFontSize, weight: .semibold))
                        .lineLimit(1)

                    if !CapabilityRailSectionPresentation.addActionSubtitle.isEmpty {
                        Text(CapabilityRailSectionPresentation.addActionSubtitle)
                            .font(Stanford.caption(CapabilityRailLayout.sectionActionSubtitleFontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(Stanford.lagunita)
            }
            .buttonStyle(.plain)
            .help(CapabilityRailSectionPresentation.addActionHelp)
            .accessibilityLabel("Add capability")
        }
    }

    private func capabilityList(_ snapshot: CapabilityRailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: capabilityGroupSpacing + 2) {
            if snapshot.items.isEmpty {
                CapabilityEmptyPrompt(
                    title: "No active capabilities",
                    description: "Add skills, tools, and connectors from the library.",
                    actionTitle: "Add capability",
                    action: onManageCapabilities
                )
            } else {
                if !snapshot.attentionItems.isEmpty {
                    capabilityGroup(
                        "Action needed",
                        count: snapshot.attentionItems.count,
                        style: .attention,
                        items: snapshot.attentionItems
                    )
                }

                if !snapshot.readyItems.isEmpty {
                    capabilitySummaryGroup(
                        "Ready",
                        items: snapshot.readyItems,
                        style: .ready,
                        isExpanded: $isReadyCapabilitiesExpanded,
                        summaryTitle: CapabilityRailSectionPresentation.readySummaryTitle(count: snapshot.readyItems.count),
                        summarySubtitle: capabilityPreview(snapshot.readyItems)
                    )
                }

                if !snapshot.draftItems.isEmpty {
                    capabilitySummaryGroup(
                        "Drafts",
                        items: snapshot.draftItems,
                        style: .draft,
                        isExpanded: $isDraftCapabilitiesExpanded,
                        summaryTitle: CapabilityRailSectionPresentation.draftSummaryTitle(count: snapshot.draftItems.count),
                        summarySubtitle: capabilityPreview(snapshot.draftItems)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capabilityPreview(_ items: [RailCapabilityItem]) -> String {
        CapabilityRailSectionPresentation.previewList(items.map { capabilityDisplayName($0.name) })
    }

    private func capabilitySummaryIcon(for style: CapabilityRailGroupStyle) -> String {
        switch style {
        case .attention:
            return "exclamationmark.triangle.fill"
        case .ready:
            return "cloud"
        case .draft:
            return "doc.text"
        }
    }

    private func capabilitySummaryTint(for style: CapabilityRailGroupStyle) -> Color {
        switch style {
        case .attention:
            return Stanford.poppy
        case .ready, .draft:
            return Stanford.lagunita
        }
    }

    private func capabilitySummaryGroup(
        _ title: String,
        items: [RailCapabilityItem],
        style: CapabilityRailGroupStyle,
        isExpanded: Binding<Bool>,
        summaryTitle: String,
        summarySubtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            capabilityGroupHeader(title, count: items.count, style: style)

            if isExpanded.wrappedValue {
                capabilityRows(items, style: style)
                Button {
                    withAnimation(disclosureAnimation) {
                        isExpanded.wrappedValue = false
                    }
                } label: {
                    Text("Hide")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                        .padding(.leading, CapabilityRailLayout.dividerLeadingPadding(isCompact: isCompact))
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            } else {
                CapabilitySummaryRow(
                    icon: capabilitySummaryIcon(for: style),
                    iconColor: capabilitySummaryTint(for: style),
                    title: summaryTitle,
                    subtitle: summarySubtitle,
                    actionTitle: style == .ready ? "Show all" : nil,
                    action: {
                        withAnimation(disclosureAnimation) {
                            isExpanded.wrappedValue = true
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capabilityArchitectureSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            CapabilityHierarchySummary()

            Divider().opacity(0.25)

            HStack(alignment: .top, spacing: 0) {
                CapabilityOverviewMetric(
                    title: "Enabled here",
                    value: "\(enabledPackageCount)",
                    icon: "checkmark.circle.fill",
                    color: Stanford.paloAltoGreen
                )
                Divider().opacity(0.25).padding(.horizontal, 8)
                CapabilityOverviewMetric(
                    title: "Needs setup",
                    value: "\(needsSetupPackageCount)",
                    icon: "exclamationmark.triangle.fill",
                    color: Stanford.poppy
                )
                Divider().opacity(0.25).padding(.horizontal, 8)
                CapabilityOverviewMetric(
                    title: "Shared here",
                    value: "\(enabledSharedResourceCount)",
                    icon: "square.3.layers.3d",
                    color: Stanford.sky
                )
            }

            Text("Package actions are workspace scoped. Shared resources can be reused elsewhere; workspace resources can carry different instructions or credentials here.")
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Stanford.railInlineCardPadding)
        .railCard(
            cornerRadius: Stanford.railCompactCardCornerRadius,
            fill: Color.primary.opacity(0.025),
            strokeOpacity: 0.04
        )
    }

    @ViewBuilder
    private var sharedResourceScopeSummary: some View {
        let enabledShared = enabledSharedResourceCount
        let availableShared = availableSharedResourceCount
        let workspaceOnly = workspaceOnlyResourceCount

        if enabledShared + availableShared + workspaceOnly > 0 {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d")
                        .font(Stanford.ui(11, weight: .semibold))
                        .foregroundStyle(Stanford.sky)
                    Text("Reusable resources")
                        .font(Stanford.caption(12).weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    CapabilityResourceScopeRow(title: "Shared enabled here", value: enabledShared)
                    CapabilityResourceScopeRow(title: "Shared available", value: availableShared)
                    CapabilityResourceScopeRow(title: "Workspace-only", value: workspaceOnly)
                }

                HStack(spacing: 8) {
                    Text("Shared skills, connectors, and tools keep one definition across workspaces.")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }

                if onOpenConfigureTab != nil {
                    Button {
                        onOpenConfigureTab?(.skills, nil)
                    } label: {
                        Text("Configure resources")
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(Stanford.lagunita)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                }
            }
            .padding(Stanford.railInlineCardPadding)
            .railCard(
                cornerRadius: Stanford.railCompactCardCornerRadius,
                fill: Color.primary.opacity(0.025),
                strokeOpacity: 0.04
            )
        }
    }

    private func capabilityGroupHeader(
        _ title: String,
        count _: Int,
        style: CapabilityRailGroupStyle
    ) -> some View {
        return HStack(spacing: 8) {
            if style == .attention, CapabilityRailSectionPresentation.attentionGroupShowsWarningIcon {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(Stanford.poppy)
            }

            Text(title)
                .font(Stanford.caption(CapabilityRailLayout.groupHeadingFontSize).weight(.semibold))
                .foregroundStyle(capabilityGroupHeaderForeground(style))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func capabilityGroup(
        _ title: String,
        count: Int,
        style: CapabilityRailGroupStyle,
        items: [RailCapabilityItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            capabilityGroupHeader(title, count: count, style: style)
            capabilityRows(items, style: style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capabilityRows(_ items: [RailCapabilityItem], style: CapabilityRailGroupStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius, style: .continuous)

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                capabilityRow(item)

                if index < items.count - 1 {
                    Divider()
                        .opacity(0.34)
                        .padding(.leading, CapabilityRailLayout.dividerLeadingPadding(isCompact: isCompact))
                        .padding(.trailing, CapabilityRailLayout.dividerTrailingPadding(isCompact: isCompact))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if CapabilityRailLayout.usesNestedGroupChrome {
                shape.fill(capabilityGroupFill(style))
            }
        }
        .overlay {
            if CapabilityRailLayout.usesNestedGroupChrome {
                shape.stroke(capabilityGroupStroke(style), lineWidth: 1)
            }
        }
    }

    private func capabilityGroupHeaderForeground(_ style: CapabilityRailGroupStyle) -> Color {
        if style == .attention, CapabilityRailSectionPresentation.attentionGroupUsesWarningTint {
            return Stanford.poppy
        }

        return .secondary
    }

    private func capabilityGroupFill(_ style: CapabilityRailGroupStyle) -> Color {
        switch style {
        case .attention:
            return Stanford.poppy.opacity(0.035)
        case .ready:
            return Color.primary.opacity(0.018)
        case .draft:
            return Color.primary.opacity(0.018)
        }
    }

    private func capabilityGroupStroke(_ style: CapabilityRailGroupStyle) -> Color {
        switch style {
        case .attention:
            return Stanford.poppy.opacity(0.16)
        case .ready:
            return Color.primary.opacity(0.055)
        case .draft:
            return Color.primary.opacity(0.055)
        }
    }

    private func capabilityRow(_ item: RailCapabilityItem) -> some View {
        let isHighlighted = item.readiness.level == .needsAttention

        return CapabilityRailRow(
            icon: WorkspaceContextIconography.capabilityIcon(name: item.name, fallback: item.icon),
            title: capabilityDisplayName(item.name),
            subtitle: capabilityListSubtitle(for: item),
            color: item.color,
            readiness: item.readiness,
            statusLabel: capabilityBadgeTitle(for: item),
            statusColor: capabilityBadgeColor(for: item),
            isEnabled: item.isEnabled,
            isCompact: isCompact,
            onOpen: { openCapabilityConfiguration(item) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CapabilityRailLayout.groupHorizontalPadding(isCompact: isCompact))
        .padding(.leading, isHighlighted ? 14 : 0)
        .padding(.vertical, isCompact ? 3 : 4)
        .overlay(alignment: .leading) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Stanford.poppy)
                    .frame(width: 2, height: 52)
                    .padding(.leading, 2)
            }
        }
    }

    private var enabledPackageCount: Int {
        railCapabilityItems.filter(\.isEnabled).count
    }

    private var needsSetupPackageCount: Int {
        railCapabilityItems.filter { $0.readiness.level == .needsAttention }.count
    }

    private var attentionCapabilityItems: [RailCapabilityItem] {
        railCapabilityItems.filter { $0.readiness.level == .needsAttention }
    }

    private var readyCapabilityItems: [RailCapabilityItem] {
        railCapabilityItems.filter { $0.readiness.level != .needsAttention && !isDraftCapability($0) }
    }

    private var draftCapabilityItems: [RailCapabilityItem] {
        railCapabilityItems.filter(isDraftCapability)
    }

    private func isDraftCapability(_ item: RailCapabilityItem) -> Bool {
        item.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("New Skill") == .orderedSame
    }

    private func capabilityDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveCompare("New Skill") == .orderedSame {
            return "Untitled Capability"
        }
        return trimmed
            .replacingOccurrences(of: " (Restored)", with: "")
            .replacingOccurrences(of: "(Restored)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func capabilityBadgeTitle(for item: RailCapabilityItem) -> String? {
        if let statusLabel = item.presentation.statusLabel {
            return statusLabel
        }

        if item.name.localizedCaseInsensitiveContains("(Restored)") {
            return "Restored"
        }

        if item.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("New Skill") == .orderedSame {
            return "Draft"
        }

        return nil
    }

    private func capabilityBadgeColor(for item: RailCapabilityItem) -> Color {
        if item.readiness.level == .needsAttention {
            return Stanford.poppy
        }
        if item.name.localizedCaseInsensitiveContains("(Restored)") {
            return .secondary
        }
        if item.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("New Skill") == .orderedSame {
            return Stanford.poppy
        }
        return readinessColor(for: item.readiness, isEnabled: item.isEnabled)
    }

    private func capabilityListSubtitle(for item: RailCapabilityItem) -> String {
        let source = isWorkspaceAuthoredCapability(item) ? "Custom" : "Built-in"
        let composition = capabilityCompositionSummary(for: item)
        return "\(source): \(composition)"
    }

    private func capabilityCompositionSummary(for item: RailCapabilityItem) -> String {
        var parts: [String] = []
        appendCount(item.skillNames.count, singular: "skill", plural: "skills", to: &parts)
        appendCount(item.connectorNames.count, singular: "connector", plural: "connectors", to: &parts)
        appendCount(item.toolNames.count, singular: "tool", plural: "tools", to: &parts)
        appendCount(item.browserAdapterNames.count, singular: "browser adapter", plural: "browser adapters", to: &parts)
        appendCount(item.templateNames.count, singular: "template", plural: "templates", to: &parts)

        if !parts.isEmpty {
            return parts.joined(separator: ", ")
        }

        let fallback = item.presentation.rowSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "No resources" : fallback
    }

    private func appendCount(_ count: Int, singular: String, plural: String, to parts: inout [String]) {
        guard count > 0 else { return }
        parts.append("\(count) \(count == 1 ? singular : plural)")
    }

    private func isWorkspaceAuthoredCapability(_ item: RailCapabilityItem) -> Bool {
        switch item.source {
        case .package(let package):
            let kind = package.sourceMetadata?.kind
            return kind == "workspace" || kind == "shared"
        case .skill:
            return true
        }
    }

    private var capabilityRailSnapshot: CapabilityRailSnapshot {
        PerformanceTelemetry.measure(
            "workspace_right_rail_capability_snapshot",
            thresholdMilliseconds: 20,
            fields: [
                "workspace_id": workspace.id.uuidString,
                "package_count": String(approvedCapabilityPackages.count)
            ]
        ) {
            let currentCapabilities = capabilities
            var cachedStates: [String: CapabilityPackageState] = [:]

            func state(for package: PluginPackage) -> CapabilityPackageState {
                if let cached = cachedStates[package.id] {
                    return cached
                }
                let state = CapabilityPackageState(
                    package: package,
                    workspace: workspace,
                    capabilities: currentCapabilities
                )
                cachedStates[package.id] = state
                return state
            }

            let catalogPackages = CapabilityCatalogInventory.packages(
                catalogPackages: approvedCapabilityPackages,
                capabilities: currentCapabilities,
                policyContext: catalogPolicyContext
            )

            let items = catalogPackages
                .compactMap { package -> RailCapabilityItem? in
                    let packageState = state(for: package)
                    guard packageState.isEnabled else { return nil }
                    return makePackageCapabilityItem(
                        package,
                        state: packageState,
                        prerequisiteStatuses: capabilityPrerequisiteStatuses
                    )
                }
                .sorted(by: sortRailCapabilityItems)

            return CapabilityRailSnapshot(
                items: items,
                isDraft: isDraftCapability
            )
        }
    }

    private var enabledSharedResourceCount: Int {
        enabledGlobalSkills.count + enabledGlobalConnectors.count + capabilities.enabledGlobalTools.count
    }

    private var availableSharedResourceCount: Int {
        let disabledSharedSkills = capabilities.availableGlobalSkills.filter {
            !workspace.enabledGlobalSkillIDs.contains($0.id.uuidString)
        }.count
        let disabledSharedConnectors = capabilities.availableGlobalConnectors.filter {
            !workspace.enabledGlobalConnectorIDs.contains($0.id.uuidString)
        }.count
        let disabledSharedTools = capabilities.availableGlobalTools.filter {
            !workspace.enabledGlobalToolIDs.contains($0.id.uuidString)
        }.count
        return disabledSharedSkills + disabledSharedConnectors + disabledSharedTools
    }

    private var workspaceOnlyResourceCount: Int {
        capabilities.workspaceSkills.count + capabilities.workspaceConnectors.count + capabilities.workspaceTools.count
    }

    private var railCapabilityItems: [RailCapabilityItem] {
        capabilityRailSnapshot.items
    }

    private func sortRailCapabilityItems(_ lhs: RailCapabilityItem, _ rhs: RailCapabilityItem) -> Bool {
        let lhsNeedsSetup = lhs.readiness.level == .needsAttention
        let rhsNeedsSetup = rhs.readiness.level == .needsAttention
        if lhsNeedsSetup != rhsNeedsSetup { return lhsNeedsSetup && !rhsNeedsSetup }

        let lhsPriority = railCapabilityPriority(lhs)
        let rhsPriority = railCapabilityPriority(rhs)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func railCapabilityPriority(_ item: RailCapabilityItem) -> Int {
        let normalizedID: String? = {
            if case .package(let package) = item.source {
                return package.id.lowercased()
            }
            return nil
        }()
        let normalizedName = item.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")

        if normalizedID == "jira-workflow" || normalizedName.contains("jira") { return 0 }
        if normalizedID == "github-workflow" || normalizedName.contains("github") { return 1 }
        if normalizedID == "gcloud-workflow" || normalizedName.contains("google-cloud") || normalizedName.contains("gcloud") { return 2 }
        if normalizedName.contains("claude") { return 3 }
        if normalizedID == "redcap-workflow" || normalizedName.contains("redcap") { return 4 }
        if normalizedName.contains("bigquery") { return 5 }
        return 100
    }

    private func makePackageCapabilityItem(
        _ package: PluginPackage,
        state: CapabilityPackageState,
        prerequisiteStatuses: [String: HealthStatus]
    ) -> RailCapabilityItem {
        let sharedResourceCount = state.linkedSkills.filter(\.isGlobal).count
            + state.linkedConnectors.filter(\.isGlobal).count
            + state.linkedTools.filter(\.isGlobal).count
        let workspaceResourceCount = state.linkedSkills.filter { !$0.isGlobal }.count
            + state.linkedConnectors.filter { !$0.isGlobal }.count
            + state.linkedTools.filter { !$0.isGlobal }.count
        let declaredResourceCount = package.skills.count
            + package.connectors.count
            + package.localTools.count
            + package.templates.count
            + package.browserAdapters.count
        let readiness = readiness(
            for: package,
            stateReadiness: state.readiness,
            prerequisiteStatuses: prerequisiteStatuses
        )
        let presentation = CapabilityRailPackagePresentation.make(
            isEnabled: state.isEnabled,
            readinessLevel: readiness.level,
            workspaceName: workspace.name,
            sharedResourceCount: sharedResourceCount,
            workspaceResourceCount: workspaceResourceCount,
            declaredResourceCount: declaredResourceCount,
            contentSummary: package.contentSummary
        )

        return RailCapabilityItem(
            id: "package:\(package.id)",
            name: package.name,
            icon: package.icon,
            summary: package.description.isEmpty ? package.contentSummary : package.description,
            color: Stanford.lagunita,
            isEnabled: state.isEnabled,
            readiness: readiness,
            presentation: presentation,
            source: .package(package),
            skillNames: (package.skills.map(\.name) + state.linkedSkills.map(\.name)).uniqueSorted(),
            connectorNames: (package.connectors.map(\.name) + state.linkedConnectors.map { $0.name.isEmpty ? "Untitled Connector" : $0.name }).uniqueSorted(),
            toolNames: (package.localTools.map(\.name) + state.linkedTools.map { $0.name.isEmpty ? "Untitled Tool" : $0.name }).uniqueSorted(),
            browserAdapterNames: package.browserAdapters.map(browserAdapterDisplayName).uniqueSorted(),
            templateNames: package.templates.map(\.name).uniqueSorted(),
            requirementNames: package.prerequisites.map(\.displayName).uniqueSorted()
        )
    }

    private func makeSkillCapabilityItem(_ skill: Skill) -> RailCapabilityItem {
        let connectors = uniqueConnectors(skill.connectors)
        let tools = uniqueTools(skill.localTools)
        let isEnabled = skill.isGlobal ? workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString) : true
        let presentation = CapabilityRailPackagePresentation.make(
            isEnabled: isEnabled,
            readinessLevel: readinessForSkill(isEnabled: isEnabled, connectors: connectors).level,
            workspaceName: workspace.name,
            sharedResourceCount: skillSharedResourceCount(skill: skill, connectors: connectors, tools: tools),
            workspaceResourceCount: skillWorkspaceResourceCount(skill: skill, connectors: connectors, tools: tools),
            declaredResourceCount: 1 + connectors.count + tools.count,
            contentSummary: "\(skill.allowedTools.count) permission\(skill.allowedTools.count == 1 ? "" : "s")"
        )
        return RailCapabilityItem(
            id: "skill:\(skill.id.uuidString)",
            name: skill.name.isEmpty ? "Untitled Capability" : skill.name,
            icon: skill.icon,
            summary: skill.skillDescription.isEmpty ? "\(skill.allowedTools.count) permissions" : skill.skillDescription,
            color: Stanford.lagunita,
            isEnabled: isEnabled,
            readiness: readinessForSkill(isEnabled: isEnabled, connectors: connectors),
            presentation: presentation,
            source: .skill(skill),
            skillNames: [skill.name.isEmpty ? "Untitled Skill" : skill.name],
            connectorNames: connectors.map { $0.name.isEmpty ? "Untitled Connector" : $0.name }.uniqueSorted(),
            toolNames: tools.map { $0.name.isEmpty ? "Untitled Tool" : $0.name }.uniqueSorted(),
            browserAdapterNames: [],
            templateNames: [],
            requirementNames: []
        )
    }

    private func readinessForSkill(isEnabled: Bool, connectors: [Connector]) -> CapabilityReadiness {
        guard isEnabled else { return .inactive }

        let messages = connectors.flatMap { connector -> [String] in
            guard connector.authMethod != "none" else { return [] }
            let name = connector.name.isEmpty ? "Connector" : connector.name
            let missing = connector.missingCredentialKeys()
            if !missing.isEmpty {
                return ["\(name): missing \(missing.joined(separator: ", "))"]
            }
            if connector.credentialKeys.isEmpty {
                return ["\(name): no credentials configured"]
            }
            return []
        }

        return messages.isEmpty
            ? .ready
            : CapabilityReadiness(level: .needsAttention, messages: messages)
    }

    private func readiness(
        for package: PluginPackage,
        stateReadiness: CapabilityReadiness,
        prerequisiteStatuses: [String: HealthStatus]
    ) -> CapabilityReadiness {
        guard stateReadiness.level != .inactive else { return stateReadiness }
        let prerequisiteMessages = CapabilityHealthService.readinessMessages(
            for: package,
            statuses: prerequisiteStatuses
        )
        guard !prerequisiteMessages.isEmpty else { return stateReadiness }
        let existingMessages = stateReadiness.level == .ready ? [] : stateReadiness.messages
        return CapabilityReadiness(
            level: .needsAttention,
            messages: existingMessages + prerequisiteMessages
        )
    }

    private func skillSharedResourceCount(skill: Skill, connectors: [Connector], tools: [LocalTool]) -> Int {
        (skill.isGlobal ? 1 : 0)
            + connectors.filter(\.isGlobal).count
            + tools.filter(\.isGlobal).count
    }

    private func skillWorkspaceResourceCount(skill: Skill, connectors: [Connector], tools: [LocalTool]) -> Int {
        (skill.isGlobal ? 0 : 1)
            + connectors.filter { !$0.isGlobal }.count
            + tools.filter { !$0.isGlobal }.count
    }

    private func linkedConnectors(for package: PluginPackage, linkedSkills: [Skill]) -> [Connector] {
        let packageNames = Set(package.connectors.map(\.name))
        let active = capabilities.activeConnectors.filter { packageNames.contains($0.name) }
        return uniqueConnectors(active + linkedSkills.flatMap(\.connectors))
    }

    private func linkedTools(for package: PluginPackage, linkedSkills: [Skill]) -> [LocalTool] {
        let packageNames = Set(package.localTools.map(\.name))
        let active = capabilities.activeTools.filter { packageNames.contains($0.name) }
        return uniqueTools(active + linkedSkills.flatMap(\.localTools))
    }

    private func hasEnabledElements(
        package: PluginPackage,
        linkedSkills: [Skill],
        linkedConnectors: [Connector],
        linkedTools: [LocalTool]
    ) -> Bool {
        if linkedSkills.contains(where: { skill in
            skill.isGlobal ? workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString) : workspace.skills.contains { $0.id == skill.id }
        }) {
            return true
        }

        if linkedConnectors.contains(where: { connector in
            connector.isGlobal ? workspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString) : workspace.connectors.contains { $0.id == connector.id }
        }) {
            return true
        }

        if linkedTools.contains(where: { tool in
            tool.isGlobal ? workspace.enabledGlobalToolIDs.contains(tool.id.uuidString) : workspace.localTools.contains { $0.id == tool.id }
        }) {
            return true
        }

        return false
    }

    private func setCapability(_ item: RailCapabilityItem, enabled: Bool) {
        switch item.source {
        case .package(let package):
            if enabled {
                let traceID = AuditTrace.make("capability-enable")
                AppLogger.breadcrumb(action: "enable_capability_clicked", category: "Capabilities", traceID: traceID, fields: [
                    "source": "right_rail",
                    "package_id": package.id,
                    "package_name": package.name,
                    "workspace_id": workspace.id.uuidString,
                    "readiness_level": String(describing: item.readiness.level),
                    "requirement_count": String(item.requirementNames.count)
                ])
                AppLogger.audit(.capabilityEnableStarted, category: "Capabilities", fields: [
                    "source": "right_rail",
                    "trace_id": traceID,
                    "package_id": package.id,
                    "package_name": package.name,
                    "package_version": package.version,
                    "workspace_id": workspace.id.uuidString,
                    "readiness_level": String(describing: item.readiness.level),
                    "readiness_messages_count": String(item.readiness.messages.count),
                    "requirement_count": String(item.requirementNames.count)
                ])
                do {
                    try CapabilityInstaller().install(
                        package,
                        into: workspace,
                        modelContext: modelContext,
                        policyContext: catalogPolicyContext,
                        traceID: traceID
                    )
                    refreshApprovedCapabilities()
                    refreshCapabilityPrerequisiteStatuses()
                } catch {
                    capabilityError = error.localizedDescription
                    AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                        "result": "failed",
                        "source": "right_rail",
                        "trace_id": traceID,
                        "package_id": package.id,
                        "package_name": package.name,
                        "workspace_id": workspace.id.uuidString,
                        "readiness_level": String(describing: item.readiness.level),
                        "readiness_messages_count": String(item.readiness.messages.count),
                        "requirement_count": String(item.requirementNames.count),
                        "error_type": String(describing: type(of: error))
                    ], level: .error)
                }
            } else {
                disablePackageCapability(package)
            }
        case .skill(let skill):
            guard skill.isGlobal else { return }
            let traceID = AuditTrace.make("skill-toggle")
            AppLogger.breadcrumb(action: enabled ? "enable_skill_clicked" : "disable_skill_clicked", category: "Capabilities", traceID: traceID, fields: [
                "source": "right_rail",
                "skill_id": skill.id.uuidString,
                "skill_name": skill.name,
                "workspace_id": workspace.id.uuidString
            ])
            let idString = skill.id.uuidString
            if enabled {
                if !workspace.enabledGlobalSkillIDs.contains(idString) {
                    workspace.enabledGlobalSkillIDs.append(idString)
                }
            } else {
                workspace.enabledGlobalSkillIDs.removeAll { $0 == idString }
            }
            workspace.updatedAt = Date()
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
            AppLogger.audit(enabled ? .capabilityEnabled : .capabilityDisabled, category: "Capabilities", fields: [
                "source": "skill",
                "trace_id": traceID,
                "skill_id": skill.id.uuidString,
                "workspace_id": workspace.id.uuidString,
                "readiness_level": String(describing: item.readiness.level),
                "readiness_messages_count": String(item.readiness.messages.count)
            ])
        }
    }

    private func disablePackageCapability(_ package: PluginPackage) {
        let state = CapabilityPackageState(
            package: package,
            workspace: workspace,
            capabilities: capabilities
        )
        let traceID = AuditTrace.make("capability-disable")
        AppLogger.breadcrumb(action: "disable_capability_clicked", category: "Capabilities", traceID: traceID, fields: [
            "source": "right_rail",
            "package_id": package.id,
            "package_name": package.name,
            "workspace_id": workspace.id.uuidString
        ])
        AppLogger.audit(.capabilityDisableStarted, category: "Capabilities", fields: [
            "source": "right_rail",
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
            availablePackages: approvedCapabilityPackages + PluginCatalog.builtInPackages
        )
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
            "source": "package",
            "trace_id": traceID,
            "package_id": package.id,
            "workspace_id": workspace.id.uuidString,
            "skills_count": String(state.skillIDStrings.count),
            "connectors_count": String(state.connectorIDStrings.count),
            "tools_count": String(state.toolIDStrings.count),
            "removed_workspace_skills_count": String(result.removedWorkspaceSkillIDs.count),
            "removed_workspace_connectors_count": String(result.removedWorkspaceConnectorIDs.count),
            "readiness_level": String(describing: state.readiness.level),
            "readiness_messages_count": String(state.readiness.messages.count)
        ])
    }

    private func openCapabilityConfiguration(_ item: RailCapabilityItem) {
        switch item.source {
        case .package(let package):
            if let onOpenCapabilityPackage {
                onOpenCapabilityPackage(package.id)
            } else {
                onOpenConfigureTab?(.capabilities, nil)
            }
        case .skill(let skill):
            onOpenConfigureTab?(.skills, skill.id)
        }
    }

    private func refreshApprovedCapabilities() {
        let packages = PerformanceTelemetry.measure(
            "workspace_right_rail_capability_load",
            thresholdMilliseconds: 20
        ) {
            CapabilityLibrary().installedPackages()
        }
        approvedCapabilityPackages = packages.isEmpty ? PluginCatalog.builtInPackages : packages
    }

    private func refreshCapabilityPrerequisiteStatuses() {
        let currentCapabilities = capabilities
        let packages = approvedCapabilityPackages.filter { package in
            guard !package.prerequisites.isEmpty else { return false }
            return CapabilityPackageState(
                package: package,
                workspace: workspace,
                capabilities: currentCapabilities
            ).isEnabled
        }
        Task { @MainActor in
            let cache = PreflightCache()
            var statuses: [String: HealthStatus] = [:]
            for package in packages {
                let packageStatuses = await CapabilityHealthService.prerequisiteStatuses(
                    for: package,
                    cache: cache
                )
                statuses.merge(packageStatuses) { _, new in new }
            }
            capabilityPrerequisiteStatuses = statuses
        }
    }

    private func readinessColor(for readiness: CapabilityReadiness, isEnabled: Bool) -> Color {
        guard isEnabled else { return Color.secondary.opacity(0.45) }
        switch readiness.level {
        case .ready:
            return Stanford.paloAltoGreen
        case .needsAttention:
            return Stanford.poppy
        case .inactive:
            return Color.secondary.opacity(0.45)
        }
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

    // MARK: - Connector Subsection

    private var connectorSubsection: some View {
        VStack(alignment: .leading, spacing: sectionContentSpacing) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(Stanford.ui(12))
                        .foregroundStyle(Stanford.paloAltoGreen)
                    Text("Connectors")
                        .font(Stanford.caption(12).weight(.semibold))
                    Text("\(workspaceConnectors.count) active")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            let localConnectors = capabilities.workspaceConnectors

            ForEach(localConnectors) { connector in
                CapabilityRow(
                    icon: connector.icon,
                    title: connector.name.isEmpty ? "Untitled" : connector.name,
                    subtitle: connector.displaySummary,
                    color: Stanford.paloAltoGreen,
                    trailing: "Connected"
                )
            }

            let availableGlobals = capabilities.availableGlobalConnectors

            ForEach(availableGlobals) { connector in
                CapabilityToggleRow(
                    icon: connector.icon,
                    title: connector.name.isEmpty ? "Untitled" : connector.name,
                    subtitle: connector.displaySummary,
                    color: Stanford.paloAltoGreen,
                    isOn: workspaceGlobalConnectorBinding(connector)
                )
            }
        }
    }

    // MARK: - Tools & Templates Pills

    @ViewBuilder
    private var toolsAndTemplatesPills: some View {
        let availableGlobalTools = capabilities.availableGlobalTools.filter {
            !workspace.enabledGlobalToolIDs.contains($0.id.uuidString)
        }
        let hasTools = !workspaceTools.isEmpty || !availableGlobalTools.isEmpty

        if !hasTools && templates.isEmpty {
            Text("No tools or templates attached")
                .font(Stanford.caption(11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        } else {
            if hasTools {
                resourceSection(
                    title: "Tools",
                    count: workspaceTools.count,
                    icon: "wrench.and.screwdriver",
                    color: Stanford.plum,
                    isExpanded: $isToolsExpanded
                ) {
                    if !workspaceTools.isEmpty {
                        resourceRows(
                            items: workspaceTools,
                            emptyTitle: "No tools",
                            emptyDescription: "Add scripts or CLI commands in Configure."
                        ) { tool in
                            ResourceRow(
                                icon: LocalTool.iconForType(tool.toolType),
                                title: tool.name.isEmpty ? "Untitled Tool" : tool.name,
                                subtitle: tool.displayCommand.isEmpty ? tool.toolType.uppercased() : tool.displayCommand,
                                color: Stanford.plum,
                                onEdit: { onOpenConfigureTab?(.tools, tool.id) }
                            )
                        }
                    }

                    ForEach(availableGlobalTools) { tool in
                        CapabilityToggleRow(
                            icon: LocalTool.iconForType(tool.toolType),
                            title: tool.name.isEmpty ? "Untitled Tool" : tool.name,
                            subtitle: tool.displayCommand.isEmpty ? tool.toolType.uppercased() : tool.displayCommand,
                            color: Stanford.plum,
                            isOn: workspaceGlobalToolBinding(tool)
                        )
                    }
                }
            }

            if !templates.isEmpty {
                resourceSection(
                    title: "Templates",
                    count: templates.count,
                    icon: "rectangle.3.group",
                    color: Stanford.poppy,
                    isExpanded: $isTemplatesExpanded
                ) {
                    resourceRows(
                        items: templates,
                        emptyTitle: "No templates",
                        emptyDescription: "Create reusable task workflows in Configure."
                    ) { template in
                        ResourceRow(
                            icon: template.icon,
                            title: template.name,
                            subtitle: template.templateDescription.isEmpty ? templatePhaseSummary(template) : template.templateDescription,
                            color: Stanford.poppy,
                            onEdit: { onOpenConfigureTab?(.templates, template.id) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Context Section

    private var workspaceSetupChecklistPanel: some View {
        VStack(alignment: .leading, spacing: sectionContentSpacing) {
            rightRailSectionHeader(WorkspaceSetupChecklistPresentation.sectionTitle) {
                EmptyView()
            }

            VStack(alignment: .leading, spacing: capabilityGroupSpacing + 2) {
                if workspaceSetupMissingCount > 0 {
                    workspaceSetupGroup(WorkspaceSetupChecklistPresentation.missingGroupTitle) {
                        workspaceSetupRows(for: .missing)
                    }
                }

                if workspaceSetupConfiguredCount > 0 {
                    workspaceSetupConfiguredGroup
                }
            }
        }
    }

    private var workspaceSetupConfiguredGroup: some View {
        workspaceSetupGroup(WorkspaceSetupChecklistPresentation.configuredGroupTitle) {
            if isConfiguredWorkspaceSetupExpanded {
                workspaceSetupRows(for: .configured)
                Button {
                    withAnimation(disclosureAnimation) {
                        isConfiguredWorkspaceSetupExpanded = false
                    }
                } label: {
                    Text("Hide")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                        .padding(.leading, CapabilityRailLayout.dividerLeadingPadding(isCompact: isCompact))
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            } else {
                CapabilitySummaryRow(
                    icon: WorkspaceSetupChecklistPresentation.configuredSummaryIcon,
                    iconColor: Stanford.lagunita,
                    title: WorkspaceSetupChecklistPresentation.configuredSummaryTitle,
                    subtitle: workspaceSetupConfiguredPreview,
                    actionTitle: WorkspaceSetupChecklistPresentation.configuredSummaryActionTitle,
                    action: {
                        withAnimation(disclosureAnimation) {
                            isConfiguredWorkspaceSetupExpanded = true
                        }
                    }
                )
            }
        }
    }

    private func workspaceSetupGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            capabilityGroupHeader(title, count: 0, style: .ready)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func workspaceSetupRows(for state: WorkspaceSetupChecklistPresentation.State) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let rows = workspaceSetupRowItems(for: state)
            ForEach(Array(rows.enumerated()), id: \.element) { index, item in
                workspaceSetupRow(for: item)

                if index < rows.count - 1 {
                    checklistDivider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workspaceSetupRowItems(for state: WorkspaceSetupChecklistPresentation.State) -> [WorkspaceSetupItem] {
        var items: [WorkspaceSetupItem] = []
        if workspaceSetupState(for: .instructions) == state { items.append(.instructions) }
        if workspaceSetupState(for: .memory) == state { items.append(.memory) }
        if workspaceSetupState(for: .folders) == state { items.append(.folders) }
        if workspaceSetupState(for: .remoteAccess) == state { items.append(.remoteAccess) }
        if !workspace.schedules.isEmpty, state == .configured { items.append(.routines) }
        return items
    }

    private var workspaceSetupConfiguredPreview: String {
        WorkspaceSetupChecklistPresentation.configuredPreview(
            workspaceSetupRowItems(for: .configured).map(workspaceSetupTitle(for:))
        )
    }

    private func workspaceSetupTitle(for item: WorkspaceSetupItem) -> String {
        switch item {
        case .instructions:
            return "Instructions"
        case .memory:
            return "Memory"
        case .folders:
            return "Folders"
        case .remoteAccess:
            return "Remote access"
        case .routines:
            return "Routines"
        }
    }

    private func workspaceSetupState(for item: WorkspaceSetupItem) -> WorkspaceSetupChecklistPresentation.State {
        switch item {
        case .instructions:
            hasWorkspaceInstructions ? .configured : .missing
        case .memory:
            workspace.memories.isEmpty ? .missing : .configured
        case .folders:
            workspaceFolderCount > 0 ? .configured : .missing
        case .remoteAccess:
            sshConnections.isEmpty ? .missing : .configured
        case .routines:
            .configured
        }
    }

    @ViewBuilder
    private func workspaceSetupRow(for item: WorkspaceSetupItem) -> some View {
        switch item {
        case .instructions:
            workspaceSetupChecklistRow(
                item: .instructions,
                icon: "text.quote",
                title: "Instructions",
                subtitle: hasWorkspaceInstructions ? "Main task guidance is set" : "Add guidance for how tasks should run",
                state: workspaceSetupState(for: .instructions),
                actionTitle: hasWorkspaceInstructions ? "Edit" : "Add",
                action: {
                    withAnimation(disclosureAnimation) {
                        _ = expandedWorkspaceSetupItems.insert(.instructions)
                    }
                }
            ) {
                instructionsSetupDetails
            }
        case .memory:
            workspaceSetupChecklistRow(
                item: .memory,
                icon: "text.badge.checkmark",
                title: "Memory",
                subtitle: workspace.memories.isEmpty
                    ? "Save details the agent should remember"
                    : "\(workspace.memories.count) saved \(workspace.memories.count == 1 ? "detail" : "details")",
                state: workspaceSetupState(for: .memory),
                actionTitle: "Add",
                action: {
                    withAnimation(disclosureAnimation) {
                        _ = expandedWorkspaceSetupItems.insert(.memory)
                        isMemoryComposerVisible = true
                    }
                }
            ) {
                memorySetupDetails
            }
        case .folders:
            workspaceSetupChecklistRow(
                item: .folders,
                icon: "folder",
                title: "Folders",
                subtitle: workspace.primaryPath.isEmpty
                    ? "No folder selected"
                    : "Primary \(compactPath(workspace.primaryPath))",
                state: workspaceSetupState(for: .folders),
                actionTitle: "Add",
                action: {
                    withAnimation(disclosureAnimation) {
                        _ = expandedWorkspaceSetupItems.insert(.folders)
                    }
                    addExtraFolder()
                }
            ) {
                foldersSetupDetails
            }
        case .remoteAccess:
            workspaceSetupChecklistRow(
                item: .remoteAccess,
                icon: "network",
                title: "Remote access",
                subtitle: sshConnections.isEmpty
                    ? "Add remote servers the agent can access"
                    : "\(sshConnections.count) configured \(sshConnections.count == 1 ? "server" : "servers")",
                state: workspaceSetupState(for: .remoteAccess),
                actionTitle: "Add",
                action: onNewSSHConnection
            ) {
                remoteAccessSetupDetails
            }
        case .routines:
            workspaceSetupChecklistRow(
                item: .routines,
                icon: "arrow.triangle.2.circlepath",
                title: "Routines",
                subtitle: "\(workspace.schedules.count) scheduled \(workspace.schedules.count == 1 ? "routine" : "routines")",
                state: .configured,
                actionTitle: "Add",
                action: onNewSchedule
            ) {
                routinesSetupDetails
            }
        }
    }

    private func workspaceSetupChecklistRow<Details: View>(
        item: WorkspaceSetupItem,
        icon: String,
        title: String,
        subtitle: String,
        state: WorkspaceSetupChecklistPresentation.State,
        actionTitle: String?,
        action: (() -> Void)?,
        @ViewBuilder details: () -> Details
    ) -> some View {
        let isExpanded = expandedWorkspaceSetupItems.contains(item)

        return VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    toggleWorkspaceSetupItem(item)
                } label: {
                    HStack(alignment: .center, spacing: CapabilityRailLayout.leadingIconSpacing) {
                        Image(systemName: icon)
                            .font(Stanford.ui(CapabilityRailLayout.leadingIconFontSize, weight: .medium))
                            .foregroundStyle(setupChecklistIconColor(for: state))
                            .frame(width: CapabilityRailLayout.leadingIconFrame)

                        VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                            Text(title)
                                .font(Stanford.ui(CapabilityRailLayout.rowTitleFontSize, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(subtitle)
                                .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 10)
                    }
                    .frame(maxWidth: .infinity, minHeight: CapabilityRailLayout.setupRowMinHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(Stanford.caption(CapabilityRailLayout.rowActionFontSize).weight(.medium))
                            .foregroundStyle(Stanford.lagunita)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(2)
                }

                Button {
                    toggleWorkspaceSetupItem(item)
                } label: {
                    Image(systemName: isExpanded
                        ? WorkspaceSetupChecklistPresentation.expandedDisclosureIcon
                        : WorkspaceSetupChecklistPresentation.collapsedDisclosureIcon)
                        .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 22)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                details()
                    .padding(.leading, CapabilityRailLayout.dividerLeadingPadding(isCompact: isCompact))
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
            }
        }
    }

    private func toggleWorkspaceSetupItem(_ item: WorkspaceSetupItem) {
        withAnimation(disclosureAnimation) {
            if expandedWorkspaceSetupItems.contains(item) {
                expandedWorkspaceSetupItems.remove(item)
            } else {
                expandedWorkspaceSetupItems.insert(item)
            }
        }
    }

    private var instructionsSetupDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if workspace.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add guidance for how tasks in this workspace should run...")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }

                TextEditor(text: workspaceInstructionsBinding)
                    .font(Stanford.caption(12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 78, maxHeight: 140)
                    .padding(5)
            }
            .background(setupInlineControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Text("Included in every new task prompt.")
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if hasWorkspaceInstructions {
                    Button {
                        workspace.instructions = ""
                        markWorkspaceConfigurationChanged()
                    } label: {
                        Text("Clear")
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var memorySetupDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspace.memories.isEmpty {
                setupEmptyDetail("No saved memory details yet.")
            } else {
                ForEach(Array(workspace.memories.indices), id: \.self) { index in
                    editableMemoryRow(index)
                }
            }

            if isMemoryComposerVisible {
                memoryComposer
                    .padding(.top, 2)
            }
        }
    }

    private var foldersSetupDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspaceFolderCount == 0 {
                setupEmptyDetail("No workspace folder selected.")
            } else {
                let descriptors = WorkspacePathPresentation.descriptors(
                    primaryPath: workspace.primaryPath,
                    additionalPaths: workspace.additionalPaths
                )
                ForEach(descriptors) { descriptor in
                    let canRemove = descriptor.role == .additional
                    setupFolderRow(
                        title: descriptor.title,
                        roleLabel: descriptor.roleLabel,
                        path: descriptor.path,
                        canRemove: canRemove,
                        removeAction: canRemove ? { removeAdditionalPath(at: descriptor.index - 1) } : nil
                    )
                }
            }

            Button {
                addExtraFolder()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(Stanford.ui(10, weight: .semibold))
                    Text("Add path")
                        .font(Stanford.caption(11).weight(.medium))
                }
                .foregroundStyle(Stanford.lagunita)
            }
            .buttonStyle(.plain)
        }
    }

    private var remoteAccessSetupDetails: some View {
        let limit = WorkspaceSetupChecklistPresentation.detailPreviewLimit
        let visibleConnections = Array(sshConnections.prefix(limit))

        return VStack(alignment: .leading, spacing: 7) {
            if visibleConnections.isEmpty {
                setupEmptyDetail("No remote servers configured.")
            } else {
                ForEach(visibleConnections) { connection in
                    setupDetailItem(
                        title: connection.name.isEmpty ? connection.host : connection.name,
                        detail: remoteConnectionDetail(connection),
                        isMonospaced: true,
                        lineLimit: 1
                    )
                    .help(remoteConnectionDetail(connection))
                }

                setupOverflowDetail(
                    total: sshConnections.count,
                    visible: visibleConnections.count,
                    singular: "remote server",
                    plural: "remote servers"
                )
            }
        }
    }

    private var routinesSetupDetails: some View {
        let sortedSchedules = workspace.schedules.sorted { $0.name < $1.name }
        let limit = WorkspaceSetupChecklistPresentation.detailPreviewLimit
        let visibleSchedules = Array(sortedSchedules.prefix(limit))

        return VStack(alignment: .leading, spacing: 7) {
            if visibleSchedules.isEmpty {
                setupEmptyDetail("No routines configured.")
            } else {
                ForEach(visibleSchedules) { schedule in
                    setupDetailItem(
                        title: schedule.name,
                        detail: "\(schedule.frequencySummary) - \(schedule.isEnabled ? "Enabled" : "Paused")",
                        lineLimit: 1
                    )
                }

                setupOverflowDetail(
                    total: sortedSchedules.count,
                    visible: visibleSchedules.count,
                    singular: "routine",
                    plural: "routines"
                )
            }
        }
    }

    private func remoteConnectionDetail(_ connection: SSHConnection) -> String {
        let target = "\(connection.user)@\(connection.host):\(connection.port)"
        let remotePath = connection.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return remotePath.isEmpty ? target : "\(target)  \(remotePath)"
    }

    private var workspaceInstructionsBinding: Binding<String> {
        Binding(
            get: { workspace.instructions },
            set: { value in
                workspace.instructions = value
                markWorkspaceConfigurationChanged()
            }
        )
    }

    private func memoryBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard workspace.memories.indices.contains(index) else { return "" }
                return workspace.memories[index]
            },
            set: { value in
                guard workspace.memories.indices.contains(index) else { return }
                workspace.memories[index] = value
                markWorkspaceConfigurationChanged()
            }
        )
    }

    private func editableMemoryRow(_ index: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            TextField("Saved detail", text: memoryBinding(at: index), axis: .vertical)
                .font(Stanford.caption(12))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .background(setupInlineControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            Button {
                removeMemory(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(Stanford.ui(11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 24)
            }
            .buttonStyle(.plain)
            .help("Remove memory")
        }
    }

    private func setupFolderRow(
        title: String,
        roleLabel: String,
        path: String,
        canRemove: Bool = false,
        removeAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(roleLabel)
                        .font(Stanford.caption(9).weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Text(compactPath(path))
                    .font(Stanford.mono(10))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(Stanford.ui(10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .help("Copy path")

            if canRemove, let removeAction {
                Button(action: removeAction) {
                    Image(systemName: "trash")
                        .font(Stanford.ui(11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
                .help("Remove path")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(setupInlineControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
    }

    private func setupDetailItem(
        title: String,
        detail: String,
        isMonospaced: Bool = false,
        lineLimit: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(detail)
                .font(isMonospaced ? Stanford.mono(10) : Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .truncationMode(isMonospaced ? .middle : .tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setupEmptyDetail(_ text: String) -> some View {
        Text(text)
            .font(Stanford.caption(11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var setupInlineControlBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.035)
    }

    @ViewBuilder
    private func setupOverflowDetail(
        total: Int,
        visible: Int,
        singular: String,
        plural: String
    ) -> some View {
        if let summary = WorkspaceSetupChecklistPresentation.overflowSummary(
            total: total,
            visible: visible,
            singular: singular,
            plural: plural
        ) {
            Text(summary)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(Stanford.lagunita)
        }
    }

    private func checklistDivider() -> some View {
        Divider()
            .opacity(0.22)
            .padding(.leading, CapabilityRailLayout.dividerLeadingPadding(isCompact: isCompact))
    }

    private func setupChecklistIconColor(for _: WorkspaceSetupChecklistPresentation.State) -> Color {
        Stanford.lagunita
    }

    private var workspaceFolderCount: Int {
        (workspace.primaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
            + workspace.additionalPaths.count
    }

    private var workspaceSetupConfiguredCount: Int {
        var count = 0
        if hasWorkspaceInstructions { count += 1 }
        if !workspace.memories.isEmpty { count += 1 }
        if workspaceFolderCount > 0 { count += 1 }
        if !sshConnections.isEmpty { count += 1 }
        if !workspace.schedules.isEmpty { count += 1 }
        return count
    }

    private var workspaceSetupMissingCount: Int {
        workspaceSetupTotalCount - workspaceSetupConfiguredCount
    }

    private var workspaceSetupTotalCount: Int {
        4 + (workspace.schedules.isEmpty ? 0 : 1)
    }

    // MARK: - Access Section

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: sectionContentSpacing) {
            // Paths
            HStack(spacing: 4) {
                Text("Paths")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button { addExtraFolder() } label: {
                    Text("+ Add folder")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Primary")
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                    Text(abbreviatePath(workspace.primaryPath))
                        .font(Stanford.mono(11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(workspace.primaryPath)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workspace.primaryPath, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(Stanford.ui(10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy path")
            }
            .padding(8)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall))

            ForEach(Array(workspace.additionalPaths.enumerated()), id: \.offset) { idx, path in
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(Stanford.ui(11))
                        .foregroundStyle(.secondary)
                    Text(abbreviatePath(path))
                        .font(Stanford.caption(12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(path)
                    Spacer(minLength: 0)
                    Button {
                        removeAdditionalPath(at: idx)
                    } label: {
                        Image(systemName: "xmark")
                            .font(Stanford.ui(10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
            }

            Divider().opacity(0.3)

            // SSH
            HStack(spacing: 4) {
                Text("SSH Connections")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { onNewSSHConnection?() } label: {
                    Text("+ Add remote server")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
            }

            if sshConnections.isEmpty {
                Text("No remote connections configured")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: contentListSpacing) {
                    ForEach(sshConnections) { conn in
                        Button { onEditSSHConnection?(conn) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "network")
                                    .font(Stanford.ui(12))
                                    .foregroundStyle(conn.lastTestResult == true ? Stanford.completed : (conn.lastTestResult == false ? Stanford.failed : .secondary))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(conn.name.isEmpty ? conn.host : conn.name)
                                        .font(Stanford.body(12).weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(conn.user)@\(conn.host):\(conn.port)")
                                        .font(Stanford.caption(11))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(Stanford.ui(10, weight: .semibold))
                                    .foregroundStyle(.quaternary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(Stanford.railInlineCardPadding)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius))
                    }
                }
            }
        }
    }

    // MARK: - Routines Content

    private var schedulesContent: some View {
        VStack(alignment: .leading, spacing: sectionContentSpacing) {
            if workspace.schedules.isEmpty {
                Button { onNewSchedule?() } label: {
                    Text("+ Add routine")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: contentListSpacing) {
                    ForEach(workspace.schedules.sorted { $0.name < $1.name }) { schedule in
                        HStack(spacing: 8) {
                            Button { onEditSchedule?(schedule) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(Stanford.ui(12))
                                        .foregroundStyle(schedule.isEnabled ? Stanford.lagunita : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(schedule.name)
                                            .font(Stanford.body(12).weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(schedule.frequencySummary)
                                            .font(Stanford.caption(11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle("Enabled", isOn: Binding(
                                get: { schedule.isEnabled },
                                set: { schedule.isEnabled = $0; schedule.updatedAt = Date() }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                        }
                        .padding(Stanford.railInlineCardPadding)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius))
                    }
                }
            }
        }
    }

    // MARK: - Collapsible Section Helpers

    private func collapsibleSection<Content: View>(
        _ title: String,
        summary: String? = nil,
        isCollapsed: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: isCollapsed.wrappedValue ? 0 : sectionContentSpacing) {
            Button {
                withAnimation(disclosureAnimation) {
                    isCollapsed.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let summary {
                        Text(summary)
                            .font(Stanford.caption(10).weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed.wrappedValue {
                content()
            }
        }
    }

    private func collapsibleSectionWithTrailing<Trailing: View, Content: View>(
        _ title: String,
        isCollapsed: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: isCollapsed.wrappedValue ? 0 : sectionContentSpacing) {
            HStack {
                Button {
                    withAnimation(disclosureAnimation) {
                        isCollapsed.wrappedValue.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                            .font(Stanford.ui(10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(title)
                            .font(Stanford.caption(11).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if !isCollapsed.wrappedValue {
                    trailing()
                }
            }

            if !isCollapsed.wrappedValue {
                content()
            }
        }
    }

    private func markWorkspaceConfigurationChanged() {
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func removeAdditionalPath(at index: Int) {
        guard workspace.additionalPaths.indices.contains(index) else { return }
        workspace.additionalPaths.remove(at: index)
        markWorkspaceConfigurationChanged()
    }

    private func loadSSHConnections() {
        guard !workspace.primaryPath.isEmpty else {
            sshConnections = []
            return
        }
        sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
    }

    private func checkGitRepositories() {
        let inputs = WorkspaceGitRepositoryScanInputs(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        Task {
            let repos = await GitService.shared.scanForGitRepositories(
                primaryPath: inputs.primaryPath,
                additionalPaths: inputs.additionalPaths
            )
            await MainActor.run {
                guard inputs.matches(
                    primaryPath: workspace.primaryPath,
                    additionalPaths: workspace.additionalPaths
                ) else { return }
                self.hasGitRepositories = !repos.isEmpty
            }
        }
    }

    private func applyConfigureDefaults() {
        isAccessCollapsed = sshConnections.isEmpty && workspace.additionalPaths.isEmpty
        isSchedulesSectionCollapsed = workspace.schedules.isEmpty
        isContextCollapsed = false
        isToolsExpanded = false
        isTemplatesExpanded = false
        isConfiguredWorkspaceSetupExpanded = false
        isMemoryComposerVisible = false
        expandedWorkspaceSetupItems = []
    }

    private func addExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder the agent can also read from or execute in"
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !workspace.additionalPaths.contains(path) {
                workspace.additionalPaths.append(path)
                markWorkspaceConfigurationChanged()
            }
        }
    }

    private func addMemory() {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        workspace.memories.append(text)
        markWorkspaceConfigurationChanged()
        newMemoryText = ""
        isMemoryComposerVisible = false
    }

    private func removeMemory(at index: Int) {
        guard workspace.memories.indices.contains(index) else { return }
        workspace.memories.remove(at: index)
        markWorkspaceConfigurationChanged()
    }

    private var memoryComposer: some View {
        HStack(spacing: 6) {
            TextField("Remember something about this workspace...", text: $newMemoryText, axis: .vertical)
                .font(Stanford.caption(12))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { addMemory() }

            Button {
                addMemory()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(Stanford.ui(14))
                    .foregroundStyle(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Stanford.sandstone : Stanford.lagunita)
            }
            .buttonStyle(.plain)
            .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                newMemoryText = ""
                isMemoryComposerVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var hasWorkspaceInstructions: Bool {
        !workspace.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func compactPath(_ path: String) -> String {
        let abbreviated = abbreviatePath(path)
        let parts = abbreviated
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard parts.count > 3 else { return abbreviated }

        let leaf = parts[parts.count - 1]
        let parent = parts[parts.count - 2]

        if abbreviated.hasPrefix("~/") {
            return "~/.../\(parent)/\(leaf)"
        }
        if abbreviated.hasPrefix("/") {
            return "/.../\(parent)/\(leaf)"
        }
        return ".../\(parent)/\(leaf)"
    }

    // MARK: - Inspector Helpers

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: sectionContentSpacing) {
            Text(title)
                .font(Stanford.ui(10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func inspectorSectionWithTrailing<Trailing: View, Content: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: sectionContentSpacing) {
            HStack {
                Text(title)
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .frame(width: Stanford.inspectorLabelWidth, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(Stanford.caption(12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var workspaceSkillSection: some View {
        VStack(alignment: .leading, spacing: sectionContentSpacing) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(Stanford.ui(12))
                        .foregroundStyle(Stanford.lagunita)
                    Text("Skills")
                        .font(Stanford.caption(12).weight(.semibold))
                    Text("\(availableSkills.count) active")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ForEach(workspaceSkills) { skill in
                CapabilityRow(
                    icon: skill.icon,
                    title: skill.name.isEmpty ? "Untitled" : skill.name,
                    subtitle: "\(skill.allowedTools.count) capabilities",
                    color: Stanford.lagunita,
                    onTap: { onOpenConfigureTab?(.skills, skill.id) }
                )
            }

            let availableGlobals = capabilities.availableGlobalSkills

            ForEach(availableGlobals) { skill in
                CapabilityToggleRow(
                    icon: skill.icon,
                    title: skill.name.isEmpty ? "Untitled" : skill.name,
                    subtitle: "\(skill.allowedTools.count) capabilities",
                    color: Stanford.lagunita,
                    isOn: workspaceGlobalSkillBinding(skill)
                )
            }
        }
    }

    private func resourceSection<Content: View>(
        title: String,
        count: Int,
        icon: String,
        color: Color,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: sectionContentSpacing) {
            Button {
                withAnimation(disclosureAnimation) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Text(title)
                        .font(Stanford.body(13).weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    RailCountBadge(count: count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    @ViewBuilder
    private func resourceRows<Item: Identifiable, Row: View>(
        items: [Item],
        emptyTitle: String,
        emptyDescription: String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if items.isEmpty {
            EmptyRailState(title: emptyTitle, description: emptyDescription)
        } else {
            VStack(spacing: contentListSpacing) {
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }

    private func workspaceGlobalSkillBinding(_ skill: Skill) -> Binding<Bool> {
        Binding(
            get: {
                workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString)
            },
            set: { enabled in
                let idString = skill.id.uuidString
                if enabled {
                    if !workspace.enabledGlobalSkillIDs.contains(idString) {
                        workspace.enabledGlobalSkillIDs.append(idString)
                    }
                } else {
                    workspace.enabledGlobalSkillIDs.removeAll { $0 == idString }
                }
                workspace.updatedAt = Date()
                WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
            }
        )
    }

    private func workspaceGlobalConnectorBinding(_ connector: Connector) -> Binding<Bool> {
        Binding(
            get: {
                workspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString)
            },
            set: { enabled in
                let idString = connector.id.uuidString
                if enabled {
                    if !workspace.enabledGlobalConnectorIDs.contains(idString) {
                        workspace.enabledGlobalConnectorIDs.append(idString)
                    }
                } else {
                    workspace.enabledGlobalConnectorIDs.removeAll { $0 == idString }
                }
                workspace.updatedAt = Date()
                WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
            }
        )
    }

    private func workspaceGlobalToolBinding(_ tool: LocalTool) -> Binding<Bool> {
        Binding(
            get: {
                workspace.enabledGlobalToolIDs.contains(tool.id.uuidString)
            },
            set: { enabled in
                let idString = tool.id.uuidString
                if enabled {
                    if !workspace.enabledGlobalToolIDs.contains(idString) {
                        workspace.enabledGlobalToolIDs.append(idString)
                    }
                } else {
                    workspace.enabledGlobalToolIDs.removeAll { $0 == idString }
                }
                workspace.updatedAt = Date()
                WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
            }
        )
    }

    private func uniqueTools(_ tools: [LocalTool]) -> [LocalTool] {
        Dictionary(grouping: tools, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueSkills(_ skills: [Skill]) -> [Skill] {
        Dictionary(grouping: skills, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        Dictionary(grouping: connectors, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func templatePhaseSummary(_ template: TaskTemplate) -> String {
        var phases = ["main"]
        if template.hasBeforePhase {
            phases.insert("before", at: 0)
        }
        if template.hasAfterPhase {
            phases.append("after")
        }
        return phases.joined(separator: " · ")
    }
}


struct WorkspaceGitRepositoryScanInputs: Equatable {
    let primaryPath: String
    let additionalPaths: [String]

    func matches(primaryPath: String, additionalPaths: [String]) -> Bool {
        self.primaryPath == primaryPath && self.additionalPaths == additionalPaths
    }
}

extension View {
    func railCard(
        cornerRadius: CGFloat = Stanford.railCardCornerRadius,
        fill: Color = Color(nsColor: .windowBackgroundColor),
        strokeOpacity: Double = 0.06
    ) -> some View {
        liquidSurface(
            cornerRadius: cornerRadius,
            fallbackFill: fill,
            fallbackStrokeOpacity: strokeOpacity
        )
    }
}
