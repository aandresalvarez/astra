import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

extension HeadlessChatScenarioTests {
    @Test("Fake Copilot chat completes through the worker without UI")
    func fakeCopilotChatCompletes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Headless Copilot response"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Answer from Copilot", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(run.output == "Headless Copilot response")
        #expect(run.inputTokens == 2)
        #expect(run.outputTokens == 4)
        #expect(events.contains { if case .text("Headless Copilot response") = $0 { true } else { false } })
    }

    @Test("Fake Copilot runtime support tools complete who-are-you prompt")
    func fakeCopilotRuntimeSupportToolsCompleteWhoAreYouPrompt() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("who-are-you-copilot-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
            printf '%s\\n' '{"type":"tool.execution_start","data":{"toolCallId":"intent-1","toolName":"report_intent","arguments":{"intent":"Answering provider identity question"}}}'
            printf '%s\\n' '{"type":"tool.execution_complete","data":{"toolCallId":"intent-1","success":true,"result":{"content":"ok"}}}'
            printf '%s\\n' '{"type":"tool.execution_start","data":{"toolCallId":"docs-1","toolName":"fetch_copilot_cli_documentation","arguments":{}}}'
            printf '%s\\n' '{"type":"tool.execution_complete","data":{"toolCallId":"docs-1","success":true,"result":{"content":"ok"}}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I am GitHub Copilot CLI running through ASTRA."}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "who are you?", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.stopReason == "completed")
        #expect(run.output == "I am GitHub Copilot CLI running through ASTRA.")

        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let availableEntries = Set(Self.argumentValues(after: "--available-tools", in: args))
        let excludedEntries = Set(Self.argumentValues(after: "--excluded-tools", in: args))
        #expect(availableEntries.contains("fetch_copilot_cli_documentation"))
        #expect(availableEntries.contains("report_intent"))
        #expect(!availableEntries.contains("task"))
        #expect(excludedEntries.contains("task"))
    }

    @Test("Fake Copilot malformed runtime support tool input fails before output")
    func fakeCopilotMalformedRuntimeSupportToolInputFailsBeforeOutput() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"tool.execution_start","data":{"toolCallId":"docs-1","toolName":"fetch_copilot_cli_documentation","arguments":{"command":"git status"}}}'
            /bin/sleep 20
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "who are you?", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "policy_violation")
        #expect(run.output.isEmpty)
        #expect(task.events.contains {
            $0.type == "error" && $0.payload.contains("provider support tool carried action-like input")
        })
    }

    @Test("Fake Claude chat completes through the worker without UI")
    func fakeClaudeChatCompletes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Headless Claude response"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Headless Claude response","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Answer from Claude", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(task.sessionId == "session-1")
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(run.output == "Headless Claude response")
        #expect(run.inputTokens == 3)
        #expect(run.outputTokens == 5)
        #expect(events.contains { if case .systemInit(_, "session-1") = $0 { true } else { false } })
    }

    @Test("Fake Antigravity chat completes through the worker without UI")
    func fakeAntigravityChatCompletes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.2'
              exit 0
            fi
            printf '%s\\n' 'Headless Antigravity response'
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Answer from Antigravity",
            model: "Gemini 3.5 Flash (Low)"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.antigravityCLI.rawValue)
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Headless Antigravity response")
        #expect(run.tokensUsed > 0)
        #expect(run.inputTokens > 0)
        #expect(run.outputTokens > 0)
        #expect(task.tokensUsed == run.tokensUsed)
        #expect(task.events.contains {
            $0.type == "task.stats" && $0.payload.contains("estimated tokens") && $0.payload.contains("provider usage unavailable")
        })
        #expect(events.contains {
            if case .text(let text) = $0 {
                text.trimmingCharacters(in: .whitespacesAndNewlines) == "Headless Antigravity response"
            } else {
                false
            }
        })
        #expect(FileManager.default.fileExists(
            atPath: AntigravityCLIRuntime.settingsURL(providerHomeDirectory: worker.homeDirectory(for: .antigravityCLI)).path
        ))
    }

    @Test("Concurrent Antigravity runs with a shared home keep their selected models isolated")
    func concurrentAntigravityRunsWithSharedHomeKeepModelsIsolated() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            /usr/bin/python3 -u - <<'PY'
            import json
            import os
            import time
            time.sleep(0.25)
            settings_path = os.path.join(os.environ["HOME"], ".gemini", "antigravity-cli", "settings.json")
            with open(settings_path, "r", encoding="utf-8") as handle:
                model = json.load(handle).get("model", "")
            print(f"model={model}", flush=True)
            PY
            exit 0
            """
        )

        let firstTask = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Use the first Antigravity model",
            model: "Gemini 3.5 Flash"
        )
        let secondTask = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Use the second Antigravity model",
            model: "Gemini 3 Flash"
        )
        let firstWorker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)
        let secondWorker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        let firstRun = Task { @MainActor in
            await harness.execute(task: firstTask, worker: firstWorker)
        }
        let secondRun = Task { @MainActor in
            await harness.execute(task: secondTask, worker: secondWorker)
        }
        _ = await (firstRun.value, secondRun.value)

        let firstOutput = try #require(firstTask.runs.first?.output)
        let secondOutput = try #require(secondTask.runs.first?.output)
        #expect(firstTask.status == .completed)
        #expect(secondTask.status == .completed)
        #expect(firstOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "model=Gemini 3.5 Flash")
        #expect(secondOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "model=Gemini 3 Flash")
    }

    @Test("Standalone artifact task without created files stays pending review")
    func standaloneArtifactTaskWithoutCreatedFilesStaysPendingReview() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Save this as index.html: <html><script></script></html>"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a web page with html and javascript for a tic tac toe game",
            model: "gpt-5"
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "no_usable_result")
        #expect(task.completedAt == nil)
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("did not create a usable file") })
        #expect(!task.events.contains { $0.type == "task.completed" })
    }

    @Test("Misspelled JavaScript page task without created files stays pending review")
    func misspelledJavaScriptPageTaskWithoutCreatedFilesStaysPendingReview() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Wrote .astra/tasks/9B2FC25F/index.html\\n\\nFile: .astra/tasks/9B2FC25F/index.html\\n<html></html>"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "buid a rubis cuve solved in 3d in ajavascript page",
            model: "gpt-5"
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "no_usable_result")
        #expect(run.fileChanges.isEmpty)
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("did not create a usable file") })
        #expect(!task.events.contains { $0.type == "task.completed" })
    }

    @Test("Copilot artifact task receives bootstrap write permission and creates a file")
    func copilotArtifactTaskReceivesBootstrapWritePermissionAndCreatesFile() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "createa web page wit a masterball (similar to rubicks cube but as aball ) with a solver in javascript",
            model: "gpt-5.3-codex",
            tokenBudget: 200_000
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let artifactURL = URL(fileURLWithPath: taskFolder).appendingPathComponent("index.html")
        let argsURL = harness.rootURL.appendingPathComponent("copilot-artifact-bootstrap-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                allowed_write=0
                visible_create=0
                visible_edit=0
                mode=""
                for arg in "$@"; do
                  if [ "$arg" = "--allow-tool" ]; then
                    mode="allow"
                    continue
                  fi
                  if [ "$arg" = "--available-tools" ]; then
                    mode="available"
                    continue
                  fi
                  case "$arg" in
                    --*) mode="" ;;
                  esac
                  if [ "$mode" = "allow" ] && [ "$arg" = "write" ]; then
                    allowed_write=1
                  fi
                  if [ "$mode" = "available" ] && [ "$arg" = "create" ]; then
                    visible_create=1
                  fi
                  if [ "$mode" = "available" ] && [ "$arg" = "edit" ]; then
                    visible_edit=1
                  fi
                done
                if [ "$allowed_write" = "1" ] && [ "$visible_create" = "1" ] && [ "$visible_edit" = "1" ]; then
                  mkdir -p \(Self.shQuote(taskFolder))
                  printf '%s\\n' '<!doctype html><html><body><h1>Masterball solver</h1><script>console.log("solver")</script></body></html>' > \(Self.shQuote(artifactURL.path))
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Created the Masterball solver page at .astra/tasks/bootstrap/index.html"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I could not directly write files in this run because the available tools are read-only, so here is a ready-to-save artifact for index.html: <html></html>"}}'
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 0
                """,
                argsFile: argsURL
            )
        )
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.execute(task: task, worker: worker)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let allowedEntries = Set(Self.argumentValues(after: "--allow-tool", in: args))
        let availableEntries = Set(Self.argumentValues(after: "--available-tools", in: args))
        let run = try #require(task.runs.first)

        #expect(allowedEntries.contains("write"))
        #expect(availableEntries.contains("create"))
        #expect(availableEntries.contains("edit"))
        #expect(!availableEntries.contains("apply_patch"))
        #expect(FileManager.default.fileExists(atPath: artifactURL.path))
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.stopReason == "completed")
        #expect(TaskDeliverableExpectation.hasRunScopedArtifact(for: task, run: run))
        #expect(task.artifacts.contains {
            $0.path == artifactURL.path &&
                $0.type == "html" &&
                !$0.isStale
        })
        #expect(task.artifacts.filter { $0.path == artifactURL.path }.count == 1)
        #expect(!task.events.contains { $0.type == "error" && $0.payload.contains("did not create a usable file") })
    }

    @Test("Copilot streamed create deltas complete under Auto strict sandbox")
    func copilotStreamedCreateDeltasCompleteUnderAutoStrictSandbox() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a report.md with this information",
            model: "claude-sonnet-4.6",
            tokenBudget: 50_000
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let artifactURL = URL(fileURLWithPath: taskFolder).appendingPathComponent("report.md")
        let outsideProbeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".astra-strict-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outsideProbeURL) }
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            if (printf '%s\\n' 'must stay blocked' > \(Self.shQuote(outsideProbeURL.path))) 2>/dev/null; then
              exit 91
            fi
            printf '%s\\n' '{"type":"assistant.tool_call_delta","data":{"toolCallId":"toolu_create_report","toolName":"create","inputDelta":"{\\"path\\":\\""}}'
            printf '%s\\n' '{"type":"assistant.tool_call_delta","data":{"toolCallId":"toolu_create_report","toolName":"create","inputDelta":"/tmp/astra-headless"}}'
            printf '%s\\n' '{"type":"assistant.tool_call_delta","data":{"toolCallId":"toolu_create_report","toolName":"create","inputDelta":"/.astra/tasks/"}}'
            printf '%s\\n' '{"type":"assistant.tool_call_delta","data":{"toolCallId":"toolu_create_report","toolName":"create","inputDelta":"report.md"}}'
            printf '%s\\n' '{"type":"assistant.tool_call_delta","data":{"toolCallId":"toolu_create_report","toolName":"create","inputDelta":"\\",\\"file_text\\":\\""}}'
            printf '%s\\n' '{"type":"assistant.tool_call_delta","data":{"toolCallId":"toolu_create_report","toolName":"create","inputDelta":"# Jira report"}}'
            printf '%s\\n' '{"type":"assistant.tool_call_delta","data":{"toolCallId":"toolu_create_report","toolName":"create","inputDelta":"29 open issues"}}'
            printf '%s\\n' '{"type":"assistant.tool_call_delta","data":{"toolCallId":"toolu_create_report","toolName":"create","inputDelta":"\\"}"}}'
            printf '%s\\n' '{"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"toolu_create_report","name":"create","arguments":{"path":"report.md"}}]}}'
            printf '%s\\n' '{"type":"tool.execution_start","data":{"toolCallId":"toolu_create_report","toolName":"create","arguments":{"path":"report.md","file_text":"# Jira report"}}}'
            printf '%s\\n' '# Jira report' '29 open issues' > \(Self.shQuote(artifactURL.path))
            printf '%s\\n' '{"type":"tool.execution_complete","data":{"toolCallId":"toolu_create_report","success":true,"result":{"content":"Created report.md"}}}'
            printf '%s\\n' '{"type":"assistant.message","data":{"content":"Created report.md with the Jira summary."}}'
            printf '%s\\n' '{"type":"result","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .autonomous,
            sandboxEnforcementOverride: .strict
        )

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(FileManager.default.fileExists(atPath: artifactURL.path))
        #expect(!FileManager.default.fileExists(atPath: outsideProbeURL.path))
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.stopReason == "completed")
        #expect(task.events.filter { $0.type == "tool.use" }.count == 1)
        #expect(!task.events.contains { $0.type == "error" && $0.payload.contains("Repetition loop detected") })
    }

    @Test("Manual artifact completion automatically records inferred baseline verification")
    func manualArtifactCompletionAutomaticallyRecordsInferredBaselineVerification() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "create a notes.txt file summarizing a masterball solver",
            model: "gpt-5"
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let artifactURL = URL(fileURLWithPath: taskFolder).appendingPathComponent("notes.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            mkdir -p \(Self.shQuote(taskFolder))
            printf '%s\\n' 'Masterball solver notes' > \(Self.shQuote(artifactURL.path))
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Created notes.txt with the Masterball solver summary."}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        let state = try #require(TaskContextStateManager.load(taskFolder: taskFolder))
        #expect(FileManager.default.fileExists(atPath: artifactURL.path))
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.stopReason == "completed")
        #expect(task.events.contains { $0.type == TaskDeliverableVerificationEventTypes.reviewNeeded })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractCreated })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
        #expect(state.validationContract?.status == "passed")
        #expect(state.verification.status == "passed")
        #expect(state.verification.strategy == "validation_contract")
    }

    @Test("Broken deliverable syntax blocks fake provider completion")
    func brokenDeliverableSyntaxBlocksFakeProviderCompletion() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "create a json file named config.json",
            model: "gpt-5"
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let artifactURL = URL(fileURLWithPath: taskFolder).appendingPathComponent("config.json")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            mkdir -p \(Self.shQuote(taskFolder))
            printf '%s\\n' '{ invalid json' > \(Self.shQuote(artifactURL.path))
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Created config.json"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(FileManager.default.fileExists(atPath: artifactURL.path))
        #expect(task.artifacts.contains {
            $0.path == artifactURL.path &&
                $0.type == "json" &&
                !$0.isStale
        })
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "deliverable_verification_failed")
        #expect(task.events.contains {
            $0.type == TaskDeliverableVerificationEventTypes.failed &&
                $0.payload.contains("\"level\":\"failed\"")
        })
        #expect(task.events.contains {
            $0.type == "error" && $0.payload.contains("failed deterministic verification")
        })
        #expect(!task.events.contains { $0.type == "task.completed" })
    }

    @Test("Antigravity empty non-artifact task stays pending review")
    func antigravityEmptyNonArtifactTaskStaysPendingReview() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.2'
              exit 0
            fi
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Answer from Antigravity",
            model: "Gemini 3.5 Flash"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "no_usable_result")
        #expect(task.completedAt == nil)
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("finished with exit code 0") })
        #expect(!task.events.contains { $0.type == "task.completed" })
    }

    @Test("Antigravity empty run surfaces hidden diagnostic log failure")
    func antigravityEmptyRunSurfacesHiddenDiagnosticLogFailure() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            log_file=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--log-file" ]; then
                shift
                log_file="$1"
              fi
              shift
            done
            if [ -n "$log_file" ]; then
              mkdir -p "$(dirname "$log_file")"
              {
                printf '%s\\n' 'W server_oauth.go:99] Account ineligible: Your current account is not eligible for Antigravity.'
                printf '%s\\n' 'E log.go:398] RESOURCE_EXHAUSTED (code 429): You have exhausted your capacity on this model. Your quota will reset after 91h11m50s.'
                printf '%s\\n' 'E discovery.go:383] Failed to load JSON config file /Users/alvaro1/.gemini/config/mcp_config.json: unexpected end of JSON input'
              } > "$log_file"
            fi
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Answer from Antigravity",
            model: "Gemini 3.5 Flash"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        let logPath = try #require(AntigravityCLIRuntime.diagnosticLogPath(task: task, runID: run.id))
        let errorPayload = try #require(task.events.first { $0.type == "error" }?.payload)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "no_usable_result")
        #expect(FileManager.default.fileExists(atPath: logPath))
        #expect(errorPayload.contains("quota is exhausted"))
        #expect(errorPayload.contains("account_ineligible"))
        #expect(errorPayload.contains("malformed_mcp_config"))
        #expect(errorPayload.contains(logPath))
    }

    @Test("Antigravity empty misspelled artifact task stays pending review")
    func antigravityEmptyMisspelledArtifactTaskStaysPendingReview() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.2'
              exit 0
            fi
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "cerate a html slide deck about agents lanscape in the 2030",
            model: "Gemini 3.5 Flash"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "no_usable_result")
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("did not create a usable file") })
        #expect(!task.events.contains { $0.type == "task.completed" })
    }

    @Test("Antigravity task-folder artifact prevents empty result review")
    func antigravityTaskFolderArtifactPreventsEmptyResultReview() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "create an html slide deck about agents",
            model: "Gemini 3.5 Flash"
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let artifactURL = URL(fileURLWithPath: taskFolder).appendingPathComponent("index.html")
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.2'
              exit 0
            fi
            printf '%s\\n' '<html>generated</html>' > '\(artifactURL.path)'
            exit 0
            """
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.stopReason == "completed")
        #expect(TaskDeliverableExpectation.hasRunScopedArtifact(for: task, run: run))
        #expect(FileManager.default.fileExists(atPath: artifactURL.path))
        #expect(!task.events.contains { $0.type == "error" })
    }

    @Test("Antigravity empty retry ignores earlier artifacts")
    func antigravityEmptyRetryIgnoresEarlierArtifacts() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.2'
              exit 0
            fi
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "create an html slide deck about agents",
            model: "Gemini 3.5 Flash"
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let existingArtifact = URL(fileURLWithPath: taskFolder).appendingPathComponent("index.html")
        try "<html>already here</html>".write(to: existingArtifact, atomically: true, encoding: .utf8)
        let priorRun = TaskRun(task: task)
        priorRun.status = .completed
        priorRun.stopReason = "completed"
        let priorArtifact = Artifact(task: task, type: "file", path: existingArtifact.path)
        harness.context.insert(priorRun)
        harness.context.insert(priorArtifact)
        try harness.context.save()
        #expect(TaskDeliverableExpectation.hasArtifact(for: task, run: priorRun))

        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.id != priorRun.id)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "no_usable_result")
        #expect(run.fileChanges.isEmpty)
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(task.events.contains { $0.type == "error" && $0.run?.id == run.id && $0.payload.contains("for this run") })
        #expect(!task.events.contains { $0.type == "task.completed" && $0.run?.id == run.id })
    }
}
