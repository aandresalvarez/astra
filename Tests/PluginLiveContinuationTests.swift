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
        Validation in this disposable workspace only. Run exactly these two commands,
        as two separate Bash calls. Do not combine or reformat them, or call other tools:

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
            try #require(environment["CLAUDE_CODE_USE_VERTEX"] == "1"
                && environment["ANTHROPIC_VERTEX_PROJECT_ID"] == project,
                "Set the Vertex launch environment as well as the readiness configuration")
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
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.liveApprovalsEnabled = false
        for turn in 0..<3 {
            let events = try await E2ETestSupport.withLiveProviderSlot {
                if turn == 0 { return await harness.execute(task: task, worker: worker) }
                return await harness.continueTask(task: task, message: goal, worker: worker)
            }
            if task.status != .completed {
                print("PLUGIN_LIVE_FAILURE stop=\(task.runs.last?.stopReason ?? "none") events=\(task.events.filter { $0.type.contains("error") || $0.type.contains("blocked") || $0.type.contains("permission") }.map { LiveProviderDiagnostics.redacted(String($0.payload.suffix(800))) })")
            }
            try #require(task.status == .completed, "Validation run did not complete: \((task.runs.last?.output ?? "No run output").suffix(800))")
            try requireValidationTools(events)
            try #require(task.runs.count == turn + 1)
            try #require(task.runs.allSatisfy { $0.status == .completed && $0.output.contains("ASTRA_PLUGIN_TOOL_OK") })
            try #require(try Data(contentsOf: sshFile) == originalSSH)
            print("PLUGIN_LIVE_ACCEPTANCE completed_turn=\(turn + 1) tools=true ssh_config_preserved=true")
        }
        let queue = TaskQueue(poolSize: 1, workerFactory: { worker }, sandboxEnforcementProvider: { .strict })
        for successor in 0..<2 {
            let next = AgentTask(title: "Successor isolated task", goal: goal, workspace: workspace,
                                 tokenBudget: 200_000, model: model)
            next.runtimeID = AgentRuntimeID.claudeCode.rawValue
            next.status = .queued
            harness.context.insert(next)
            try harness.context.save()
            let submission = try ExecutionRequestSubmissionService.submitInitial(for: next, into: harness.context).get()
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: harness.context))
            if successor == 0 {
                // Native tools retain uncertainty even after provider exit. Use
                // the normal one-time workspace decision, never erase its journal.
                let preview = try RuntimeWorkspaceContinuation.preview(task: next, request: request, context: harness.context)
                try RuntimeWorkspaceContinuation.authorize(preview, task: next, request: request,
                    context: harness.context, rememberWorkspace: true)
            }
            let events = try await E2ETestSupport.withLiveProviderSlot {
                var events: [ParsedEvent] = []
                await queue.executeTask(next, modelContext: harness.context, executionRequestID: request.id) {
                    events.append($0)
                }
                return events
            }
            try #require(next.status == .completed && next.runs.count == 1)
            try requireValidationTools(events)
            try #require(task.runs.count == 3 && task.runs.allSatisfy { $0.status == .completed })
            try #require(try Data(contentsOf: sshFile) == originalSSH)
            print("PLUGIN_LIVE_ACCEPTANCE successor=\(successor + 1) completed=true reused_workspace_authorization=\(successor > 0)")
        }
        let receipts = try String(contentsOf: harness.rootURL.appendingPathComponent("guard-receipts.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        try #require(receipts.count == 10 && receipts.allSatisfy { $0?["allowed"] as? Bool == true }
            && receipts.compactMap { $0?["command_index"] as? Int } == [0, 1, 0, 1, 0, 1, 0, 1, 0, 1])
        print("PLUGIN_LIVE_ACCEPTANCE successor_tasks_completed=2 prior_runs_preserved=3 guarded_tool_calls=10")
    }

    private func requireValidationTools(_ events: [ParsedEvent]) throws {
        let commands = events.compactMap { event -> String? in
            guard case .toolUse(let name, _, let input) = event, name == "Bash" else { return nil }
            // Runtime callbacks deliberately expose a summary, not raw tool input.
            return input?["summary"] as? String
        }
        try #require(commands.count == 2)
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
        let receipt = harness.rootURL.appendingPathComponent("guard-receipts.jsonl")
        let guardSource = """
        import json, sys
        try:
            with open(sys.argv[1]) as f:
                allowed = json.load(f)
            event = json.load(sys.stdin)
            permitted = event.get("tool_name") == "Bash" and event.get("tool_input", {}).get("command") in allowed
            with open(sys.argv[2], "a") as f:
                f.write(json.dumps({"allowed": permitted, "command_index": allowed.index(event["tool_input"]["command"]) if permitted else -1}) + "\\n")
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                "permissionDecision": "allow" if permitted else "deny",
                "permissionDecisionReason": "Isolated validation allows only its two exact fixture reads"}}))
        except BaseException:
            print("Validation tool guard could not verify the command", file=sys.stderr)
            sys.exit(2)
        """
        try guardSource.write(to: guardURL, atomically: true, encoding: .utf8)
        let settings = harness.rootURL.appendingPathComponent("isolated-settings.json")
        let hook = "/usr/bin/python3 \(HeadlessChatScenarioTests.shQuote(guardURL.path)) \(HeadlessChatScenarioTests.shQuote(allowlist.path)) \(HeadlessChatScenarioTests.shQuote(receipt.path)) || exit 2"
        let json: [String: Any] = ["hooks": ["PreToolUse": [["matcher": ".*", "hooks": [["type": "command", "command": hook]]]]],
            "permissions": ["defaultMode": "dontAsk", "allow": [] as [String]]]
        try JSONSerialization.data(withJSONObject: json).write(to: settings)
        let wrapper = """
        #!/usr/bin/python3
        import os, sys
        cli = \(String(data: try JSONSerialization.data(withJSONObject: [cli], options: [.withoutEscapingSlashes]), encoding: .utf8)!)[0]
        settings = \(String(data: try JSONSerialization.data(withJSONObject: [settings.path], options: [.withoutEscapingSlashes]), encoding: .utf8)!)[0]
        # Keep provider session history and settings in the disposable root too.
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(os.path.dirname(cli), "claude-config")
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"], exist_ok=True)
        args = sys.argv[1:]
        if args and args[0] in ("--version", "auth"):
            os.execv(cli, [cli] + args)
        # Remove blanket shell grants. The hook must attest every accepted
        # fixture command; failures return exit 2 and the test checks receipts.
        filtered = []
        i = 0
        while i < len(args):
            if args[i] in ("--allowedTools", "--allowed-tools", "--tools"):
                i += 1
                while i < len(args) and not args[i].startswith("--"):
                    i += 1
                continue
            if args[i] == "--permission-mode":
                i += 2
                continue
            if args[i] in ("--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"):
                # ASTRA tests Auto admission, while this fixture keeps the
                # provider constrained by strict OS scope and its command hook.
                i += 1
                continue
            filtered.append(args[i])
            i += 1
        os.execv(cli, [cli] + filtered + ["--restricted", "--setting-sources", "", "--settings", settings,
            "--permission-mode", "dontAsk", "--tools", "Bash", "--disable-slash-commands", "--no-chrome"])
        """
        return try harness.writeExecutable(named: "isolated-claude", script: wrapper)
    }

}
