import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

extension HeadlessChatScenarioTests {
    @Test("Changing runtime from Claude to Copilot starts a clean provider run")
    func changingRuntimeFromClaudeToCopilotStartsCleanProviderRun() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude first answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude first answer","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"session.mcp_servers_loaded","session":{"id":"copilot-session-1","model":"gpt-5"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Copilot follow-up answer"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":4,"output_tokens":6},"duration_ms":9,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Start with Claude", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "claude-session-1")

        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.model = "gpt-5"
        _ = await harness.continueTask(task: task, message: "Continue with Copilot", worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(runs[0].runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(runs[0].providerSessionId == "claude-session-1")
        #expect(runs[1].runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(runs[1].providerSessionId == "copilot-session-1")
        #expect(runs[1].providerSessionId != "claude-session-1")
        #expect(runs[1].output == "Copilot follow-up answer")
        #expect(task.sessionId == "copilot-session-1")
        #expect(task.status == .completed)
    }

    @Test("Claude follow-up attaches native session while sending rebuilt ASTRA prompt")
    func claudeFollowUpAttachesNativeSessionWithRebuiltPrompt() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("claude-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude answer","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """, argsFile: argsFile)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Keep ASTRA state authoritative", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "claude-session-1")

        _ = await harness.continueTask(
            task: task,
            message: "Use the prior context and continue deterministically",
            worker: worker
        )

        let rawArgs = try String(contentsOf: argsFile, encoding: .utf8)
        let args = rawArgs
            .split(separator: "\n")
            .map(String.init)
        let resumeIndex = try #require(args.firstIndex(of: "--resume"))
        #expect(args.count > resumeIndex + 1)
        #expect(rawArgs.contains("Context Capsule v2:"))
        #expect(rawArgs.contains("Context Source Index:"))
        #expect(rawArgs.contains("Native Continuation Policy:"))
        #expect(rawArgs.contains("Context Capsule v2 and Context Source Index above remain authoritative"))
        #expect(rawArgs.contains("User's follow-up request:\nUse the prior context and continue deterministically"))
        if args.count > resumeIndex + 1 {
            #expect(args[resumeIndex + 1] == "claude-session-1")
        }
        #expect(task.runs.count == 2)
        #expect(task.status == .completed)
    }

    @Test("Queue-admitted follow-up starts from a terminal task without caller prewriting running")
    func queueAdmittedFollowUpOwnsRunningTransition() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"queue-session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Queue answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Queue answer","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )
        let task = harness.makeTask(runtime: .claudeCode, goal: "Start through queue", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.status == .completed)

        let queue = TaskQueue(poolSize: 1) {
            AgentRuntimeWorker.scenarioWorker()
        }
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(claudePath, for: .claudeCode)
        queue.applySettings(
            claudePath: claudePath,
            providerSettings: settings,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 5,
            validationModel: "claude-sonnet-4-6"
        )

        let didStart = await queue.continueSession(
            task: task,
            message: "Continue through queue",
            modelContext: harness.context
        )

