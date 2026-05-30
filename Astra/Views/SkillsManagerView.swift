import SwiftUI
import SwiftData

struct SkillsManagerView: View {
    var workspace: Workspace
    var onManageCapabilities: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSkill: Skill?

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    private var workspaceSkills: [Skill] {
        workspace.skills.filter { !$0.isGlobal && !$0.isSystemBuiltIn }.sorted { $0.name < $1.name }
    }

    private var skills: [Skill] {
        let ws = workspaceSkills
        let globals = globalSkills.filter { gs in !ws.contains { $0.id == gs.id } }
        return ws + globals
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Skills")
                    .font(Stanford.heading(22))
                    .foregroundStyle(Stanford.black)
                Spacer()
                if let onManageCapabilities {
                    Button { onManageCapabilities() } label: {
                        Label("Manage Capabilities", systemImage: "square.grid.2x2")
                    }
                    .help("Open Manage Capabilities")
                }
                Button { createSkill() } label: {
                    Label("New Skill", systemImage: "plus")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Master / Detail
            HStack(spacing: 0) {
                // Skill list
                VStack(spacing: 0) {
                    List(selection: $selectedSkill) {
                        if !workspaceSkills.isEmpty {
                            Section("Workspace") {
                                ForEach(workspaceSkills) { skill in
                                    skillRow(skill)
                                        .tag(skill)
                                }
                            }
                        }
                        let availableGlobals = globalSkills.filter { gs in
                            !gs.isSystemBuiltIn &&
                            !workspaceSkills.contains { $0.id == gs.id }
                        }
                        if !availableGlobals.isEmpty {
                            Section("Shared Library") {
                                ForEach(availableGlobals) { skill in
                                    HStack(spacing: 6) {
                                        let enabled = workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString)
                                        Button {
                                            toggleGlobalSkill(skill)
                                        } label: {
                                            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(enabled ? Stanford.paloAltoGreen : Stanford.coolGrey.opacity(0.4))
                                                .font(Stanford.ui(15))
                                        }
                                        .buttonStyle(.plain)
                                        .help(enabled ? "Disable in this workspace" : "Enable in this workspace")

                                        skillRow(skill)
                                    }
                                    .tag(skill)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(width: 200)
                .background(Stanford.fog)

                Divider()

                // Editor
                if let skill = selectedSkill {
                    SkillEditorView(skill: skill, workspace: workspace, onDelete: {
                        deleteSkill(skill)
                    })
                } else {
                    ContentUnavailableView(
                        "Select a Skill",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Select a skill to edit or click + to create one.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 660, height: 500)
        .onAppear {
            if selectedSkill == nil, let first = skills.first {
                selectedSkill = first
            }
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        HStack(spacing: 8) {
            Image(systemName: skill.icon)
                .foregroundStyle(skill.isGlobal ? Stanford.poppy : Stanford.lagunita)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name.isEmpty ? "Untitled" : skill.name)
                    .font(Stanford.body(15))
                HStack(spacing: 4) {
                    Text("\(skill.allowedTools.count) capabilities")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                    if skill.isGlobal {
                        Text("shared")
                            .font(Stanford.caption(10))
                            .foregroundStyle(Stanford.poppy)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Stanford.poppy.opacity(0.1))
                            .clipShape(Capsule())
                    }
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

// MARK: - Skill Editor

struct SkillEditorView: View {
    private struct InheritedConnectorSecret: Identifiable {
        let connector: Connector
        let key: String
        let isAvailable: Bool

        var id: String { "\(connector.id.uuidString):\(key)" }
    }

    @Bindable var skill: Skill
    var workspace: Workspace?
    let onDelete: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var newCustomTool = ""
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""
    @State private var newConfigItem = ""
    @State private var showEnvValues = false
    @State private var isAddingSecret = false
    @FocusState private var isNameFocused: Bool

    @Query private var allConnectors: [Connector]
    @Query private var allLocalTools: [LocalTool]

    private var availableConnectors: [Connector] {
        guard let ws = workspace else { return [] }
        return ws.connectors.filter { conn in
            !skill.connectors.contains { $0.id == conn.id }
        }.sorted { $0.name < $1.name }
    }

    private var availableLocalTools: [LocalTool] {
        guard let ws = workspace else { return [] }
        return ws.localTools.filter { tool in
            !skill.localTools.contains { $0.id == tool.id }
        }.sorted { $0.name < $1.name }
    }

    private var directSecretVars: [(offset: Int, key: String)] {
        skill.environmentKeys.enumerated()
            .filter { Self.isSecretKey($0.element) }
            .map { (offset: $0.offset, key: $0.element) }
    }

    private var inheritedConnectorSecrets: [InheritedConnectorSecret] {
        skill.connectors
            .sorted { $0.name < $1.name }
            .flatMap { connector in
                connector.credentialKeys.map { key in
                    InheritedConnectorSecret(
                        connector: connector,
                        key: key,
                        isAvailable: KeychainService.exists(key: key, connectorID: connector.id)
                    )
                }
            }
    }

    private var totalSecretCount: Int {
        directSecretVars.count + inheritedConnectorSecrets.count
    }

    private static func isSecretKey(_ key: String) -> Bool {
        Skill.isSecretEnvironmentKey(key)
    }

    private static func isListKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return upper.contains("PROJECTS") || upper.contains("REPOS") ||
               upper.contains("CHANNELS") || upper.contains("TAGS") ||
               upper.contains("LABELS") || upper.contains("TEAMS")
    }

    private static func placeholderForKey(_ key: String) -> String {
        let upper = key.uppercased()
        if upper.contains("PROJECT") { return "Project key, e.g. ENG" }
        if upper.contains("REPO") { return "e.g. my-repo" }
        if upper.contains("CHANNEL") { return "e.g. #general" }
        return "Add item"
    }

    private static func hintForKey(_ key: String) -> String? {
        let upper = key.uppercased()
        if upper.contains("PROJECT") { return "Use Jira project keys (the prefix before ticket numbers, e.g. ENG from ENG-123)" }
        if upper.contains("REPO") { return "Repository names as they appear in your source control" }
        if upper.contains("CHANNEL") { return "Channel names including the # prefix" }
        return nil
    }

    private let iconOptions = [
        "puzzlepiece.extension", "lock.shield", "eye", "checkmark.seal",
        "terminal", "wrench", "shield", "hand.raised",
        "doc.text.magnifyingglass", "gearshape", "bolt", "leaf"
    ]

    private let capabilityTools = ["Write", "Edit", "Bash", "WebFetch", "WebSearch", "Agent", "NotebookEdit", "TodoWrite"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Identity
                GroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name", text: $skill.name)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)

                        TextField("Description", text: $skill.skillDescription)
                            .textFieldStyle(.roundedBorder)

                        Toggle(isOn: Binding(
                            get: { skill.isGlobal },
                            set: { newValue in
                                skill.isGlobal = newValue
                                if newValue {
                                    // Detach from workspace so cascade delete won't remove it
                                    skill.workspace = nil
                                    if let ws = workspace {
                                        let idString = skill.id.uuidString
                                        if !ws.enabledGlobalSkillIDs.contains(idString) {
                                            ws.enabledGlobalSkillIDs.append(idString)
                                        }
                                        ws.updatedAt = Date()
                                    }
                                } else if let ws = workspace {
                                    skill.workspace = ws
                                    ws.enabledGlobalSkillIDs.removeAll { $0 == skill.id.uuidString }
                                    ws.updatedAt = Date()
                                }
                                skill.updatedAt = Date()
                                WorkspacePersistenceCoordinator.saveAndAutoExport(
                                    workspace: workspace ?? skill.workspace,
                                    modelContext: modelContext
                                )
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Shared across all workspaces")
                                    .font(Stanford.body(14))
                                Text("This skill will appear in every workspace's skill picker")
                                    .font(Stanford.caption(12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)

                        // Icon picker
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Icon")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 6), spacing: 8) {
                                ForEach(iconOptions, id: \.self) { icon in
                                    Button {
                                        skill.icon = icon
                                    } label: {
                                        Image(systemName: icon)
                                            .font(Stanford.ui(16))
                                            .frame(width: 32, height: 32)
                                            .background(skill.icon == icon ? Stanford.lagunita.opacity(0.15) : Color.clear)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(skill.icon == icon ? Stanford.lagunita : .clear, lineWidth: 1.5)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(skill.icon == icon ? Stanford.lagunita : Stanford.coolGrey)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Capabilities
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(capabilityTools, id: \.self) { tool in
                            toolToggle(tool)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        Text("Capabilities")
                        Spacer()
                        let count = capabilityTools.filter { skill.allowedTools.contains($0) }.count
                        Text("\(count) of \(capabilityTools.count)")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                }


                // Attached Connectors
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if !skill.connectors.isEmpty {
                            ForEach(skill.connectors.sorted(by: { $0.name < $1.name })) { conn in
                                HStack(spacing: 10) {
                                    Image(systemName: conn.icon)
                                        .font(Stanford.ui(15))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Stanford.paloAltoGreen)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conn.name)
                                            .font(Stanford.body(14))
                                            .fontWeight(.medium)
                                        HStack(spacing: 6) {
                                            Text(conn.serviceType.replacingOccurrences(of: "_", with: " ").capitalized)
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(Stanford.paloAltoGreen)
                                            if !conn.baseURL.isEmpty {
                                                Text(conn.baseURL)
                                                    .font(Stanford.caption(11))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    Spacer()
                                    if !conn.credentialKeys.isEmpty {
                                        HStack(spacing: 2) {
                                            Image(systemName: "key.fill")
                                                .font(Stanford.ui(10))
                                            Text("\(conn.credentialKeys.count)")
                                                .font(Stanford.caption(11))
                                        }
                                        .foregroundStyle(Stanford.paloAltoGreen)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Stanford.paloAltoGreen.opacity(0.1))
                                        .clipShape(Capsule())
                                    }
                                    Button {
                                        conn.skill = nil
                                        skill.updatedAt = Date()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(Stanford.ui(16))
                                            .foregroundStyle(Stanford.coolGrey.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Detach connector")
                                }
                                .padding(8)
                                .background(Stanford.paloAltoGreen.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Stanford.paloAltoGreen.opacity(0.15), lineWidth: 1)
                                )
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.horizontal.circle")
                                    .font(Stanford.ui(16))
                                    .foregroundStyle(Stanford.paloAltoGreen.opacity(0.4))
                                Text("No connectors attached")
                                    .font(Stanford.caption(13))
                                    .foregroundStyle(Stanford.coolGrey)
                                Spacer()
                            }
                            .padding(8)
                        }

                        if !availableConnectors.isEmpty {
                            Menu {
                                ForEach(availableConnectors) { conn in
                                    Button {
                                        conn.skill = skill
                                        skill.updatedAt = Date()
                                    } label: {
                                        Label(conn.name, systemImage: conn.icon)
                                    }
                                }
                            } label: {
                                Label("Attach Connector", systemImage: "plus.circle")
                                    .font(Stanford.body(13))
                                    .foregroundStyle(Stanford.paloAltoGreen)
                            }
                        } else if skill.connectors.isEmpty {
                            Text("Create connectors in the Connectors tab to attach them here.")
                                .font(Stanford.caption(11))
                                .foregroundStyle(Stanford.coolGrey.opacity(0.7))
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle")
                            .foregroundStyle(Stanford.paloAltoGreen)
                        Text("Connectors")
                        if !skill.connectors.isEmpty {
                            Text("\(skill.connectors.count)")
                                .font(Stanford.caption(11))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Stanford.paloAltoGreen)
                                .clipShape(Capsule())
                        }
                    }
                }

                // Tools (scripts, MCP servers, custom tool names)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        // Attached workspace tools
                        if !skill.localTools.isEmpty {
                            ForEach(skill.localTools.sorted(by: { $0.name < $1.name })) { tool in
                                HStack(spacing: 10) {
                                    Image(systemName: LocalTool.iconForType(tool.toolType))
                                        .font(Stanford.ui(15))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Stanford.tools)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name)
                                            .font(Stanford.body(14))
                                            .fontWeight(.medium)
                                        Text(tool.displayCommand)
                                            .font(Stanford.ui(11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(tool.toolType.uppercased())
                                        .font(Stanford.caption(10))
                                        .foregroundStyle(Stanford.tools)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Stanford.tools.opacity(0.1))
                                        .clipShape(Capsule())
                                    Button {
                                        tool.skill = nil
                                        skill.updatedAt = Date()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(Stanford.ui(16))
                                            .foregroundStyle(Stanford.coolGrey.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Detach tool")
                                }
                                .padding(8)
                                .background(Stanford.tools.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Stanford.tools.opacity(0.15), lineWidth: 1)
                                )
                            }
                        }

                        // Inline custom tool names (MCP tools, etc.)
                        if !skill.customTools.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(skill.customTools, id: \.self) { tool in
                                    HStack(spacing: 4) {
                                        Text(tool)
                                            .font(Stanford.ui(13, design: .monospaced))
                                        Button {
                                            skill.customTools.removeAll { $0 == tool }
                                            skill.updatedAt = Date()
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(Stanford.ui(10, weight: .bold))
                                                .foregroundStyle(Stanford.coolGrey)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Stanford.tools.opacity(0.1))
                                    .foregroundStyle(Stanford.tools)
                                    .clipShape(Capsule())
                                }
                            }
                        }

                        if skill.localTools.isEmpty && skill.customTools.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(Stanford.ui(16))
                                    .foregroundStyle(Stanford.tools.opacity(0.4))
                                Text("No tools attached")
                                    .font(Stanford.caption(13))
                                    .foregroundStyle(Stanford.coolGrey)
                                Spacer()
                            }
                            .padding(8)
                        }

                        // Add tool name or attach workspace tool
                        HStack(spacing: 8) {
                            TextField("Add tool name (e.g. mcp__server__tool)", text: $newCustomTool)
                                .textFieldStyle(.roundedBorder)
                                .font(Stanford.ui(13, design: .monospaced))
                                .onSubmit { addCustomTool() }
                            Button("Add") { addCustomTool() }
                                .disabled(newCustomTool.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        if !availableLocalTools.isEmpty {
                            Menu {
                                ForEach(availableLocalTools) { tool in
                                    Button {
                                        tool.skill = skill
                                        skill.updatedAt = Date()
                                    } label: {
                                        Label(tool.name, systemImage: LocalTool.iconForType(tool.toolType))
                                    }
                                }
                            } label: {
                                Label("Attach Workspace Tool", systemImage: "plus.circle")
                                    .font(Stanford.body(13))
                                    .foregroundStyle(Stanford.tools)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(Stanford.tools)
                        Text("Tools")
                        if !skill.localTools.isEmpty || !skill.customTools.isEmpty {
                            let totalTools = skill.localTools.count + skill.customTools.count
                            Text("\(totalTools)")
                                .font(Stanford.caption(11))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Stanford.tools)
                                .clipShape(Capsule())
                        }
                    }
                }

                // Behavioral Instructions
                GroupBox("Behavioral Instructions") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("These instructions are injected into the agent's prompt when this skill is active.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $skill.behaviorInstructions)
                            .font(Stanford.ui(14, design: .monospaced))
                            .frame(minHeight: 80, maxHeight: 140)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Stanford.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Stanford.sandstone.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .padding(.vertical, 4)
                }

                // Configuration (non-secret parameters)
                let configVars = skill.environmentKeys.enumerated().filter { !Self.isSecretKey($0.element) }
                if !configVars.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Non-secret parameters passed to the agent process.")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)

                            ForEach(configVars, id: \.offset) { origIdx, key in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key)
                                        .font(Stanford.ui(13, design: .monospaced))
                                        .fontWeight(.medium)

                                    if let hint = Self.hintForKey(key) {
                                        Text(hint)
                                            .font(Stanford.caption(11))
                                            .foregroundStyle(Stanford.coolGrey)
                                    }

                                    if Self.isListKey(key) {
                                        // Chip-style editor for list values
                                        let items = skill.valueForEnvironmentKey(at: origIdx)
                                            .split(separator: ",")
                                            .map { $0.trimmingCharacters(in: .whitespaces) }
                                            .filter { !$0.isEmpty }

                                        FlowLayout(spacing: 5) {
                                            ForEach(items, id: \.self) { item in
                                                HStack(spacing: 4) {
                                                    Text(item)
                                                        .font(Stanford.ui(12, design: .monospaced))
                                                    Button {
                                                        let updated = items.filter { $0 != item }.joined(separator: ",")
                                                        skill.setEnvironmentValue(updated, at: origIdx)
                                                    } label: {
                                                        Image(systemName: "xmark")
                                                            .font(Stanford.ui(10, weight: .bold))
                                                            .foregroundStyle(Stanford.coolGrey)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Stanford.lagunita.opacity(0.1))
                                                .foregroundStyle(Stanford.lagunita)
                                                .clipShape(Capsule())
                                            }
                                        }

                                        HStack(spacing: 6) {
                                            TextField(Self.placeholderForKey(key), text: $newConfigItem)
                                                .textFieldStyle(.roundedBorder)
                                                .font(Stanford.ui(13, design: .monospaced))
                                                .onSubmit { addConfigItem(at: origIdx) }
                                            Button("Add") { addConfigItem(at: origIdx) }
                                                .disabled(newConfigItem.trimmingCharacters(in: .whitespaces).isEmpty)
                                        }
                                    } else {
                                        // Plain text field for single values
                                        TextField("value", text: Binding(
                                            get: { skill.valueForEnvironmentKey(at: origIdx) },
                                            set: { skill.setEnvironmentValue($0, at: origIdx) }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .font(Stanford.ui(13, design: .monospaced))
                                    }

                                    HStack {
                                        Spacer()
                                        Button {
                                            skill.removeEnvironmentEntry(at: origIdx)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(Stanford.ui(11))
                                                .foregroundStyle(Stanford.coolGrey)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(8)
                                .background(Stanford.fog)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Configuration", systemImage: "slider.horizontal.3")
                    }
                }

                // Secrets (credentials, tokens, keys)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Credentials passed securely to the agent. Values never appear in prompts or logs.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)

                        if !directSecretVars.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(directSecretVars, id: \.offset) { origIdx, key in
                                    HStack(spacing: 8) {
                                        Text(key)
                                            .font(Stanford.ui(13, design: .monospaced))
                                            .fontWeight(.medium)
                                            .frame(minWidth: 100, alignment: .leading)

                                        if showEnvValues {
                                            let value = skill.valueForEnvironmentKey(at: origIdx)
                                            Text(value.isEmpty ? "(empty)" : value)
                                                .font(Stanford.ui(13, design: .monospaced))
                                                .foregroundStyle(value.isEmpty ? .tertiary : .secondary)
                                                .lineLimit(1)
                                        } else {
                                            let inKeychain = KeychainService.exists(key: key, skillID: skill.id)
                                            let hasValue = !skill.valueForEnvironmentKey(at: origIdx).isEmpty
                                            HStack(spacing: 4) {
                                                Text(String(repeating: "\u{2022}", count: hasValue ? 12 : 0))
                                                    .font(Stanford.ui(13))
                                                    .foregroundStyle(.secondary)
                                                if hasValue {
                                                    Image(systemName: inKeychain ? "checkmark.shield.fill" : "exclamationmark.triangle")
                                                        .font(Stanford.ui(10))
                                                        .foregroundStyle(inKeychain ? Stanford.paloAltoGreen : Stanford.poppy)
                                                        .help(inKeychain ? "Stored in skill Keychain entry" : "Secret value exists but has not been migrated to Keychain")
                                                }
                                            }
                                        }

                                        Spacer()

                                        Button {
                                            skill.removeEnvironmentEntry(at: origIdx)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(Stanford.ui(12))
                                                .foregroundStyle(Stanford.coolGrey)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Stanford.fog)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }

                        if !inheritedConnectorSecrets.isEmpty {
                            if !directSecretVars.isEmpty {
                                Divider()
                                    .padding(.vertical, 2)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 4) {
                                    Image(systemName: "link")
                                        .font(Stanford.ui(10))
                                    Text("Inherited from attached connectors")
                                        .font(Stanford.caption(12).weight(.medium))
                                }
                                .foregroundStyle(Stanford.paloAltoGreen)

                                Text("These keys are injected automatically from connector credentials and are managed in the Connectors tab.")
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 4) {
                                    ForEach(inheritedConnectorSecrets) { item in
                                        HStack(spacing: 8) {
                                            Text(item.key)
                                                .font(Stanford.ui(13, design: .monospaced))
                                                .fontWeight(.medium)
                                                .frame(minWidth: 140, alignment: .leading)

                                            if showEnvValues {
                                                let value = KeychainService.load(key: item.key, connectorID: item.connector.id) ?? ""
                                                Text(value.isEmpty ? "(empty)" : value)
                                                    .font(Stanford.ui(13, design: .monospaced))
                                                    .foregroundStyle(value.isEmpty ? .tertiary : .secondary)
                                                    .lineLimit(1)
                                            } else {
                                                HStack(spacing: 4) {
                                                    Text(String(repeating: "\u{2022}", count: 12))
                                                        .font(Stanford.ui(13))
                                                        .foregroundStyle(.secondary)
                                                    Image(systemName: item.isAvailable ? "checkmark.shield.fill" : "exclamationmark.triangle")
                                                        .font(Stanford.ui(10))
                                                        .foregroundStyle(item.isAvailable ? Stanford.paloAltoGreen : Stanford.poppy)
                                                        .help(item.isAvailable ? "Stored in connector Keychain entry" : "Credential key exists but has no stored value")
                                                }
                                            }

                                            Spacer()

                                            Text(item.connector.name)
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(Stanford.paloAltoGreen)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Stanford.paloAltoGreen.opacity(0.1))
                                                .clipShape(Capsule())
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Stanford.paloAltoGreen.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Stanford.paloAltoGreen.opacity(0.12), lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }

                        if isAddingSecret {
                            HStack(spacing: 6) {
                                TextField("KEY", text: $newEnvKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Stanford.ui(13, design: .monospaced))
                                    .frame(width: 140)
                                SecureField("value", text: $newEnvValue)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Stanford.ui(13, design: .monospaced))
                                    .onSubmit { addEnvVar() }
                                Button("Add") { addEnvVar() }
                                    .disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty || newEnvValue.isEmpty)
                                Button("Cancel") {
                                    cancelSecretEntry()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Stanford.coolGrey)
                            }
                        } else {
                            Button {
                                isAddingSecret = true
                            } label: {
                                Label("Add Secret", systemImage: "plus.circle")
                                    .font(Stanford.body(13))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        Label("Secrets", systemImage: "key")
                        Spacer()
                        if totalSecretCount > 0 {
                            Text("\(totalSecretCount)")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            showEnvValues.toggle()
                        } label: {
                            Image(systemName: showEnvValues ? "eye.slash" : "eye")
                                .font(Stanford.ui(12))
                                .foregroundStyle(Stanford.coolGrey)
                        }
                        .buttonStyle(.plain)
                        .help(showEnvValues ? "Hide values" : "Show values")
                    }
                }

                // Delete
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Skill", systemImage: "trash")
                    }
                }
            }
            .padding()
        }
        .onAppear { if skill.name == "New Skill" { isNameFocused = true } }
        .onDisappear {
            skill.updatedAt = Date()
            WorkspacePersistenceCoordinator.flushPendingExport(workspace: workspace ?? skill.workspace, modelContext: modelContext)
        }
    }

    private func addEnvVar() {
        let key = newEnvKey.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty, !newEnvValue.isEmpty else { return }
        skill.upsertEnvironmentEntry(key: key, value: newEnvValue)
        cancelSecretEntry()
    }

    private func addConfigItem(at envIdx: Int) {
        let item = newConfigItem.trimmingCharacters(in: .whitespaces).uppercased()
        guard !item.isEmpty else { return }
        let current = skill.valueForEnvironmentKey(at: envIdx)
        let items = current.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !items.contains(item) else { newConfigItem = ""; return }
        skill.setEnvironmentValue(items.isEmpty ? item : current + ",\(item)", at: envIdx)
        newConfigItem = ""
    }

    private func cancelSecretEntry() {
        newEnvKey = ""
        newEnvValue = ""
        isAddingSecret = false
    }

    private func toolToggle(_ tool: String) -> some View {
        Toggle(isOn: Binding(
            get: { skill.allowedTools.contains(tool) },
            set: { enabled in
                if enabled {
                    if !skill.allowedTools.contains(tool) {
                        skill.allowedTools.append(tool)
                    }
                } else {
                    skill.allowedTools.removeAll { $0 == tool }
                }
                skill.updatedAt = Date()
                AppLogger.audit(.skillToolPermissionChanged, category: "UI", fields: [
                    "skill_id": skill.id.uuidString,
                    "tool": tool,
                    "enabled": String(enabled)
                ])
            }
        )) {
            HStack(spacing: 6) {
                Text(tool)
                    .font(Stanford.body(14))
                    .fontWeight(.medium)
                if let desc = Skill.toolDescriptions[tool] {
                    Text("— \(desc)")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func addCustomTool() {
        let name = newCustomTool.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !skill.customTools.contains(name) else { newCustomTool = ""; return }
        skill.customTools.append(name)
        skill.updatedAt = Date()
        newCustomTool = ""
    }
}

// MARK: - Flow Layout (wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}


// MARK: - Natural Language Skill Parser

enum SkillDescriptionParser {
    private static let scriptPathRegex = try? NSRegularExpression(pattern: #"[./~]\S+\.(sh|py|rb|js|ts)"#)
    struct DetectedEnvVar: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        var hint: String
    }

    struct Result {
        var name: String
        var icon: String
        var allowedTools: [String]
        var disallowedTools: [String]
        var behaviorInstructions: String
        var detectedEnvVars: [DetectedEnvVar]
        var detectedScripts: [String]
    }

    static func parse(_ input: String) -> Result {
        let lower = input.lowercased()
        let allTools = ["Read", "Write", "Edit", "Bash", "Glob", "Grep", "WebFetch", "WebSearch", "Agent", "NotebookEdit"]

        var allowed = Set(Skill.defaultAllowed)
        var disallowed = Set<String>()
        var instructions: [String] = []
        var icon = "puzzlepiece.extension"
        var name = ""
        var envVars: [DetectedEnvVar] = []
        var scripts: [String] = []

        // Detect "read-only" / "read only"
        if lower.contains("read-only") || lower.contains("read only") || lower.contains("no writ") || lower.contains("no edit") {
            allowed = ["Read", "Glob", "Grep"]
            disallowed = ["Write", "Edit", "Bash"]
            instructions.append("Do not create, modify, or delete any files. Only read and analyze.")
            icon = "eye"
        }

        // Explicit tool blocks
        let toolMap: [(keywords: [String], tool: String)] = [
            (["no bash", "no shell", "without bash", "block bash", "disable bash"], "Bash"),
            (["no write", "without write", "block write", "disable write", "can't write", "cannot write"], "Write"),
            (["no edit", "without edit", "block edit", "disable edit"], "Edit"),
            (["no web", "no fetch", "no internet", "offline"], "WebFetch"),
        ]
        for entry in toolMap {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                allowed.remove(entry.tool)
                disallowed.insert(entry.tool)
                if entry.tool == "WebFetch" {
                    allowed.remove("WebSearch")
                    disallowed.insert("WebSearch")
                }
            }
        }

        // Explicit tool additions
        if lower.contains("with web") || lower.contains("allow web") || lower.contains("web access") {
            allowed.insert("WebFetch")
            allowed.insert("WebSearch")
            disallowed.remove("WebFetch")
            disallowed.remove("WebSearch")
        }

        // Purpose detection
        if lower.contains("security") || lower.contains("audit") || lower.contains("vulnerab") {
            if name.isEmpty { name = "Security Reviewer" }
            icon = "lock.shield"
            instructions.append("Focus on security vulnerabilities, OWASP top 10, secrets in code, and insecure patterns.")
        }
        if lower.contains("test") || lower.contains("testing") {
            if name.isEmpty { name = "Test Runner" }
            icon = "checkmark.seal"
            instructions.append("Focus on running tests and reporting results clearly.")
        }
        if lower.contains("review") || lower.contains("code review") {
            if name.isEmpty { name = "Review Assistant" }
            icon = "magnifyingglass"
            instructions.append("Review code for quality, bugs, and maintainability. Provide actionable suggestions.")
        }
        if lower.contains("refactor") {
            if name.isEmpty { name = "Refactorer" }
            icon = "arrow.triangle.2.circlepath"
            instructions.append("Improve code quality: reduce duplication, improve naming, simplify logic.")
        }
        if lower.contains("doc") || lower.contains("documentation") || lower.contains("readme") {
            if name.isEmpty { name = "Doc Writer" }
            icon = "doc.text"
            instructions.append("Write clear, concise documentation matching the project's style.")
        }
        if lower.contains("data") || lower.contains("analy") {
            if name.isEmpty { name = "Data Analyst" }
            icon = "chart.bar"
            instructions.append("Analyze data files and produce clear reports. Do not modify source data.")
        }
        if lower.contains("devops") || lower.contains("deploy") || lower.contains("infra") {
            if name.isEmpty { name = "DevOps" }
            icon = "server.rack"
            instructions.append("Handle infrastructure tasks carefully. Prefer dry-run flags when available.")
        }
        if lower.contains("safe") || lower.contains("careful") || lower.contains("cautious") {
            if name.isEmpty { name = "Safe Executor" }
            icon = "shield"
            instructions.append("Never run destructive commands (rm -rf, sudo, curl|bash). Only safe operations.")
        }

        // Detect API keys / credentials / tokens
        let credentialPatterns: [(keywords: [String], envKey: String, hint: String)] = [
            (["api key", "apikey", "api_key"], "API_KEY", "Your API key"),
            (["openai", "gpt"], "OPENAI_API_KEY", "OpenAI API key"),
            (["anthropic", "claude key"], "ANTHROPIC_API_KEY", "Anthropic API key"),
            (["github token", "gh token"], "GITHUB_TOKEN", "GitHub personal access token"),
            (["aws"], "AWS_ACCESS_KEY_ID", "AWS access key"),
            (["gcp", "google cloud"], "GOOGLE_APPLICATION_CREDENTIALS", "Path to GCP service account JSON"),
            (["slack"], "SLACK_TOKEN", "Slack bot token"),
            (["database", "db_url", "database url"], "DATABASE_URL", "Database connection string"),
            (["token"], "AUTH_TOKEN", "Authentication token"),
            (["secret", "credential"], "SECRET_KEY", "Secret key or credential"),
        ]
        for pattern in credentialPatterns {
            if pattern.keywords.contains(where: { lower.contains($0) }) {
                if !envVars.contains(where: { $0.key == pattern.envKey }) {
                    envVars.append(DetectedEnvVar(key: pattern.envKey, value: "", hint: pattern.hint))
                }
            }
        }

        // Detect scripts / commands to run
        let scriptPatterns: [(keywords: [String], script: String)] = [
            (["lint", "linting", "linter"], "lint"),
            (["format", "formatter", "prettier", "black"], "format"),
            (["build", "compile"], "build"),
            (["deploy", "deployment"], "deploy"),
            (["migrate", "migration"], "migrate"),
            (["docker", "container"], "docker"),
        ]
        for pattern in scriptPatterns {
            if pattern.keywords.contains(where: { lower.contains($0) }) {
                scripts.append(pattern.script)
                // Ensure Bash is allowed if scripts are needed
                allowed.insert("Bash")
                disallowed.remove("Bash")
            }
        }

        // Detect custom script paths mentioned (e.g., "./scripts/check.sh")
        if let regex = scriptPathRegex {
            let matches = regex.matches(in: input, range: NSRange(location: 0, length: input.utf16.count))
            for match in matches {
                if let range = Range(match.range, in: input) {
                    scripts.append(String(input[range]))
                }
            }
        }

        // Fallback name
        if name.isEmpty {
            let words = input.split(separator: " ").prefix(3).map(String.init)
            name = words.joined(separator: " ").capitalized
            if name.count > 30 { name = String(name.prefix(30)) }
        }

        return Result(
            name: name,
            icon: icon,
            allowedTools: allTools.filter { allowed.contains($0) },
            disallowedTools: allTools.filter { disallowed.contains($0) },
            behaviorInstructions: instructions.joined(separator: " "),
            detectedEnvVars: envVars,
            detectedScripts: scripts
        )
    }
}

// MARK: - Skill Review Card

struct SkillReviewCard: View {
    @State var parsed: SkillDescriptionParser.Result
    let onCreate: (SkillDescriptionParser.Result) -> Void
    let onCancel: () -> Void
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""
    @State private var newScript = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: parsed.icon)
                    .font(Stanford.ui(16))
                    .foregroundStyle(Stanford.lagunita)
                TextField("Name", text: $parsed.name)
                    .font(Stanford.body(15))
                    .fontWeight(.semibold)
                    .textFieldStyle(.roundedBorder)
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Tools summary
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allowed")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    FlowLayout(spacing: 3) {
                        ForEach(parsed.allowedTools, id: \.self) { tool in
                            Text(tool)
                                .font(Stanford.ui(11, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Stanford.paloAltoGreen.opacity(0.1))
                                .foregroundStyle(Stanford.paloAltoGreen)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
            }

            // Behavior
            if !parsed.behaviorInstructions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Behavior")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    TextField("Instructions", text: $parsed.behaviorInstructions, axis: .vertical)
                        .font(Stanford.caption(12))
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
            }

            // Detected env vars
            if !parsed.detectedEnvVars.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Credentials detected — fill in values:", systemImage: "key")
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.poppy)

                    ForEach(parsed.detectedEnvVars, id: \.key) { ev in
                        let idx = parsed.detectedEnvVars.firstIndex(where: { $0.key == ev.key }) ?? 0
                        HStack(spacing: 6) {
                            Text(ev.key)
                                .font(Stanford.ui(12, design: .monospaced))
                                .fontWeight(.medium)
                                .frame(minWidth: 120, alignment: .leading)
                            SecureField(ev.hint, text: Binding(
                                get: { idx < parsed.detectedEnvVars.count ? parsed.detectedEnvVars[idx].value : "" },
                                set: { if idx < parsed.detectedEnvVars.count { parsed.detectedEnvVars[idx].value = $0 } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(12, design: .monospaced))
                            Button {
                                parsed.detectedEnvVars.removeAll { $0.key == ev.key }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(Stanford.ui(10))
                                    .foregroundStyle(Stanford.coolGrey)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Add custom env var
                    HStack(spacing: 4) {
                        TextField("KEY", text: $newEnvKey)
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(12, design: .monospaced))
                            .frame(width: 120)
                        SecureField("value", text: $newEnvValue)
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(12, design: .monospaced))
                            .onSubmit { addEnvVar() }
                        Button("Add") { addEnvVar() }
                            .font(Stanford.caption(12))
                            .disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(8)
                .background(Stanford.poppy.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Detected scripts
            if !parsed.detectedScripts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Custom tools / scripts detected:", systemImage: "terminal")
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.lagunita)

                    FlowLayout(spacing: 4) {
                        ForEach(parsed.detectedScripts, id: \.self) { script in
                            HStack(spacing: 3) {
                                Text(script)
                                    .font(Stanford.ui(12, design: .monospaced))
                                Button {
                                    parsed.detectedScripts.removeAll { $0 == script }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(Stanford.ui(10, weight: .bold))
                                        .foregroundStyle(Stanford.coolGrey)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Stanford.lagunita.opacity(0.1))
                            .foregroundStyle(Stanford.lagunita)
                            .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 4) {
                        TextField("Add tool name or script path", text: $newScript)
                            .textFieldStyle(.roundedBorder)
                            .font(Stanford.ui(12, design: .monospaced))
                            .onSubmit { addScript() }
                        Button("Add") { addScript() }
                            .font(Stanford.caption(12))
                            .disabled(newScript.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(8)
                .background(Stanford.lagunita.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // No env vars or scripts detected — offer to add
            if parsed.detectedEnvVars.isEmpty && parsed.detectedScripts.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        parsed.detectedEnvVars.append(
                            SkillDescriptionParser.DetectedEnvVar(key: "API_KEY", value: "", hint: "Enter value")
                        )
                    } label: {
                        Label("Add credential", systemImage: "key")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.coolGrey)
                    }
                    .buttonStyle(.plain)

                    Button {
                        parsed.detectedScripts.append("")
                    } label: {
                        Label("Add custom tool", systemImage: "terminal")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.coolGrey)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Create button
            HStack {
                Spacer()
                Button("Create Skill") {
                    onCreate(parsed)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Stanford.fog.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Stanford.lagunita.opacity(0.3), lineWidth: 1)
        )
    }

    private func addEnvVar() {
        let key = newEnvKey.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return }
        parsed.detectedEnvVars.append(
            SkillDescriptionParser.DetectedEnvVar(key: key, value: newEnvValue, hint: "")
        )
        newEnvKey = ""
        newEnvValue = ""
    }

    private func addScript() {
        let script = newScript.trimmingCharacters(in: .whitespaces)
        guard !script.isEmpty else { return }
        parsed.detectedScripts.append(script)
        newScript = ""
    }
}
