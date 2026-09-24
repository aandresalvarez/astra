import SwiftUI
import SwiftData
import ASTRAModels
import ASTRAPersistence

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
    @State private var secretSaveErrorMessage: String?
    @State private var pendingDestruction: PendingSkillDestruction?
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
                        isAvailable: KeychainService.exists(key: key, connector: connector)
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
                                CapabilityPersistence.saveResourceMutation(
                                    workspace: workspace ?? skill.workspace,
                                    isGlobal: skill.isGlobal,
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
                                                    .stroke(skill.icon == icon ? Stanford.lagunita : .clear, lineWidth: Stanford.strokeFocusWidth)
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
                            let sortedConnectors = skill.connectors.sorted(by: { $0.name < $1.name })
                            ForEach(Array(sortedConnectors.enumerated()), id: \.element.id) { index, conn in
                                if index > 0 {
                                    Divider().padding(.leading, 38)
                                }
                                HStack(spacing: 10) {
                                    CapabilityLeadingIcon(
                                        systemImage: conn.icon,
                                        brand: BrandMark.resolve(id: conn.serviceType, name: conn.name),
                                        pointSize: 16
                                    )
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conn.name)
                                            .font(Stanford.body(14))
                                            .fontWeight(.medium)
                                        HStack(spacing: 6) {
                                            Text(conn.serviceType.replacingOccurrences(of: "_", with: " ").capitalized)
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.secondary)
                                    }
                                    Button {
                                        pendingDestruction = PendingSkillDestruction(
                                            title: "Detach Connector",
                                            message: "Detach \u{201C}\(conn.name)\u{201D} from \u{201C}\(skill.name.isEmpty ? "this skill" : skill.name)\u{201D}? Its credentials will no longer be inherited by the skill.",
                                            confirmTitle: "Detach",
                                            perform: {
                                                conn.skill = nil
                                                skill.updatedAt = Date()
                                            }
                                        )
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(Stanford.ui(16))
                                            .foregroundStyle(Stanford.coolGrey.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Detach connector")
                                }
                                .padding(.vertical, 4)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.horizontal.circle")
                                    .font(Stanford.ui(16))
                                    .foregroundStyle(.tertiary)
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
                                    .foregroundStyle(Stanford.lagunita)
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
                            .foregroundStyle(.secondary)
                        Text("Connectors")
                        Spacer()
                        if !skill.connectors.isEmpty {
                            Text("\(skill.connectors.count)")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Tools (scripts, MCP servers, custom tool names)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        // Attached workspace tools
                        if !skill.localTools.isEmpty {
                            let sortedTools = skill.localTools.sorted(by: { $0.name < $1.name })
                            ForEach(Array(sortedTools.enumerated()), id: \.element.id) { index, tool in
                                if index > 0 {
                                    Divider().padding(.leading, 38)
                                }
                                HStack(spacing: 10) {
                                    Image(systemName: LocalTool.iconForType(tool.toolType))
                                        .font(Stanford.ui(15))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 28)
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
                                        .foregroundStyle(.secondary)
                                    Button {
                                        pendingDestruction = PendingSkillDestruction(
                                            title: "Detach Tool",
                                            message: "Detach \u{201C}\(tool.name)\u{201D} from \u{201C}\(skill.name.isEmpty ? "this skill" : skill.name)\u{201D}? It will no longer be available to the skill.",
                                            confirmTitle: "Detach",
                                            perform: {
                                                tool.skill = nil
                                                skill.updatedAt = Date()
                                            }
                                        )
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(Stanford.ui(16))
                                            .foregroundStyle(Stanford.coolGrey.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Detach tool")
                                }
                                .padding(.vertical, 4)
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
                                    .foregroundStyle(.tertiary)
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
                            Button("Add tool") { addCustomTool() }
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
                                    .foregroundStyle(Stanford.lagunita)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(.secondary)
                        Text("Tools")
                        Spacer()
                        if !skill.localTools.isEmpty || !skill.customTools.isEmpty {
                            let totalTools = skill.localTools.count + skill.customTools.count
                            Text("\(totalTools)")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
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
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Stanford.borderRest, lineWidth: 1)
                            )

                        // Written here rather than discovered at run time: a
                        // brokered credential named in these instructions is a
                        // route the agent cannot take.
                        let brokeredFindings = BrokeredSkillInstructionLint.findings(
                            instructions: skill.behaviorInstructions,
                            environmentKeys: skill.environmentKeys
                        )
                        ForEach(brokeredFindings) { finding in
                            Label(finding.message, systemImage: "exclamationmark.triangle.fill")
                                .font(Stanford.caption(12))
                                .foregroundStyle(Stanford.poppy)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                                            Button("Add value") { addConfigItem(at: origIdx) }
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
                                .foregroundStyle(.secondary)

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
                                                let value = KeychainService.load(key: item.key, connector: item.connector) ?? ""
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
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Stanford.fog)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                                Button("Save secret") { addEnvVar() }
                                    .disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty || newEnvValue.isEmpty)
                                Button("Cancel") {
                                    cancelSecretEntry()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Stanford.coolGrey)
                            }
                            if let secretSaveErrorMessage {
                                Text(secretSaveErrorMessage)
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(.red)
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
                        pendingDestruction = PendingSkillDestruction(
                            title: "Delete Skill",
                            message: "Delete \u{201C}\(skill.name.isEmpty ? "this skill" : skill.name)\u{201D}? This permanently removes the skill and its stored secrets. This cannot be undone.",
                            confirmTitle: "Delete",
                            perform: { onDelete() }
                        )
                    } label: {
                        Label("Delete Skill", systemImage: "trash")
                    }
                }
            }
            .padding()
        }
        .confirmationDialog(
            pendingDestruction?.title ?? "",
            isPresented: Binding(
                get: { pendingDestruction != nil },
                set: { presented in if !presented { pendingDestruction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDestruction
        ) { destruction in
            Button(destruction.confirmTitle, role: .destructive) {
                destruction.perform()
                pendingDestruction = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDestruction = nil
            }
        } message: { destruction in
            Text(destruction.message)
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
        guard skill.upsertEnvironmentEntry(key: key, value: newEnvValue, allowUserInteraction: true) else {
            secretSaveErrorMessage = "Could not save \"\(key)\" to Keychain. Allow the permission prompt and try again."
            return
        }
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
        secretSaveErrorMessage = nil
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

// MARK: - Pending Destruction

private struct PendingSkillDestruction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let perform: () -> Void
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