        #expect(didStart)
        #expect(task.runs.count == 2)
        #expect(task.events.contains { $0.type == "user.message" && $0.payload == "Continue through queue" })
        #expect(task.status == .completed)
    }

    @Test("Claude follow-up skips native session when launch signature changes")
    func claudeFollowUpSkipsNativeSessionWhenLaunchSignatureChanges() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("claude-signature-change-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude answer","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """, argsFile: argsFile)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Investigate cache behavior", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "claude-session-1")

        let cacheSkill = Skill(
            name: "Cache Agent",
            skillDescription: "Investigate cache behavior and cache policy",
            allowedTools: ["Read"],
            behaviorInstructions: "Use cache-specific diagnostics when discussing cache behavior."
        )
        cacheSkill.workspace = task.workspace
        harness.context.insert(cacheSkill)
        task.skills = [cacheSkill]
        try harness.context.save()

        _ = await harness.continueTask(
            task: task,
            message: "Continue after enabling the cache capability",
            worker: worker
        )

        let rawArgs = try String(contentsOf: argsFile, encoding: .utf8)
        let args = rawArgs
            .split(separator: "\n")
            .map(String.init)
        #expect(!args.contains("--resume"))
        #expect(rawArgs.contains("Context Capsule v2:"))
        #expect(rawArgs.contains("User's follow-up request:\nContinue after enabling the cache capability"))
        #expect(task.events.filter { $0.type == "astra.provider_launch_signature" }.count == 2)
        #expect(task.runs.count == 2)
        #expect(task.status == .completed)
    }

    @Test("Claude follow-up keeps native session after a permission approval grant")
    func claudeFollowUpKeepsNativeSessionAfterPermissionGrant() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("claude-grant-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude answer","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """, argsFile: argsFile)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Research the API surface", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "claude-session-1")

        let recorded = TaskRuntimePermissionGrants.record(
            grants: [.providerTool(name: "WebSearch")],
            providerID: .claudeCode,
            task: task,
            modelContext: harness.context,
            source: "test_user_approval"
        )
        #expect(!recorded.isEmpty)
        try harness.context.save()

        _ = await harness.continueTask(
            task: task,
            message: "Continue with the newly approved access",
            worker: worker
        )

        let rawArgs = try String(contentsOf: argsFile, encoding: .utf8)
        let args = rawArgs
            .split(separator: "\n")
            .map(String.init)
        let resumeIndex = try #require(args.firstIndex(of: "--resume"))
        #expect(args.count > resumeIndex + 1)
        if args.count > resumeIndex + 1 {
            #expect(args[resumeIndex + 1] == "claude-session-1")
        }
        #expect(task.runs.count == 2)
        #expect(task.status == .completed)
    }

    @Test("Claude no-progress follow-up starts a clean provider session")
    func claudeNoProgressFollowUpStartsCleanProviderSession() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("claude-clean-retry-args.txt")
        let countFile = harness.rootURL.appendingPathComponent("claude-clean-retry-count")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            count=0
            if [ -f '\(countFile.path)' ]; then
              count=$(cat '\(countFile.path)')
            fi
            count=$((count + 1))
            printf '%s\\n' "$count" > '\(countFile.path)'
            if [ "$count" = "1" ]; then
              printf '%s\\n' '{"type":"system","subtype":"init","session_id":"stuck-claude-session","model":"claude-sonnet-4-6"}'
              sleep 60
              exit 0
            fi
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"clean-claude-session","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Recovered answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Recovered answer","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """, argsFile: argsFile)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Create a standalone artifact", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)
        worker.timeoutSeconds = 2

        _ = await harness.execute(task: task, worker: worker)

        let failedRun = try #require(task.runs.first)
        #expect(failedRun.status == .failed)
        #expect(failedRun.stopReason == "provider_no_semantic_progress")
        #expect(failedRun.output.isEmpty)
        #expect(task.sessionId == "stuck-claude-session")

        _ = await harness.continueTask(
            task: task,
            message: "Continue with a clean retry",
            worker: worker
        )

        let rawArgs = try String(contentsOf: argsFile, encoding: .utf8)
        let args = rawArgs
            .split(separator: "\n")
            .map(String.init)
        #expect(!args.contains("--resume"))
        #expect(rawArgs.contains("Context Capsule v2:"))
        #expect(rawArgs.contains("User's follow-up request:\nContinue with a clean retry"))
        #expect(task.sessionId == "clean-claude-session")
        #expect(task.runs.count == 2)
        #expect(task.runs.sorted { $0.startedAt < $1.startedAt }.last?.output == "Recovered answer")
        #expect(task.status == .completed)
    }

    @Test("Claude launch prompt prunes irrelevant Graph Mail capability for artifact task")
    func claudeLaunchPromptPrunesIrrelevantGraphMailCapabilityForArtifactTask() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "createa web page wit a masterball (similar to rubicks cube but as aball ) with a solver in javascript",
            model: "claude-sonnet-4-6"
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            all_args="$*"
            case "$all_args" in
              *"Stanford Graph Mail Agent"*|*"stanford-graph-mail"*|*"create rules"*)
                printf '%s\\n' 'Prompt leaked irrelevant Graph Mail capability' >&2
                exit 42
                ;;
            esac
            mkdir -p \(Self.shQuote(taskFolder))
            printf '%s\\n' '<!doctype html><html><body><h1>Created a clean Masterball solver page.</h1></body></html>' > \(Self.shQuote("\(taskFolder)/index.html"))
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"clean-capability-session","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Created a clean Masterball solver page."}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Created a clean Masterball solver page.","usage":{"input_tokens":7,"output_tokens":9}}'
            exit 0
            """)
        )

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Search and read locally signed-in Microsoft 365 mail via Graph PowerShell",
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["Write", "Edit"],
            behaviorInstructions: """
            You are a Stanford Graph Mail assistant. Use the `stanford-graph-mail` CLI via Bash.
            Read only. Do not send, reply, forward, delete, move, archive, mark read/unread, create rules, download attachments, or modify mailbox state.
            Do NOT use these tools: Write, Edit.
            """
        )
        mailSkill.workspace = task.workspace
        harness.context.insert(mailSkill)
        let mailTool = LocalTool(
            name: "stanford-graph-mail",
            toolDescription: "Read the locally signed-in Microsoft 365 mailbox",
            command: "stanford-graph-mail"
        )
        mailTool.skill = mailSkill
        harness.context.insert(mailTool)
        task.skills = [mailSkill]
        TaskCapabilitySnapshotter.capture(for: task)
        try harness.context.save()

        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)
        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Created a clean Masterball solver page.")
        #expect(!task.events.contains { $0.type == "skill.active" && $0.payload.contains("Stanford Graph Mail Agent") })
    }

    @Test("Changing runtime from Copilot to Claude starts a clean provider run")
    func changingRuntimeFromCopilotToClaudeStartsCleanProviderRun() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"session.mcp_servers_loaded","session":{"id":"copilot-session-1","model":"gpt-5"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Copilot first answer"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )
        let claudeArgsFile = harness.rootURL.appendingPathComponent("claude-switch-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-2","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude follow-up answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":13,"num_turns":1,"result":"Claude follow-up answer","usage":{"input_tokens":5,"output_tokens":7}}'
            exit 0
            """, argsFile: claudeArgsFile)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Start with Copilot", model: "gpt-5")
        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "copilot-session-1")

        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        task.model = "claude-sonnet-4-6"
        task.tokenBudget = 200_000
        _ = await harness.continueTask(task: task, message: "Continue with Claude", worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(runs[0].runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(runs[0].providerSessionId == "copilot-session-1")
        #expect(runs[1].runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(runs[1].providerSessionId == "claude-session-2")
        #expect(runs[1].providerSessionId != "copilot-session-1")
        #expect(runs[1].output == "Claude follow-up answer")
        #expect(task.sessionId == "claude-session-2")
        #expect(task.status == .completed)

        let rawClaudeArgs = try String(contentsOf: claudeArgsFile, encoding: .utf8)
        let claudeArgs = rawClaudeArgs
            .split(separator: "\n")
            .map(String.init)
        #expect(claudeArgs.contains("--resume") == false)
        #expect(claudeArgs.contains("copilot-session-1") == false)
        #expect(rawClaudeArgs.contains("User's follow-up request:\nContinue with Claude"))
    }

    // MARK: - Multi-turn conversation context preservation

    @Test("Copilot multi-turn follow-up prompt includes prior run output")
    func copilotMultiTurnPreservesContext() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("copilot-turn2-args.txt")
        let countFile = harness.rootURL.appendingPathComponent("copilot-ctx-count.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
                count=$((count + 1))
                printf '%s' "$count" > \(Self.shQuote(countFile.path))
                if [ "$count" = "1" ]; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"The capital of France is Paris."}}'
                else
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Follow-up answer"}}'
                fi
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":5,"output_tokens":5},"duration_ms":5,"turns":1}'
                exit 0
                """,
                argsFile: argsFile
            )
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "What is the capital of France?", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.runs.first?.output == "The capital of France is Paris.")

        // Clear args file so we only capture turn 2
        try? FileManager.default.removeItem(at: argsFile)
        _ = await harness.continueTask(task: task, message: "What about Germany?", worker: worker)

        let turn2Args = try String(contentsOf: argsFile, encoding: .utf8)
        // The follow-up prompt should include the original goal
        #expect(turn2Args.contains("capital of France"))
        // And the user's follow-up message
        #expect(turn2Args.contains("What about Germany?"))
        // And the prior response (either in "Previous responses" or transcript)
        #expect(turn2Args.contains("Paris"))
        #expect(task.runs.count == 2)
        #expect(task.status == .completed)
    }

    @Test("Claude multi-turn follow-up prompt includes prior run output")
    func claudeMultiTurnPreservesContext() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("claude-turn2-args.txt")
        let countFile = harness.rootURL.appendingPathComponent("claude-ctx-count.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
                count=$((count + 1))
                printf '%s' "$count" > \(Self.shQuote(countFile.path))
                if [ "$count" = "1" ]; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"ctx-sess","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"The speed of light is 299792458 m/s."}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"num_turns":1,"result":"The speed of light is 299792458 m/s.","usage":{"input_tokens":5,"output_tokens":10}}'
                else
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"ctx-sess","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Follow-up Claude answer"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"num_turns":1,"result":"Follow-up Claude answer","usage":{"input_tokens":10,"output_tokens":15}}'
                fi
                exit 0
                """,
                argsFile: argsFile
            )
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "What is the speed of light?", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.runs.first?.output == "The speed of light is 299792458 m/s.")

        try? FileManager.default.removeItem(at: argsFile)
        _ = await harness.continueTask(task: task, message: "Express that in km/h", worker: worker)

        let turn2Args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(turn2Args.contains("speed of light"))
        #expect(turn2Args.contains("Express that in km/h"))
        #expect(turn2Args.contains("299792458"))
        #expect(task.runs.count == 2)
        #expect(task.status == .completed)
    }

    @Test("Codex follow-up resumes the provider thread while sending rebuilt prompt")
    func codexFollowUpResumesProviderThread() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("codex-resume-args.txt")
        let codexPath = try harness.writeExecutable(
            named: "codex",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' 'codex-cli 0.50.0'
              exit 0
            fi
            printf '%s\\n' "$@" > '\(argsFile.path)'
            printf '%s\\n' '{"type":"thread.started","thread_id":"codex-thread-1"}'
            printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Codex answer"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":7}}'
            exit 0
            """
        )

        let task = harness.makeTask(runtime: .codexCLI, goal: "Trace the request flow", model: "gpt-5.5")
        let worker = harness.makeWorker(runtime: .codexCLI, executablePath: codexPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "codex-thread-1")
        #expect(task.runs.first?.providerSessionId == "codex-thread-1")

        _ = await harness.continueTask(task: task, message: "Continue from the prior thread", worker: worker)

        let rawArgs = try String(contentsOf: argsFile, encoding: .utf8)
        let args = rawArgs
            .split(separator: "\n")
            .map(String.init)
        let resumeIndex = try #require(args.firstIndex(of: "resume"))
        let sessionIndex = try #require(args.firstIndex(of: "codex-thread-1"))
        #expect(sessionIndex > resumeIndex)
        #expect(!args.contains("--color"))
        #expect(!args.contains("--cd"))
        #expect(!args.contains("--add-dir"))
        #expect(!args.contains("--sandbox"))
        #expect(rawArgs.contains("User's follow-up request:\nContinue from the prior thread"))
        #expect(task.runs.count == 2)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs[0].tokensUsed == 12)
        #expect(runs[1].tokensUsed == 12)
        #expect(task.tokensUsed == 24)
        #expect(task.status == .completed)
    }

    @Test("Antigravity multi-turn follow-up prompt includes prior run output")
    func antigravityMultiTurnPreservesContext() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("agy-turn2-args.txt")
        let countFile = harness.rootURL.appendingPathComponent("agy-ctx-count.txt")
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf '%s\\n' "$@" > '\(argsFile.path)'
            count="$(cat '\(countFile.path)' 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > '\(countFile.path)'
            if [ "$count" = "1" ]; then
              printf '%s\\n' 'Water boils at 100 degrees Celsius.'
            else
              printf '%s\\n' 'Follow-up Antigravity answer'
            fi
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "At what temperature does water boil?",
            model: "Gemini 3.5 Flash"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.runs.first?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Water boils at 100 degrees Celsius.")

        _ = await harness.continueTask(task: task, message: "What about in Fahrenheit?", worker: worker)

        let turn2Args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(turn2Args.contains("water boil") || turn2Args.contains("temperature"))
        #expect(turn2Args.contains("Fahrenheit"))
        #expect(turn2Args.contains("100 degrees") || turn2Args.contains("100"))
        #expect(task.runs.count == 2)
        #expect(task.status == .completed)
    }

    @Test("Cross-provider follow-up carries context from previous provider")
    func crossProviderFollowUpCarriesContext() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotArgsFile = harness.rootURL.appendingPathComponent("cross-copilot-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"cross-sess","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Pi is approximately 3.14159265."}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"num_turns":1,"result":"Pi is approximately 3.14159265.","usage":{"input_tokens":5,"output_tokens":10}}'
            exit 0
            """)
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Cross-provider follow-up done"}}'
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":5,"output_tokens":5},"duration_ms":5,"turns":1}'
                exit 0
                """,
                argsFile: copilotArgsFile
            )
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "What is the value of pi?", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.runs.first?.output == "Pi is approximately 3.14159265.")

        // Switch to Copilot for the follow-up
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.model = "gpt-5"
        _ = await harness.continueTask(task: task, message: "Now calculate pi squared", worker: worker)

        let copilotArgs = try String(contentsOf: copilotArgsFile, encoding: .utf8)
        // The Copilot follow-up should include context from the Claude run
        #expect(copilotArgs.contains("pi") || copilotArgs.contains("Pi"))
        #expect(copilotArgs.contains("3.14159"))
        #expect(copilotArgs.contains("pi squared") || copilotArgs.contains("Now calculate"))
        #expect(task.runs.count == 2)
        #expect(task.runs.sorted { $0.startedAt < $1.startedAt }[0].runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(task.runs.sorted { $0.startedAt < $1.startedAt }[1].runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(task.status == .completed)
    }

    @Test("Cursor GitHub Workflow follow-up stops at runtime capability gate before provider policy")
    func cursorGitHubWorkflowFollowUpStopsAtRuntimeCapabilityGate() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor provider should not launch for GitHub host-control work'
            exit 0
            """
        )
        let task = harness.makeTask(
            runtime: .cursorCLI,
            goal: "list my open prs in the astra repo",
            model: "composer-2.5-fast"
        )
        task.workspace?.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let githubSkill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read", "Glob", "Grep"],
            behaviorInstructions: "Use ASTRA's host-control GitHub MCP tool mcp__astra_host__github for GitHub operations."
        )
        githubSkill.skillDescription = "Inspect issues, PRs, and CI via ASTRA host-control GitHub"
        githubSkill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        githubSkill.workspace = task.workspace
        task.skills = [githubSkill]
        harness.context.insert(githubSkill)

        let worker = harness.makeWorker(
            runtime: .cursorCLI,
            executablePath: cursorPath,
            permissionPolicy: .autonomous
        )
        worker.defaultRuntimeID = .cursorCLI
        worker.claudePath = harness.rootURL.appendingPathComponent("missing-claude").path
        worker.copilotPath = harness.rootURL.appendingPathComponent("missing-copilot").path
        worker.setExecutablePath(harness.rootURL.appendingPathComponent("missing-codex").path, for: .codexCLI)

        _ = await harness.continueTask(
            task: task,
            message: "retry listing my open PRs in the astra repo",
            worker: worker
        )

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.status == .failed)
        #expect(run.typedStopReason == TaskRunStopReason.custom(TaskRuntimeCompatibilityService.runtimeCapabilityIncompatibleReason))
        #expect(task.status == .pendingUser)
        #expect(task.events.contains { event in
            event.run?.id == run.id &&
            event.type == TaskEventTypes.System.error.rawValue &&
            event.payload.contains("Selected runtime is incompatible with required ASTRA capabilities") &&
            event.payload.contains("host-control MCP server for github")
        })
        #expect(!task.events.contains { event in
            event.run?.id == run.id &&
            event.payload.contains("Provider policy blocked this run before launch")
        })
        #expect(run.output.isEmpty)
    }

    @Test("Cursor generic host-control capability stops at runtime capability gate")
    func cursorGenericHostControlCapabilityStopsAtRuntimeCapabilityGate() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor provider should not launch for generic host-control work'
            exit 0
            """
        )
        let task = harness.makeTask(
            runtime: .cursorCLI,
            goal: "read Jira issue STAR-123",
            model: "composer-2.5-fast"
        )
        task.workspace?.enabledCapabilityIDs = ["custom-jira-host-control"]
        let jiraSkill = Skill(
            name: "Jira Host Control",
            allowedTools: ["Read", "Glob", "Grep"],
            behaviorInstructions: "Always use ASTRA's host-control Jira MCP tool mcp__astra_host__jira for Jira operations. Do not use Bash, curl, or raw REST API calls to bypass this broker."
        )
        jiraSkill.skillDescription = "Read Jira through ASTRA host-control Jira"
        jiraSkill.originPackageID = "custom-jira-host-control"
        jiraSkill.workspace = task.workspace
        task.skills = [jiraSkill]
        harness.context.insert(jiraSkill)

        let worker = harness.makeWorker(
            runtime: .cursorCLI,
            executablePath: cursorPath,
            permissionPolicy: .autonomous
        )
        worker.defaultRuntimeID = .cursorCLI
        worker.claudePath = harness.rootURL.appendingPathComponent("missing-claude").path
        worker.copilotPath = harness.rootURL.appendingPathComponent("missing-copilot").path
        worker.setExecutablePath(harness.rootURL.appendingPathComponent("missing-codex").path, for: .codexCLI)

        _ = await harness.continueTask(
            task: task,
            message: "retry reading Jira issue STAR-123",
            worker: worker
        )

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.status == .failed)
        #expect(run.typedStopReason == TaskRunStopReason.custom(TaskRuntimeCompatibilityService.runtimeCapabilityIncompatibleReason))
        #expect(task.status == .pendingUser)
        #expect(task.events.contains { event in
            event.run?.id == run.id &&
            event.type == TaskEventTypes.System.error.rawValue &&
            event.payload.contains("Selected runtime is incompatible with required ASTRA capabilities") &&
            event.payload.contains("host-control MCP server for jira")
        })
        #expect(!task.events.contains { event in
            event.run?.id == run.id &&
            event.payload.contains("Provider policy blocked this run before launch")
        })
        #expect(run.output.isEmpty)
    }

    @Test("Cursor Docker workspace follow-up stops at runtime capability gate")
    func cursorDockerWorkspaceFollowUpStopsAtRuntimeCapabilityGate() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor provider should not launch for Docker workspace host-control work'
            exit 0
            """
        )
        let task = harness.makeTask(
            runtime: .cursorCLI,
            goal: "run a project check inside Docker",
            model: "composer-2.5-fast"
        )
        let dockerEnvironment = WorkspaceExecutionEnvironment(
            id: "docker:test",
            kind: .dockerImage,
            displayName: "Docker Test",
            image: "astra/test:latest",
            providerPlacement: .host,
            containerWorkingDirectory: "/workspace",
            mounts: [
                ExecutionEnvironmentMount(
                    hostPath: harness.workspaceURL.path,
                    containerPath: "/workspace",
                    access: .readWrite,
                    role: .workspace
                )
            ]
        )
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(dockerEnvironment)
        task.workspace?.activeExecutionEnvironmentJSON = task.executionEnvironmentSnapshotJSON
        try? harness.context.save()

        let worker = harness.makeWorker(
            runtime: .cursorCLI,
            executablePath: cursorPath,
            permissionPolicy: .autonomous
        )
        worker.defaultRuntimeID = .cursorCLI
        worker.claudePath = harness.rootURL.appendingPathComponent("missing-claude").path
        worker.copilotPath = harness.rootURL.appendingPathComponent("missing-copilot").path
        worker.setExecutablePath(harness.rootURL.appendingPathComponent("missing-codex").path, for: .codexCLI)

        _ = await harness.continueTask(
            task: task,
            message: "retry the Docker workspace check",
            worker: worker
        )

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.status == .failed)
        #expect(run.typedStopReason == TaskRunStopReason.custom(TaskRuntimeCompatibilityService.runtimeCapabilityIncompatibleReason))
        #expect(task.status == .pendingUser)
        #expect(task.events.contains { event in
            event.run?.id == run.id &&
            event.type == TaskEventTypes.System.error.rawValue &&
            event.payload.contains("Selected runtime is incompatible with required ASTRA capabilities") &&
            event.payload.contains("Docker workspace shell MCP")
        })
        #expect(!task.events.contains { event in
            event.run?.id == run.id &&
            event.payload.contains("Provider policy blocked this run before launch")
        })
        #expect(run.output.isEmpty)
    }

    @Test("Generic Cursor follow-up remains on Cursor")
    func genericCursorFollowUpRemainsOnCursor() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor handled generic work'
            exit 0
            """
        )
        let task = harness.makeTask(
            runtime: .cursorCLI,
            goal: "Summarize the local notes",
            model: "composer-2.5-fast"
        )
        let worker = harness.makeWorker(
            runtime: .cursorCLI,
            executablePath: cursorPath,
            permissionPolicy: .autonomous
        )
        worker.defaultRuntimeID = .codexCLI

        _ = await harness.continueTask(task: task, message: "retry generic work", worker: worker)

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.cursorCLI.rawValue)
        #expect(task.runtimeID == AgentRuntimeID.cursorCLI.rawValue)
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Cursor handled generic work")
        #expect(!task.events.contains { $0.payload.contains("Runtime changed from Cursor CLI") })
    }

    @Test("GitHub host-control retry skips old Copilot default and reroutes to Codex")
    func githubHostControlRetrySkipsOldCopilotDefaultAndReroutesToCodex() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor provider should not launch for GitHub host-control work'
            exit 0
            """
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' 'old copilot should not launch'
            exit 0
            """)
        )
        let codexPath = try harness.writeExecutable(
            named: "codex",
            script: """
            #!/bin/sh
            printf '%s\\n' '{"type":"thread.started","thread_id":"codex-thread"}'
            printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Codex handled GitHub"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
            exit 0
            """
        )

        let task = harness.makeTask(runtime: .cursorCLI, goal: "List my open PRs", model: "composer-2.5-fast")
        task.workspace?.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let skill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read"],
            behaviorInstructions: "Use ASTRA's host-control GitHub MCP tool mcp__astra_host__github."
        )
        skill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        skill.workspace = task.workspace
        task.skills = [skill]
        harness.context.insert(skill)

        let worker = harness.makeWorker(runtime: .cursorCLI, executablePath: cursorPath, permissionPolicy: .autonomous)
        worker.defaultRuntimeID = .copilotCLI
        worker.setExecutablePath(copilotPath, for: .copilotCLI)
        worker.setExecutablePath(codexPath, for: .codexCLI)

        _ = await harness.continueTask(task: task, message: "retry", worker: worker)

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.codexCLI.rawValue)
        #expect(run.output == "Codex handled GitHub")
        #expect(task.events.contains { $0.payload.contains("Runtime changed from Cursor CLI to Codex CLI") })
        #expect(!run.output.contains("old copilot should not launch"))
    }

    @Test("GitHub host-control retry accepts new Copilot default")
    func githubHostControlRetryAcceptsNewCopilotDefaultWhenAdditionalMCPConfigIsSupported() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor provider should not launch for GitHub host-control work'
            exit 0
            """
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: """
            #!/bin/sh
            if [ "$1" = "help" ]; then
              printf '%s\\n' '--output-format=FORMAT --stream=MODE --no-ask-user --allow-all-tools --additional-mcp-config CONFIG'
              exit 0
            fi
            if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
              echo "copilot fake 1.0"
              exit 0
            fi
            printf '%s\\n' '{"type":"session.mcp_servers_loaded","session":{"id":"new-copilot-session","model":"gpt-5"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Copilot handled GitHub"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":1,"turns":1}'
            exit 0
            """
        )

        let task = harness.makeTask(runtime: .cursorCLI, goal: "List my open PRs", model: "composer-2.5-fast")
        task.workspace?.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let skill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read"],
            behaviorInstructions: "Use ASTRA's host-control GitHub MCP tool mcp__astra_host__github."
        )
        skill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        skill.workspace = task.workspace
        task.skills = [skill]
        harness.context.insert(skill)

        let worker = harness.makeWorker(runtime: .cursorCLI, executablePath: cursorPath, permissionPolicy: .autonomous)
        worker.defaultRuntimeID = .copilotCLI
        worker.setExecutablePath(copilotPath, for: .copilotCLI)

        _ = await harness.continueTask(task: task, message: "retry", worker: worker)

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(run.output == "Copilot handled GitHub")
        #expect(task.events.contains { $0.payload.contains("Runtime changed from Cursor CLI to GitHub Copilot CLI") })
    }

    @Test("GitHub host-control retry reroutes from Cursor to configured compatible runtime")
    func githubHostControlRetryReroutesFromCursorToConfiguredCompatibleRuntime() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor provider should not launch for GitHub host-control work'
            exit 0
            """
        )
        let codexPath = try harness.writeExecutable(
            named: "codex",
            script: """
            #!/bin/sh
            printf '%s\\n' '{"type":"thread.started","thread_id":"codex-github-thread"}'
            printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Codex GitHub answer"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":7}}'
            exit 0
            """
        )
        let task = harness.makeTask(
            runtime: .cursorCLI,
            goal: "List my open PRs in the astra repo",
            model: "composer-2.5-fast"
        )
        task.workspace?.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let githubSkill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read", "Glob", "Grep"],
            behaviorInstructions: "Use ASTRA's host-control GitHub MCP tool mcp__astra_host__github for GitHub operations."
        )
        githubSkill.skillDescription = "Inspect issues, PRs, and CI via ASTRA host-control GitHub"
        githubSkill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        githubSkill.workspace = task.workspace
        task.skills = [githubSkill]
        harness.context.insert(githubSkill)

        let worker = harness.makeWorker(
            runtime: .cursorCLI,
            executablePath: cursorPath,
            permissionPolicy: .autonomous
        )
        worker.defaultRuntimeID = .codexCLI
        worker.setExecutablePath(codexPath, for: .codexCLI)
        worker.setHomeDirectory(
            harness.rootURL.appendingPathComponent("codex-home", isDirectory: true).path,
            for: .codexCLI
        )

        _ = await harness.continueTask(
            task: task,
            message: "retry listing my open PRs in the astra repo",
            worker: worker
        )

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.codexCLI.rawValue)
        #expect(task.runtimeID == AgentRuntimeID.codexCLI.rawValue)
        #expect(task.status == .completed)
        #expect(run.output == "Codex GitHub answer")
        #expect(task.events.contains { event in
            event.run?.id == run.id &&
            event.type == TaskEventTypes.System.info.rawValue &&
            event.payload.contains("Runtime changed from Cursor CLI to Codex CLI")
        })
        #expect(!task.events.contains { event in
            event.run?.id == run.id &&
            event.type == TaskEventTypes.System.error.rawValue &&
            event.payload.contains("Selected runtime is incompatible with required ASTRA capabilities")
        })
    }

    // MARK: - Permission mode passed to CLI (Claude & Antigravity)

    @Test("Claude restricted mode passes no skip flag but autonomous does")
    func claudePermissionModePassedToCLI() async throws {
        // Restricted mode: no --dangerously-skip-permissions flag
        let restrictedHarness = try HeadlessChatHarness()
        defer { restrictedHarness.cleanup() }
        let restrictedArgsURL = restrictedHarness.rootURL.appendingPathComponent("claude-restricted-args.txt")
        let restrictedClaudePath = try restrictedHarness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-r","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"num_turns":1,"result":"restricted","usage":{"input_tokens":1,"output_tokens":1}}'
                exit 0
                """,
                argsFile: restrictedArgsURL
            )
        )
        let restrictedTask = restrictedHarness.makeTask(runtime: .claudeCode, goal: "Restricted Claude", model: "claude-sonnet-4-6")
        let restrictedWorker = restrictedHarness.makeWorker(
            runtime: .claudeCode,
            executablePath: restrictedClaudePath,
            permissionPolicy: .restricted
        )

        _ = await restrictedHarness.execute(task: restrictedTask, worker: restrictedWorker)

        let restrictedArgs = try String(contentsOf: restrictedArgsURL, encoding: .utf8)
        #expect(!restrictedArgs.contains("--dangerously-skip-permissions"))
        #expect(restrictedTask.status == .completed)

        // Autonomous mode: --dangerously-skip-permissions present
        let autoHarness = try HeadlessChatHarness()
        defer { autoHarness.cleanup() }
        let autoArgsURL = autoHarness.rootURL.appendingPathComponent("claude-auto-args.txt")
        let autoClaudePath = try autoHarness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-a","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"num_turns":1,"result":"autonomous","usage":{"input_tokens":1,"output_tokens":1}}'
                exit 0
                """,
                argsFile: autoArgsURL
            )
        )
        let autoTask = autoHarness.makeTask(runtime: .claudeCode, goal: "Autonomous Claude", model: "claude-sonnet-4-6")
        let autoWorker = autoHarness.makeWorker(
            runtime: .claudeCode,
            executablePath: autoClaudePath,
            permissionPolicy: .autonomous
        )

        _ = await autoHarness.execute(task: autoTask, worker: autoWorker)

        let autoArgs = try String(contentsOf: autoArgsURL, encoding: .utf8)
        #expect(autoArgs.contains("--dangerously-skip-permissions"))
        #expect(autoTask.status == .completed)
    }

    @Test("Antigravity restricted mode passes sandbox flag and autonomous skips permissions")
    func antigravityPermissionModePassedToCLI() async throws {
        // Restricted mode: --sandbox flag
        let restrictedHarness = try HeadlessChatHarness()
        defer { restrictedHarness.cleanup() }
        let restrictedArgsURL = restrictedHarness.rootURL.appendingPathComponent("agy-restricted-args.txt")
        let restrictedAgyPath = try restrictedHarness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf '%s\\n' "$@" > \(Self.shQuoteSandboxPath(restrictedArgsURL.path))
            printf '%s\\n' 'restricted response'
            exit 0
            """
        )
        let restrictedTask = restrictedHarness.makeTask(
            runtime: .antigravityCLI,
            goal: "Restricted Antigravity",
            model: "Gemini 3.5 Flash"
        )
        let restrictedWorker = restrictedHarness.makeWorker(
            runtime: .antigravityCLI,
            executablePath: restrictedAgyPath,
            permissionPolicy: .restricted
        )

        _ = await restrictedHarness.execute(task: restrictedTask, worker: restrictedWorker)

        let restrictedArgs = try String(contentsOf: restrictedArgsURL, encoding: .utf8)
        #expect(restrictedArgs.contains("--sandbox"))
        #expect(!restrictedArgs.contains("--dangerously-skip-permissions"))
        #expect(restrictedTask.status == .completed)

        // Autonomous mode: --dangerously-skip-permissions, no --sandbox
        let autoHarness = try HeadlessChatHarness()
        defer { autoHarness.cleanup() }
        let autoArgsURL = autoHarness.rootURL.appendingPathComponent("agy-auto-args.txt")
        let autoAgyPath = try autoHarness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf '%s\\n' "$@" > \(Self.shQuoteSandboxPath(autoArgsURL.path))
            printf '%s\\n' 'autonomous response'
            exit 0
            """
        )
        let autoTask = autoHarness.makeTask(
            runtime: .antigravityCLI,
            goal: "Autonomous Antigravity",
            model: "Gemini 3.5 Flash"
        )
        let autoWorker = autoHarness.makeWorker(
            runtime: .antigravityCLI,
            executablePath: autoAgyPath,
            permissionPolicy: .autonomous
        )

        _ = await autoHarness.execute(task: autoTask, worker: autoWorker)

        let autoArgs = try String(contentsOf: autoArgsURL, encoding: .utf8)
        #expect(autoArgs.contains("--dangerously-skip-permissions"))
        #expect(!autoArgs.contains("--sandbox"))
        #expect(autoTask.status == .completed)
    }

    // MARK: - Continue/resume a task

    @Test("Claude task can be continued and preserves session ID across runs")
    func claudeTaskCanBeContinued() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("claude-resume-args.txt")
        let countFile = harness.rootURL.appendingPathComponent("claude-call-count.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > \(Self.shQuote(countFile.path))
            if [ "$count" = "1" ]; then
              printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-resume-sess","model":"claude-sonnet-4-6"}'
              printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Initial Claude answer"}]}}'
              printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Initial Claude answer","usage":{"input_tokens":10,"output_tokens":20}}'
            else
              printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-resume-sess","model":"claude-sonnet-4-6"}'
              printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude follow-up answer"}]}}'
              printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":8,"num_turns":1,"result":"Claude follow-up answer","usage":{"input_tokens":15,"output_tokens":25}}'
            fi
            exit 0
            """, argsFile: argsFile)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Start a Claude thread", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.status == .completed)
        #expect(task.sessionId == "claude-resume-sess")
        #expect(task.runs.count == 1)

        _ = await harness.continueTask(task: task, message: "Tell me more", worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(runs[0].runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(runs[0].output == "Initial Claude answer")
        #expect(runs[0].providerSessionId == "claude-resume-sess")
        #expect(runs[1].runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(runs[1].output == "Claude follow-up answer")
        #expect(runs[1].providerSessionId == "claude-resume-sess")
        #expect(task.sessionId == "claude-resume-sess")
        #expect(task.status == .completed)
        #expect(task.events.contains { $0.type == "user.message" && $0.payload == "Tell me more" })
    }

    @Test("Antigravity task can be continued with a follow-up message")
    func antigravityTaskCanBeContinued() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let countFile = harness.rootURL.appendingPathComponent("agy-call-count.txt")
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > \(Self.shQuote(countFile.path))
            if [ "$count" = "1" ]; then
              printf '%s\\n' 'Initial Antigravity answer'
            else
              printf '%s\\n' 'Antigravity follow-up answer'
            fi
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Start an Antigravity thread",
            model: "Gemini 3.5 Flash"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.status == .completed)
        #expect(task.runs.count == 1)

        _ = await harness.continueTask(task: task, message: "Elaborate on that", worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(runs[0].runtimeID == AgentRuntimeID.antigravityCLI.rawValue)
        #expect(runs[0].output.trimmingCharacters(in: .whitespacesAndNewlines) == "Initial Antigravity answer")
        #expect(runs[1].runtimeID == AgentRuntimeID.antigravityCLI.rawValue)
        #expect(runs[1].output.trimmingCharacters(in: .whitespacesAndNewlines) == "Antigravity follow-up answer")
        #expect(task.status == .completed)
        #expect(task.events.contains { $0.type == "user.message" && $0.payload == "Elaborate on that" })
    }

    // MARK: - Crash and timeout recovery
}
