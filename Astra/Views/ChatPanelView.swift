import SwiftUI
import SwiftData
import ASTRACore

/// Chat message for the conversation
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp = Date()
}

// MARK: - Slash Command Wizard

enum SlashWizardType: String {
    case skill = "/skill"
    case tool = "/tool"
    case connector = "/connector"
    case template = "/template"
    case schedule = "/routine"
    case recap = "/recap"
}

struct SlashWizard {
    let type: SlashWizardType
    var step: Int = 0
    var collected: [String: String] = [:]

    var currentPrompt: String {
        switch type {
        case .skill:
            switch step {
            case 0: return "What should this skill be called?"
            case 1: return "Describe what this skill does (behavior instructions for the agent):"
            case 2: return "Which tools should be **allowed**? (comma-separated, e.g. `Read, Glob, Grep, Bash`)\n\nAvailable: `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`, `WebFetch`, `WebSearch`, `Agent`, `NotebookEdit`"
            case 3: return "Which tools should be **blocked**? (comma-separated, or type `none`):"
            default: return ""
            }
        case .tool:
            switch step {
            case 0: return "What should this tool be called?"
            case 1: return "What type of tool is it?\n\n`1` — CLI Command (e.g. jq, curl, docker)\n`2` — Script File (e.g. /path/to/script.sh)\n`3` — MCP Tool (e.g. mcp__server__tool)"
            case 2:
                let toolType = collected["type"] ?? "cli"
                switch toolType {
                case "script": return "Enter the path to the script file:"
                case "mcp": return "Enter the MCP tool name (e.g. `mcp__server__tool_name`):"
                default: return "Enter the CLI command (e.g. `jq`, `curl`, `docker`):"
                }
            case 3: return "Description (optional, press Enter to skip):"
            default: return ""
            }
        case .connector:
            switch step {
            case 0: return "What should this connector be called?"
            case 1: return "What service type?\n\n`1` — Jira\n`2` — GitHub\n`3` — Slack\n`4` — Database\n`5` — REST API\n`6` — Confluence\n`7` — Custom"
            case 2: return "Enter the base URL (e.g. `https://mysite.atlassian.net`):"
            case 3: return "Auth method?\n\n`1` — None\n`2` — Basic (username/password)\n`3` — Bearer token\n`4` — API Key"
            case 4:
                // Smart credential prompts based on service type
                if let key = nextCredentialKey {
                    return "Enter the value for `\(key)` (stored securely):"
                }
                return "Add a credential key name (e.g. `API_TOKEN`), or type `done` to finish:"
            case 5: return "Enter the value for `\(collected["pendingCredKey"] ?? "")` (stored securely):"
            case 6:
                // After known credentials, offer to add more
                return "Add another credential key name, or type `done` to finish:"
            default: return ""
            }
        case .template:
            switch step {
            case 0:
                // Show available templates (list is set externally before wizard starts)
                let list = collected["templateList"] ?? "No templates available."
                return "\(list)\n\nEnter the number of the template to use:"
            case 1:
                // Ask for task title
                return "What should this task be called?"
            default:
                // Variable prompts — dynamically generated
                let varLabel = collected["currentVarLabel"] ?? "value"
                let varDefault = collected["currentVarDefault"] ?? ""
                let defaultHint = varDefault.isEmpty ? "" : " (default: `\(varDefault)`)"
                return "Enter **\(varLabel)**\(defaultHint):"
            }
        case .schedule:
            return "" // Routine uses provider-assisted conversation, not wizard steps
        case .recap:
            return "" // Recap is one-shot, bypasses the wizard
        }
    }

    /// Known credential keys for common service types
    private static let knownCredentials: [String: [String]] = [
        "jira": ["JIRA_EMAIL", "JIRA_API_TOKEN"],
        "github": ["GITHUB_TOKEN"],
        "slack": ["SLACK_TOKEN"],
        "database": ["DATABASE_URL"],
        "rest_api": ["API_TOKEN"],
        "confluence": ["CONFLUENCE_EMAIL", "CONFLUENCE_API_TOKEN"],
    ]

    /// The next credential key to ask for (nil if all known keys collected or custom type)
    var nextCredentialKey: String? {
        guard let serviceType = collected["serviceType"],
              let keys = Self.knownCredentials[serviceType] else { return nil }
        let existingKeys = (collected["credKeys"] ?? "").split(separator: ",").map(String.init)
        return keys.first { !existingKeys.contains($0) }
    }

    var totalSteps: Int {
        switch type {
        case .skill: return 4
        case .tool: return 4
        case .connector: return 4 // base steps, credentials are variable
        case .template: return 10 // variable, depends on template variables
        case .schedule: return 0
        case .recap: return 0
        }
    }

    var isComplete: Bool {
        switch type {
        case .skill: return step >= 4
        case .tool: return step >= 4
        case .connector:
            return collected["credentialsDone"] == "true"
        case .template:
            return collected["templateDone"] == "true"
        case .schedule: return false
        case .recap: return false
        }
    }

    static func introMessage(for type: SlashWizardType) -> String {
        switch type {
        case .skill:
            return "Let's create a new **skill**. A skill defines what tools an agent can use and how it should behave.\n\nI'll guide you through 4 steps."
        case .tool:
            return "Let's create a new **tool**. Tools are local scripts, CLI commands, or MCP integrations your agent can use.\n\nI'll guide you through 4 steps."
        case .connector:
            return "Let's create a new **connector**. Connectors provide authentication and configuration for external services.\n\nI'll guide you through the setup."
        case .template:
            return "Let's create a task from a **template**. Templates define multi-phase workflows with before, main, and after agents."
        case .schedule:
            return "Let's create a **routine**. I'll help you set up recurring work."
        case .recap:
            return "" // Recap is one-shot, bypasses the wizard
        }
    }

    mutating func processInput(_ input: String) -> String? {
        switch type {
        case .skill: return processSkillStep(input)
        case .tool: return processToolStep(input)
        case .connector: return processConnectorStep(input)
        case .template: return processTemplateStep(input)
        case .schedule: return nil
        case .recap: return nil
        }
    }

    private mutating func processSkillStep(_ input: String) -> String? {
        switch step {
        case 0:
            collected["name"] = input
            step = 1
            return "Got it — **\(input)**.\n\n\(currentPrompt)"
        case 1:
            collected["behavior"] = input
            step = 2
            return "Behavior set.\n\n\(currentPrompt)"
        case 2:
            collected["allowed"] = input
            step = 3
            return "Allowed tools: `\(input)`\n\n\(currentPrompt)"
        case 3:
            collected["blocked"] = input.lowercased() == "none" ? "" : input
            step = 4
            return nil // signals completion
        default:
            return nil
        }
    }

    private mutating func processToolStep(_ input: String) -> String? {
        switch step {
        case 0:
            collected["name"] = input
            step = 1
            return "Got it — **\(input)**.\n\n\(currentPrompt)"
        case 1:
            let typeMap = ["1": "cli", "2": "script", "3": "mcp",
                          "cli": "cli", "script": "script", "mcp": "mcp"]
            let resolved = typeMap[input.lowercased().trimmingCharacters(in: .whitespaces)] ?? "cli"
            collected["type"] = resolved
            step = 2
            let label = resolved == "cli" ? "CLI Command" : resolved == "script" ? "Script File" : "MCP Tool"
            return "Type: **\(label)**\n\n\(currentPrompt)"
        case 2:
            collected["command"] = input
            step = 3
            return "Command: `\(input)`\n\n\(currentPrompt)"
        case 3:
            collected["description"] = input
            step = 4
            return nil // signals completion
        default:
            return nil
        }
    }

    private mutating func processConnectorStep(_ input: String) -> String? {
        switch step {
        case 0:
            collected["name"] = input
            step = 1
            return "Got it — **\(input)**.\n\n\(currentPrompt)"
        case 1:
            let typeMap = ["1": "jira", "2": "github", "3": "slack", "4": "database",
                          "5": "rest_api", "6": "confluence", "7": "custom"]
            let resolved = typeMap[input.trimmingCharacters(in: .whitespaces)] ?? input.lowercased()
            collected["serviceType"] = resolved
            step = 2
            return "Service: **\(resolved.replacingOccurrences(of: "_", with: " ").capitalized)**\n\n\(currentPrompt)"
        case 2:
            collected["baseURL"] = input
            step = 3
            return "Base URL: `\(input)`\n\n\(currentPrompt)"
        case 3:
            let authMap = ["1": "none", "2": "basic", "3": "bearer", "4": "api_key"]
            let resolved = authMap[input.trimmingCharacters(in: .whitespaces)] ?? input.lowercased()
            collected["authMethod"] = resolved
            step = 4
            // For known service types, go straight to asking for values
            if nextCredentialKey != nil {
                return "Auth: **\(resolved.replacingOccurrences(of: "_", with: " ").capitalized)**\n\nNow let's add your credentials.\n\n\(currentPrompt)"
            }
            return "Auth: **\(resolved.replacingOccurrences(of: "_", with: " ").capitalized)**\n\n\(currentPrompt)"
        case 4:
            // Smart mode: if we have a known credential key, the user just types the VALUE
            if let key = nextCredentialKey {
                let existingKeys = collected["credKeys"] ?? ""
                let existingVals = collected["credVals"] ?? ""
                collected["credKeys"] = existingKeys.isEmpty ? key : existingKeys + "," + key
                collected["credVals"] = existingVals.isEmpty ? input : existingVals + "," + input

                // Check if there's another known key to collect
                if nextCredentialKey != nil {
                    return "Saved `\(key)`.\n\n\(currentPrompt)"
                } else {
                    // All known credentials collected — done
                    collected["credentialsDone"] = "true"
                    return nil
                }
            }

            // Manual mode (custom service types): user enters key name or "done"
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "done" || trimmed.isEmpty {
                collected["credentialsDone"] = "true"
                return nil
            }
            collected["pendingCredKey"] = trimmed.uppercased()
            step = 5
            return currentPrompt
        case 5:
            // Manual mode: user enters the value for a custom key
            let key = collected["pendingCredKey"] ?? ""
            let existingKeys = collected["credKeys"] ?? ""
            let existingVals = collected["credVals"] ?? ""
            collected["credKeys"] = existingKeys.isEmpty ? key : existingKeys + "," + key
            collected["credVals"] = existingVals.isEmpty ? input : existingVals + "," + input
            collected.removeValue(forKey: "pendingCredKey")
            step = 6
            return "Saved `\(key)`.\n\n\(currentPrompt)"
        case 6:
            // After manual credential, ask for more or done
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "done" || trimmed.isEmpty {
                collected["credentialsDone"] = "true"
                return nil
            }
            collected["pendingCredKey"] = trimmed.uppercased()
            step = 5
            return currentPrompt
        default:
            return nil
        }
    }

