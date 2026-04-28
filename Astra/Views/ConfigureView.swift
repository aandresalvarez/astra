import SwiftUI
import SwiftData

enum ConfigureTab: String, CaseIterable {
    case connectors = "Connectors"
    case tools = "Tools"
    case skills = "Skills"
    case templates = "Templates"

    var icon: String {
        switch self {
        case .connectors: return "bolt.horizontal.circle"
        case .tools: return "wrench.and.screwdriver"
        case .skills: return "puzzlepiece.extension"
        case .templates: return "rectangle.3.group"
        }
    }

    var color: Color {
        switch self {
        case .connectors: return Stanford.paloAltoGreen
        case .tools: return Stanford.tools
        case .skills: return Stanford.lagunita
        case .templates: return Stanford.poppy
        }
    }

    var subtitle: String {
        switch self {
        case .connectors: return "APIs & Services"
        case .tools: return "Scripts & MCP"

        case .skills: return "Intent & Behavior"
        case .templates: return "Multi-Phase Workflows"
        }
    }

}

struct ConfigureView: View {
    var workspace: Workspace
    var initialTab: ConfigureTab = .skills
    var focusItemID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]
    @State private var selectedTab: ConfigureTab = .skills

    private var activeWorkspaceSkillCount: Int {
        let workspaceSkills = workspace.skills.filter { !$0.isGlobal && !$0.isSystemBuiltIn }
        let enabledIDs = Set(workspace.enabledGlobalSkillIDs)
        let enabledGlobals = globalSkills.filter { enabledIDs.contains($0.id.uuidString) && !$0.isSystemBuiltIn }
        let dedupedGlobals = enabledGlobals.filter { globalSkill in
            !workspaceSkills.contains { $0.id == globalSkill.id }
        }
        return workspaceSkills.count + dedupedGlobals.count
    }

    private func count(for tab: ConfigureTab) -> Int {
        switch tab {
        case .connectors:
            workspace.connectors.count
        case .tools:
            workspace.localTools.count
        case .skills:
            activeWorkspaceSkillCount
        case .templates:
            workspace.templates.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configure")
                        .font(Stanford.heading(24))
                        .foregroundStyle(Stanford.black)
                    Text(workspace.name)
                        .font(Stanford.caption(13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            NavigationSplitView {
                List(ConfigureTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    ConfigureSidebarRow(
                        tab: tab,
                        count: count(for: tab)
                    )
                    .tag(tab)
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
            } detail: {
                ZStack(alignment: .topLeading) {
                    switch selectedTab {
                    case .connectors:
                        ConnectorsTabContent(workspace: workspace, focusItemID: focusItemID)
                    case .tools:
                        ToolsTabContent(workspace: workspace, focusItemID: focusItemID)
                    case .skills:
                        SkillsTabContent(workspace: workspace, focusItemID: focusItemID)
                    case .templates:
                        TemplatesTabContent(workspace: workspace, focusItemID: focusItemID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 1080, idealWidth: 1260, maxWidth: 1440, minHeight: 720, idealHeight: 820)
        .onAppear { selectedTab = initialTab }
    }
}

private struct ConfigureSidebarRow: View {
    let tab: ConfigureTab
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(Stanford.ui(14))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.rawValue)
                    .font(Stanford.body(14).weight(.medium))
                    .foregroundStyle(.primary)
                Text(tab.subtitle)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text("\(count)")
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}

private struct ConfigureSelectionList<Content: View>: View {
    let maxContentWidth: CGFloat
    @ViewBuilder let content: Content

    init(maxContentWidth: CGFloat = 640, @ViewBuilder content: () -> Content) {
        self.maxContentWidth = maxContentWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .frame(maxWidth: maxContentWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ConfigureSelectionSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    private let columns = [
        GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 10, alignment: .top)
    ]

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConfigureSelectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ConfigureCardIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(Stanford.ui(18, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ConfigureCardChip: View {
    let title: String
    var color: Color? = nil

    var body: some View {
        Text(title)
            .font(Stanford.caption(10))
            .foregroundStyle(color ?? Stanford.coolGrey)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((color ?? Color.primary).opacity(color == nil ? 0.04 : 0.1))
            .clipShape(Capsule())
    }
}

// MARK: - Connectors Tab

struct ConnectorsTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    @Environment(\.modelContext) private var modelContext
    @State private var selectedConnector: Connector?
    @State private var showCatalog = false

    var body: some View {
        let connectors = workspace.connectors.sorted(by: { $0.name < $1.name })
        let showingDetail = selectedConnector != nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connectors")
                        .font(Stanford.heading(18))
                    Text("APIs & Services")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    if showCatalog || showingDetail {
                        Button {
                            if showCatalog {
                                showCatalog = false
                            } else {
                                selectedConnector = nil
                            }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(Stanford.body(13))
                        }
                    } else {
                        Button { showCatalog = true } label: {
                            Label("Add from Catalog", systemImage: "square.grid.2x2")
                                .font(Stanford.body(13))
                        }

                        Button { createConnector() } label: {
                            Label("New Connector", systemImage: "plus")
                                .font(Stanford.body(13))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                if showCatalog {
                    PluginCatalogView(workspace: workspace, catalog: PluginCatalog(), focus: .connectors, onInstall: { _ in
                        showCatalog = false
                    })
                } else if let connector = selectedConnector {
                    ConnectorEditorView(connector: connector, workspace: workspace, onDelete: {
                        deleteConnector(connector)
                    })
                } else if connectors.isEmpty {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        ConfigureSelectionSection("Connectors") {
                            ForEach(connectors) { connector in
                                ConfigureSelectionCard {
                                    Button {
                                        selectedConnector = connector
                                    } label: {
                                        HStack(spacing: 12) {
                                            connectorRow(connector)
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(Stanford.ui(11, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let conn = workspace.connectors.first(where: { $0.id == focusItemID }) {
                selectedConnector = conn
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.circle")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.connectors.color.opacity(0.5))
            Text("No Connectors Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Connectors provide authentication and configuration for external services like Jira, GitHub, Slack, and databases.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button {
                    createConnector()
                } label: {
                    Label("Create Blank", systemImage: "plus")
                        .font(Stanford.body(14))
                }

                Button {
                    showCatalog = true
                } label: {
                    Label("Add from Catalog", systemImage: "square.grid.2x2")
                        .font(Stanford.body(14))
                }
                .buttonStyle(.borderedProminent)
                .tint(ConfigureTab.connectors.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectorRow(_ connector: Connector) -> some View {
        let subtitle = connector.connectorDescription.isEmpty ? connector.displaySummary : connector.connectorDescription
        let serviceLabel = connector.serviceType.replacingOccurrences(of: "_", with: " ").capitalized
        let authLabel = connector.authMethod.replacingOccurrences(of: "_", with: " ").capitalized

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(systemName: connector.icon, color: ConfigureTab.connectors.color)

                VStack(alignment: .leading, spacing: 3) {
                    Text(connector.name.isEmpty ? "Untitled" : connector.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                ConfigureCardChip(title: serviceLabel, color: ConfigureTab.connectors.color)
                ConfigureCardChip(title: authLabel)
                if !connector.credentialKeys.isEmpty {
                    ConfigureCardChip(title: "\(connector.credentialKeys.count) secret\(connector.credentialKeys.count == 1 ? "" : "s")")
                }
            }
        }
    }

    private func createConnector() {
        let connector = Connector(name: "New Connector")
        connector.workspace = workspace
        modelContext.insert(connector)
        selectedConnector = connector
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.connectorCreated, category: "UI", fields: [
            "connector_id": connector.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }

    private func deleteConnector(_ connector: Connector) {
        if selectedConnector?.id == connector.id {
            selectedConnector = nil
        }
        connector.cleanupKeychain()
        modelContext.delete(connector)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }
}

// MARK: - Tools Tab

struct ToolsTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTool: LocalTool?

    var body: some View {
        let tools = workspace.localTools.sorted(by: { $0.name < $1.name })
        let showingDetail = selectedTool != nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools")
                        .font(Stanford.heading(18))
                    Text("Scripts & MCP")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showingDetail {
                    Button {
                        selectedTool = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(Stanford.body(13))
                    }
                } else {
                    Button { createTool() } label: {
                        Label("New Tool", systemImage: "plus")
                            .font(Stanford.body(13))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                if let tool = selectedTool {
                    LocalToolEditorView(tool: tool, onDelete: {
                        deleteTool(tool)
                    })
                } else if tools.isEmpty {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        ConfigureSelectionSection("Tools") {
                            ForEach(tools) { tool in
                                ConfigureSelectionCard {
                                    Button {
                                        selectedTool = tool
                                    } label: {
                                        HStack(spacing: 12) {
                                            toolRow(tool)
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(Stanford.ui(11, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let tool = workspace.localTools.first(where: { $0.id == focusItemID }) {
                selectedTool = tool
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wrench.and.screwdriver")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.tools.color.opacity(0.5))
            Text("No Tools Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Tools are local scripts, CLI commands, or MCP servers that extend your agent's capabilities. Define them here and attach them to skills.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                createTool()
            } label: {
                Label("Create Tool", systemImage: "plus")
                    .font(Stanford.body(14))
            }
            .buttonStyle(.borderedProminent)
            .tint(ConfigureTab.tools.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolRow(_ tool: LocalTool) -> some View {
        let typeLabel: String = switch tool.toolType {
        case "cli": "CLI"
        case "mcp": "MCP"
        case "script": "Script"
        default: tool.toolType.capitalized
        }
        let subtitle = tool.toolDescription.isEmpty ? (tool.displayCommand.isEmpty ? "No command configured yet" : tool.displayCommand) : tool.toolDescription

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(systemName: LocalTool.iconForType(tool.toolType), color: ConfigureTab.tools.color)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name.isEmpty ? "Untitled" : tool.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                ConfigureCardChip(title: typeLabel, color: ConfigureTab.tools.color)
                if !tool.command.isEmpty {
                    ConfigureCardChip(title: "Configured")
                }
            }
        }
    }

    private func createTool() {
        let tool = LocalTool(name: "New Tool")
        tool.workspace = workspace
        modelContext.insert(tool)
        selectedTool = tool
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.localToolCreated, category: "UI", fields: [
            "tool_id": tool.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }

    private func deleteTool(_ tool: LocalTool) {
        if selectedTool?.id == tool.id {
            selectedTool = nil
        }
        modelContext.delete(tool)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.localToolDeleted, category: "UI", fields: [
            "tool_id": tool.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }
}

// MARK: - Skills Tab

struct SkillsTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    @Environment(\.modelContext) private var modelContext
    @State private var selectedSkill: Skill?
    @State private var showCatalog = false

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    private var workspaceSkills: [Skill] {
        workspace.skills.filter { !$0.isGlobal && !$0.isSystemBuiltIn }.sorted { $0.name < $1.name }
    }

    private var sharedLibrarySkills: [Skill] {
        globalSkills.filter { globalSkill in
            !globalSkill.isSystemBuiltIn &&
            !workspaceSkills.contains { $0.id == globalSkill.id }
        }
        .sorted { $0.name < $1.name }
    }

    private var hasVisibleSkills: Bool {
        !workspaceSkills.isEmpty || !sharedLibrarySkills.isEmpty
    }

    var body: some View {
        let showingDetail = selectedSkill != nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills")
                        .font(Stanford.heading(18))

                    Text("Intent & Behavior")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    if showCatalog || showingDetail {
                        Button {
                            if showCatalog {
                                showCatalog = false
                            } else {
                                selectedSkill = nil
                            }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(Stanford.body(13))
                        }
                    } else {
                        Button { showCatalog = true } label: {
                            Label("Add from Catalog", systemImage: "square.grid.2x2")
                                .font(Stanford.body(13))
                        }

                        Button { createSkill() } label: {
                            Label("New Skill", systemImage: "plus")
                                .font(Stanford.body(13))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                if showCatalog {
                    PluginCatalogView(workspace: workspace, catalog: PluginCatalog(), focus: .skills, onInstall: { _ in
                        showCatalog = false
                    })
                } else if let skill = selectedSkill {
                    SkillEditorView(skill: skill, workspace: workspace, onDelete: {
                        deleteSkill(skill)
                    })
                } else if !hasVisibleSkills {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        if !workspaceSkills.isEmpty {
                            ConfigureSelectionSection("Workspace Skills") {
                                ForEach(workspaceSkills) { skill in
                                    ConfigureSelectionCard {
                                        Button {
                                            selectedSkill = skill
                                        } label: {
                                            HStack(spacing: 12) {
                                                skillRow(skill)
                                                Spacer(minLength: 0)
                                                Image(systemName: "chevron.right")
                                                    .font(Stanford.ui(11, weight: .semibold))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if !sharedLibrarySkills.isEmpty {
                            ConfigureSelectionSection("Shared Library") {
                                ForEach(sharedLibrarySkills) { skill in
                                    let enabled = workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString)

                                    ConfigureSelectionCard {
                                        HStack(spacing: 12) {
                                            Button {
                                                selectedSkill = skill
                                            } label: {
                                                HStack(spacing: 12) {
                                                    skillRow(skill)
                                                    Spacer(minLength: 0)
                                                    Image(systemName: "chevron.right")
                                                        .font(Stanford.ui(11, weight: .semibold))
                                                        .foregroundStyle(.tertiary)
                                                }
                                                .contentShape(Rectangle())
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .buttonStyle(.plain)

                                            Button(enabled ? "Disable" : "Enable") {
                                                toggleGlobalSkill(skill)
                                            }
                                            .font(Stanford.caption(12))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let skill = workspace.skills.first(where: { $0.id == focusItemID }) {
                selectedSkill = skill
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.skills.color.opacity(0.5))
            Text("No Skills Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Skills define what your agent can do — which tools it can use, behavioral instructions, and attached connectors and tools.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button {
                    createSkill()
                } label: {
                    Label("Create Blank", systemImage: "plus")
                        .font(Stanford.body(14))
                }

                Button {
                    showCatalog = true
                } label: {
                    Label("Add from Catalog", systemImage: "square.grid.2x2")
                        .font(Stanford.body(14))
                }
                .buttonStyle(.borderedProminent)
                .tint(ConfigureTab.skills.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func skillRow(_ skill: Skill) -> some View {
        let subtitle = skill.skillDescription.isEmpty
            ? "\(skill.allowedTools.count) capabilities configured"
            : skill.skillDescription

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(
                    systemName: skill.icon,
                    color: skill.isGlobal ? Stanford.poppy : ConfigureTab.skills.color
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name.isEmpty ? "Untitled" : skill.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                ConfigureCardChip(title: "\(skill.allowedTools.count) capabilities")
                if !skill.connectors.isEmpty {
                    ConfigureCardChip(title: "\(skill.connectors.count) connector\(skill.connectors.count == 1 ? "" : "s")", color: ConfigureTab.connectors.color)
                }
                if !skill.localTools.isEmpty {
                    ConfigureCardChip(title: "\(skill.localTools.count) tool\(skill.localTools.count == 1 ? "" : "s")", color: ConfigureTab.tools.color)
                }
                if skill.isGlobal {
                    ConfigureCardChip(title: "Shared", color: Stanford.poppy)
                }
            }
        }
    }

    private func createSkill() {
        let skill = Skill(name: "New Skill", allowedTools: Skill.defaultAllowed)
        skill.workspace = workspace
        modelContext.insert(skill)
        selectedSkill = skill
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.skillCreated, category: "UI", fields: [
            "skill_id": skill.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "allowed_tools_count": String(skill.allowedTools.count)
        ])
    }

    private func toggleGlobalSkill(_ skill: Skill) {
        let idString = skill.id.uuidString
        if let idx = workspace.enabledGlobalSkillIDs.firstIndex(of: idString) {
            workspace.enabledGlobalSkillIDs.remove(at: idx)
        } else {
            workspace.enabledGlobalSkillIDs.append(idString)
        }
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.skillToolPermissionChanged, category: "UI", fields: [
            "skill_id": skill.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "enabled_global": String(workspace.enabledGlobalSkillIDs.contains(idString))
        ])
    }

    private func deleteSkill(_ skill: Skill) {
        if selectedSkill?.id == skill.id {
            selectedSkill = nil
        }
        skill.cleanupKeychain()
        modelContext.delete(skill)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

}

// MARK: - Templates Tab

struct TemplatesTabContent: View {
    var workspace: Workspace
    var focusItemID: UUID?
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTemplate: TaskTemplate?

    var body: some View {
        let templates = workspace.templates.sorted(by: { $0.name < $1.name })
        let showingDetail = selectedTemplate != nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Templates")
                        .font(Stanford.heading(18))
                    Text("Multi-Phase Workflows")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showingDetail {
                    Button {
                        selectedTemplate = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(Stanford.body(13))
                    }
                } else {
                    Button { createTemplate() } label: {
                        Label("New Template", systemImage: "plus")
                            .font(Stanford.body(13))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                if let template = selectedTemplate {
                    TemplateEditorView(template: template, onDelete: {
                        deleteTemplate(template)
                    })
                } else if templates.isEmpty {
                    emptyState
                } else {
                    ConfigureSelectionList(maxContentWidth: 980) {
                        ConfigureSelectionSection("Templates") {
                            ForEach(templates) { template in
                                ConfigureSelectionCard {
                                    Button {
                                        selectedTemplate = template
                                    } label: {
                                        HStack(spacing: 12) {
                                            templateRow(template)
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(Stanford.ui(11, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let focusItemID,
               let template = workspace.templates.first(where: { $0.id == focusItemID }) {
                selectedTemplate = template
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.3.group")
                .font(Stanford.ui(36))
                .foregroundStyle(ConfigureTab.templates.color.opacity(0.5))
            Text("No Templates Yet")
                .font(Stanford.heading(18))
                .foregroundStyle(Stanford.black)
            Text("Templates define multi-phase workflows with before, main, and after agents. Each phase is a full Claude agent that can think, adapt, and troubleshoot.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                createTemplate()
            } label: {
                Label("Create Template", systemImage: "plus")
                    .font(Stanford.body(14))
            }
            .buttonStyle(.borderedProminent)
            .tint(ConfigureTab.templates.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func templateRow(_ template: TaskTemplate) -> some View {
        let subtitle = template.templateDescription.isEmpty ? templatePhaseSummary(template) : template.templateDescription

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ConfigureCardIcon(systemName: template.icon, color: ConfigureTab.templates.color)

                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name.isEmpty ? "Untitled" : template.name)
                        .font(Stanford.body(14))
                        .fontWeight(.semibold)
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                if template.hasBeforePhase {
                    ConfigureCardChip(title: "Before", color: Stanford.interactive)
                }
                ConfigureCardChip(title: "Main", color: Stanford.paloAltoGreen)
                if template.hasAfterPhase {
                    ConfigureCardChip(title: "After", color: Stanford.tools)
                }
                if !template.variables.isEmpty {
                    ConfigureCardChip(title: "\(template.variables.count) variable\(template.variables.count == 1 ? "" : "s")")
                }
            }
        }
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

    private func createTemplate() {
        let template = TaskTemplate(name: "New Template", mainGoal: "{{goal}}", workspace: workspace)
        modelContext.insert(template)
        selectedTemplate = template
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.templateCreated, category: "UI", fields: [
            "template_id": template.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }

    private func deleteTemplate(_ template: TaskTemplate) {
        if selectedTemplate?.id == template.id {
            selectedTemplate = nil
        }
        modelContext.delete(template)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.templateDeleted, category: "UI", fields: [
            "template_id": template.id.uuidString,
            "workspace_id": workspace.id.uuidString
        ])
    }
}

// MARK: - Template Editor

struct TemplateEditorView: View {
    @Bindable var template: TaskTemplate
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var selectedPhase: TemplatePhase = .main
    @State private var showVariableEditor = false
    @State private var showDeleteConfirm = false
    @FocusState private var isNameFocused: Bool

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    private var availableSkills: [Skill] {
        let workspaceSkills = template.workspace?.skills ?? []
        let enabledIDs = Set(template.workspace?.enabledGlobalSkillIDs ?? [])
        let enabledGlobals = globalSkills.filter { enabledIDs.contains($0.id.uuidString) }
        return (workspaceSkills.filter { !$0.isGlobal } + enabledGlobals).sorted { $0.name < $1.name }
    }

    enum TemplatePhase: String, CaseIterable {
        case before = "Before"
        case main = "Main"
        case after = "After"

        var color: Color {
            switch self {
            case .before: return Stanford.interactive
            case .main: return Stanford.paloAltoGreen
            case .after: return Stanford.tools
            }
        }

        var icon: String {
            switch self {
            case .before: return "arrow.right.circle"
            case .main: return "play.circle.fill"
            case .after: return "checkmark.circle"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Name & icon
                HStack(spacing: 12) {
                    Menu {
                        ForEach(templateIcons, id: \.self) { icon in
                            Button {
                                template.icon = icon
                                template.updatedAt = Date()
                            } label: {
                                Label(icon, systemImage: icon)
                            }
                        }
                    } label: {
                        Image(systemName: template.icon)
                            .font(Stanford.ui(22))
                            .foregroundStyle(ConfigureTab.templates.color)
                            .frame(width: 36, height: 36)
                            .background(ConfigureTab.templates.color.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Template Name", text: $template.name)
                            .font(Stanford.heading(18))
                            .textFieldStyle(.plain)
                            .focused($isNameFocused)
                        TextField("Description", text: $template.templateDescription)
                            .font(Stanford.body(13))
                            .foregroundStyle(.secondary)
                            .textFieldStyle(.plain)
                    }
                }

                Divider()

                // Phase selector
                HStack(spacing: 4) {
                    ForEach(TemplatePhase.allCases, id: \.self) { phase in
                        let isActive = phaseIsActive(phase)
                        Button {
                            selectedPhase = phase
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: phase.icon)
                                    .font(Stanford.ui(13))
                                Text(phase.rawValue)
                                    .font(Stanford.body(13))
                                    .fontWeight(.medium)
                                if !isActive && phase != .main {
                                    Text("off")
                                        .font(Stanford.caption(10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedPhase == phase ? phase.color.opacity(0.12) : .clear)
                            .foregroundStyle(selectedPhase == phase ? phase.color : isActive ? Stanford.black : Stanford.coolGrey)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedPhase == phase ? phase.color.opacity(0.3) : .clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // Phase content
                phaseEditor(for: selectedPhase)

                Divider()

                // Variables
                variablesSection

                Divider()

                // Options
                optionsSection

                // Default skills
                if !availableSkills.isEmpty {
                    Divider()
                    defaultSkillsSection
                }

                Divider()

                // Delete
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Template", systemImage: "trash")
                            .font(Stanford.body(13))
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if template.name == "New Template" { isNameFocused = true } }
        .alert("Delete Template?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will permanently delete \"\(template.name)\". This cannot be undone.")
        }
        .onDisappear {
            template.updatedAt = Date()
            WorkspacePersistenceCoordinator.flushPendingExport(workspace: template.workspace, modelContext: modelContext)
        }
    }

    // MARK: - Phase Editor

    @ViewBuilder
    private func phaseEditor(for phase: TemplatePhase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .before:
                Toggle("Enable Before Phase", isOn: Binding(
                    get: { template.hasBeforePhase },
                    set: { enabled in
                        template.beforeGoal = enabled ? "Prepare the environment for the main task." : ""
                        template.updatedAt = Date()
                    }
                ))
                .font(Stanford.body(14))

                if template.hasBeforePhase {
                    goalEditor(title: "Before Agent Goal", text: $template.beforeGoal)
                    budgetField(label: "Budget", value: $template.beforeBudget)
                    modelField(label: "Model Override", value: $template.beforeModel)
                }

            case .main:
                goalEditor(title: "Main Agent Goal", text: $template.mainGoal)
                budgetField(label: "Budget", value: $template.mainBudget)
                modelField(label: "Model Override", value: $template.mainModel)

            case .after:
                Toggle("Enable After Phase", isOn: Binding(
                    get: { template.hasAfterPhase },
                    set: { enabled in
                        template.afterGoal = enabled ? "Verify and clean up after the main task." : ""
                        template.updatedAt = Date()
                    }
                ))
                .font(Stanford.body(14))

                if template.hasAfterPhase {
                    goalEditor(title: "After Agent Goal", text: $template.afterGoal)
                    budgetField(label: "Budget", value: $template.afterBudget)
                    modelField(label: "Model Override", value: $template.afterModel)
                }
            }
        }
    }

    private func goalEditor(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Stanford.body(13))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(Stanford.ui(13, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 160)
                .padding(6)
                .background(Stanford.fog.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Stanford.coolGrey.opacity(0.2), lineWidth: 1)
                )
            Text("Use {{variable}} placeholders. Available: " + template.variables.map { "{{\($0.name)}}" }.joined(separator: ", "))
                .font(Stanford.caption(11))
                .foregroundStyle(.tertiary)
        }
    }

    private func budgetField(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(Stanford.body(13))
                .foregroundStyle(.secondary)
            Spacer()
            TextField("", value: value, format: .number)
                .font(Stanford.body(13))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            Text("tokens")
                .font(Stanford.caption(12))
                .foregroundStyle(.tertiary)
        }
    }

    private func modelField(label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(Stanford.body(13))
                .foregroundStyle(.secondary)
            Spacer()
            TextField("default", text: value)
                .font(Stanford.body(13))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    // MARK: - Variables

    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Variables")
                    .font(Stanford.body(15))
                    .fontWeight(.medium)
                Spacer()
                Button {
                    var vars = template.variables
                    vars.append(TemplateVariable(name: "new_var", label: "New Variable"))
                    template.variables = vars
                    template.updatedAt = Date()
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(Stanford.body(12))
                }
            }

            if template.variables.isEmpty {
                Text("No variables defined. Variables let users customize the template when creating tasks.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(template.variables.enumerated()), id: \.element.id) { index, variable in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("{{\(variable.name)}}")
                                    .font(Stanford.ui(12, design: .monospaced))
                                    .foregroundStyle(ConfigureTab.templates.color)
                                if variable.isRequired {
                                    Text("required")
                                        .font(Stanford.caption(10))
                                        .foregroundStyle(Stanford.cardinalRed)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Stanford.cardinalRed.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(variable.label)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.secondary)
                            if !variable.defaultValue.isEmpty {
                                Text("Default: \(variable.defaultValue)")
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button {
                            var vars = template.variables
                            vars.remove(at: index)
                            template.variables = vars
                            template.updatedAt = Date()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(Stanford.ui(15))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Stanford.fog.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Passing")
                .font(Stanford.body(15))
                .fontWeight(.medium)

            Toggle("Pass Before output to Main agent", isOn: $template.passContextToMain)
                .font(Stanford.body(13))
                .disabled(!template.hasBeforePhase)

            Toggle("Pass Main output to After agent", isOn: $template.passContextToAfter)
                .font(Stanford.body(13))
                .disabled(!template.hasAfterPhase)
        }
    }

    private var defaultSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Skills")
                .font(Stanford.body(15))
                .fontWeight(.medium)
            Text("Skills auto-attached to tasks created from this template")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)

            ForEach(availableSkills) { skill in
                Toggle(isOn: Binding(
                    get: { template.defaultSkillIDs.contains(skill.id.uuidString) },
                    set: { enabled in
                        if enabled {
                            if !template.defaultSkillIDs.contains(skill.id.uuidString) {
                                template.defaultSkillIDs.append(skill.id.uuidString)
                            }
                        } else {
                            template.defaultSkillIDs.removeAll { $0 == skill.id.uuidString }
                        }
                        template.updatedAt = Date()
                    }
                )) {
                    Label(skill.name, systemImage: skill.icon)
                        .font(Stanford.body(13))
                }
            }
        }
    }

    private func phaseIsActive(_ phase: TemplatePhase) -> Bool {
        switch phase {
        case .before: return template.hasBeforePhase
        case .main: return true
        case .after: return template.hasAfterPhase
        }
    }

    private var templateIcons: [String] {
        [
            "rectangle.3.group", "gearshape.2", "arrow.triangle.branch",
            "server.rack", "cloud", "terminal",
            "doc.text", "folder.badge.gearshape", "testtube.2",
            "shield.checkered", "antenna.radiowaves.left.and.right", "bolt.circle"
        ]
    }
}
