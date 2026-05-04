import AppKit
import ASTRACore
import SwiftData
import SwiftUI

private enum WorkspaceRightRailTab: String, CaseIterable, Identifiable {
    case configure
    case usage
    case logs

    var id: Self { self }

    var title: String {
        switch self {
        case .configure: "Configure"
        case .usage: "Usage"
        case .logs: "Logs"
        }
    }

    var subtitle: String {
        switch self {
        case .configure: "Skills, connectors, context, and settings"
        case .usage: "Tokens, costs, and task activity"
        case .logs: "Runtime diagnostics and log access"
        }
    }

    var icon: String {
        switch self {
        case .configure: "slider.horizontal.3"
        case .usage: "chart.bar"
        case .logs: "doc.text.magnifyingglass"
        }
    }
}

struct WorkspaceRightRailView: View {
    let workspace: Workspace
    let selectedTask: AgentTask?
    let onConfigure: () -> Void
    let onEditWorkspace: () -> Void
    let onShowDashboard: () -> Void
    let onShowLogs: () -> Void
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    var onManageCapabilities: (() -> Void)?
    var onOpenConfigureTab: ((ConfigureTab, UUID?) -> Void)?
    var onNewSSHConnection: (() -> Void)?
    var onEditSSHConnection: ((SSHConnection) -> Void)?
    var sshReloadTrigger: Int = 0

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]

    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: WorkspaceRightRailTab = .configure
    @State private var isIdentityCollapsed = true
    @State private var isCapabilitiesCollapsed = false
    @State private var isContextCollapsed = false
    @State private var isAccessCollapsed = true
    @State private var isSchedulesSectionCollapsed = false
    @State private var logEntries: [LogEntry] = AppLogger.entries
    @State private var sshConnections: [SSHConnection] = []
    @State private var isConnectorsExpanded = false
    @State private var isToolsExpanded = false
    @State private var isTemplatesExpanded = false
    @State private var newMemoryText = ""
    @State private var isMemoryComposerVisible = false
    @State private var editingMemoryIndex: Int?
    @State private var approvedCapabilityPackages: [PluginPackage] = []
    @State private var expandedCapabilityID: String?
    @State private var capabilityError: String?

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
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

    private var recentTasks: [AgentTask] {
        workspace.tasks.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var completedTasks: [AgentTask] {
        workspace.tasks.filter { $0.status == .completed }
    }

    private var failedTasks: [AgentTask] {
        workspace.tasks.filter { $0.status == .failed || $0.status == .budgetExceeded }
    }

    private var activeTasks: [AgentTask] {
        workspace.tasks.filter { $0.status == .running || $0.status == .pendingUser || $0.status == .queued }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabStrip
            ScrollView {
                AdaptiveGlassContainer(spacing: Stanford.railListSpacing) {
                    selectedTabContent
                        .padding(.horizontal, Stanford.railContentPadding)
                        .padding(.vertical, Stanford.railContentPadding)
                }
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onReceive(NotificationCenter.default.publisher(for: .appLoggerDidAppendEntry)) { notification in
            guard let entry = notification.userInfo?["entry"] as? LogEntry else { return }
            DispatchQueue.main.async {
                logEntries.append(entry)
                if logEntries.count > 2000 {
                    logEntries.removeFirst(logEntries.count - 2000)
                }
            }
        }
    }

    // MARK: - Workspace Identity Anchor

    private var header: some View {
        HStack(alignment: .center, spacing: Stanford.railSectionContentSpacing) {
            // Bare folder icon. We used to wrap this in a tinted chip, but
            // in the narrow right rail the chip read as a button and fought
            // visually with the "Updated…" line below the workspace name.
            Image(systemName: "folder.fill")
                .font(Stanford.ui(18, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: Stanford.railHeaderIconFrame, height: Stanford.railHeaderIconFrame)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(Stanford.heading(16))
                    .lineLimit(1)
                Text("Updated \(Self.shortDateFormatter.string(from: workspace.updatedAt))")
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, Stanford.railHeaderTopPadding)
        .padding(.horizontal, Stanford.railContentPadding)
        .padding(.bottom, Stanford.railHeaderBottomPadding)
    }

    // MARK: - Compact Tab Strip

    private var tabStrip: some View {
        HStack(spacing: Stanford.railTabStripSpacing) {
            ForEach(WorkspaceRightRailTab.allCases) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(Stanford.ui(13, weight: .medium))
                        Text(tab.title)
                            .font(Stanford.caption(11).weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedTab == tab ? Stanford.lagunita : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Stanford.railTabButtonVerticalPadding)
                    .contentShape(Rectangle())
                    .background(selectedTab == tab ? Stanford.lagunita.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius - 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Stanford.railTabStripPadding)
        .liquidSurface(
            cornerRadius: Stanford.railCompactCardCornerRadius + 1,
            interactive: true,
            fallbackFill: Color.primary.opacity(0.03),
            fallbackStrokeOpacity: 0
        )
        .padding(.horizontal, Stanford.railTabOuterHorizontalPadding)
        .padding(.bottom, Stanford.railTabBottomPadding)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .configure:
            configurePanel
        case .usage:
            usagePanel
        case .logs:
            logsPanel
        }
    }

    // MARK: - Unified Configure Panel

    private var configurePanel: some View {
        VStack(alignment: .leading, spacing: Stanford.railPanelSpacing) {
            collapsibleSectionWithTrailing("Capabilities", isCollapsed: $isCapabilitiesCollapsed) {
                HStack(spacing: 10) {
                    if let onManageCapabilities {
                        Button {
                            onManageCapabilities()
                        } label: {
                            Text("Manage capabilities")
                                .font(Stanford.caption(11).weight(.medium))
                                .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } content: {
                capabilityList
            }

            // CONTEXT (expanded by default)
            collapsibleSection("Context", isCollapsed: $isContextCollapsed) {
                contextSection
            }

            // ACCESS (collapsed by default)
            collapsibleSection("Access", isCollapsed: $isAccessCollapsed) {
                accessSection
            }

            // SCHEDULES (expanded by default)
            collapsibleSectionWithTrailing("Schedules", isCollapsed: $isSchedulesSectionCollapsed) {
                if !workspace.schedules.isEmpty {
                    Button { onNewSchedule?() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(Stanford.ui(14))
                            .foregroundStyle(Stanford.lagunita)
                    }
                    .buttonStyle(.plain)
                    .help("New Schedule")
                }
            } content: {
                schedulesContent
            }
        }
        .tint(Stanford.lagunita)
        .onAppear {
            loadSSHConnections()
            refreshApprovedCapabilities()
            applyConfigureDefaults()
        }
        .onChange(of: workspace.primaryPath) { loadSSHConnections() }
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

    private var capabilityList: some View {
        VStack(alignment: .leading, spacing: Stanford.railListSpacing) {
            if railCapabilityItems.isEmpty {
                EmptyRailState(
                    title: "No capabilities enabled",
                    description: "Open Manage Capabilities to enable approved capabilities for this workspace."
                )
            } else {
                ForEach(railCapabilityItems) { item in
                    capabilityCard(item)
                }
            }
        }
    }

    private func capabilityCard(_ item: RailCapabilityItem) -> some View {
        let isExpanded = expandedCapabilityID == item.id

        return VStack(alignment: .leading, spacing: 0) {
            CapabilityRailRow(
                icon: item.icon,
                title: item.name,
                subtitle: item.summary,
                color: item.color,
                readiness: item.readiness,
                isExpanded: isExpanded,
                isOn: capabilityEnabledBinding(item),
                onTap: {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        expandedCapabilityID = isExpanded ? nil : item.id
                    }
                }
            )

            if isExpanded {
                capabilityDetails(item)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Stanford.railInlineCardPadding)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius))
    }

    private func capabilityDetails(_ item: RailCapabilityItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.3)

            if !item.skillNames.isEmpty {
                capabilityDetailGroup("Behavior", values: item.skillNames)
            }

            if !item.connectorNames.isEmpty {
                capabilityDetailGroup("Connectors", values: item.connectorNames)
            }

            if !item.toolNames.isEmpty {
                capabilityDetailGroup("Tools", values: item.toolNames)
            }

            if !item.requirementNames.isEmpty {
                capabilityDetailGroup("Requirements", values: item.requirementNames)
            }

            if item.readiness.level == .needsAttention {
                capabilityDetailGroup("Needs attention", values: item.readiness.messages)
            }

            Button {
                openCapabilityConfiguration(item)
            } label: {
                Text("Open configuration")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.lagunita)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.top, 6)
        .padding(.leading, 25)
    }

    private func capabilityDetailGroup(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(Stanford.ui(9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)

            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var railCapabilityItems: [RailCapabilityItem] {
        CapabilityCatalogInventory.configuredPackages(
            catalogPackages: approvedCapabilityPackages,
            capabilities: capabilities,
            workspace: workspace
        ).map(makePackageCapabilityItem).sorted {
            let lhsPriority = railCapabilityPriority($0)
            let rhsPriority = railCapabilityPriority($1)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if $0.isEnabled != $1.isEnabled { return $0.isEnabled && !$1.isEnabled }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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

    private func makePackageCapabilityItem(_ package: PluginPackage) -> RailCapabilityItem {
        let state = CapabilityPackageState(
            package: package,
            workspace: workspace,
            capabilities: capabilities
        )

        return RailCapabilityItem(
            id: "package:\(package.id)",
            name: package.name,
            icon: package.icon,
            summary: package.description.isEmpty ? package.contentSummary : package.description,
            color: Stanford.lagunita,
            isEnabled: state.isEnabled,
            readiness: state.readiness,
            source: .package(package),
            skillNames: (package.skills.map(\.name) + state.linkedSkills.map(\.name)).uniqueSorted(),
            connectorNames: (package.connectors.map(\.name) + state.linkedConnectors.map { $0.name.isEmpty ? "Untitled Connector" : $0.name }).uniqueSorted(),
            toolNames: (package.localTools.map(\.name) + state.linkedTools.map { $0.name.isEmpty ? "Untitled Tool" : $0.name }).uniqueSorted(),
            requirementNames: package.prerequisites.map(\.displayName).uniqueSorted()
        )
    }

    private func makeSkillCapabilityItem(_ skill: Skill) -> RailCapabilityItem {
        let connectors = uniqueConnectors(skill.connectors)
        let tools = uniqueTools(skill.localTools)
        let isEnabled = skill.isGlobal ? workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString) : true
        return RailCapabilityItem(
            id: "skill:\(skill.id.uuidString)",
            name: skill.name.isEmpty ? "Untitled Capability" : skill.name,
            icon: skill.icon,
            summary: skill.skillDescription.isEmpty ? "\(skill.allowedTools.count) permissions" : skill.skillDescription,
            color: Stanford.lagunita,
            isEnabled: isEnabled,
            readiness: readinessForSkill(isEnabled: isEnabled, connectors: connectors),
            source: .skill(skill),
            skillNames: [skill.name.isEmpty ? "Untitled Skill" : skill.name],
            connectorNames: connectors.map { $0.name.isEmpty ? "Untitled Connector" : $0.name }.uniqueSorted(),
            toolNames: tools.map { $0.name.isEmpty ? "Untitled Tool" : $0.name }.uniqueSorted(),
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

    private func capabilityEnabledBinding(_ item: RailCapabilityItem) -> Binding<Bool> {
        Binding(
            get: { item.isEnabled },
            set: { enabled in
                setCapability(item, enabled: enabled)
            }
        )
    }

    private func setCapability(_ item: RailCapabilityItem, enabled: Bool) {
        switch item.source {
        case .package(let package):
            if enabled {
                do {
                    try CapabilityInstaller().install(package, into: workspace, modelContext: modelContext)
                    refreshApprovedCapabilities()
                } catch {
                    capabilityError = error.localizedDescription
                    AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: [
                        "result": "failed",
                        "package_id": package.id,
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

        workspace.enabledCapabilityIDs.removeAll { $0 == package.id }
        workspace.enabledGlobalSkillIDs.removeAll { state.skillIDStrings.contains($0) }
        workspace.enabledGlobalConnectorIDs.removeAll { state.connectorIDStrings.contains($0) }
        workspace.enabledGlobalToolIDs.removeAll { state.toolIDStrings.contains($0) }
        for connector in state.linkedConnectors where !connector.isGlobal {
            connector.cleanupKeychain()
            modelContext.delete(connector)
        }
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
            "source": "package",
            "package_id": package.id,
            "workspace_id": workspace.id.uuidString,
            "skills_count": String(state.skillIDStrings.count),
            "connectors_count": String(state.connectorIDStrings.count),
            "tools_count": String(state.toolIDStrings.count),
            "readiness_level": String(describing: state.readiness.level),
            "readiness_messages_count": String(state.readiness.messages.count)
        ])
    }

    private func openCapabilityConfiguration(_ item: RailCapabilityItem) {
        switch item.source {
        case .package:
            onOpenConfigureTab?(.capabilities, nil)
        case .skill(let skill):
            onOpenConfigureTab?(.skills, skill.id)
        }
    }

    private func refreshApprovedCapabilities() {
        let library = CapabilityLibrary()
        try? library.seedApprovedPackages(PluginCatalog.builtInPackages)
        approvedCapabilityPackages = library.installedPackages()
    }

    // MARK: - Connector Subsection

    private var connectorSubsection: some View {
        VStack(alignment: .leading, spacing: Stanford.railSectionContentSpacing) {
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

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: Stanford.railSectionContentSpacing) {
            // Memories
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(Stanford.ui(11))
                        .foregroundStyle(Stanford.plum)
                    Text("\(workspace.memories.count) memories")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if workspace.memories.isEmpty && !isMemoryComposerVisible {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        isMemoryComposerVisible = true
                    }
                } label: {
                    InlineActionRow(icon: "plus", title: "Add memory", tint: Stanford.plum)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(Array(workspace.memories.enumerated()), id: \.offset) { idx, memory in
                    memoryRow(memory: memory, index: idx)
                }

                if isMemoryComposerVisible {
                    memoryComposer
                } else {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                            isMemoryComposerVisible = true
                        }
                    } label: {
                        Text("+ Add memory")
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(Stanford.lagunita)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                }
            }

            Divider().opacity(0.3)

            // Instructions
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(Stanford.ui(12, weight: .medium))
                    .foregroundStyle(Stanford.lagunita)
                Text("Workspace Instructions")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            if workspace.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { onEditWorkspace() } label: {
                    Text("Add instructions to guide agent behavior")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                Button { onEditWorkspace() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(instructionsPreview)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.primary)
                            .lineSpacing(2)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "pencil")
                            .font(Stanford.ui(10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Access Section

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: Stanford.railSectionContentSpacing) {
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
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
                        workspace.additionalPaths.remove(at: idx)
                        workspace.updatedAt = Date()
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
                VStack(spacing: Stanford.railListSpacing) {
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

    // MARK: - Schedules Content

    private var schedulesContent: some View {
        VStack(alignment: .leading, spacing: Stanford.railSectionContentSpacing) {
            if workspace.schedules.isEmpty {
                Button { onNewSchedule?() } label: {
                    Text("+ Add schedule")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: Stanford.railListSpacing) {
                    ForEach(workspace.schedules.sorted { $0.name < $1.name }) { schedule in
                        HStack(spacing: 8) {
                            Button { onEditSchedule?(schedule) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: schedule.isEnabled ? "clock.fill" : "clock")
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
        isCollapsed: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: isCollapsed.wrappedValue ? 0 : Stanford.railSectionContentSpacing) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isCollapsed.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(title.uppercased())
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Spacer()
                }
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
        VStack(alignment: .leading, spacing: isCollapsed.wrappedValue ? 0 : Stanford.railSectionContentSpacing) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        isCollapsed.wrappedValue.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                            .font(Stanford.ui(10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(title.uppercased())
                            .font(Stanford.ui(10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.5)
                    }
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

    private func loadSSHConnections() {
        guard !workspace.primaryPath.isEmpty else {
            sshConnections = []
            return
        }
        sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
    }

    private func applyConfigureDefaults() {
        isAccessCollapsed = sshConnections.isEmpty && workspace.additionalPaths.isEmpty
        isSchedulesSectionCollapsed = workspace.schedules.isEmpty
        isToolsExpanded = !workspaceTools.isEmpty
        isTemplatesExpanded = false
        isMemoryComposerVisible = workspace.memories.isEmpty
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
                workspace.updatedAt = Date()
            }
        }
    }

    private func addMemory() {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        workspace.memories.append(text)
        workspace.updatedAt = Date()
        newMemoryText = ""
        isMemoryComposerVisible = false
        editingMemoryIndex = nil
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

    @ViewBuilder
    private func memoryRow(memory: String, index: Int) -> some View {
        if editingMemoryIndex == index {
            HStack(spacing: 6) {
                TextField("Memory", text: Binding(
                    get: { workspace.memories[index] },
                    set: { workspace.memories[index] = $0 }
                ), axis: .vertical)
                .font(Stanford.caption(12))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)

                Button {
                    editingMemoryIndex = nil
                    workspace.updatedAt = Date()
                } label: {
                    Image(systemName: "checkmark")
                        .font(Stanford.ui(10, weight: .bold))
                        .foregroundStyle(Stanford.paloAltoGreen)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(Stanford.plum.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .padding(.top, 6)

                Text(memory)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    Button { editingMemoryIndex = index } label: {
                        Image(systemName: "pencil")
                            .font(Stanford.ui(10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        workspace.memories.remove(at: index)
                        workspace.updatedAt = Date()
                    } label: {
                        Image(systemName: "xmark")
                            .font(Stanford.ui(10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var instructionsPreview: String {
        workspace.instructions
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                line
                    .replacingOccurrences(of: "#", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "`", with: "")
            }
            .joined(separator: " ")
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Inspector Helpers

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Stanford.railSectionContentSpacing) {
            Text(title.uppercased())
                .font(Stanford.ui(10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            content()
        }
    }

    private func inspectorSectionWithTrailing<Trailing: View, Content: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Stanford.railSectionContentSpacing) {
            HStack {
                Text(title.uppercased())
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
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

    private var usagePanel: some View {
        VStack(alignment: .leading, spacing: Stanford.railPanelSpacing) {
            RailActionButton(
                title: "Usage Dashboard",
                subtitle: "Full report with filters and breakdowns",
                icon: "chart.bar",
                color: Stanford.poppy,
                action: onShowDashboard
            )

            // Stats grid — compact inline rows
            inspectorSection("Stats") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: Stanford.railListSpacing) {
                    RailMetricCard(title: "Tasks", value: "\(workspace.tasks.count)", color: Stanford.lagunita)
                    RailMetricCard(title: "Active", value: "\(activeTasks.count)", color: Stanford.running)
                    RailMetricCard(title: "Done", value: "\(completedTasks.count)", color: Stanford.completed)
                    RailMetricCard(title: "Failed", value: "\(failedTasks.count)", color: Stanford.failed)
                    RailMetricCard(title: "Tokens", value: Formatters.formatTokens(workspace.totalTokens), color: Stanford.poppy)
                    RailMetricCard(title: "Cost", value: String(format: "$%.2f", workspace.totalCost), color: Stanford.sky)
                }
            }

            // Recent activity — flat rows
            inspectorSection("Recent Activity") {
                if recentTasks.isEmpty {
                    Text("No task history yet")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(recentTasks.prefix(5))) { task in
                            CompactTaskUsageRow(task: task)
                        }
                    }
                }
            }
        }
    }

    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: Stanford.railPanelSpacing) {
            VStack(spacing: Stanford.railListSpacing) {
                RailActionButton(
                    title: "Logs Viewer",
                    subtitle: "Full log viewer with filters and search",
                    icon: "doc.text.magnifyingglass",
                    color: Stanford.sky,
                    action: onShowLogs
                )

                RailActionButton(
                    title: "Open Log Folder",
                    subtitle: AppLogger.mainLogFile.deletingLastPathComponent().path,
                    icon: "folder",
                    color: Stanford.paloAltoGreen,
                    action: {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppLogger.mainLogFile.deletingLastPathComponent().path)
                    }
                )
            }

            inspectorSectionWithTrailing("Recent Entries") {
                HStack(spacing: 8) {
                    RailCountBadge(count: logEntries.count)

                    Button {
                        logEntries = AppLogger.entries
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(Stanford.ui(11))
                            .foregroundStyle(.secondary)
                            .frame(width: Stanford.railBadgeHeight, height: Stanford.railBadgeHeight)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh logs")
                }
            } content: {
                if logEntries.isEmpty {
                    Text("Runtime logs will appear here as the app runs.")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(logEntries.suffix(8).reversed())) { entry in
                            CompactLogRow(entry: entry, timeFormatter: Self.logTimeFormatter)
                        }
                    }
                }
            }
        }
        .onAppear {
            logEntries = AppLogger.entries
        }
    }

    private var workspaceSkillSection: some View {
        VStack(alignment: .leading, spacing: Stanford.railSectionContentSpacing) {
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
        VStack(alignment: .leading, spacing: Stanford.railSectionContentSpacing) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            VStack(spacing: Stanford.railListSpacing) {
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

private struct RailActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: Stanford.railIconFrame, height: Stanford.railIconFrame)
                    .background(color.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Stanford.body(13).weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(height: Stanford.railActionRowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidSurface(
                cornerRadius: Stanford.railCompactCardCornerRadius,
                interactive: true,
                fallbackFill: Color.primary.opacity(0.03),
                fallbackStrokeOpacity: 0
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RailCountBadge: View {
    let text: String

    init(count: Int) {
        self.text = "\(count)"
    }

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Stanford.caption(11).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Stanford.railBadgeHorizontalPadding)
            .frame(minWidth: Stanford.railBadgeMinWidth, minHeight: Stanford.railBadgeHeight)
            .background(Color.primary.opacity(0.05))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Stanford.railBadgeCornerRadius,
                    style: .continuous
                )
            )
    }
}

private struct RailMetricCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Stanford.heading(15))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(title)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius))
    }
}

private struct RailCapabilityItem: Identifiable {
    enum Source {
        case package(PluginPackage)
        case skill(Skill)
    }

    let id: String
    let name: String
    let icon: String
    let summary: String
    let color: Color
    let isEnabled: Bool
    let readiness: CapabilityReadiness
    let source: Source
    let skillNames: [String]
    let connectorNames: [String]
    let toolNames: [String]
    let requirementNames: [String]
}

private struct CapabilityRailRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let readiness: CapabilityReadiness
    let isExpanded: Bool
    let isOn: Binding<Bool>
    let onTap: () -> Void

    private var readinessColor: Color {
        switch readiness.level {
        case .ready:
            return Stanford.paloAltoGreen
        case .needsAttention:
            return Stanford.poppy
        case .inactive:
            return Color.secondary.opacity(0.35)
        }
    }

    private var readinessLabel: String {
        switch readiness.level {
        case .ready:
            return "Functional"
        case .needsAttention:
            return "Needs attention"
        case .inactive:
            return "Disabled"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(Stanford.ui(13, weight: .medium))
                        .foregroundStyle(isOn.wrappedValue ? color : .secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(title.isEmpty ? "Untitled Capability" : title)
                                .font(Stanford.caption(12).weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Circle()
                                .fill(readinessColor)
                                .frame(width: 6, height: 6)
                                .help(readiness.messages.joined(separator: "\n"))
                                .accessibilityLabel(readinessLabel)
                        }

                        Text(subtitle.isEmpty ? "No details" : subtitle)
                            .font(Stanford.caption(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

private struct CompactTaskUsageRow: View {
    let task: AgentTask

    private var statusText: String {
        task.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var statusColor: Color {
        switch task.status {
        case .draft: Stanford.plum
        case .queued, .cancelled: Stanford.sandstone
        case .running: Stanford.running
        case .pendingUser: Stanford.pendingUser
        case .completed: Stanford.completed
        case .failed, .budgetExceeded: Stanford.failed
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)

            Text(task.title)
                .font(Stanford.body(12).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("\(Formatters.formatTokens(task.tokensUsed))")
                .font(Stanford.caption(11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .frame(height: Stanford.railCompactRowHeight, alignment: .leading)
    }
}

private struct CompactLogRow: View {
    let entry: LogEntry
    let timeFormatter: DateFormatter

    private var levelColor: Color {
        switch entry.logLevel {
        case .debug: .secondary
        case .info: Stanford.lagunita
        case .warning: Stanford.poppy
        case .error: Stanford.failed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(timeFormatter.string(from: entry.timestamp))
                    .font(Stanford.mono(11))
                    .foregroundStyle(.quaternary)

                Text(entry.level.uppercased())
                    .font(Stanford.ui(11, weight: .bold, design: .monospaced))
                    .foregroundStyle(levelColor)

                Text(entry.category)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(entry.message)
                .font(Stanford.caption(11))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .frame(height: Stanford.railCompactLogRowHeight, alignment: .leading)
    }
}

private struct CapabilityRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var trailing: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? "No details" : subtitle)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .contentShape(Rectangle())
    }
}

private struct CapabilityToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? color : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? "No details" : subtitle)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 5)
        .padding(.leading, 2)
        .padding(.trailing, 4)
    }
}

private struct ResourceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var onEdit: (() -> Void)?

    var body: some View {
        Group {
            if let onEdit {
                Button(action: onEdit) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .padding(Stanford.railCardPadding)
        .frame(minHeight: Stanford.railResourceRowHeight, alignment: .leading)
        .railCard(cornerRadius: Stanford.railCardCornerRadius)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: Stanford.railIconFrame, height: Stanford.railIconFrame)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.body(13).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? "No details" : subtitle)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if onEdit != nil {
                Image(systemName: "chevron.right")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
        }
        .contentShape(Rectangle())
    }
}

private extension Array where Element == String {
    func uniqueSorted() -> [String] {
        var seen = Set<String>()
        return filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && seen.insert(trimmed).inserted
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

private struct InlineActionRow: View {
    let icon: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct EmptyRailState: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Stanford.body(13).weight(.medium))
                .foregroundStyle(.secondary)
            Text(description)
                .font(Stanford.caption(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Stanford.railCardPadding)
        .railCard(cornerRadius: Stanford.railCardCornerRadius, fill: Color(nsColor: .windowBackgroundColor), strokeOpacity: 0.05)
    }
}

private extension View {
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
