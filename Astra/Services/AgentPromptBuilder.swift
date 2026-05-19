import Foundation
import ASTRACore

enum AgentPromptBuilder {
    private static let recentSessionOutputFileLimit = 6
    private static let recentSessionFullOutputFileLimit = 4
    private static let recentSessionFullOutputMaxCharacters = 8_000
    private static let olderSessionOutputMaxCharacters = 2_000
    private static let fallbackRunResponseLimit = 8
    private static let fallbackRecentRunResponseLimit = 3
    private static let fallbackRecentRunResponseMaxCharacters = 8_000
    private static let fallbackOlderRunResponseMaxCharacters = 1_500

    static func buildPrompt(for task: AgentTask) -> String {
        var parts: [String] = []
        let capabilityScope = TaskCapabilityResolver(task: task).promptScope()

        parts.append(currentTaskBlock(for: task))

        if let instructions = task.workspace?.instructions,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Workspace Context:\n\(instructions)")
        }

        if let memories = task.workspace?.memories, !memories.isEmpty {
            let memoriesBlock = """
            YOUR MEMORIES (saved by the user for this workspace — these ARE your persistent memories, do NOT look for memory files on disk):
            \(memories.map { "- \($0)" }.joined(separator: "\n"))
            When the user asks about your memories, report these items. Do not check ~/.claude/ or any file-based memory system.
            """
            parts.append(memoriesBlock)
        }

        if let ws = task.workspace {
            let recentTasks = ws.tasks
                .filter { $0.id != task.id && $0.isTerminal }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                .prefix(3)

            if !recentTasks.isEmpty {
                var summaryBlock = "Recent tasks in this workspace (for context):"
                for t in recentTasks {
                    let status = t.status.rawValue
                    let output = t.runs.last?.output ?? ""
                    let summary = output.isEmpty ? "(no output)" : String(output.prefix(200))
                    summaryBlock += "\n- [\(status)] \(t.title): \(summary)"
                }
                parts.append(summaryBlock)
            }
        }

        appendSSHContext(for: task, to: &parts)
        appendWorkspacePaths(for: task, to: &parts)
        appendTaskOutputFolder(for: task, to: &parts)

        parts.append("Goal: \(task.goal)")

        appendInputs(for: task, to: &parts)
        appendConstraints(for: task, to: &parts)
        appendSkillInstructions(from: capabilityScope, to: &parts)
        appendConnectorContext(from: capabilityScope, to: &parts)
        appendToolContext(from: capabilityScope, to: &parts)
        appendShelfBrowserContext(for: task, enabledBrowserAdapters: capabilityScope.enabledBrowserAdapters, to: &parts)
        appendDocumentReaderContext(to: &parts)
        if task.resolvedRuntimeID.supportsAstraRunProtocol {
            appendAstraRunProtocolInstructions(to: &parts)
        }

        parts.append(currentTaskReminder(for: task))

        if task.useAgentTeam {
            var teamBlock = "Create an agent team with \(task.teamSize) teammates to accomplish the goal below. Coordinate them to work in parallel and synthesize their results."
            if !task.teamInstructions.isEmpty {
                teamBlock += "\n\(task.teamInstructions)"
            }
            parts.insert(teamBlock, at: 0)
        }