    private mutating func processTemplateStep(_ input: String) -> String? {
        switch step {
        case 0:
            // User selected a template by number
            collected["templateIndex"] = input.trimmingCharacters(in: .whitespaces)
            step = 1
            let templateName = collected["templateName_\(input.trimmingCharacters(in: .whitespaces))"] ?? "template"
            return "Using **\(templateName)**.\n\n\(currentPrompt)"
        case 1:
            // Task title
            collected["taskTitle"] = input
            step = 2
            // Check if there are variables to collect
            let varCount = Int(collected["varCount"] ?? "0") ?? 0
            if varCount == 0 {
                collected["templateDone"] = "true"
                return nil
            }
            // Set up first variable prompt
            collected["currentVarIndex"] = "0"
            let varName = collected["var_0_name"] ?? ""
            let varLabel = collected["var_0_label"] ?? varName
            let varDefault = collected["var_0_default"] ?? ""
            collected["currentVarLabel"] = varLabel
            collected["currentVarDefault"] = varDefault
            return "Title: **\(input)**\n\nNow let's fill in the template variables.\n\n\(currentPrompt)"
        default:
            // Collecting variable values
            let varIndex = Int(collected["currentVarIndex"] ?? "0") ?? 0
            let varName = collected["var_\(varIndex)_name"] ?? ""
            let varDefault = collected["var_\(varIndex)_default"] ?? ""
            let value = input.trimmingCharacters(in: .whitespaces).isEmpty ? varDefault : input
            collected["varValue_\(varName)"] = value

            let varCount = Int(collected["varCount"] ?? "0") ?? 0
            let nextIndex = varIndex + 1

            if nextIndex >= varCount {
                collected["templateDone"] = "true"
                return nil
            }

            // Set up next variable
            collected["currentVarIndex"] = "\(nextIndex)"
            let nextName = collected["var_\(nextIndex)_name"] ?? ""
            let nextLabel = collected["var_\(nextIndex)_label"] ?? nextName
            let nextDefault = collected["var_\(nextIndex)_default"] ?? ""
            collected["currentVarLabel"] = nextLabel
            collected["currentVarDefault"] = nextDefault
            step = nextIndex + 2
            return "Set `\(varName)` = `\(value)`\n\n\(currentPrompt)"
        }
    }
}

/// Shown when no task is selected — conversational task creation
struct ChatPanelView: View {
    private static let jsonBlockRegex = try? NSRegularExpression(pattern: "```json\\s*\\n([\\s\\S]*?)\\n\\s*```")
    static let newTaskPrompts = [
        "What should we get done?",
        "Where should we start?",
        "What’s the next move?",
        "What problem are we solving?",
        "What should we prototype?",
        "What’s worth solving next?",
        "What idea should we test?",
        "What should we make real?",
        "Start with a question, goal, or problem.",
    ]

    var taskQueue: TaskQueue?
    var workspace: Workspace?
    var sshReloadTrigger: Int = 0
    var draftToLoad: AgentTask?
    var onQuickRun: ((AgentTask) -> Void)?
    var onTaskCreated: ((AgentTask) -> Void)?
    var onAddSSHConnection: (() -> Void)?
    var onManageSkills: (() -> Void)?
    var isPlanCanvasVisible = false
    var onOpenPlan: ((AgentTask) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var isThinking = false
    @State private var extractedSpec: TaskSpec?
    @State private var showSpecCard = false
    @State private var attachedFiles: [String] = []
    @State private var pasteMonitor: Any?
    @State private var isDragOver = false
    @State private var sshConnections: [SSHConnection] = []
    @AppStorage("defaultModel") private var defaultModel = "claude-sonnet-4-6"
    @AppStorage("defaultRuntimeID") private var defaultRuntimeID = AgentRuntimeID.claudeCode.rawValue
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("copilotPath") private var copilotPath = ""
    @AppStorage("defaultTokenBudget") private var defaultBudget = 50000
    @AppStorage(AppStorageKeys.skipPermissions) private var skipPermissions = false
    @State private var chainedGoal = ""
    @State private var draftTask: AgentTask?
    @State private var useAgentTeam = false
    @State private var teamSize = 3
    @State private var activeWizard: SlashWizard?
    @State private var slashSelectedIndex: Int = 0
    @State private var activeSlashContext: String?
    @State private var isPlanMode = false
    @State private var pendingPlan: TaskPlanPayload?
    @State private var isApprovedPlanHistoryExpanded = false
    @State private var excludedSkillIDs: Set<UUID> = []
    // Random per session; a live-cycling prompt mutated while the user was reading it.
    @State private var newTaskPromptIndex = Int.random(in: 0..<ChatPanelView.newTaskPrompts.count)
    @FocusState private var isComposerFocused: Bool

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    private var availableSkills: [Skill] {
        guard let workspace else { return [] }
        return WorkspaceCapabilities(workspace: workspace, globalSkills: globalSkills).activeSkills
    }

    private var selectedSkills: [Skill] {
        availableSkills.filter { !excludedSkillIDs.contains($0.id) }
    }

    private var hasInput: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var planningUtilityRuntime: AgentUtilityRuntimeConfiguration {
        let runtime = AgentRuntimeID(rawValue: defaultRuntimeID) ?? .claudeCode
        let model = runtime.defaultModels.contains(defaultModel) ? defaultModel : runtime.defaultModel
        return AgentUtilityRuntimeConfiguration(
            runtime: runtime,
            model: model,
            claudePath: claudePath,
            copilotPath: copilotPath,
            copilotHome: CopilotCLIRuntime.channelHome()
        )
    }

    private var showSlashMenu: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") && activeWizard == nil && !trimmed.contains(" ") && trimmed.count < 14
    }

    private var isSlashCommandInput: Bool {
        let lower = messageText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["/skill", "/tool", "/connector", "/template", "/routine", "/schedule", "/remember", "/recap"].contains { command in
            lower == command || lower.hasPrefix(command + " ")
        }
    }

    private struct SlashOption: Identifiable {
        let id: String
        let command: String
        let icon: String
        let color: Color
        let title: String
        let description: String
    }

    private var slashOptions: [SlashOption] {
        let all: [SlashOption] = [
            SlashOption(id: "skill", command: "/skill", icon: "puzzlepiece.extension", color: Stanford.lagunita,
                       title: "Create Skill", description: "Define agent behavior, allowed tools, and instructions"),
            SlashOption(id: "tool", command: "/tool", icon: "wrench.and.screwdriver", color: Stanford.plum,
                       title: "Create Tool", description: "Add a CLI command, script, or MCP tool"),
            SlashOption(id: "connector", command: "/connector", icon: "bolt.horizontal.circle", color: Stanford.paloAltoGreen,
                       title: "Create Connector", description: "Set up auth for Jira, GitHub, Slack, or APIs"),
            SlashOption(id: "template", command: "/template", icon: "rectangle.3.group", color: Stanford.poppy,
                       title: "Use Template", description: "Create a multi-phase task from a template"),
            SlashOption(id: "schedule", command: "/routine", icon: "arrow.triangle.2.circlepath", color: Stanford.poppy,
                       title: "Create Routine", description: "Automate recurring work with instructions and capabilities"),
            SlashOption(id: "remember", command: "/remember", icon: "brain", color: Stanford.plum,
                       title: "Add Memory", description: "Save a fact for the agent to remember in this workspace"),
            SlashOption(id: "recap", command: "/recap", icon: "doc.text", color: Stanford.paloAltoGreen,
                       title: "Recap Task", description: "Summarize this conversation so you can pause and resume later"),
        ]
        let filter = messageText.trimmingCharacters(in: .whitespaces).lowercased()
        if filter == "/" { return all }
        return all.filter { $0.command.hasPrefix(filter) }
    }

    private var hasConversation: Bool {
        !messages.isEmpty
    }

    private var pendingPlanInsertionMessageID: UUID? {
        guard pendingPlan != nil else { return nil }
        return messages.last(where: { $0.role == "assistant" })?.id
    }

    private var approvedDraftPlan: TaskPlanPayload? {
        guard let draftTask,
              draftTask.status == .draft else { return nil }
        let state = TaskPlanService.reconstruct(for: draftTask)
        guard state.lifecycleStatus == .approved else { return nil }
        return state.plan
    }

    private var newTaskPrompt: String {
        Self.newTaskPrompts[newTaskPromptIndex % Self.newTaskPrompts.count]
    }

    private var isPlanModeActive: Bool {
        hasConversation || isPlanMode || isSlashCommandInput
    }

    private var submitButtonTitle: String {
        if isPlanModeActive {
            return hasConversation ? "Send" : "Plan"
        }
        return "Run"
    }

