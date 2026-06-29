import Foundation
import Testing
@testable import ASTRA
import ASTRACore

private let slashCommandRealProviderEnabled = ProcessInfo.processInfo.environment["RUN_REAL_PROVIDERS"] != nil

@Suite("Slash Command Real Provider Smoke", .serialized)
struct SlashCommandRealProviderSmokeTests {
    @Test(
        "real provider follows provider-assisted slash command contexts",
        .enabled(if: slashCommandRealProviderEnabled, "Set RUN_REAL_PROVIDERS=1 to run real-provider slash command smoke tests")
    )
    func realProviderFollowsProviderAssistedSlashCommandContexts() async throws {
        try await SlashCommandLiveProviderProbe.run()
    }
}

private enum SlashCommandLiveProviderProbe {
    private static let environment = ProcessInfo.processInfo.environment

    private struct RuntimeSelection {
        var runtimeCase: E2ETestSupport.RuntimeCase
        var executablePath: String
    }

    private struct ActionProbe {
        var command: String
        var expectedAction: String
        var userPrompt: String
        var context: String
        var validate: ([String: Any]) -> Void
    }

    static func run() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slash-command-real-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = try #require(
            selectedRuntime(),
            "RUN_REAL_PROVIDERS was set, but no runnable real provider utility runtime was found"
        )
        let configuration = utilityConfiguration(for: selection, root: root)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        print("Slash command real-provider smoke runtime=\(selection.runtimeCase.runtimeID.rawValue) executable=\(selection.executablePath)")

        try await E2ETestSupport.withLiveProviderSlot {
            for probe in actionProbes {
                try await assertActionProbe(probe, workspacePath: workspace.path, configuration: configuration)
            }
            try await assertRecapProbe(workspacePath: workspace.path, configuration: configuration)
        }
    }

    private static var actionProbes: [ActionProbe] {
        let templateID = "11111111-2222-3333-4444-555555555555"
        return [
            ActionProbe(
                command: "/skill",
                expectedAction: "create_skill",
                userPrompt: """
                /skill Create a skill named Slash Smoke Skill. It should help review logs. Allowed tools: Read and Grep. \
                Do not ask follow-up questions; output the final JSON action now.
                """,
                context: """
                The user wants to create a new Skill for their workspace.
                When ready, output exactly one JSON object and no prose:
                {"action":"create_skill","name":"Slash Smoke Skill","behavior":"Review logs and identify risky findings.","allowed":["Read","Grep"],"blocked":[]}
                """
            ) { object in
                #expect(nonEmptyString(object["name"])?.localizedCaseInsensitiveContains("slash") == true)
                #expect(nonEmptyString(object["behavior"]) != nil)
                #expect(stringList(object["allowed"]).contains("Read"))
            },
            ActionProbe(
                command: "/tool",
                expectedAction: "create_tool",
                userPrompt: """
                /tool Create an MCP tool named slash-smoke-search with command mcp__linear__search_issues and description Search Linear issues. \
                Do not ask follow-up questions; output the final JSON action now.
                """,
                context: """
                The user wants to create a new Tool for their workspace.
                When ready, output exactly one JSON object and no prose:
                {"action":"create_tool","name":"slash-smoke-search","type":"mcp","command":"mcp__linear__search_issues","description":"Search Linear issues."}
                """
            ) { object in
                #expect(nonEmptyString(object["name"])?.localizedCaseInsensitiveContains("slash") == true)
                #expect(nonEmptyString(object["type"]) == "mcp")
                #expect(nonEmptyString(object["command"]) == "mcp__linear__search_issues")
            },
            ActionProbe(
                command: "/connector",
                expectedAction: "create_connector",
                userPrompt: """
                /connector Create a Jira connector named Slash Smoke Jira using base URL https://jira.example.test and auth method none. \
                Do not ask follow-up questions; output the final JSON action now.
                """,
                context: """
                The user wants to create a new Connector for their workspace.
                When ready, output exactly one JSON object and no prose:
                {"action":"create_connector","name":"Slash Smoke Jira","serviceType":"jira","baseURL":"https://jira.example.test","authMethod":"none","credentials":{}}
                """
            ) { object in
                #expect(nonEmptyString(object["serviceType"]) == "jira")
                #expect(nonEmptyString(object["baseURL"]) == "https://jira.example.test")
                #expect(nonEmptyString(object["authMethod"]) == "none")
            },
            ActionProbe(
                command: "/template",
                expectedAction: "use_template",
                userPrompt: """
                /template Use the available template to create a task titled Slash Template Task with variable topic set to slash commands. \
                Do not ask follow-up questions; output the final JSON action now.
                """,
                context: """
                The user wants to create a task from a template. Available templates:
                - Slash Smoke Template: Create a task about {{topic}}

                Template IDs (in same order): \(templateID)

                When ready, output exactly one JSON object and no prose:
                {"action":"use_template","templateID":"\(templateID)","taskTitle":"Slash Template Task","variables":{"topic":"slash commands"}}
                """
            ) { object in
                #expect(nonEmptyString(object["templateID"]) == templateID)
                #expect(nonEmptyString(object["taskTitle"]) == "Slash Template Task")
                let variables = object["variables"] as? [String: Any]
                #expect(nonEmptyString(variables?["topic"]) == "slash commands")
            },
            ActionProbe(
                command: "/routine",
                expectedAction: "create_schedule",
                userPrompt: """
                /routine Create a daily routine named Slash Smoke Routine that reviews open PR comments at 9:15 every day. \
                Do not ask follow-up questions; output the final JSON action now.
                """,
                context: """
                The user wants to create a new Routine for their workspace.
                When ready, output exactly one JSON object and no prose:
                {"action":"create_schedule","name":"Slash Smoke Routine","description":"Review open PR comments","instructions":"Review open PR comments and summarize blockers.","scheduleType":"daily","dailyHour":9,"dailyMinute":15}
                """
            ) { object in
                #expect(nonEmptyString(object["name"])?.localizedCaseInsensitiveContains("routine") == true)
                #expect(nonEmptyString(object["scheduleType"]) == "daily")
                #expect(nonEmptyString(object["instructions"]) != nil || nonEmptyString(object["goal"]) != nil)
            }
        ]
    }

    private static func assertActionProbe(
        _ probe: ActionProbe,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration
    ) async throws {
        let result = await AgentUtilityRuntimeRunner.runPrompt(
            slashActionPrompt(for: probe, workspacePath: workspacePath),
            workspacePath: workspacePath,
            configuration: configuration,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            throw SlashCommandLiveProviderProbeFailure.providerPromptFailed(
                command: probe.command,
                detail: result.failureDetail
            )
        }
        let response = result.output
        print("\(probe.command) provider response: \(LiveProviderDiagnostics.redacted(String(response.prefix(800))))")

        let object = try jsonObject(from: response)
        #expect(nonEmptyString(object["action"]) == probe.expectedAction)
        probe.validate(object)
    }

    private static func assertRecapProbe(
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration
    ) async throws {
        let result = await AgentUtilityRuntimeRunner.runPrompt(
            recapPrompt(workspacePath: workspacePath),
            workspacePath: workspacePath,
            configuration: configuration,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            throw SlashCommandLiveProviderProbeFailure.providerPromptFailed(
                command: "/recap",
                detail: result.failureDetail
            )
        }
        let response = result.output
        let normalized = response.lowercased()
        print("/recap provider response: \(LiveProviderDiagnostics.redacted(String(response.prefix(800))))")
        #expect(!response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!normalized.contains("```json"))
        #expect(normalized.contains("intent") || normalized.contains("progress") || normalized.contains("next"))
    }

    private static func slashActionPrompt(for probe: ActionProbe, workspacePath: String) -> String {
        """
        You are ASTRA's headless real-provider slash command smoke test.
        Working directory: \(workspacePath)

        The user selected \(probe.command). Follow the slash command context exactly.
        Return exactly one JSON object. Do not use markdown fences. Do not include prose.

        Slash command context:
        \(probe.context)

        User:
        \(probe.userPrompt)

        Assistant:
        """
    }

    private static func recapPrompt(workspacePath: String) -> String {
        """
        You are ASTRA's headless real-provider slash command smoke test.
        Working directory: \(workspacePath)

        Conversation:
        User: We are polishing the slash command menu.
        Assistant: We exposed /mcp and tightened the menu presentation.
        User: /recap

        The user selected /recap. Produce a concise markdown recap with sections such as Intent, Progress, and Next steps.
        Do not output JSON. Do not ask follow-up questions.

        Assistant:
        """
    }

    private static func selectedRuntime() -> RuntimeSelection? {
        for runtimeCase in E2ETestSupport.runtimeCases(environment: environment) {
            guard let executablePath = executablePath(for: runtimeCase.runtimeID),
                  FileManager.default.isExecutableFile(atPath: executablePath),
                  LiveProviderReadiness.check(runtimeID: runtimeCase.runtimeID, executablePath: executablePath) == nil else {
                continue
            }
            return RuntimeSelection(runtimeCase: runtimeCase, executablePath: executablePath)
        }
        return nil
    }

    private static func utilityConfiguration(
        for selection: RuntimeSelection,
        root: URL
    ) -> AgentUtilityRuntimeConfiguration {
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(selection.executablePath, for: selection.runtimeCase.runtimeID)
        if selection.runtimeCase.runtimeID == .copilotCLI {
            settings.setHomeDirectory(root.appendingPathComponent("copilot-home", isDirectory: true).path, for: .copilotCLI)
        }
        return AgentUtilityRuntimeConfiguration(
            runtime: selection.runtimeCase.runtimeID,
            model: selection.runtimeCase.model,
            timeoutSeconds: TimeInterval(environment["REAL_PROVIDER_SLASH_TIMEOUT"] ?? "") ?? 60,
            providerSettings: settings
        )
    }

    private static func executablePath(for runtimeID: AgentRuntimeID) -> String? {
        let detected: String
        switch runtimeID {
        case .claudeCode:
            detected = RuntimePathResolver.detectClaudePath()
        case .copilotCLI:
            detected = RuntimePathResolver.detectCopilotPath()
        case .antigravityCLI:
            detected = RuntimePathResolver.detectAntigravityPath()
        case .cursorCLI:
            detected = RuntimePathResolver.detectCursorPath()
        case .openCodeCLI:
            detected = RuntimePathResolver.detectOpenCodePath()
        default:
            return nil
        }
        if FileManager.default.isExecutableFile(atPath: detected) {
            return detected
        }
        return findExecutable(executableName(for: runtimeID))
    }

    private static func executableName(for runtimeID: AgentRuntimeID) -> String {
        switch runtimeID {
        case .claudeCode:
            return "claude"
        case .copilotCLI:
            return "copilot"
        case .antigravityCLI:
            return "agy"
        case .cursorCLI:
            return "cursor-agent"
        case .openCodeCLI:
            return "opencode"
        default:
            return runtimeID.rawValue
        }
    }

    private static func findExecutable(_ name: String) -> String? {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/\(name)" }
            + [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "\(NSHomeDirectory())/.local/bin/\(name)",
                "\(NSHomeDirectory())/.npm-global/bin/\(name)"
            ]
        var seen: Set<String> = []
        return candidates.first { candidate in
            guard !seen.contains(candidate) else { return false }
            seen.insert(candidate)
            return FileManager.default.isExecutableFile(atPath: candidate)
        }
    }

    private static func jsonObject(from response: String) throws -> [String: Any] {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start <= end else {
            Issue.record("Expected provider response to contain a JSON object: \(response)")
            return [:]
        }
        let json = String(response[start...end])
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return string?.isEmpty == false ? string : nil
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let values = value as? [String] {
            return values
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        if let value = nonEmptyString(value) {
            return [value]
        }
        return []
    }
}

private enum SlashCommandLiveProviderProbeFailure: Error, CustomStringConvertible {
    case providerPromptFailed(command: String, detail: String)

    var description: String {
        switch self {
        case .providerPromptFailed(let command, let detail):
            return "\(command) provider prompt failed: \(detail)"
        }
    }
}