        return parts.joined(separator: "\n\n")
    }

    private static func currentTaskBlock(for task: AgentTask) -> String {
        """
        Current Task:
        \(task.goal)

        Complete this task now. Treat recent tasks, memories, skills, browser state, and protocol notes as supporting context only.
        """
    }

    private static func currentTaskReminder(for task: AgentTask) -> String {
        "Current Task Reminder: complete this task now: \(task.goal)"
    }

    static func buildApprovedPlanExecutionPrompt(for task: AgentTask, plan: TaskPlanPayload) -> String {
        var prompt = buildPrompt(for: task)
        prompt += "\n\n" + approvedPlanExecutionInstructions(plan: plan)
        return prompt
    }

    static func buildApprovedPlanStepExecutionPrompt(for task: AgentTask, plan: TaskPlanPayload, step: TaskPlanPayloadStep) -> String {
        var prompt = buildPrompt(for: task)
        prompt += "\n\n" + approvedPlanExecutionInstructions(plan: plan, approvedStep: step)
        return prompt
    }

    static func buildApprovedPlanFollowUpPrompt(message: String, task: AgentTask, plan: TaskPlanPayload) -> String {
        var prompt = buildFreshFollowUpPrompt(message: message, task: task)
        prompt += "\n\n" + approvedPlanExecutionInstructions(plan: plan, userRequest: message)
        return prompt
    }

    private static func appendSSHContext(for task: AgentTask, to parts: inout [String]) {
        guard let ws = task.workspace else { return }
        let connections = SSHConnectionManager.load(workspacePath: ws.primaryPath)
        if connections.count == 1, let conn = connections.first {
            let alias = conn.configAlias.isEmpty ? conn.sshTarget : conn.configAlias
            var sshBlock = "Remote Server: This workspace is connected to a remote server via SSH."
            sshBlock += "\n- Name: \(conn.displayLabel)"
            sshBlock += "\n- Connect with: ssh \(alias)"
            sshBlock += "\n- Remote path: \(conn.remotePath)"
            sshBlock += "\nWhen the user says \"the server\", \"the remote\", \"this connection\", or \"it\" in the context of SSH, they mean this server."
            sshBlock += "\nTo run commands: ssh \(alias) '<command>'"
            sshBlock += "\nTo run commands in a specific directory: ssh \(alias) 'cd \(conn.remotePath) && <command>'"
            parts.append(sshBlock)
        } else if connections.count > 1 {
            var sshBlock = "Available SSH Connections (use these to access remote servers via Bash with ssh):"
            for conn in connections {
                let alias = conn.configAlias.isEmpty ? conn.sshTarget : conn.configAlias
                sshBlock += "\n- \(conn.displayLabel): ssh \(alias) (remote path: \(conn.remotePath))"
                if !conn.configAlias.isEmpty {
                    sshBlock += " [uses ~/.ssh/config alias]"
                }
            }
            sshBlock += "\nTo run commands on a remote server, use: ssh <alias> '<command>'"
            parts.append(sshBlock)
        }
    }

    private static func appendWorkspacePaths(for task: AgentTask, to parts: inout [String]) {
        guard let ws = task.workspace, !ws.additionalPaths.isEmpty else { return }
        let codeDir = TaskWorkspaceAccess(task: task).codeWorkingDirectory
        if codeDir != TaskWorkspaceAccess(task: task).effectiveWorkspacePath {
            parts.append("WORKING DIRECTORY: Your process is running in \(codeDir). This is the primary code directory for this workspace. All relative paths resolve from here.")
        }
        if ws.additionalPaths.count > 1 {
            let extras = ws.additionalPaths.dropFirst().map { path -> String in
                let name = (path as NSString).lastPathComponent
                return "- \(name): \(path)"
            }.joined(separator: "\n")
            parts.append("Additional Workspace Folders:\n\(extras)")
        }
    }

    private static func appendTaskOutputFolder(for task: AgentTask, to parts: inout [String]) {
        let taskDir = TaskWorkspaceAccess(task: task).taskFolder
        if !taskDir.isEmpty {
            let relativePath = relativeTaskFolderPath(for: task, taskDir: taskDir)
            if let relativePath {
                parts.append("""
                Task Output Folder: \(relativePath)
                Absolute path: \(taskDir)
                This directory already exists. Save output files, reports, or artifacts there using the relative path when writing from the current working directory. Do not create the folder yourself.
                """)
            } else {
                parts.append("""
                Task Output Folder: \(taskDir)
                This directory already exists. Save output files, reports, or artifacts there. Do not create the folder yourself.
                """)
            }
        }
    }

    private static func relativeTaskFolderPath(for task: AgentTask, taskDir: String) -> String? {
        let base = TaskWorkspaceAccess(task: task).codeWorkingDirectory
        guard !base.isEmpty else { return nil }
        let standardizedBase = URL(fileURLWithPath: base).standardizedFileURL.path
        let standardizedTaskDir = URL(fileURLWithPath: taskDir).standardizedFileURL.path
        guard standardizedTaskDir == standardizedBase || standardizedTaskDir.hasPrefix(standardizedBase + "/") else {
            return nil
        }
        if standardizedTaskDir == standardizedBase {
            return "."
        }
        let suffix = standardizedTaskDir.dropFirst(standardizedBase.count + 1)
        return suffix.isEmpty ? "." : String(suffix)
    }

    private static func appendInputs(for task: AgentTask, to parts: inout [String]) {
        guard !task.inputs.isEmpty else { return }
        var contextParts: [String] = []
        for input in task.inputs {
            if input.hasPrefix("/") || input.hasPrefix("~") {
                let path = (input as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    contextParts.append("Folder: \(path)\nUse this folder as routine context when needed.")
                } else if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    let truncated = content.count > 5000 ? String(content.prefix(5000)) + "\n... (truncated)" : content
                    contextParts.append("File: \(input)\n```\n\(truncated)\n```")
                } else {
                    contextParts.append("Context: \(input)")
                }
            } else {
                contextParts.append("Context: \(input)")
            }
        }
        parts.append("Context/Inputs:\n" + contextParts.joined(separator: "\n\n"))
    }

    private static func appendConstraints(for task: AgentTask, to parts: inout [String]) {
        if !task.constraints.isEmpty {
            parts.append("Constraints:\n" + task.constraints.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !task.acceptanceCriteria.isEmpty {
            parts.append("Acceptance Criteria:\n" + task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }
    }

    private static func appendSkillInstructions(from capabilityScope: TaskCapabilityPromptScope, to parts: inout [String]) {
        let behaviorBlock = capabilityScope.resolver.resolvedBehaviorInstructions
        if !behaviorBlock.isEmpty {
            parts.append("Behavioral Instructions (from Skills):\n\(behaviorBlock)")
        }
    }

    private static func appendConnectorContext(from capabilityScope: TaskCapabilityPromptScope, to parts: inout [String]) {
        let projection = ConnectorRuntimeProjection(connectors: capabilityScope.connectors)
        let aliasesByID = projection.aliasesByConnectorID
        let bindingsByConnectorID = Dictionary(grouping: projection.environmentBindings(), by: \.connectorID)

        let connectorDescriptions = capabilityScope.connectors.map { conn in
            let alias = aliasesByID[conn.id] ?? ConnectorRuntimeProjection.alias(for: conn)
            let bindings = bindingsByConnectorID[conn.id] ?? []
            let credentialBindings = bindings.filter {
                $0.kind == .credential && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let configBindings = bindings.filter { $0.kind == .config }
            let configuredCredentialKeys = Set(credentialBindings.map(\.originalKey))
            let missingCredentialKeys = conn.credentialKeys.filter { !configuredCredentialKeys.contains($0) }

            var desc = "[\(conn.name)] \(conn.serviceType) - \(conn.connectorDescription)"
            desc += "\n  Alias: \(alias)"
            if !conn.baseURL.isEmpty { desc += "\n  Base URL: \(conn.baseURL)" }
            if !conn.configKeys.isEmpty {
                let configs = zip(conn.configKeys, conn.configValues)
                    .map { "\($0): \($1)" }
                    .joined(separator: ", ")
                desc += "\n  Config: \(configs)"
            }
            if !bindings.isEmpty {
                let rendered = bindings
                    .sorted { $0.envKey < $1.envKey }
                    .map { "\($0.logicalName): $\($0.envKey)" }
                    .joined(separator: ", ")
                desc += "\n  Connector env vars: \(rendered)"
            }
            if !credentialBindings.isEmpty {
                let rendered = credentialBindings
                    .sorted { $0.envKey < $1.envKey }
                    .map(\.envKey)
                    .joined(separator: ", ")
                desc += "\n  Credentials ALREADY SET in your environment: \(rendered) - use os.environ[\"KEY\"] directly, do NOT ask the user for these"
            }
            if !missingCredentialKeys.isEmpty {
                desc += "\n  Credentials NOT configured (ask user to fill them in workspace settings): \(missingCredentialKeys.joined(separator: ", "))"
            }
            if !configBindings.isEmpty {
                let rendered = configBindings
                    .sorted { $0.envKey < $1.envKey }
                    .map(\.envKey)
                    .joined(separator: ", ")
                desc += "\n  Config env vars: \(rendered)"
            }
            if let example = connectorRuntimeExample(for: conn, bindings: bindings) {
                desc += "\n  Runtime example: \(example)"
            }
            desc += "\n  Auth: \(conn.authMethod)"
            if !conn.notes.isEmpty { desc += "\n  Notes: \(conn.notes)" }
            return desc
        }
        guard !connectorDescriptions.isEmpty else { return }

        parts.append("""
        Available Connectors (credentials are pre-loaded into your process environment — use them directly, never ask the user to provide them again):
        \(connectorDescriptions.joined(separator: "\n\n"))

        The connector env vars listed above and the ASTRA_CONNECTORS JSON manifest are authoritative for this run. When more than one connector of the same service is available, use the connector name or alias to pick the right env vars. If behavioral instructions mention bare legacy env names, use those names only when they are explicitly listed above or in ASTRA_CONNECTORS. If the user request is ambiguous, ask which connector to use before calling external APIs.

        IMPORTANT: To call authenticated APIs, use Bash with curl/python and the env var tokens — NOT WebFetch. \
        WebFetch cannot handle SSO, session cookies, or token-based auth headers. Prefer the per-connector runtime examples above, or in Python use os.environ["ENV_KEY_LISTED_ABOVE"] to read the credential.
        """)
    }

    private static func connectorRuntimeExample(
        for connector: Connector,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding]
    ) -> String? {
        let serviceType = connector.serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch serviceType {
        case "jira":
            return jiraRuntimeExample(for: connector, bindings: bindings)
        case "redcap":
            return redcapRuntimeExample(for: connector, bindings: bindings)
        case "gcloud", "google_cloud", "googlecloud", "gcp":
            return gcloudRuntimeExample(bindings: bindings)
        default:
            return nil
        }
    }

    private static func jiraRuntimeExample(
        for connector: Connector,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding]
    ) -> String? {
        guard let baseURL = runtimeURLBase(
            bindings: bindings,
            logicalNames: ["baseURL", "jiraBaseURL", "url"],
            originalKeys: ["JIRA_BASE_URL", "BASE_URL", "URL"],
            keyFragments: ["BASE_URL"]
        ) else {
            return nil
        }
        guard let email = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["email", "jiraEmail", "username"],
            originalKeys: ["JIRA_EMAIL", "EMAIL", "USERNAME"],
            keyFragments: ["EMAIL", "USERNAME"],
            preferredKind: .credential
        ),
              let token = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["apiToken", "token", "jiraAPIToken"],
            originalKeys: ["JIRA_API_TOKEN", "API_TOKEN", "TOKEN"],
            keyFragments: ["API_TOKEN", "TOKEN"],
            preferredKind: .credential
        ) else {
            return nil
        }
        let url = shellQuote("\(baseURL)/rest/api/3/mypermissions?permissions=BROWSE_PROJECTS")
        return #"curl -s -u "\#(email):\#(token)" -H "Content-Type: application/json" "\#(url)""#
    }

    private static func redcapRuntimeExample(
        for connector: Connector,
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding]
    ) -> String? {
        guard let url = runtimeURLBase(
            bindings: bindings,
            logicalNames: ["apiURL", "baseURL", "url"],
            originalKeys: ["REDCAP_API_URL", "API_URL", "BASE_URL", "URL"],
            keyFragments: ["API_URL", "BASE_URL"]
        ) else {
            return nil
        }
        guard let token = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["apiToken", "token", "redcapAPIToken"],
            originalKeys: ["REDCAP_API_TOKEN", "API_TOKEN", "TOKEN"],
            keyFragments: ["API_TOKEN", "TOKEN"],
            preferredKind: .credential
        ) else {
            return nil
        }
        let quotedURL = shellQuote(url)
        return #"curl -sS -H "Content-Type: application/x-www-form-urlencoded" -H "Accept: application/json" -X POST --data-urlencode "token=\#(token)" --data-urlencode "content=project" --data-urlencode "format=json" --data-urlencode "returnFormat=json" "\#(quotedURL)""#
    }

    private static func gcloudRuntimeExample(
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding]
    ) -> String? {
        let project = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["project", "gcpProject", "projectID"],
            originalKeys: ["GCP_PROJECT", "PROJECT", "PROJECT_ID"],
            keyFragments: ["PROJECT"],
            preferredKind: .config
        )
        let region = runtimeEnvValue(
            bindings: bindings,
            logicalNames: ["region", "gcpRegion"],
            originalKeys: ["GCP_REGION", "REGION"],
            keyFragments: ["REGION"],
            preferredKind: .config
        )

        if let project, let region {
            return #"gcloud run services list --project "\#(project)" --region "\#(region)" --format=json"#
        } else if let project {
            return #"gcloud projects describe "\#(project)" --format=json"#
        } else if let region {
            return #"gcloud run services list --region "\#(region)" --format=json"#
        }
        return nil
    }

    private static func runtimeEnvValue(
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        logicalNames: Set<String>,
        originalKeys: Set<String>,
        keyFragments: [String],
        preferredKind: ConnectorRuntimeProjection.BindingKind
    ) -> String? {
        guard let binding = matchingBinding(
            in: bindings,
            logicalNames: logicalNames,
            originalKeys: originalKeys,
            keyFragments: keyFragments,
            preferredKind: preferredKind
        ) else {
            return nil
        }
        return "$\(binding.envKey)"
    }

    private static func runtimeURLBase(
        bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        logicalNames: Set<String>,
        originalKeys: Set<String>,
        keyFragments: [String]
    ) -> String? {
        if let binding = matchingBinding(
            in: bindings,
            logicalNames: logicalNames,
            originalKeys: originalKeys,
            keyFragments: keyFragments,
            preferredKind: .config
        ) {
            return "${\(binding.envKey)}"
        }
        return nil
    }

    private static func matchingBinding(
        in bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        logicalNames: Set<String>,
        originalKeys: Set<String>,
        keyFragments: [String],
        preferredKind: ConnectorRuntimeProjection.BindingKind
    ) -> ConnectorRuntimeProjection.EnvironmentBinding? {
        let preferred = bindings.filter { $0.kind == preferredKind }
        return firstMatchingBinding(in: preferred, logicalNames: logicalNames, originalKeys: originalKeys, keyFragments: keyFragments)
            ?? firstMatchingBinding(in: bindings, logicalNames: logicalNames, originalKeys: originalKeys, keyFragments: keyFragments)
    }

    private static func firstMatchingBinding(
        in bindings: [ConnectorRuntimeProjection.EnvironmentBinding],
        logicalNames: Set<String>,
        originalKeys: Set<String>,
        keyFragments: [String]
    ) -> ConnectorRuntimeProjection.EnvironmentBinding? {
        let normalizedLogicalNames = Set(logicalNames.map { $0.lowercased() })
        let normalizedOriginalKeys = Set(originalKeys.map { $0.uppercased() })
        let normalizedFragments = keyFragments.map { $0.uppercased() }
        return bindings
            .sorted { $0.envKey < $1.envKey }
            .first { binding in
                let logicalName = binding.logicalName.lowercased()
                let originalKey = binding.originalKey.uppercased()
                return normalizedLogicalNames.contains(logicalName)
                    || normalizedOriginalKeys.contains(originalKey)
                    || normalizedFragments.contains { originalKey.contains($0) }
            }
    }

    private static func shellQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func appendToolContext(from capabilityScope: TaskCapabilityPromptScope, to parts: inout [String]) {
        let allLocalTools = capabilityScope.localTools.filter { !$0.command.isEmpty }
        let cliTools = allLocalTools.filter { $0.toolType != "mcp" }
        let mcpTools = allLocalTools.filter { $0.toolType == "mcp" }

        if !cliTools.isEmpty {
            let descriptions = cliTools.map { tool in
                "- \(tool.name): `\(tool.displayCommand)` — \(tool.toolDescription)"
            }.joined(separator: "\n")
            parts.append("Available CLI/Script Tools (run these using the Bash tool):\n\(descriptions)\n\nTo use these, call them via the Bash tool. Example: Bash(`\(cliTools[0].displayCommand)`)")
        }

        if !mcpTools.isEmpty {
            let descriptions = mcpTools.map { tool in
                "- \(tool.name): \(tool.command) — \(tool.toolDescription)"
            }.joined(separator: "\n")
            parts.append("Available MCP Tools (use directly by tool name):\n" + descriptions)
        }
    }

    private static func appendDocumentReaderContext(to parts: inout [String]) {
        let readfilePath = NSHomeDirectory() + "/.astra/tools/readfile"
        guard FileManager.default.isExecutableFile(atPath: readfilePath) else { return }
        parts.append("""
        Document Reader Tool: You have a `readfile` command available for reading documents.
        Usage: `readfile <path>` — reads .docx, .pdf, .rtf, .xlsx, .pptx, .csv, .odt, .html, and more.
        For directories: `readfile <folder>` — lists contents recursively.
        Add `--metadata` for file metadata. Run via Bash tool: `\(readfilePath) <path>`
        """)
    }

    private static func appendShelfBrowserContext(
        for task: AgentTask,
        enabledBrowserAdapters: [String],
        to parts: inout [String]
    ) {
        let override = enabledBrowserAdapters.isEmpty ? nil : enabledBrowserAdapters
        guard let browserContext = ShelfBrowserBridgeRegistry.shared.promptContext(
            for: task.id,
            enabledBrowserAdapters: override
        ) else { return }
        parts.append(browserContext)
    }

    static func buildFreshFollowUpPrompt(message: String, task: AgentTask) -> String {
        var parts: [String] = []
        let capabilityScope = TaskCapabilityResolver(task: task).promptScope(contextText: message)

        parts.append("You are continuing work on a task. Here is the original goal:")
        parts.append("Goal: \(task.goal)")

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        var includedExactSessionTranscript = false
        if !folder.isEmpty {
            if let transcript = buildRecentConversationTranscript(for: task) {
                parts.append("Recent conversation transcript (exact recent turns from this task):\n\(transcript)")
                includedExactSessionTranscript = true
            } else {
                let historyPath = SessionHistoryManager.historyPath(taskFolder: folder)
                if let history = try? String(contentsOfFile: historyPath, encoding: .utf8) {
                    let trimmed = recentSessionHistorySummary(from: history)
                    parts.append("Session History (prior turns):\n\(trimmed)")
                }
            }
        }

        let sortedRuns = followUpContextRuns(for: task)
        if !includedExactSessionTranscript, !sortedRuns.isEmpty {
            var answersBlock = "Previous responses (your final answers from each turn):"
            for (i, run) in sortedRuns.enumerated() where !run.output.isEmpty {
                let turnLabel = "Turn \(i + 1)"
                let recentIndex = sortedRuns.count - i
                let maxLen = recentIndex <= fallbackRecentRunResponseLimit
                    ? fallbackRecentRunResponseMaxCharacters
                    : fallbackOlderRunResponseMaxCharacters
                let snippet = boundedText(run.output, maxCharacters: maxLen, keeping: .suffix)
                answersBlock += "\n\n--- \(turnLabel) ---\n\(snippet)"
            }
            parts.append(answersBlock)
        }

        let allChanges = sortedRuns.flatMap { $0.fileChanges }
        if !allChanges.isEmpty {
            let uniquePaths = Array(Set(allChanges.map { $0.path })).sorted().suffix(20)
            let changeList = uniquePaths.map { path -> String in
                let lastChange = allChanges.last { $0.path == path }
                let icon = lastChange?.changeType == "Write" ? "+" : "~"
                return "[\(icon)] \(path)"
            }.joined(separator: "\n")
            parts.append("Files modified in this task:\n\(changeList)")
        }

        if !folder.isEmpty {
            let taskFiles = listTaskFolderFiles(folder)
            if !taskFiles.isEmpty {
                parts.append("Generated files in task folder (\(folder)):\n\(taskFiles.joined(separator: "\n"))\nYou can read these files if needed for context.")
            }
        }

        let contextLine = buildFollowUpMessage(message: "", task: task, capabilityScope: capabilityScope)
        if contextLine != "",
           let bracketEnd = contextLine.range(of: "]\n\n") {
            parts.append(String(contextLine[contextLine.startIndex...bracketEnd.lowerBound]))
        }

        appendConnectorContext(from: capabilityScope, to: &parts)

        appendShelfBrowserContext(for: task, enabledBrowserAdapters: capabilityScope.enabledBrowserAdapters, to: &parts)

        if let memories = task.workspace?.memories, !memories.isEmpty {
            let memoriesBlock = """
            YOUR MEMORIES (saved by the user for this workspace — these ARE your persistent memories, do NOT look for memory files on disk):
            \(memories.map { "- \($0)" }.joined(separator: "\n"))
            When the user asks about your memories, report these items. Do not check ~/.claude/ or any file-based memory system.
            """
            parts.append(memoriesBlock)
        }

        if task.resolvedRuntimeID.supportsAstraRunProtocol {
            appendAstraRunProtocolInstructions(to: &parts)
        }

        parts.append("User's follow-up request:\n\(message)")

        return parts.joined(separator: "\n\n")
    }

    static func buildRecentConversationTranscript(for task: AgentTask) -> String? {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty else { return nil }
        return recentSessionOutputTranscript(taskFolder: folder)
    }

    private enum TextBound {
        case prefix
        case suffix
    }

    private static func recentSessionOutputTranscript(taskFolder: String) -> String? {
        let outputDirectory = (taskFolder as NSString).appendingPathComponent("outputs")
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: outputDirectory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let turnFiles = urls
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("turn_") && name.hasSuffix(".md")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .suffix(recentSessionOutputFileLimit)

        guard !turnFiles.isEmpty else { return nil }

        let sections = turnFiles.enumerated().compactMap { offset, url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let recentIndex = turnFiles.count - offset
            let maxCharacters = recentIndex <= recentSessionFullOutputFileLimit
                ? recentSessionFullOutputMaxCharacters
                : olderSessionOutputMaxCharacters
            let excerpt = boundedText(text, maxCharacters: maxCharacters, keeping: .prefix)
            return "--- \(url.lastPathComponent) ---\n\(excerpt)"
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private static func recentSessionHistorySummary(from history: String) -> String {
        let marker = "\n## Turn "
        let pieces = history.components(separatedBy: marker)
        guard pieces.count > 1 else {
            return boundedText(history, maxCharacters: 4_000, keeping: .suffix)
        }

        let header = pieces[0]
        let recentTurns = pieces.dropFirst().suffix(recentSessionOutputFileLimit).map { "## Turn " + $0 }
        let summary = ([header] + recentTurns).joined(separator: "\n")
        return boundedText(summary, maxCharacters: 8_000, keeping: .suffix)
    }

    private static func followUpContextRuns(for task: AgentTask) -> [TaskRun] {
        let sortedRuns = task.runs.sorted { $0.startedAt < $1.startedAt }
        guard !sortedRuns.isEmpty else { return [] }

        let activeRuns: [TaskRun]
        if task.forkedFromID != nil,
           task.forkedAtRunIndex > 0,
           task.forkedAtRunIndex < sortedRuns.count {
            activeRuns = Array(sortedRuns.suffix(sortedRuns.count - task.forkedAtRunIndex))
        } else {
            activeRuns = sortedRuns
        }

        let runsWithOutput = activeRuns.filter { !$0.output.isEmpty }
        return Array(runsWithOutput.suffix(fallbackRunResponseLimit))
    }

    private static func boundedText(_ text: String, maxCharacters: Int, keeping bound: TextBound) -> String {
        guard text.count > maxCharacters else { return text }
        switch bound {
        case .prefix:
            return String(text.prefix(maxCharacters)) + "\n... (truncated)"
        case .suffix:
            return "... (truncated)\n" + String(text.suffix(maxCharacters))
        }
    }

    static func buildFollowUpMessage(message: String, task: AgentTask) -> String {
        let capabilityScope = TaskCapabilityResolver(task: task).promptScope(contextText: message)
        return buildFollowUpMessage(message: message, task: task, capabilityScope: capabilityScope)
    }

    private static func buildFollowUpMessage(message: String, task: AgentTask, capabilityScope: TaskCapabilityPromptScope) -> String {
        var contextParts: [String] = []

        if let ws = task.workspace {
            let connections = SSHConnectionManager.load(workspacePath: ws.primaryPath)
            if let conn = connections.first, !conn.remotePath.isEmpty {
                contextParts.append("Remote server: ssh \(conn.configAlias.isEmpty ? conn.sshTarget : conn.configAlias) — remote path: \(conn.remotePath)")
            }

            if !ws.additionalPaths.isEmpty {
                let paths = ws.additionalPaths.map { "\((($0 as NSString).lastPathComponent)): \($0)" }.joined(separator: ", ")
                contextParts.append("Additional workspace folders: \(paths)")
            }

            if !ws.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contextParts.append("Workspace: \(String(ws.instructions.prefix(300)))")
            }
        }

        let behaviorBlock = capabilityScope.resolver.resolvedBehaviorInstructions
        if !behaviorBlock.isEmpty {
            contextParts.append("Skills: \(String(behaviorBlock.prefix(500)))")
        }

        if let lastRun = task.runs.sorted(by: { $0.startedAt > $1.startedAt }).first {
            let recentPaths = lastRun.fileChanges.suffix(5).map { $0.path }
            if !recentPaths.isEmpty {
                let dirs = Set(recentPaths.compactMap { path -> String? in
                    let url = URL(fileURLWithPath: path)
                    let dir = url.deletingLastPathComponent().path
                    return dir.isEmpty ? nil : dir
                })
                if !dirs.isEmpty {
                    contextParts.append("You were working in: \(dirs.joined(separator: ", "))")
                }
            }
        }

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        if !folder.isEmpty {
            let historyPath = SessionHistoryManager.historyPath(taskFolder: folder)
            if FileManager.default.fileExists(atPath: historyPath) {
                contextParts.append("Session history: \(historyPath)")
            }
        }

        let readfilePath = NSHomeDirectory() + "/.astra/tools/readfile"
        if FileManager.default.isExecutableFile(atPath: readfilePath) {
            contextParts.append("Document reader: `readfile <path>` reads .docx/.pdf/.xlsx/.pptx and more")
        }

        if contextParts.isEmpty {
            return message
        }

        return "[Context: \(contextParts.joined(separator: " | "))]\n\n\(message)"
    }

    private static func listTaskFolderFiles(_ folder: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let rel = url.path.replacingOccurrences(of: folder + "/", with: "")
            if rel.hasPrefix("outputs/") { continue }
            if rel == "session_history.md" { continue }
            files.append("- \(rel) (\(url.path))")
            if files.count >= 30 { break }
        }
        return files
    }

    private static func appendAstraRunProtocolInstructions(to parts: inout [String]) {
        parts.append("""
        Astra Run Protocol v1:
        Emit structured progress markers only when useful, each on its own line and outside code fences.
        Marker prefix must be exactly `ASTRA_EVENT ` followed by one JSON object.
        Supported markers:
        ASTRA_EVENT {"v":1,"type":"todo.replace","items":[{"text":"Short step","status":"pending"}]}
        ASTRA_EVENT {"v":1,"type":"plan.step.started","planID":"PLAN_UUID","stepID":"stable-step-id","status":"running"}
        ASTRA_EVENT {"v":1,"type":"plan.step.completed","planID":"PLAN_UUID","stepID":"stable-step-id","status":"done","summary":"What finished"}
        ASTRA_EVENT {"v":1,"type":"plan.step.blocked","planID":"PLAN_UUID","stepID":"stable-step-id","status":"blocked","reason":"What is blocking progress"}
        ASTRA_EVENT {"v":1,"type":"plan.step.skipped","planID":"PLAN_UUID","stepID":"stable-step-id","status":"skipped","reason":"Why skipped"}
        ASTRA_EVENT {"v":1,"type":"complete","summary":"What changed and what is ready for review.","verifiedBy":"Tests or checks run"}
        For todo.replace, replace the whole visible plan. Each item status must be `pending` or `done`.
        For plan.step markers, use the exact planID and stepID from the approved plan. Emit started before work on a step, completed when it is done, blocked when permission or missing context prevents progress, and skipped when intentionally not doing a step.
        For complete, summarize completed work and include verifiedBy when you ran checks. This marker is advisory only: keep writing the final response normally and do not rely on it to end the task.
        Do not wrap ASTRA_EVENT lines in markdown, quotes, bullets, or code fences.
        """)
    }

    private static func approvedPlanExecutionInstructions(
        plan: TaskPlanPayload,
        userRequest: String? = nil,
        approvedStep: TaskPlanPayloadStep? = nil
    ) -> String {
        let scopeInstructions = if let approvedStep {
            """
            ASTRA review mode approved only the next plan step.
            Execute exactly this approved step and stop: \(approvedStep.id) — \(approvedStep.title).
            Do not execute later plan steps. If the approved step requires a later step first, emit a blocked marker for this step and explain the dependency.
            """
        } else {
            """
            ASTRA auto mode approved the full plan.
            Execute the remaining approved plan steps until the plan is complete or blocked.
            Do not redo steps already marked done or skipped.
            """
        }

        var parts: [String] = [
            """
            You are executing an ASTRA-approved plan.
            Use the full plan for context, but work step by step.
            \(scopeInstructions)
            Before starting a step, emit ASTRA_EVENT {"v":1,"type":"plan.step.started","planID":"\(plan.planID.uuidString)","stepID":"STEP_ID","status":"running"}.
            When a step finishes, emit ASTRA_EVENT {"v":1,"type":"plan.step.completed","planID":"\(plan.planID.uuidString)","stepID":"STEP_ID","status":"done","summary":"What finished"}.
            If blocked, emit ASTRA_EVENT {"v":1,"type":"plan.step.blocked","planID":"\(plan.planID.uuidString)","stepID":"STEP_ID","status":"blocked","reason":"What is blocking progress"} and explain the blocker.
            If skipped, emit ASTRA_EVENT {"v":1,"type":"plan.step.skipped","planID":"\(plan.planID.uuidString)","stepID":"STEP_ID","status":"skipped","reason":"Why skipped"}.
            Do not materially change the approved plan without saying why.
            The user has explicitly approved this plan in ASTRA. Do not ask for a separate interactive tool approval; if a permission or policy blocks work, emit a blocked marker and explain the exact missing permission.
            """
        ]

        if let userRequest, !userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("User's approved execution request:\n\(userRequest)")
        }

        parts.append("Approved plan JSON:\n\(TaskPlanService.encodePlanPayload(plan))")
        if let approvedStep {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(approvedStep),
               let stepJSON = String(data: data, encoding: .utf8) {
                parts.append("Approved next step JSON:\n\(stepJSON)")
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