    private var submitButtonIcon: String {
        isPlanModeActive ? "arrow.up" : "bolt.fill"
    }

    private var submitButtonColor: Color {
        isPlanModeActive ? Stanford.cardinalRed : Stanford.lagunita
    }

    private var resolvedWorkspace: String {
        workspace?.primaryPath ?? FileManager.default.currentDirectoryPath
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chat area — hero centered when empty, scrollable when has messages
            if messages.isEmpty && !isThinking && !showSpecCard && pendingPlan == nil && approvedDraftPlan == nil {
                heroView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            if let approvedPlan = approvedDraftPlan,
                               pendingPlan == nil {
                                ApprovedPlanReadyCard(
                                    plan: approvedPlan,
                                    isHistoryExpanded: $isApprovedPlanHistoryExpanded,
                                    isPlanCanvasVisible: isPlanCanvasVisible,
                                    onOpenPlan: {
                                        if let draftTask {
                                            onOpenPlan?(draftTask)
                                        }
                                    }
                                )
                                .padding(.horizontal)
                                .id("approved-plan-card")

                                if isApprovedPlanHistoryExpanded {
                                    conversationMessages
                                }
                            } else {
                                conversationMessages
                            }

                            if isThinking {
                                thinkingIndicator
                            }

                            if showSpecCard {
                                SpecCardView(
                                    spec: $extractedSpec,
                                    chainedGoal: $chainedGoal,
                                    onCreateTask: createTaskFromSpec,
                                    onDismiss: { showSpecCard = false; extractedSpec = nil; chainedGoal = "" }
                                )
                                .padding(.horizontal)
                                .id("spec-card")
                            }
                        }
                        .frame(maxWidth: 780)
                        .padding()
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: messages.count) {
                        if approvedDraftPlan != nil,
                           pendingPlan == nil,
                           !isApprovedPlanHistoryExpanded {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("approved-plan-card", anchor: .bottom)
                            }
                        } else if let last = messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: showSpecCard) {
                        if showSpecCard {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("spec-card", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: pendingPlan?.planID) {
                        if pendingPlan != nil {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("pending-plan-card", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: approvedDraftPlan?.planID) {
                        if approvedDraftPlan != nil {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("approved-plan-card", anchor: .bottom)
                            }
                        }
                    }
                }
            }

            // Action bar (when conversation has content)
            if (hasConversation || approvedDraftPlan != nil) && !showSpecCard {
                actionBar
            }

            // Composer
            composerView
        }
        .navigationTitle(draftTask != nil ? "Draft" : "New Task")
        .navigationSubtitle(workspace?.name ?? "Astra")
        .onAppear {
            loadSSHConnections()
            focusComposerInput()
            if let draft = draftToLoad {
                loadDraftMessages(draft)
            }
            installPasteMonitor()
        }
        .onDisappear {
            removePasteMonitor()
        }
        .onChange(of: sshReloadTrigger) { loadSSHConnections() }
    }

    // MARK: - Hero (empty state)

    private var heroView: some View {
        VStack(spacing: 24) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(Stanford.ui(56))
                .foregroundStyle(Stanford.cardinalRed)

            Text(newTaskPrompt)
                .font(Stanford.heading(28))
                .foregroundStyle(Stanford.black)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .lineLimit(2)
                .frame(maxWidth: 720, minHeight: 84)

            if let ws = workspace {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(Stanford.ui(12))
                        .foregroundStyle(Stanford.lagunita)
                    Text(ws.name)
                        .font(Stanford.body(14).weight(.medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Stanford.lagunita.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 28) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(Stanford.ui(13))
                    Text("Enter to run immediately")
                        .font(Stanford.body(15))
                }
                .foregroundStyle(Stanford.lagunita)

                HStack(spacing: 5) {
                    Image(systemName: "switch.2")
                        .font(Stanford.ui(13))
                    Text("Enable Plan mode to refine first")
                        .font(Stanford.body(15))
                }
                .foregroundStyle(Color.primary.opacity(0.65))
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message Bubbles

    @ViewBuilder
    private var conversationMessages: some View {
        ForEach(messages) { msg in
            if let pendingPlan,
               msg.id == pendingPlanInsertionMessageID {
                DraftPlanPreviewCard(plan: pendingPlan)
                    .padding(.horizontal)
                    .id("pending-plan-card")
            }

            messageBubble(msg)
                .id(msg.id)
        }
    }

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        if msg.role == "user" {
            // User bubble — right-aligned, subtle fill
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(msg.content)
                        .font(Stanford.ui(15))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Stanford.cardinalRed.opacity(0.08))
                        .foregroundStyle(Stanford.black)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: 16,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 16
                        ))
                        .overlay(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 16,
                                bottomLeadingRadius: 16,
                                bottomTrailingRadius: 4,
                                topTrailingRadius: 16
                            )
                            .stroke(Stanford.cardinalRed.opacity(0.15), lineWidth: 1)
                        )

                    Text(msg.timestamp, style: .time)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 4)
                }
                .contextMenu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(msg.content, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        messageText = msg.content
                    } label: {
                        Label("Reuse in Composer", systemImage: "arrow.uturn.up")
                    }
                }
            }
        } else {
            // AI response — flows directly on background, no card
            VStack(alignment: .leading, spacing: 6) {
                Text(markdownAttributed(msg.content))
                    .font(Stanford.ui(15))
                    .foregroundStyle(Stanford.black)
                    .textSelection(.enabled)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Action icons + timestamp
                HStack(spacing: 14) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(msg.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(Stanford.ui(13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Stanford.coolGrey)
                    .help("Copy")

                    Button {
                        messageText = msg.content
                    } label: {
                        Image(systemName: "arrow.uturn.up")
                            .font(Stanford.ui(13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Stanford.coolGrey)
                    .help("Reuse in Composer")

                    Spacer()

                    Text(msg.timestamp, style: .time)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                }
            }
            .contextMenu {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(msg.content, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var thinkingIndicator: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking...")
                    .font(Stanford.caption(14))
                    .foregroundStyle(Stanford.coolGrey)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Stanford.fog)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 60)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing your message")
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                if let approvedPlan = approvedDraftPlan {
                    runApprovedPlan(approvedPlan)
                } else if pendingPlan != nil {
                    approvePendingPlan()
                } else {
                    generatePlanFromConversation()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: actionBarPrimaryIcon)
                        .font(Stanford.ui(14))
                    Text(actionBarPrimaryTitle)
                        .font(Stanford.body(15))
                        .fontWeight(.medium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Stanford.cardinalRed)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isThinking)

            if pendingPlan != nil && approvedDraftPlan == nil {
                Button {
                    generatePlanFromConversation()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(Stanford.ui(13))
                        Text("Regenerate")
                            .font(Stanford.caption(14))
                    }
                    .foregroundStyle(Stanford.coolGrey)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(isThinking)
            }

            Button {
                if let draft = draftTask {
                    modelContext.delete(draft)
                    draftTask = nil
                }
                messages = []
                extractedSpec = nil
                showSpecCard = false
                pendingPlan = nil
                isApprovedPlanHistoryExpanded = false
                activeSlashContext = nil
                isPlanMode = false
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(Stanford.ui(13))
                    Text("Start Over")
                        .font(Stanford.caption(14))
                }
                .foregroundStyle(Stanford.coolGrey)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Stanford.fog.opacity(0.5))
    }

    private var actionBarPrimaryTitle: String {
        if approvedDraftPlan != nil {
            return skipPermissions ? "Run Full Plan" : "Approve Next Step"
        }
        if pendingPlan != nil {
            return "Approve Plan"
        }
        return "Generate Plan"
    }

    private var actionBarPrimaryIcon: String {
        if approvedDraftPlan != nil {
            return skipPermissions ? "play.fill" : "checkmark.circle.fill"
        }
        if pendingPlan != nil {
            return "checkmark.circle.fill"
        }
        return "sparkles"
    }

    // MARK: - Composer

    private var composerView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !attachedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachedFiles, id: \.self) { file in
                                fileChip(file)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                    }
                }

                TextField("Describe a task or ask a question...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Stanford.ui(17))
                    .lineLimit(3...12)
                    .focused($isComposerFocused)
                    .padding(.horizontal, 18)
                    .padding(.top, attachedFiles.isEmpty ? 18 : 10)
                    .padding(.bottom, 14)
                    .onSubmit {
                        submitComposer()
                    }
                    .accessibilityIdentifier("ComposerInput")
                    .onChange(of: messageText) {
                        // Reset selection when filter changes
                        slashSelectedIndex = 0
                    }
                    .onKeyPress(.upArrow) {
                        guard showSlashMenu && !slashOptions.isEmpty else { return .ignored }
                        slashSelectedIndex = (slashSelectedIndex - 1 + slashOptions.count) % slashOptions.count
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard showSlashMenu && !slashOptions.isEmpty else { return .ignored }
                        slashSelectedIndex = (slashSelectedIndex + 1) % slashOptions.count
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard showSlashMenu else { return .ignored }
                        messageText = ""
                        return .handled
                    }

                Color.clear
                    .frame(height: 2)

                ComposerToolbar(
                    model: defaultModel,
                    runtimeID: defaultRuntimeID,
                    budget: defaultBudget,
                    skills: selectedSkills,
                    availableSkills: availableSkills,
                    workspace: workspace,
                    isRunning: isThinking,
                    hasInput: hasInput,
                    onAttachFile: { attachFile() },
                    onPasteClipboard: { smartPaste() },
                    onSend: { submitComposer() },
                    onModelChange: { defaultModel = $0 },
                    onRuntimeChange: { runtime in
                        defaultRuntimeID = runtime
                        let resolved = AgentRuntimeID(rawValue: runtime) ?? .claudeCode
                        if !resolved.defaultModels.contains(defaultModel) {
                            defaultModel = resolved.defaultModel
                        }
                    },
                    onBudgetChange: { defaultBudget = $0 },
                    onRemoveSkill: { skill in excludedSkillIDs.insert(skill.id) },
                    onToggleSkill: { skill, enable in
                        if enable {
                            excludedSkillIDs.remove(skill.id)
                        } else {
                            excludedSkillIDs.insert(skill.id)
                        }
                    },
                    onManageSkills: onManageSkills,
                    skipPermissions: $skipPermissions,
                    useAgentTeam: $useAgentTeam,
                    teamSize: $teamSize,
                    isPlanMode: $isPlanMode,
                    isPlanModeDisabled: hasConversation || isSlashCommandInput,
                    planModeHelp: hasConversation ? "Already in Plan mode. Use Start Over to leave planning." : "Plan and refine before creating a runnable task",
                    submitIcon: submitButtonIcon,
                    submitTitle: submitButtonTitle,
                    submitColor: submitButtonColor,
                    showSecurityGate: true,
                    showPermissionControls: true,
                    sshConnections: sshConnections
                )
            }
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isDragOver ? Stanford.cardinalRed : Stanford.sandstone.opacity(0.3), lineWidth: isDragOver ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .overlay(alignment: .topLeading) {
                if showSlashMenu && !slashOptions.isEmpty {
                    slashMenuView
                        .offset(x: 4, y: -slashMenuHeight - 8)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url {
                            DispatchQueue.main.async {
                                if !attachedFiles.contains(url.path) {
                                    attachedFiles.append(url.path)
                                }
                            }
                        }
                    }
                }
                return true
            }
        }
    }

    // MARK: - Actions

    private func focusComposerInput() {
        DispatchQueue.main.async {
            isComposerFocused = true
        }
    }

    private func submitComposer() {
        if showSlashMenu && !slashOptions.isEmpty {
            selectSlashOption(slashOptions[slashSelectedIndex])
        } else if isPlanModeActive {
            sendMessage()
        } else {
            quickRun()
        }
    }


    /// Send message → start or continue the provider-assisted conversation
    private func sendMessage() {
        let input = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        isPlanMode = true

        // Check for slash commands — route through the provider conversation with context
        let lower = input.lowercased()

        // /remember — direct action, no provider call needed
        if lower == "/remember" || lower.hasPrefix("/remember ") {
            let memoryText = String(input.dropFirst("/remember".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: "user", content: input))
            messageText = ""
            if memoryText.isEmpty {
                messages.append(ChatMessage(role: "assistant", content: "Usage: `/remember <fact>` — saves a memory to this workspace.\n\nExample: `/remember This project uses Python 3.11 and Poetry for dependency management`"))
            } else if let ws = workspace {
                ws.memories.append(memoryText)
                ws.updatedAt = Date()
                messages.append(ChatMessage(role: "assistant", content: "Saved to workspace memories:\n\n> \(memoryText)\n\nThis will be included in all future task prompts for **\(ws.name)**."))
            } else {
                messages.append(ChatMessage(role: "assistant", content: "No workspace selected — memories are workspace-scoped."))
            }
            saveDraft()
            return
        }

        if let slashType = (["/skill", "/tool", "/connector", "/template", "/routine", "/schedule"] as [String])
            .first(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {

            // Build context for the slash command
            let slashContext = buildSlashContext(for: slashType)
            if let slashContext {
                activeSlashContext = slashContext
            }

            // For /template with no templates, bail early
            if slashType == "/template" && (workspace?.templates ?? []).isEmpty {
                messages.append(ChatMessage(role: "user", content: input))
                messageText = ""
                messages.append(ChatMessage(role: "assistant", content: "No templates available in this workspace yet. Create one in **Configure > Templates** first."))
                return
            }

            // Fall through to the normal provider conversation — the slash context
            // will be injected into the system prompt
        }

        // /recap — one-shot prose summary for resuming later. Injected into skillCtx
        // for this message only; does not use activeSlashContext (no ongoing wizard).
        let recapContext: String? = (lower == "/recap" || lower.hasPrefix("/recap "))
            ? buildRecapContext()
            : nil

        messages.append(ChatMessage(role: "user", content: input))
        messageText = ""
        let planningDraft = saveDraft()
        isThinking = true

        let conversationHistory = messages.map { (role: $0.role, content: $0.content) }
        let ws = resolvedWorkspace
        var skillCtx = selectedSkills.map { skill in
            var desc = "## Skill: \(skill.name)\nInstructions:\n\(skill.behaviorInstructions)"
            if !skill.connectors.isEmpty {
                desc += "\nConnectors: \(skill.connectorSummary)"
            }
            if !skill.localTools.isEmpty {
                desc += "\nLocal Tools: \(skill.localToolSummary)"
            }
            if !skill.environmentKeys.isEmpty {
                desc += "\nEnvironment Variables: \(skill.environmentKeys.joined(separator: ", "))"
            }
            if !skill.customTools.isEmpty {
                desc += "\nCustom Tools: \(skill.customTools.joined(separator: ", "))"
            }
            return desc
        }.joined(separator: "\n\n")

        // Include workspace additional paths so the provider has them as context
        if let wsObj = workspace, !wsObj.additionalPaths.isEmpty {
            let pathList = wsObj.additionalPaths.map { path -> String in
                let name = (path as NSString).lastPathComponent
                return "- \(name): \(path)"
            }.joined(separator: "\n")
            skillCtx += (skillCtx.isEmpty ? "" : "\n\n") + "Additional workspace folders (configured by user):\n\(pathList)\n\nThese folders are part of this workspace. When the user refers to any of these folder names, they mean these paths. You can browse and read files in them."
        }

        // Include attached file/folder paths so the provider has them as context
        if !attachedFiles.isEmpty {
            let fileList = attachedFiles.map { "- \($0)" }.joined(separator: "\n")
            skillCtx += (skillCtx.isEmpty ? "" : "\n\n") + "Attached files/folders (dragged by user):\n\(fileList)\n\nThe user has attached these paths. When they refer to \"this folder\" or \"this file\", they mean these paths."
        }

        // Inject slash command context if active
        if let slashCtx = activeSlashContext {
            skillCtx += (skillCtx.isEmpty ? "" : "\n\n") + "SLASH COMMAND CONTEXT:\n" + slashCtx
        }

        // Inject /recap instructions for this message only
        if let recapCtx = recapContext {
            skillCtx += (skillCtx.isEmpty ? "" : "\n\n") + "RECAP COMMAND:\n" + recapCtx
        }

        if activeSlashContext == nil, recapContext == nil {
            skillCtx += (skillCtx.isEmpty ? "" : "\n\n") + newTaskPlanInstructions()
        }

        Task {
            let result = await SpecEngine.chat(
                messages: conversationHistory,
                workspacePath: ws,
                skillContext: skillCtx,
                utilityRuntime: planningUtilityRuntime
            )
            await MainActor.run {
                isThinking = false
                switch result {
                case .success(let response):
                    let visibleResponse = activeSlashContext == nil && recapContext == nil
                        ? TaskPlanService.userVisiblePlanningText(from: response)
                        : response
                    messages.append(ChatMessage(role: "assistant", content: visibleResponse))
                    if activeSlashContext == nil,
                       recapContext == nil,
                       let draft = planningDraft ?? draftTask {
                        preparePendingPlan(from: response, fallbackGoal: input, on: draft)
                    }
                    handleSlashAction(in: response)
                case .failure(let error):
                    messages.append(ChatMessage(role: "assistant", content: "Sorry, I encountered an error: \(error.localizedDescription)"))
                }
                saveDraft()
            }
        }
    }

    /// Quick run: create task directly from input text and run immediately
    private func quickRun() {
        let input = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let task = AgentTask(
            title: String(input.prefix(60)),
            goal: input,
            workspace: workspace,
            tokenBudget: defaultBudget,
            model: defaultModel
        )
        task.runtimeID = defaultRuntimeID
        task.status = .queued
        task.inputs = attachedFiles
        task.skills = selectedSkills
        task.captureSkillSnapshots()
        task.useAgentTeam = useAgentTeam
        task.teamSize = teamSize

        modelContext.insert(task)
        saveConversationAsEvents(on: task)
        promoteDraft(to: task)
        messageText = ""
        messages = []
        attachedFiles = []
        pendingPlan = nil
        isApprovedPlanHistoryExpanded = false
        isPlanMode = false
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.taskCreated, category: "UI", taskID: task.id, fields: [
            "source": "quick_run",
            "use_agent_team": String(useAgentTeam),
            "team_size": String(teamSize)
        ])

        onQuickRun?(task)
    }

    /// Generate a concrete plan candidate from the full planning conversation.
    private func generatePlanFromConversation() {
        guard !messages.isEmpty else { return }

        isThinking = true
        let conversationHistory = messages.map { (role: $0.role, content: $0.content) } + [
            (
                role: "user",
                content: "Generate the final execution plan now. Include exactly one ASTRA_PLAN structured plan line first for ASTRA to parse. After that, add any short clarification questions or assumptions the user may want to refine before approval."
            )
        ]
        let ws = resolvedWorkspace

        Task {
            let result = await SpecEngine.chat(
                messages: conversationHistory,
                workspacePath: ws,
                skillContext: newTaskPlanInstructions(),
                utilityRuntime: planningUtilityRuntime
            )
            await MainActor.run {
                isThinking = false
                switch result {
                case .success(let response):
                    messages.append(ChatMessage(role: "assistant", content: TaskPlanService.userVisiblePlanningText(from: response)))
                    if let draft = draftTask ?? saveDraft() {
                        preparePendingPlan(from: response, fallbackGoal: draft.goal, on: draft, allowFallback: true)
                    }
                case .failure(let error):
                    messages.append(ChatMessage(role: "assistant", content: "Failed to generate a plan: \(error.localizedDescription). Try describing the task differently."))
                }
                saveDraft()
            }
        }
    }

    private func approvePendingPlan() {
        guard var plan = pendingPlan else { return }
        guard let task = draftTask ?? saveDraft() else { return }

        if let existingPlan = TaskPlanService.reconstruct(for: task).plan {
            plan.planID = existingPlan.planID
        }

        recordPlanConversationEvents(on: task)
        TaskPlanService.recordCreated(plan, task: task, modelContext: modelContext)
        TaskPlanService.recordApproved(plan, task: task, modelContext: modelContext)
        task.title = plan.title
        task.goal = plan.goal.isEmpty ? task.goal : plan.goal
        task.status = .draft
        task.updatedAt = Date()
        pendingPlan = nil
        isApprovedPlanHistoryExpanded = false
        isPlanMode = false
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        onTaskCreated?(task)
    }

    private func runApprovedPlan(_ plan: TaskPlanPayload) {
        guard let task = draftTask,
              task.status != .running else { return }

        TaskPlanService.recordApproved(plan, task: task, modelContext: modelContext)
        task.title = plan.title
        task.goal = plan.goal.isEmpty ? plan.title : plan.goal
        task.status = .queued
        task.completedAt = nil
        task.updatedAt = Date()
        pendingPlan = nil
        isApprovedPlanHistoryExpanded = false
        isPlanMode = false
        try? modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        onTaskCreated?(task)

        Task {
            let mode: TaskPlanExecutionMode = skipPermissions ? .fullPlan : .nextStep
            await taskQueue?.executeApprovedPlan(task: task, plan: plan, mode: mode, modelContext: modelContext) { _ in }
            await MainActor.run {
                _ = WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
            }
        }
    }

    /// Create task from extracted spec
    private func createTaskFromSpec() {
        guard let spec = extractedSpec else { return }

        let task = AgentTask(
            title: spec.title,
            goal: spec.goal,
            workspace: workspace,
            tokenBudget: defaultBudget,
            model: defaultModel
        )
        task.runtimeID = defaultRuntimeID
        task.status = .queued
        task.inputs = spec.inputs + attachedFiles
        task.constraints = spec.constraints
        task.acceptanceCriteria = spec.acceptanceCriteria
        task.skills = selectedSkills
        task.captureSkillSnapshots()
        task.chainedGoal = chainedGoal
        task.useAgentTeam = useAgentTeam
        task.teamSize = teamSize

        modelContext.insert(task)

        // Persist conversation history as events so it survives draft→queued→draft transitions
        saveConversationAsEvents(on: task)

        promoteDraft(to: task)

        // Reset state
        messageText = ""
        messages = []
        extractedSpec = nil
        showSpecCard = false
        pendingPlan = nil
        isApprovedPlanHistoryExpanded = false
        attachedFiles = []
        chainedGoal = ""
        isPlanMode = false
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.taskCreated, category: "UI", taskID: task.id, fields: [
            "source": "conversation_spec",
            "inputs_count": String(task.inputs.count),
            "criteria_count": String(task.acceptanceCriteria.count)
        ])

        onTaskCreated?(task)
    }

    // MARK: - Slash Menu

    private var slashMenuHeight: CGFloat {
        CGFloat(slashOptions.count) * 52
    }

    private var slashMenuView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(slashOptions.enumerated()), id: \.element.id) { idx, option in
                Button {
                    selectSlashOption(option)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: option.icon)
                            .font(Stanford.ui(16))
                            .foregroundStyle(option.color)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(option.command)
                                    .font(Stanford.ui(15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Stanford.black)
                                Text(option.title)
                                    .font(Stanford.body(14))
                                    .foregroundStyle(Stanford.coolGrey)
                            }
                            Text(option.description)
                                .font(Stanford.caption(13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if idx == slashSelectedIndex {
                            Image(systemName: "return")
                                .font(Stanford.ui(11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(idx == slashSelectedIndex ? Stanford.lagunita.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { slashSelectedIndex = idx }
                }

                if idx < slashOptions.count - 1 {
                    Divider().padding(.leading, 48)
                }
            }
        }
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
        .frame(maxWidth: 420)
        .padding(.leading, 4)
    }

    private func selectSlashOption(_ option: SlashOption) {
        messageText = option.command
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sendMessage()
        }
    }

    // MARK: - Slash Command Wizard Finalization

    private func finalizeWizard(_ wizard: SlashWizard) {
        guard let ws = workspace else {
            messages.append(ChatMessage(role: "assistant", content: "No workspace selected. Please select a workspace first."))
            return
        }

        switch wizard.type {
        case .skill:
            let name = wizard.collected["name"] ?? "New Skill"
            let behavior = wizard.collected["behavior"] ?? ""
            let allowedRaw = wizard.collected["allowed"] ?? ""
            let blockedRaw = wizard.collected["blocked"] ?? ""

            let allowed = allowedRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let blocked = blockedRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

            let skill = WorkspaceCommandService.createSkill(
                name: name,
                behaviorInstructions: behavior,
                allowedTools: allowed,
                disallowedTools: blocked,
                workspace: ws,
                modelContext: modelContext,
                source: "wizard"
            )

            messages.append(ChatMessage(role: "assistant", content: "Skill **\(name)** created with \(skill.allowedTools.count) allowed tools.\n\nYou can further customize it in **Configure > Skills**."))

        case .tool:
            let name = wizard.collected["name"] ?? "New Tool"
            let toolType = wizard.collected["type"] ?? "cli"
            let command = wizard.collected["command"] ?? ""
            let desc = wizard.collected["description"] ?? ""

            WorkspaceCommandService.createTool(
                name: name,
                toolType: toolType,
                command: command,
                description: desc,
                workspace: ws,
                modelContext: modelContext,
                source: "wizard"
            )

            let typeLabel = toolType == "cli" ? "CLI Command" : toolType == "script" ? "Script File" : "MCP Tool"
            messages.append(ChatMessage(role: "assistant", content: "Tool **\(name)** (\(typeLabel)) created.\nCommand: `\(command)`\n\nYou can edit it in **Configure > Tools** and attach it to skills."))

        case .connector:
            let name = wizard.collected["name"] ?? "New Connector"
            let serviceType = wizard.collected["serviceType"] ?? "custom"
            let baseURL = wizard.collected["baseURL"] ?? ""
            let authMethod = wizard.collected["authMethod"] ?? "none"

            // Add credentials to Keychain
            let credKeys = (wizard.collected["credKeys"] ?? "").split(separator: ",").map(String.init)
            let credVals = (wizard.collected["credVals"] ?? "").split(separator: ",").map(String.init)
            let credentials = zip(credKeys, credVals).reduce(into: [String: String]()) { result, pair in
                result[pair.0] = pair.1
            }
            WorkspaceCommandService.createConnector(
                name: name,
                serviceType: serviceType,
                baseURL: baseURL,
                authMethod: authMethod,
                credentials: credentials,
                workspace: ws,
                modelContext: modelContext,
                source: "wizard"
            )

            let credCount = credKeys.count
            messages.append(ChatMessage(role: "assistant", content: "Connector **\(name)** (\(serviceType.replacingOccurrences(of: "_", with: " ").capitalized)) created.\nBase URL: `\(baseURL)`\nAuth: \(authMethod.replacingOccurrences(of: "_", with: " "))\nCredentials: \(credCount)\n\nYou can edit it in **Configure > Connectors** and attach it to skills."))

        case .template:
            guard let templateIDStr = wizard.collected["selectedTemplateID"],
                  let templateUUID = UUID(uuidString: templateIDStr),
                  let tmpl = ws.templates.first(where: { $0.id == templateUUID }) else {
                messages.append(ChatMessage(role: "assistant", content: "Template not found."))
                return
            }

            let taskTitle = wizard.collected["taskTitle"] ?? tmpl.name

            // Collect variable values
            var values: [String: String] = [:]
            let varCount = Int(wizard.collected["varCount"] ?? "0") ?? 0
            for i in 0..<varCount {
                let name = wizard.collected["var_\(i)_name"] ?? ""
                let value = wizard.collected["varValue_\(name)"] ?? wizard.collected["var_\(i)_default"] ?? ""
                values[name] = value
            }

            let mainGoal = tmpl.resolveGoal(tmpl.mainGoal, with: values)
            let creation = WorkspaceCommandService.createTemplateTasks(
                template: tmpl,
                taskTitle: taskTitle,
                variables: values,
                selectedSkills: selectedSkills,
                defaultModel: defaultModel,
                defaultRuntimeID: defaultRuntimeID,
                workspace: ws,
                modelContext: modelContext,
                source: "wizard_template"
            )

            // Build summary
            var summary = "Template task created:\n\n"
            if tmpl.hasBeforePhase {
                summary += "1. **Before**: \(tmpl.resolveGoal(tmpl.beforeGoal, with: values).prefix(80))...\n"
                summary += "2. **Main**: \(mainGoal.prefix(80))...\n"
            } else {
                summary += "**Main**: \(mainGoal.prefix(80))...\n"
            }
            if tmpl.hasAfterPhase {
                summary += "\(tmpl.hasBeforePhase ? "3" : "2"). **After**: \(tmpl.resolveGoal(tmpl.afterGoal, with: values).prefix(80))...\n"
            }

            if !values.isEmpty {
                summary += "\nVariables: " + values.map { "`\($0.key)` = `\($0.value)`" }.joined(separator: ", ")
            }

            summary += "\n\nThe task is queued and ready to run."
            messages.append(ChatMessage(role: "assistant", content: summary))

            onTaskCreated?(creation.mainTask)

        case .schedule:
            break // Routine uses provider-assisted conversation, not wizard steps
        case .recap:
            break // Recap is one-shot, bypasses the wizard
        }
    }

    // MARK: - Helpers

    private func fileChip(_ file: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: Formatters.fileIcon(for: file))
                .font(Stanford.ui(11))
                .foregroundStyle(Stanford.lagunita)
            Text(URL(fileURLWithPath: file).lastPathComponent)
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.black)
                .lineLimit(1)
            Button {
                attachedFiles.removeAll { $0 == file }
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .bold))
                    .foregroundStyle(Stanford.coolGrey)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Stanford.fog)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Stanford.sandstone.opacity(0.4), lineWidth: 0.5))
    }

    @discardableResult
    private func smartPaste() -> Bool {
        let pb = NSPasteboard.general
        let types = pb.types ?? []

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls where !attachedFiles.contains(url.path) {
                attachedFiles.append(url.path)
            }
            return true
        }

        if types.contains(.png) || types.contains(.tiff) {
            if let image = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let first = image.first {
                if let tiff = first.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    let tempPath = NSTemporaryDirectory() + "astra_paste_\(UUID().uuidString.prefix(8)).png"
                    try? png.write(to: URL(fileURLWithPath: tempPath))
                    attachedFiles.append(tempPath)
                    return true
                }
            }
        }

        if let text = pb.string(forType: .string), !text.isEmpty {
            let lineCount = text.components(separatedBy: .newlines).count
            if lineCount > 10 || text.count > 500 {
                let ext = text.hasPrefix("{") || text.hasPrefix("[") ? "json" : "txt"
                let tempPath = NSTemporaryDirectory() + "astra_paste_\(UUID().uuidString.prefix(8)).\(ext)"
                try? text.write(toFile: tempPath, atomically: true, encoding: .utf8)
                attachedFiles.append(tempPath)
                return true
            }
            return false
        }

        return false
    }

    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "v" {
                if smartPaste() { return nil }
            }
            return event
        }
    }

    private func removePasteMonitor() {
        if let monitor = pasteMonitor {
            NSEvent.removeMonitor(monitor)
            pasteMonitor = nil
        }
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Select files to attach as context"
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !attachedFiles.contains(url.path) {
                    attachedFiles.append(url.path)
                }
            }
        }
    }

    private func addAdditionalPath() {
        guard let ws = workspace else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.message = "Select additional folders for \"\(ws.name)\""
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !ws.additionalPaths.contains(url.path) {
                    ws.additionalPaths.append(url.path)
                }
            }
            ws.updatedAt = Date()
        }
    }

    private func loadSSHConnections() {
        guard let ws = workspace, !ws.primaryPath.isEmpty else {
            sshConnections = []
            return
        }
        sshConnections = SSHConnectionManager.load(workspacePath: ws.primaryPath)
    }

    private func removeSSHConnection(_ conn: SSHConnection) {
        guard let ws = workspace else { return }
        sshConnections.removeAll { $0.id == conn.id }
        SSHConnectionManager.save(sshConnections, workspacePath: ws.primaryPath)
    }

    private func sshStatusColor(_ conn: SSHConnection) -> Color {
        guard let result = conn.lastTestResult else { return Stanford.coolGrey }
        return result ? Stanford.paloAltoGreen : Stanford.cardinalRed
    }

    private func sshPillForeground(_ conn: SSHConnection) -> Color {
        guard let result = conn.lastTestResult else {
            return Stanford.coolGrey.opacity(0.8)
        }
        return result ? Stanford.paloAltoGreen.opacity(0.8) : Stanford.cardinalRed.opacity(0.8)
    }

    private func sshPillBackground(_ conn: SSHConnection) -> Color {
        guard let result = conn.lastTestResult else {
            return Stanford.fog
        }
        return result ? Stanford.paloAltoGreen.opacity(0.08) : Stanford.cardinalRed.opacity(0.08)
    }

    // MARK: - Slash Context (provider-assisted resource creation)

    private func buildSlashContext(for command: String) -> String? {
        guard let ws = workspace else { return nil }

        switch command {
        case "/skill":
            let existingSkills = (ws.skills.map { $0.name }).joined(separator: ", ")
            return """
            The user wants to create a new Skill for their workspace. A Skill defines what tools an AI agent can use \
            and how it should behave. Have a natural conversation to understand what they need.

            Ask about:
            - What the skill should be called
            - What behavior/instructions the agent should follow
            - Which tools should be allowed (available: Read, Write, Edit, Bash, Glob, Grep, WebFetch, WebSearch, Agent, NotebookEdit)
            - Which tools should be blocked (if any)

            Existing skills in this workspace: \(existingSkills.isEmpty ? "none" : existingSkills)

            When you have enough information, output a JSON block to create it:
            ```json
            {"action": "create_skill", "name": "...", "behavior": "...", "allowed": ["Read", "Glob", ...], "blocked": [...]}
            ```
            """

        case "/tool":
            let existingTools = (ws.localTools.map { $0.name }).joined(separator: ", ")
            return """
            The user wants to create a new Tool for their workspace. Tools are local CLI commands, script files, or MCP integrations \
            that agents can use. Have a natural conversation to understand what they need.

            Ask about:
            - What the tool should be called
            - What type: "cli" (command like jq, curl, docker), "script" (path to a script file), or "mcp" (MCP tool name)
            - The command/path/MCP name
            - A brief description of what it does

            Existing tools in this workspace: \(existingTools.isEmpty ? "none" : existingTools)

            When you have enough information, output a JSON block to create it:
            ```json
            {"action": "create_tool", "name": "...", "type": "cli|script|mcp", "command": "...", "description": "..."}
            ```
            """

        case "/connector":
            let existingConnectors = (ws.connectors.map { "\($0.name) (\($0.serviceType))" }).joined(separator: ", ")
            return """
            The user wants to create a new Connector for their workspace. Connectors provide authentication and configuration \
            for external services like Jira, GitHub, Slack, databases, REST APIs, etc. Have a natural conversation to understand what they need.

            Ask about:
            - What the connector should be called
            - What service type (jira, github, slack, database, rest_api, confluence, or custom)
            - The base URL for the service
            - Authentication method (none, basic, bearer, api_key)
            - Credential key/value pairs they need (e.g. JIRA_EMAIL, JIRA_API_TOKEN, GITHUB_TOKEN, etc.)

            Existing connectors: \(existingConnectors.isEmpty ? "none" : existingConnectors)

            When you have enough information, output a JSON block to create it:
            ```json
            {"action": "create_connector", "name": "...", "serviceType": "jira", "baseURL": "https://...", "authMethod": "bearer", "credentials": {"KEY": "value", ...}}
            ```
            """

        case "/template":
            let templates = ws.templates
            if templates.isEmpty { return nil }
            let templateList = templates.enumerated().map { (i, t) in
                "- **\(t.name)**: \(t.templateDescription.isEmpty ? t.mainGoal.prefix(80) : Substring(t.templateDescription))"
            }.joined(separator: "\n")
            let templateIDs = templates.map { $0.id.uuidString }.joined(separator: ", ")
            return """
            The user wants to create a task from a template. Available templates:
            \(templateList)

            Template IDs (in same order): \(templateIDs)

            Have a natural conversation. Ask which template they want to use, what to call the task, and collect values \
            for any template variables. When ready, output a JSON block:
            ```json
            {"action": "use_template", "templateID": "uuid-string", "taskTitle": "...", "variables": {"var_name": "value", ...}}
            ```
            """

        case "/routine", "/schedule":
            let existingSchedules = (ws.schedules.map { "\($0.name) (\($0.frequencySummary))" }).joined(separator: ", ")
            let skillList = availableSkills.map { $0.name }.joined(separator: ", ")
            return """
            The user wants to create a new Routine for their workspace. A Routine runs work automatically on a \
            recurring basis (daily, weekly, at intervals, or once). Have a natural conversation to understand what they need.

            Ask about:
            - What the routine should be called (a short name)
            - A short description, if useful
            - What the agent should do each time it runs (detailed instructions)
            - Any folders the routine should use as context
            - How often it should run: "once", "interval" (e.g. every 2 hours), "daily" (at a specific time), or "weekly" (on a specific day and time)
            - For interval: how many seconds between runs (900=15m, 1800=30m, 3600=1h, 14400=4h, 43200=12h)
            - For daily/weekly: what hour (0-23) and minute (0, 15, 30, 45)
            - For weekly: what day (1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday)

            Existing routines: \(existingSchedules.isEmpty ? "none" : existingSchedules)
            Available capabilities to attach: \(skillList.isEmpty ? "none" : skillList)

            When you have enough information, output a JSON block to create it:
            ```json
            {"action": "create_schedule", "name": "...", "description": "...", "instructions": "...", "scheduleType": "daily", "intervalSeconds": 3600, "dailyHour": 9, "dailyMinute": 0, "weeklyDayOfWeek": 2, "routinePaths": ["/absolute/folder"], "skills": ["skill name", ...]}
            ```
            Only include the fields relevant to the chosen scheduleType. routinePaths and skills are optional.
            """

        default:
            return nil
        }
    }

    /// Instructions for /recap — one-shot prose summary so the user can pause and resume later.
    /// No JSON action; the provider's markdown response is shown directly in the chat.
    private func buildRecapContext() -> String {
        return """
        The user typed /recap. They are the sole reader and will use this to resume their own work after a context switch.

        Read the conversation above and produce a recap in this exact format. OMIT any section that would be empty — don't write "(none)" or placeholders.

        ## Goal
        One sentence describing what "done" looks like for this task.

        ## Progress
        - Bullets: what was done, plus the non-obvious *why* behind any decision (decisions rot fastest from memory).
        - Max 5 bullets.

        ## Next steps
        - Ordered bullets of concrete actions. The first one must be immediately executable without further thinking.
        - Max 5 bullets.

        ## Watch out
        - Gotchas, blockers, dead-ends already ruled out, things waiting on someone else.
        - Skip this section entirely if there's nothing meaningful to flag.

        Rules:
        - Target ≤150 words total, hard cap 250.
        - Markdown only. No preamble, no sign-off, no meta commentary like "Here is your recap".
        - If the conversation has fewer than ~3 substantive exchanges, reply with a single sentence saying there isn't enough yet to recap.
        """
    }

    /// Parse provider responses for JSON action blocks and execute them
    private func handleSlashAction(in response: String) {
        guard activeSlashContext != nil else { return }

        // Look for ```json ... ``` blocks
        guard let regex = Self.jsonBlockRegex,
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let jsonRange = Range(match.range(at: 1), in: response) else {
            return
        }

        let jsonStr = String(response[jsonRange])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            return
        }

        guard let ws = workspace else { return }

        switch action {
        case "create_skill":
            let name = json["name"] as? String ?? "New Skill"
            let behavior = json["behavior"] as? String ?? ""
            let allowed = json["allowed"] as? [String] ?? Skill.defaultAllowed

            let skill = WorkspaceCommandService.createSkill(
                name: name,
                behaviorInstructions: behavior,
                allowedTools: allowed,
                disallowedTools: [],
                workspace: ws,
                modelContext: modelContext,
                source: "conversation"
            )
            activeSlashContext = nil
            messages.append(ChatMessage(role: "assistant", content: "Skill **\(name)** created with \(skill.allowedTools.count) allowed tools.\n\nYou can customize it in **Configure > Skills**."))

        case "create_tool":
            let name = json["name"] as? String ?? "New Tool"
            let toolType = json["type"] as? String ?? "cli"
            let command = json["command"] as? String ?? ""
            let desc = json["description"] as? String ?? ""

            WorkspaceCommandService.createTool(
                name: name,
                toolType: toolType,
                command: command,
                description: desc,
                workspace: ws,
                modelContext: modelContext,
                source: "conversation"
            )
            activeSlashContext = nil
            let typeLabel = toolType == "cli" ? "CLI Command" : toolType == "script" ? "Script File" : "MCP Tool"
            messages.append(ChatMessage(role: "assistant", content: "Tool **\(name)** (\(typeLabel)) created.\nCommand: `\(command)`\n\nYou can edit it in **Configure > Tools**."))

        case "create_connector":
            let name = json["name"] as? String ?? "New Connector"
            let serviceType = json["serviceType"] as? String ?? "custom"
            let baseURL = json["baseURL"] as? String ?? ""
            let authMethod = json["authMethod"] as? String ?? "none"
            let credentials = json["credentials"] as? [String: String] ?? [:]

            WorkspaceCommandService.createConnector(
                name: name,
                serviceType: serviceType,
                baseURL: baseURL,
                authMethod: authMethod,
                credentials: credentials,
                workspace: ws,
                modelContext: modelContext,
                source: "conversation"
            )
            activeSlashContext = nil
            messages.append(ChatMessage(role: "assistant", content: "Connector **\(name)** (\(serviceType.replacingOccurrences(of: "_", with: " ").capitalized)) created.\nBase URL: `\(baseURL)`\nCredentials: \(credentials.count) keys stored in Keychain.\n\nYou can edit it in **Configure > Connectors**."))

        case "use_template":
            guard let templateIDStr = json["templateID"] as? String,
                  let templateUUID = UUID(uuidString: templateIDStr),
                  let tmpl = ws.templates.first(where: { $0.id == templateUUID }) else {
                return
            }

            let taskTitle = json["taskTitle"] as? String ?? tmpl.name
            let variables = json["variables"] as? [String: String] ?? [:]

            let creation = WorkspaceCommandService.createTemplateTasks(
                template: tmpl,
                taskTitle: taskTitle,
                variables: variables,
                selectedSkills: selectedSkills,
                defaultModel: defaultModel,
                defaultRuntimeID: defaultRuntimeID,
                workspace: ws,
                modelContext: modelContext,
                source: "template"
            )
            activeSlashContext = nil
            onTaskCreated?(creation.mainTask)

        case "create_schedule":
            let name = json["name"] as? String ?? "New Routine"
            let goal = (json["instructions"] as? String) ?? (json["goal"] as? String) ?? ""
            let description = json["description"] as? String ?? ""
            let scheduleTypeRaw = json["scheduleType"] as? String ?? "daily"
            let scheduleType = ScheduleType(rawValue: scheduleTypeRaw) ?? .daily

            let schedule = TaskSchedule(name: name, goal: goal, workspace: ws, runtimeID: defaultRuntimeID, scheduleType: scheduleType)
            schedule.routineDescription = description

            // Configure based on type
            if let interval = json["intervalSeconds"] as? Int {
                schedule.intervalSeconds = interval
            }
            if let hour = json["dailyHour"] as? Int {
                schedule.dailyHour = hour
            }
            if let minute = json["dailyMinute"] as? Int {
                schedule.dailyMinute = minute
            }
            if let dow = json["weeklyDayOfWeek"] as? Int {
                schedule.weeklyDayOfWeek = dow
            }
            if let paths = json["routinePaths"] as? [String] {
                schedule.routinePaths = paths
            }

            // Compute initial nextFireDate
            let now = Date()
            switch scheduleType {
            case .once:
                schedule.nextFireDate = now.addingTimeInterval(60)
            case .interval:
                schedule.nextFireDate = now.addingTimeInterval(TimeInterval(schedule.intervalSeconds))
            case .daily:
                schedule.nextFireDate = Calendar.current.nextDate(
                    after: now,
                    matching: DateComponents(hour: schedule.dailyHour, minute: schedule.dailyMinute),
                    matchingPolicy: .nextTime
                ) ?? now.addingTimeInterval(86400)
            case .weekly:
                schedule.nextFireDate = Calendar.current.nextDate(
                    after: now,
                    matching: DateComponents(hour: schedule.dailyHour, minute: schedule.dailyMinute, weekday: schedule.weeklyDayOfWeek),
                    matchingPolicy: .nextTime
                ) ?? now.addingTimeInterval(604800)
            }

            // Attach skills by name
            if let skillNames = json["skills"] as? [String] {
                let matchedIDs = ws.skills.filter { skillNames.contains($0.name) }.map { $0.id.uuidString }
                schedule.skillIDs = matchedIDs
            }

            schedule.model = defaultModel
            schedule.tokenBudget = defaultBudget

            modelContext.insert(schedule)
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: ws, modelContext: modelContext)
            activeSlashContext = nil

            messages.append(ChatMessage(role: "assistant", content: "Routine **\(name)** created.\nFrequency: \(schedule.frequencySummary)\nInstructions: \(goal.prefix(120))...\n\nThe routine is enabled and will run automatically. You can manage it in the **Routines** section of the sidebar."))
            AppLogger.audit(.taskStats, category: "UI", fields: [
                "event": "schedule_created",
                "source": "conversation",
                "workspace_id": ws.id.uuidString,
                "schedule_type": scheduleTypeRaw
            ])

        default:
            break
        }
    }

    // MARK: - Draft Management

    @discardableResult
    private func saveDraft() -> AgentTask? {
        guard !messages.isEmpty else { return draftTask }

        struct DraftMessage: Codable {
            let role: String
            let content: String
        }
        let draftMessages = messages.map { DraftMessage(role: $0.role, content: $0.content) }
        guard let data = try? JSONEncoder().encode(draftMessages),
              let json = String(data: data, encoding: .utf8) else { return draftTask }

        if let draft = draftTask {
            // Update existing draft
            draft.draftMessages = json
            draft.title = String(messages.first?.content.prefix(60) ?? "Draft")
            draft.goal = messages.first?.content ?? draft.goal
            draft.tokenBudget = defaultBudget
            draft.model = defaultModel
            draft.runtimeID = defaultRuntimeID
            draft.inputs = attachedFiles
            draft.skills = selectedSkills
            draft.captureSkillSnapshots()
            draft.useAgentTeam = useAgentTeam
            draft.teamSize = teamSize
            draft.updatedAt = Date()
            return draft
        } else {
            // Create new draft
            let title = String(messages.first?.content.prefix(60) ?? "Draft")
            let draft = AgentTask(
                title: title,
                goal: messages.first?.content ?? "",
                workspace: workspace,
                tokenBudget: defaultBudget,
                model: defaultModel
            )
            draft.runtimeID = defaultRuntimeID
            draft.status = .draft
            draft.draftMessages = json
            draft.inputs = attachedFiles
            draft.skills = selectedSkills
            draft.captureSkillSnapshots()
            draft.useAgentTeam = useAgentTeam
            draft.teamSize = teamSize
            modelContext.insert(draft)
            draftTask = draft
            return draft
        }
    }

    private func preparePendingPlan(from response: String, fallbackGoal: String, on task: AgentTask, allowFallback: Bool = false) {
        if let structuredPlan = TaskPlanService.parsePlanPayload(from: response) {
            pendingPlan = structuredPlan
        } else if allowFallback {
            pendingPlan = TaskPlanService.parsePlan(from: response, fallbackGoal: fallbackGoal)
        }
        task.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    private func recordPlanConversationEvents(on task: AgentTask) {
        let existingCount = task.events.filter {
            $0.type == TaskPlanConversationEventTypes.userMessage ||
                $0.type == TaskPlanConversationEventTypes.assistantMessage
        }.count
        guard existingCount < messages.count else { return }

        for message in messages.dropFirst(existingCount) {
            let type = message.role == "user"
                ? TaskPlanConversationEventTypes.userMessage
                : TaskPlanConversationEventTypes.assistantMessage
            modelContext.insert(TaskEvent(task: task, type: type, payload: message.content))
        }
    }

    private func newTaskPlanInstructions() -> String {
        """
        PLAN MODE:
        You are planning a new ASTRA task. Do not execute tools, shell commands, writes, or external mutations. Help the user refine the work before execution.
        The user's confirmation button is named "Approve Plan". Do not tell the user to click "Create Task" in Plan Mode; when the draft is acceptable, tell them to click "Approve Plan".

        When you can propose a useful starting plan, include exactly one structured plan line before any prose or clarification questions, using this prefix:
        ASTRA_PLAN {"version":1,"planID":"UUID","title":"Short title","goal":"Brief goal summary","steps":[{"id":"stable-step-id","title":"Step title","detail":"What to do","status":"pending","risk":"low","likelyTools":["Read"],"doneSignal":"How ASTRA knows this step is done"}]}

        Step risk must be low, medium, or high. Step status must be pending. Include every likely permission needed for each step: Read for inspection, Grep for search, Write for creating files, Edit for changing existing files, and Bash for tests/builds/scripts. If a step creates an HTML/CSS/JS/file artifact, include Write in likelyTools. Include a done signal for each step. After the ASTRA_PLAN line, keep prose brief: summarize assumptions and ask only the most important clarification questions before approval. Ask only clarifying questions, without ASTRA_PLAN, if you truly cannot propose a useful starting plan.
        """
    }

    private func loadDraftMessages(_ task: AgentTask) {
        struct DraftMessage: Codable {
            let role: String
            let content: String
        }

        // First try loading from draftMessages JSON
        if !task.draftMessages.isEmpty,
           let data = task.draftMessages.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([DraftMessage].self, from: data) {
            messages = decoded.map { ChatMessage(role: $0.role, content: $0.content) }
            draftTask = task
            isPlanMode = true
            return
        }

        // Fallback: reconstruct conversation from task events (e.g. task moved back to draft from queued)
        let events = task.events.sorted { $0.timestamp < $1.timestamp }
        var restored: [ChatMessage] = []
        for event in events {
            switch event.type {
            case "user.message":
                restored.append(ChatMessage(role: "user", content: event.payload))
            case "agent.response":
                restored.append(ChatMessage(role: "assistant", content: event.payload))
            default:
                break
            }
        }
        if !restored.isEmpty {
            messages = restored
            isPlanMode = true
        }
        draftTask = task
    }

    /// Save current chat messages as TaskEvent records on the task
    private func saveConversationAsEvents(on task: AgentTask) {
        for msg in messages {
            let eventType = msg.role == "user" ? "user.message" : "agent.response"
            let event = TaskEvent(task: task, type: eventType, payload: msg.content)
            modelContext.insert(event)
        }
    }

    private func promoteDraft(to finalTask: AgentTask) {
        if let draft = draftTask {
            // Delete the draft since we're creating the real task
            modelContext.delete(draft)
            draftTask = nil
        }
    }

    private func markdownAttributed(_ text: String) -> AttributedString {
        MarkdownLinkifier.markdownAttributed(text)
    }


}

