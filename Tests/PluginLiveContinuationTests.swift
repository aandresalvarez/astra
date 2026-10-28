import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Opt-in, account-backed acceptance. All ASTRA state and workspace files are
/// synthetic. SSH is configured and resolved by the real client (-G); this
/// never connects to a user's remote host or reads production credentials.
@MainActor @Suite(.serialized)
struct PluginLiveContinuationTests {
    @Test("Real provider tools continue across tasks after isolated Add with SSH configured",
          .enabled(if: ProcessInfo.processInfo.environment["RUN_PLUGIN_LIVE_VALIDATION"] == "1"))
    func toolsAndSSHAcrossTasks() async throws {
        let support = AppChannelStoragePaths.applicationSupportDirectory().path
        try #require(AppChannel.current == .development && support.contains("/ASTRA-TestRuns/"))
        let cli = try #require(ProcessInfo.processInfo.environment["PLUGIN_LIVE_CLAUDE_PATH"])
        let harness = try HeadlessChatHarness(persistentStore: true)
        defer { harness.cleanup() }
        harness.context.autosaveEnabled = false
        let model = LiveProviderTestConfiguration().claudeModel
        let task = harness.makeTask(runtime: .claudeCode, goal: "Run the isolated terminal validation", model: model)
        let workspace = try #require(task.workspace)
        let input = harness.workspaceURL.appendingPathComponent("validation-input.txt")
        try "ASTRA_PLUGIN_TOOL_OK\n".write(to: input, atomically: true, encoding: .utf8)
        let sshConfig = harness.workspaceURL.appendingPathComponent("fixture-ssh-config")
        try "Host fixture\n  HostName 127.0.0.1\n  User fixture\n  Port 22222\n  BatchMode yes\n".write(to: sshConfig, atomically: true, encoding: .utf8)
        let ssh = SSHConnection(name: "Isolated SSH", host: "127.0.0.1", user: "fixture", port: 22222)
        SSHConnectionManager.save([ssh], workspacePath: workspace.primaryPath)
        let sshFile = URL(fileURLWithPath: SSHConnectionManager.connectionsFilePath(for: workspace.primaryPath))
        let originalSSH = try Data(contentsOf: sshFile)
        let commands = ["/bin/cat \(HeadlessChatScenarioTests.shQuote(input.path))",
            "/usr/bin/ssh -G -F \(HeadlessChatScenarioTests.shQuote(sshConfig.path)) fixture"]
        // The strict profile admits the configured launcher and fixture root;
        // keep the real standalone CLI binary inside that root too, rather than
        // granting the provider access to its user's installation directory.
        let executable = harness.rootURL.appendingPathComponent("real-claude")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: cli).resolvingSymlinksInPath(), to: executable)
        let launcher = try guardedLauncher(cli: executable.path, commands: commands, harness: harness)
        let goal = """
        Validation in this disposable workspace only. Use the terminal tool to run:
        /bin/cat \(HeadlessChatScenarioTests.shQuote(input.path))
        Then run /usr/bin/ssh -G -F \(HeadlessChatScenarioTests.shQuote(sshConfig.path)) fixture
        Verify hostname 127.0.0.1 and port 22222. This only prints SSH configuration;
        do not connect to SSH, use any other service, or modify files.
        After both commands succeed, answer ASTRA_PLUGIN_TOOL_OK.
        """
        task.goal = goal
        try harness.context.save()
        // An outstanding task edit must survive Add without being committed.
        task.title = "Pending validation title"
        var package = PluginOperationsTests.package(version: "1.0.0")
        package.id = "isolated-terminal-validation"
        package.name = "Isolated terminal validation"
        package.connectors = []; package.localTools = []; package.templates = []
        package.skills[0].allowedTools = ["Read", "Bash"]
        package.skills[0].environmentKeys = []; package.skills[0].environmentValues = []
        package.skills[0].behaviorInstructions = "Use terminal tools only for the user's explicit validation commands."
        try CapabilityCatalogActionService().add(package, workspace: workspace, modelContext: harness.context,
            policyContext: .currentUser(workspace: workspace, approvalRecords: [], packPolicy: .empty), traceID: "isolated-live-add")
        #expect(task.title == "Pending validation title")
        try harness.context.save()
        let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: { _ in
            ExecutionSandboxSettings(enforcement: .strict, readScope: .enforce)
        }, hostControlBrokerSessionManager: HostControlBrokerSessionManager(
            expectedHelperPath: BuiltProductLocator.executablePath(named: "astra-host-control") ?? ""))
        var provider = ProviderSettingsSnapshot.headlessScenario
        provider.providerSettings.setExecutablePath(launcher, for: .claudeCode)
        let environment = ProcessInfo.processInfo.environment
        if let project = environment["PLUGIN_LIVE_VERTEX_PROJECT"] {
            provider.claudeProvider = .vertex
            provider.vertexProjectID = project
            provider.vertexRegion = environment["PLUGIN_LIVE_VERTEX_REGION"] ?? "global"
            provider.vertexOpusModel = environment["PLUGIN_LIVE_VERTEX_OPUS"] ?? model
            provider.vertexSonnetModel = model
            provider.vertexHaikuModel = environment["PLUGIN_LIVE_VERTEX_HAIKU"] ?? model
        }
        let capturedProvider = provider
        let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { capturedProvider })
        worker.supervisionEnabled = false
        worker.claudePath = launcher
        worker.timeoutSeconds = 180
        worker.permissionPolicy = .restricted
        worker.liveApprovalsEnabled = false
        for turn in 0..<3 {
            let events = try await E2ETestSupport.withLiveProviderSlot {
                if turn == 0 { return await harness.execute(task: task, worker: worker) }
                return await harness.continueTask(task: task, message: goal, worker: worker)
            }
            if task.status != .completed {
                print("PLUGIN_LIVE_FAILURE events=\(task.events.filter { $0.type.contains("error") || $0.type.contains("blocked") }.map { String($0.payload.suffix(1200)) })")
            }
            try #require(task.status == .completed, "Validation run did not complete: \((task.runs.last?.output ?? "No run output").suffix(800))")
            try requireValidationTools(events, allowedCommands: commands)
            try #require(task.runs.count == turn + 1)
            try #require(task.runs.allSatisfy { $0.status == .completed && $0.output.contains("ASTRA_PLUGIN_TOOL_OK") })
            try #require(try Data(contentsOf: sshFile) == originalSSH)
            print("PLUGIN_LIVE_ACCEPTANCE completed_turn=\(turn + 1) tools=true ssh_config_preserved=true")
        }
        let next = AgentTask(title: "Second isolated task", goal: goal, workspace: workspace,
                             tokenBudget: 200_000, model: model)
        next.runtimeID = AgentRuntimeID.claudeCode.rawValue
        next.status = .queued
        harness.context.insert(next)
        try harness.context.save()
        let events = try await E2ETestSupport.withLiveProviderSlot { await harness.execute(task: next, worker: worker) }
        try requireValidationTools(events, allowedCommands: commands)
        try #require(next.status == .completed && next.runs.count == 1)
        try #require(task.runs.count == 3 && task.runs.allSatisfy { $0.status == .completed })
        try #require(try Data(contentsOf: sshFile) == originalSSH)
        print("PLUGIN_LIVE_ACCEPTANCE second_task_completed=true prior_runs_preserved=3")
    }

    private func requireValidationTools(_ events: [ParsedEvent], allowedCommands: [String]) throws {
        let commands = events.compactMap { event -> String? in
            guard case .toolUse(let name, _, let input) = event, name == "Bash" else { return nil }
            return input?["command"] as? String
        }
        try #require(Set(commands).isSubset(of: Set(allowedCommands)))
        try #require(commands.contains { $0.contains("/bin/cat") && $0.contains("validation-input.txt") })
        try #require(commands.contains { $0.contains("/usr/bin/ssh -G") && $0.contains("fixture-ssh-config") })
        try #require(!events.contains { event in
            if case .toolUse(let name, _, _) = event { return name != "Bash" }
            return false
        })
        let results = events.compactMap { event -> String? in
            guard case .toolResult(_, let content, let isError) = event, !isError else { return nil }
            return content
        }
        try #require(results.contains { $0.contains("ASTRA_PLUGIN_TOOL_OK") })
        try #require(results.contains { $0.contains("hostname 127.0.0.1") && $0.contains("port 22222") })
    }


    /// A pre-tool hook is an admission check, not an instruction to the model.
    /// Ignore all user/project/local settings and reject every command except
    /// the two fixture reads, including shell concatenations or other tools.
    private func guardedLauncher(cli: String, commands: [String], harness: HeadlessChatHarness) throws -> String {
        let allowlist = harness.rootURL.appendingPathComponent("allowed-commands.json")
        try JSONSerialization.data(withJSONObject: commands).write(to: allowlist)
        let guardURL = harness.rootURL.appendingPathComponent("tool-guard.py")
        let guardSource = """
        import json, sys
        with open(sys.argv[1]) as f:
            allowed = json.load(f)
        event = json.load(sys.stdin)
        permitted = event.get("tool_name") == "Bash" and event.get("tool_input", {}).get("command") in allowed
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
            "permissionDecision": "allow" if permitted else "deny",
            "permissionDecisionReason": "Isolated validation allows only its two exact fixture reads"}}))
        """
        try guardSource.write(to: guardURL, atomically: true, encoding: .utf8)
        let settings = harness.rootURL.appendingPathComponent("isolated-settings.json")
        let hook = "/usr/bin/python3 \(HeadlessChatScenarioTests.shQuote(guardURL.path)) \(HeadlessChatScenarioTests.shQuote(allowlist.path))"
        let json: [String: Any] = ["hooks": ["PreToolUse": [["matcher": ".*", "hooks": [["type": "command", "command": hook]]]]],
            "permissions": ["defaultMode": "dontAsk", "allow": [] as [String]]]
        try JSONSerialization.data(withJSONObject: json).write(to: settings)
        let wrapper = """
        #!/usr/bin/python3
        import os, sys
        cli = \(String(data: try JSONSerialization.data(withJSONObject: [cli]), encoding: .utf8)!)[0]
        settings = \(String(data: try JSONSerialization.data(withJSONObject: [settings.path]), encoding: .utf8)!)[0]
        args = sys.argv[1:]
        if args and args[0] in ("--version", "auth"):
            os.execv(cli, [cli] + args)
        # Only the hook can permit a tool. If it cannot run, dontAsk denies
        # the call; no generic Bash allow survives the original launch args.
        filtered = []
        i = 0
        while i < len(args):
            if args[i] in ("--allowedTools", "--allowed-tools"):
                i += 1
                while i < len(args) and not args[i].startswith("--"):
                    i += 1
                continue
            if args[i] == "--permission-mode":
                i += 2
                continue
            if args[i] in ("--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"):
                raise SystemExit("Unconfined validation launch refused")
            filtered.append(args[i])
            i += 1
        os.execv(cli, [cli] + filtered + ["--restricted", "--setting-sources", "", "--settings", settings,
            "--permission-mode", "dontAsk", "--disable-slash-commands", "--no-chrome"])
        """
        return try harness.writeExecutable(named: "isolated-claude", script: wrapper)
    }

}