// MARK: - Spec Card (editable review of extracted spec)

private struct ApprovedPlanReadyCard: View {
    let plan: TaskPlanPayload
    @Binding var isHistoryExpanded: Bool
    let isPlanCanvasVisible: Bool
    let onOpenPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(Stanford.ui(22, weight: .semibold))
                    .foregroundStyle(Stanford.paloAltoGreen)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Plan ready")
                        .font(Stanford.heading(20))
                    Text("The approved plan can still be refined on the Shelf before running it.")
                        .font(Stanford.caption(14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(plan.title)
                    .font(Stanford.body(16).weight(.semibold))
                Text("\(plan.steps.count) planned \(plan.steps.count == 1 ? "step" : "steps")")
                    .font(Stanford.caption(13))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 40)

            HStack(spacing: 10) {
                Button {
                    onOpenPlan()
                } label: {
                    Label(
                        isPlanCanvasVisible ? "Hide Plan" : "Open Plan",
                        systemImage: "rectangle.inset.filled"
                    )
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: false))
                .controlSize(.small)
                .help(isPlanCanvasVisible ? "Hide plan shelf" : "Open plan shelf")

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isHistoryExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isHistoryExpanded ? "chevron.up" : "chevron.down")
                            .font(Stanford.ui(11, weight: .semibold))
                        Text(isHistoryExpanded ? "Hide planning discussion" : "Show planning discussion")
                            .font(Stanford.caption(13).weight(.semibold))
                    }
                    .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.leading, 40)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.fog)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Stanford.lagunita.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct DraftPlanPreviewCard: View {
    let plan: TaskPlanPayload
    @State private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "list.bullet.clipboard")
                    .font(Stanford.ui(20, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Draft plan")
                        .font(Stanford.heading(19))
                    Text("Review the proposed steps. Use the action bar below to approve, regenerate, or keep discussing.")
                        .font(Stanford.caption(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(isCollapsed ? "Show" : "Hide")
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    }
                    .font(Stanford.caption(13).weight(.semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Stanford.lagunita.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show draft plan" : "Hide draft plan")
            }

            if isCollapsed {
                Text("\(plan.steps.count) planned \(plan.steps.count == 1 ? "step" : "steps") hidden")
                    .font(Stanford.caption(13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.title)
                        .font(Stanford.body(16).weight(.semibold))
                    Text(plan.goal)
                        .font(Stanford.caption(14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(plan.steps.prefix(5).enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .font(Stanford.caption(13).weight(.semibold))
                                .foregroundStyle(Stanford.lagunita)
                                .frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title)
                                    .font(Stanford.caption(14).weight(.semibold))
                                if !step.detail.isEmpty {
                                    Text(step.detail)
                                        .font(Stanford.caption(13))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if plan.steps.count > 5 {
                        Text("+ \(plan.steps.count - 5) more steps")
                            .font(Stanford.caption(13))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 32)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.fog)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Stanford.lagunita.opacity(0.18), lineWidth: 1)
        )
    }
}

struct SpecCardView: View {
    @Binding var spec: TaskSpec?
    @Binding var chainedGoal: String
    let onCreateTask: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if var spec = spec {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Task Spec")
                        .font(Stanford.ui(15, weight: .semibold))
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let clarifications = spec.clarifications, !clarifications.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Clarifications needed:", systemImage: "questionmark.circle")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.poppy)
                        ForEach(clarifications, id: \.self) { q in
                            Text("• \(q)")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(8)
                    .background(Stanford.poppy.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Group {
                    EditableField(label: "Title", text: Binding(
                        get: { spec.title },
                        set: { spec.title = $0; self.spec = spec }
                    ))

                    EditableField(label: "Goal", text: Binding(
                        get: { spec.goal },
                        set: { spec.goal = $0; self.spec = spec }
                    ), axis: .vertical)

                    HStack {
                        Label("Complexity", systemImage: "gauge.medium")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                        Text(spec.estimatedComplexity)
                            .font(Stanford.caption(12))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary)
                            .clipShape(Capsule())
                    }

                    EditableListField(label: "Constraints", items: Binding(
                        get: { spec.constraints },
                        set: { spec.constraints = $0; self.spec = spec }
                    ))

                    EditableListField(label: "Acceptance Criteria", items: Binding(
                        get: { spec.acceptanceCriteria },
                        set: { spec.acceptanceCriteria = $0; self.spec = spec }
                    ))
                }

                // Chain: follow-up task
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(Stanford.ui(12))
                            .foregroundStyle(.secondary)
                        Text("Then do... (optional)")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                    TextField("Describe what should happen after this task completes", text: $chainedGoal, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(Stanford.caption(12))
                        .lineLimit(1...3)
                }

                HStack {
                    Spacer()
                    Button("Create Task", action: onCreateTask)
                        .buttonStyle(StanfordButtonStyle())
                        .disabled(spec.title.isEmpty || spec.goal.isEmpty)
                }
            }
            .padding()
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Stanford.cardinalRed.opacity(0.3), lineWidth: 1)
            )
        }
    }
}

struct EditableField: View {
    let label: String
    @Binding var text: String
    var axis: Axis = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            TextField(label, text: $text, axis: axis == .vertical ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.body(15))
                .lineLimit(axis == .vertical ? 2...4 : 1...1)
        }
    }
}

struct EditableListField: View {
    let label: String
    @Binding var items: [String]
    @State private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    TextField(label, text: Binding(
                        get: { index < items.count ? items[index] : "" },
                        set: { if index < items.count { items[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.caption(12))
                    Button {
                        if index < items.count { items.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(Stanford.caption(12))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 4) {
                TextField("Add \(label.lowercased())...", text: $newItem)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.caption(12))
                    .onSubmit {
                        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            items.append(trimmed)
                            newItem = ""
                        }
                    }
                Button {
                    let trimmed = newItem.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        items.append(trimmed)
                        newItem = ""
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Stanford.interactive)
                        .font(Stanford.caption(12))
                }
                .buttonStyle(.plain)
                .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct ChatBubbleView: View {
    let event: TaskEvent

    var isUser: Bool {
        event.type == "user.message"
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(event.payload)
                    .font(Stanford.body())
                    .padding(10)
                    .background(isUser ? Stanford.cardinalRed : Stanford.fog)
                    .foregroundStyle(isUser ? .white : Stanford.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(event.timestamp, style: .time)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}
