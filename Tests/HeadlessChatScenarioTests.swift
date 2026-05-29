import Foundation
import Network
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Headless Chat Scenarios", .serialized)
@MainActor
struct HeadlessChatScenarioTests {
    private static func enableLocalAgentCapabilities(
        _ capabilities: LocalAgentToolCapability...,
        defaults: UserDefaults = .standard
    ) -> () -> Void {
        enableLocalAgentCapabilities(defaults: defaults, capabilities)
    }

    private static func enableLocalAgentCapabilities(
        defaults: UserDefaults = .standard,
        _ capabilities: [LocalAgentToolCapability]
    ) -> () -> Void {
        let previousValues: [String: Any?] = Dictionary(uniqueKeysWithValues: LocalAgentToolCapability.allCases.map {
            ($0.settingsKey, defaults.object(forKey: $0.settingsKey))
        })
        for capability in LocalAgentToolCapability.allCases {
            defaults.set(capabilities.contains(capability), forKey: capability.settingsKey)
        }
        return {
            for capability in LocalAgentToolCapability.allCases {
                if let storedValue = previousValues[capability.settingsKey],
                   let previousValue = storedValue {
                    defaults.set(previousValue, forKey: capability.settingsKey)
                } else {
                    defaults.removeObject(forKey: capability.settingsKey)
                }
            }
        }
    }

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
        #expect(run.output == "Headless Copilot response")
        #expect(run.inputTokens == 2)
        #expect(run.outputTokens == 4)
        #expect(events.contains { if case .text("Headless Copilot response") = $0 { true } else { false } })
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

    @Test("Fake Local MLX chat completes through the worker without UI")
    func fakeLocalMLXChatCompletes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(false, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import shutil
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            if len(sys.argv) < 2 or sys.argv[1] != "run":
                print("usage: astra-local-model run --request-file <path>", file=sys.stderr)
                sys.exit(64)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            if not os.path.isfile(request_file):
                print("missing request file", file=sys.stderr)
                sys.exit(64)

            shutil.copyfile(request_file, "local-request.json")
            print("stdout diagnostic noise from local helper", flush=True)

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-session-1", "model": "Qwen/Qwen3-4B-MLX-4bit"})
            emit({"v": 1, "type": "phase", "message": "Loading fake local model.", "phase": "load_model"})
            emit({"v": 1, "type": "memory", "phase": "after_load", "activeMemoryBytes": 2048, "peakMemoryBytes": 4096})
            emit({"v": 1, "type": "text", "text": "<thi"})
            emit({"v": 1, "type": "text", "text": "nk>hidden local reasoning"})
            emit({"v": 1, "type": "text", "text": "</thi"})
            emit({"v": 1, "type": "text", "text": "nk>"})
            emit({"v": 1, "type": "text", "text": "Headless Local MLX response"})
            emit({"v": 1, "type": "stats", "inputTokens": 4, "outputTokens": 6, "durationMs": 11, "turns": 1})
            emit({"v": 1, "type": "completed", "summary": "done"})
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Answer from Local MLX",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(task.sessionId == "local-session-1")
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.localMLX.rawValue)
        #expect(run.providerSessionId == "local-session-1")
        #expect(run.output == "Headless Local MLX response")
        #expect(!run.output.contains("hidden local reasoning"))
        #expect(run.inputTokens == 4)
        #expect(run.outputTokens == 6)
        #expect(run.tokensUsed == 10)
        #expect(task.tokensUsed == 10)
        #expect(!run.output.contains("stdout diagnostic noise"))
        #expect(task.events.contains {
            $0.type == "system.info" && $0.payload.contains("local_model.memory")
        })
        #expect(events.contains { if case .systemInit(_, "local-session-1") = $0 { true } else { false } })
        #expect(events.contains {
            if case .text(let text) = $0 {
                text == "Headless Local MLX response"
            } else {
                false
            }
        })

        let requestURL = harness.workspaceURL.appendingPathComponent("local-request.json")
        let requestData = try Data(contentsOf: requestURL)
        let request = try JSONDecoder().decode(LocalModelRunRequest.self, from: requestData)
        #expect(request.model == LocalMLXRuntime.defaultModel)
        #expect(request.prompt.contains("Answer from Local MLX"))
        #expect(request.modelDirectory == worker.homeDirectory(for: .localMLX))
        #expect(request.permissionMode == PermissionPolicy.restricted.rawValue)
    }

    @Test("Local MLX chat emits result callback when helper streams only text")
    func localMLXChatEmitsResultCallbackWhenHelperStreamsOnlyText() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(false, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-text-only-session", "model": "Qwen/Qwen3-4B-MLX-4bit"}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": "Text-only Local MLX response"}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Answer from Local MLX text only",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Text-only Local MLX response")
        #expect(events.contains {
            if case .result(let text, _, _, _, _, _, false) = $0 {
                return text == "Text-only Local MLX response"
            }
            return false
        })
    }

    @Test("Provider parity shared completion scenario runs across provider harnesses and Local Agent")
    func providerParitySharedCompletionScenarioRunsAcrossProviderHarnessesAndLocalAgent() async throws {
        for runtime in [
            AgentRuntimeID.claudeCode,
            .copilotCLI,
            .antigravityCLI,
            .localMLX
        ] {
            try await Self.runProviderParityCompletionScenario(runtime: runtime)
        }
    }

    @Test("Provider parity denied shell scenario blocks CLI harnesses and Local Agent")
    func providerParityDeniedShellScenarioBlocksCLIHarnessesAndLocalAgent() async throws {
        for runtime in [
            AgentRuntimeID.claudeCode,
            .copilotCLI,
            .antigravityCLI,
            .localMLX
        ] {
            try await Self.runProviderParityDeniedShellScenario(runtime: runtime)
        }
    }

    @Test("Provider parity blocked plan step scenario pauses CLI harnesses and Local Agent")
    func providerParityBlockedPlanStepScenarioPausesCLIHarnessesAndLocalAgent() async throws {
        for runtime in [
            AgentRuntimeID.claudeCode,
            .copilotCLI,
            .antigravityCLI,
            .localMLX
        ] {
            try await Self.runProviderParityBlockedPlanStepScenario(runtime: runtime)
        }
    }

    @Test("Provider parity write approval scenario resumes CLI harnesses and Local Agent")
    func providerParityWriteApprovalScenarioResumesCLIHarnessesAndLocalAgent() async throws {
        for runtime in [
            AgentRuntimeID.claudeCode,
            .copilotCLI,
            .antigravityCLI,
            .localMLX
        ] {
            try await Self.runProviderParityWriteApprovalScenario(runtime: runtime)
        }
    }

    @Test("Provider parity cancellation scenario stops provider harnesses and Local Agent")
    func providerParityCancellationScenarioStopsProviderHarnessesAndLocalAgent() async throws {
        for runtime in [
            AgentRuntimeID.claudeCode,
            .copilotCLI,
            .antigravityCLI,
            .localMLX
        ] {
            try await Self.runProviderParityCancellationScenario(runtime: runtime)
        }
    }

    @Test("Local MLX blocks action tasks instead of claiming fake progress")
    func localMLXBlocksActionTasksInsteadOfClaimingFakeProgress() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(false, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' 'astra-local-model 0.1.0'
              exit 0
            fi
            touch local-request.json
            printf '%s\\n' 'I will now proceed to read Jira.'
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read the latest stories in STAR from Jira",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == TextOnlyRuntimeGuard.stopReason)
        #expect(run.output.isEmpty)
        #expect(task.events.contains {
            $0.type == "error" && $0.payload.contains("Local Chat can answer from text")
        })
        #expect(!FileManager.default.fileExists(atPath: harness.workspaceURL.appendingPathComponent("local-request.json").path))
    }

    @Test("Local MLX experimental agent executes read-only workspace tool loop")
    func localMLXExperimentalAgentExecutesReadOnlyWorkspaceToolLoop() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        try "Local agent note: file-backed context works.".write(
            to: harness.workspaceURL.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys
            import time

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            if len(sys.argv) < 2 or sys.argv[1] != "run":
                print("usage: astra-local-model run --request-file <path>", file=sys.stderr)
                sys.exit(64)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                answer = "Summary: Local agent note was read through ASTRA."
                action = {"type": "final", "answer": answer}
            else:
                action = {
                    "type": "tool_call",
                    "id": "read-notes",
                    "tool": "workspace.read_file",
                    "arguments": {"path": "notes.txt", "max_bytes": 4096}
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-agent-session", "model": request.get("model")})
            emit({"v": 1, "type": "phase", "phase": "load_model", "message": "Loading local MLX model."})
            emit({"v": 1, "type": "memory", "phase": "before_load", "activeMemoryBytes": 1000, "peakMemoryBytes": 1000, "cacheMemoryBytes": 200, "memoryBudgetBytes": 4000})
            time.sleep(0.02)
            emit({"v": 1, "type": "memory", "phase": "after_load", "activeMemoryBytes": 2000, "peakMemoryBytes": 3000, "cacheMemoryBytes": 400, "memoryBudgetBytes": 4000})
            emit({"v": 1, "type": "phase", "phase": "generate", "message": "Generating local MLX response."})
            emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
            emit({"v": 1, "type": "stats", "inputTokens": 5, "outputTokens": 7, "durationMs": 12, "turns": 1, "firstTokenLatencyMs": 9, "tokensPerSecond": 12.5, "promptTokensPerSecond": 20.0})
            emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read notes.txt and summarize it",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.runtimeID == AgentRuntimeID.localMLX.rawValue)
        #expect(run.providerSessionId == "local-agent-session")
        #expect(run.output == "Summary: Local agent note was read through ASTRA.")
        #expect(task.events.contains {
            $0.type == "system.info" && $0.payload.contains("Local Agent mode is running")
        })
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("workspace.read_file") && $0.payload.contains("notes.txt")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Local agent note")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.action_proposed"
                && $0.payload.contains("\"action\":\"tool_call\"")
                && $0.payload.contains("\"tool\":\"workspace.read_file\"")
                && $0.payload.contains("\"id\":\"read-notes\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.policy_decision"
                && $0.payload.contains("\"status\":\"allowed\"")
                && $0.payload.contains("\"tool\":\"workspace.read_file\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.observation"
                && $0.payload.contains("\"status\":\"ok\"")
                && $0.payload.contains("\"tool\":\"workspace.read_file\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.final"
                && $0.payload.contains("\"tool_calls\":\"1\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.metrics"
                && $0.payload.contains("\"status\":\"completed\"")
                && $0.payload.contains("\"stop_reason\":\"completed\"")
                && $0.payload.contains("\"tool_calls\":\"1\"")
                && $0.payload.contains("\"tool_successes\":\"1\"")
                && $0.payload.contains("\"tool_errors\":\"0\"")
                && $0.payload.contains("\"policy_decisions\":\"1\"")
                && $0.payload.contains("\"parse_success_rate\":\"1.00\"")
                && $0.payload.contains("\"tool_success_rate\":\"1.00\"")
                && $0.payload.contains("\"policy_denial_rate\":\"0.00\"")
                && $0.payload.contains("\"fake_completion_repairs\":\"0\"")
                && $0.payload.contains("\"watchdog_warnings\":\"0\"")
        })
        let metricsPayload = try #require(task.events.last { $0.type == "local_agent.metrics" }?.payload)
        let metricsData = try #require(metricsPayload.data(using: .utf8))
        let metrics = try #require(JSONSerialization.jsonObject(with: metricsData) as? [String: String])
        #expect(metrics["first_token_latency_ms"] == "9")
        #expect(metrics["tokens_per_second"] == "12.50")
        #expect(metrics["prompt_tokens_per_second"] == "20.00")
        #expect(metrics["parse_success_rate"] == "1.00")
        #expect(metrics["tool_success_rate"] == "1.00")
        #expect(metrics["policy_denial_rate"] == "0.00")
        #expect(metrics["fake_completion_repairs"] == "0")
        #expect(Int(metrics["model_load_ms"] ?? "") ?? -1 >= 0)
        #expect(metrics["active_memory_bytes"] == "2000")
        #expect(metrics["peak_memory_bytes"] == "3000")
        #expect(metrics["cache_memory_bytes"] == "400")
        #expect(metrics["memory_budget_bytes"] == "4000")
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "workspace.read_file" && id == "read-notes"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .toolResult(let id, let content) = $0 {
                id == "read-notes" && content.contains("Local agent note")
            } else {
                false
            }
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        #expect(requestFiles.count >= 2)

        let requests = try requestFiles.map { url in
            try JSONDecoder().decode(LocalModelRunRequest.self, from: Data(contentsOf: url))
        }
        #expect(requests.contains { request in
            request.messages.contains { $0.role == "system" && $0.content.contains("Local Agent model adapter: Qwen.") }
                && request.messages.contains { $0.role == "user" && $0.content.contains("/no_think") }
        })
        #expect(requests.contains { request in
            request.messages.contains { $0.role == "tool" && $0.content.contains("Local agent note") }
        })
    }

    @Test("Local MLX experimental agent accepts plain text final after tool observation")
    func localMLXExperimentalAgentAcceptsPlainTextFinalAfterToolObservation() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        try "ASTRA_LOCAL_AGENT_PLAIN_TEXT_OK".write(
            to: harness.workspaceURL.appendingPathComponent("plain.txt"),
            atomically: true,
            encoding: .utf8
        )

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            request_file = sys.argv[sys.argv.index("--request-file") + 1]
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)
            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                text = "The file marker is ASTRA_LOCAL_AGENT_PLAIN_TEXT_OK."
            else:
                text = json.dumps({
                    "type": "tool_call",
                    "id": "plain-read",
                    "tool": "workspace.read_file",
                    "arguments": {"path": "plain.txt"}
                }, separators=(",", ":"))

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "plain-text-agent", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": text}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "stats", "inputTokens": 4, "outputTokens": 6}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read plain.txt and include its marker in the final answer",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "The file marker is ASTRA_LOCAL_AGENT_PLAIN_TEXT_OK.")
        #expect(task.events.contains {
            $0.type == "local_agent.action_repaired"
                && $0.payload.contains("plain_text_final_after_observation")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.final"
                && $0.payload.contains("\"format\":\"plain_text_after_observation\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.metrics"
                && $0.payload.contains("\"status\":\"completed\"")
                && $0.payload.contains("\"plain_text_final_repairs\":\"1\"")
        })
    }

    @Test("Local MLX experimental agent falls back to tool observation after empty final repairs")
    func localMLXExperimentalAgentFallsBackToToolObservationAfterEmptyFinalRepairs() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        try "ASTRA_LOCAL_AGENT_OBSERVATION_FALLBACK_OK".write(
            to: harness.workspaceURL.appendingPathComponent("fallback.txt"),
            atomically: true,
            encoding: .utf8
        )

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            request_file = sys.argv[sys.argv.index("--request-file") + 1]
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)
            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                text = ""
            else:
                text = json.dumps({
                    "type": "tool_call",
                    "id": "fallback-read",
                    "tool": "workspace.read_file",
                    "arguments": {"path": "fallback.txt"}
                }, separators=(",", ":"))

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "observation-fallback-agent", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            if text:
                protocol.write(json.dumps({"v": 1, "type": "text", "text": text}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "stats", "inputTokens": 4, "outputTokens": 6}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read fallback.txt and include its marker in the final answer",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output.contains("ASTRA_LOCAL_AGENT_OBSERVATION_FALLBACK_OK"))
        #expect(task.events.contains {
            $0.type == "local_agent.action_repaired"
                && $0.payload.contains("observation_final_after_invalid_action")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.final"
                && $0.payload.contains("\"format\":\"observation_after_invalid_action\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.metrics"
                && $0.payload.contains("\"status\":\"completed\"")
                && $0.payload.contains("\"observation_fallback_finals\":\"1\"")
        })
    }

    @Test("Local MLX experimental agent rejects plain text final before tool observation")
    func localMLXExperimentalAgentRejectsPlainTextFinalBeforeToolObservation() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            request_file = sys.argv[sys.argv.index("--request-file") + 1]
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "plain-text-before-tool", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": "I read the file and found the answer."}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Use workspace tools to read missing.txt before answering",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "local_agent_invalid_action")
        #expect(run.output.isEmpty)
        #expect(!task.events.contains { $0.type == "local_agent.final" })
        #expect(!task.events.contains { $0.type == "tool.use" })
    }

    @Test("Local MLX experimental agent searches workspace and reads task output")
    func localMLXExperimentalAgentSearchesWorkspaceAndReadsTaskOutput() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let docs = harness.workspaceURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "Needle context from the workspace search file.".write(
            to: docs.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if len(tool_messages) == 0:
                action = {
                    "type": "tool_call",
                    "id": "search-workspace",
                    "tool": "workspace.search",
                    "arguments": {"query": "Needle", "path": ".", "max_results": 10}
                }
            elif len(tool_messages) == 1:
                action = {
                    "type": "tool_call",
                    "id": "list-outputs",
                    "tool": "task.list_outputs",
                    "arguments": {"max_results": 10}
                }
            elif len(tool_messages) == 2:
                action = {
                    "type": "tool_call",
                    "id": "read-output",
                    "tool": "task.read_output",
                    "arguments": {"path": "outputs/turn_001.md", "max_bytes": 4096}
                }
            else:
                action = {"type": "final", "answer": "Found workspace notes and read the prior task output."}

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-search-output-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Search the workspace for Needle and inspect current task outputs",
            model: LocalMLXRuntime.defaultModel
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let outputDirectory = URL(fileURLWithPath: taskFolder).appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try "Prior task output with verified details.".write(
            to: outputDirectory.appendingPathComponent("turn_001.md"),
            atomically: true,
            encoding: .utf8
        )

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Found workspace notes and read the prior task output.")
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("workspace.search")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("notes.txt") && $0.payload.contains("Needle context")
        })
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("task.list_outputs")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("turn_001.md")
        })
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("task.read_output")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Prior task output")
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "workspace.search" && id == "search-workspace"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "task.read_output" && id == "read-output"
            } else {
                false
            }
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        #expect(requestFiles.count == 4)
    }

    @Test("Local MLX experimental agent records cancellation and stops helper through control FD")
    func localMLXExperimentalAgentRecordsCancellationAndStopsHelper() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import select
            import sys
            import time

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            if len(sys.argv) < 2 or sys.argv[1] != "run":
                print("usage: astra-local-model run --request-file <path>", file=sys.stderr)
                sys.exit(64)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            control_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_CONTROL_FD", "4"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-agent-cancel-session", "model": request.get("model")})
            pending = b""
            deadline = time.time() + 30
            while time.time() < deadline:
                readable, _, _ = select.select([control_fd], [], [], 0.1)
                if not readable:
                    continue
                chunk = os.read(control_fd, 4096)
                if not chunk:
                    break
                pending += chunk
                if b"\\n" in pending:
                    emit({"v": 1, "type": "cancelled", "message": "cancelled_by_user"})
                    sys.exit(130)
            emit({"v": 1, "type": "text", "text": "{\\"type\\":\\"final\\",\\"answer\\":\\"not cancelled\\"}"})
            sys.exit(0)
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Wait until this local run is cancelled",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        let execution = Swift.Task { @MainActor in
            await harness.execute(task: task, worker: worker)
        }
        let started = await harness.waitUntil(task: task, timeoutSeconds: 5) {
            $0.events.contains { $0.type == "local_agent.turn" }
        }
        #expect(started)

        worker.cancel()
        _ = await execution.value

        let run = try #require(task.runs.first)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.stopReason == "cancelled")
        #expect(run.providerSessionId == "local-agent-cancel-session")
        #expect(task.events.contains {
            $0.type == "local_agent.cancelled" && $0.payload.contains("after local inference")
        })
        let metricsPayload = try #require(task.events.last { $0.type == "local_agent.metrics" }?.payload)
        let metricsData = try #require(metricsPayload.data(using: .utf8))
        let metrics = try #require(JSONSerialization.jsonObject(with: metricsData) as? [String: String])
        #expect(metrics["status"] == "cancelled")
        #expect(Int(metrics["cancellation_latency_ms"] ?? "") ?? -1 >= 0)
    }

    @Test("Local MLX experimental agent writes task output through ASTRA broker")
    func localMLXExperimentalAgentWritesTaskOutputThroughBroker() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(.taskOutputWrite)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Created reports/local-summary.md."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "write-report",
                    "tool": "task.write_output",
                    "arguments": {
                        "path": "reports/local-summary.md",
                        "content": "Local Agent generated report.\\n",
                        "overwrite": False
                    }
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-write-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Create a markdown report file in the task output folder",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .autonomous)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Created reports/local-summary.md.")
        let outputURL = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent("reports/local-summary.md")
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "Local Agent generated report.\n")
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("task.write_output") && $0.payload.contains("local-summary.md")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Wrote task output") && $0.payload.contains("local-summary.md")
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "task.write_output" && id == "write-report"
            } else {
                false
            }
        })
    }

    @Test("Local MLX experimental agent pauses for task output write approval and resumes")
    func localMLXExperimentalAgentPausesForTaskOutputWriteApprovalAndResumes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(.taskOutputWrite)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Approved local report was created."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "write-approved-report",
                    "tool": "task.write_output",
                    "arguments": {
                        "path": "approved/report.md",
                        "content": "Approved Local Agent report.\\n",
                        "overwrite": False
                    }
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-approval-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Create a markdown report file in the task output folder after approval",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .restricted)

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        let outputURL = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent("approved/report.md")
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))

        let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.providerID == .localMLX)
        switch approvalPayload.request {
        case .fileWrite(let path, let toolName):
            #expect(path.hasSuffix("/approved/report.md"))
            #expect(toolName == "Write")
        default:
            Issue.record("Expected task.write_output to request a file-write approval.")
        }
        let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
        #expect(grants.contains(.providerTool(name: "Write")))
        #expect(grants.contains {
            if case .filePath(let path, let access) = $0 {
                return access == "write" && path.hasSuffix("/approved/report.md")
            }
            return false
        })

        _ = await harness.continueTask(
            task: task,
            message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
            worker: worker,
            executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(task.status == .completed)
        #expect(runs[1].status == .completed)
        #expect(runs[1].output == "Approved local report was created.")
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "Approved Local Agent report.\n")
        #expect(task.events.contains {
            $0.type == "local_agent.policy" && $0.payload.contains("previously approved") && $0.payload.contains("task.write_output")
        })
    }

    @Test("Local MLX experimental agent previews approves and records rollback for workspace file edits")
    func localMLXExperimentalAgentPreviewsApprovesAndRecordsRollbackForWorkspaceFileEdits() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(.workspaceWrite)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let targetURL = harness.workspaceURL.appendingPathComponent("notes.md")
        try "Original workspace note.\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Approved workspace note was updated."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "write-workspace-note",
                    "tool": "workspace.write_file",
                    "arguments": {
                        "path": "notes.md",
                        "content": "Updated workspace note.\\n",
                        "overwrite": True
                    }
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-workspace-write-approval-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Update notes.md after showing a preview",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .restricted)

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "Original workspace note.\n")

        let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.providerID == .localMLX)
        #expect(approvalPayload.displayMessage.contains("Diff preview"))
        #expect(approvalPayload.displayMessage.contains("Original workspace note."))
        #expect(approvalPayload.displayMessage.contains("Updated workspace note."))
        switch approvalPayload.request {
        case .fileWrite(let path, let toolName):
            #expect(path == "notes.md")
            #expect(toolName == "Write")
        default:
            Issue.record("Expected workspace.write_file to request a file-write approval.")
        }
        let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
        #expect(grants.contains(.providerTool(name: "Write")))
        #expect(grants.contains {
            if case .filePath(let path, let access) = $0 {
                return access == "write" && path == "notes.md"
            }
            return false
        })

        _ = await harness.continueTask(
            task: task,
            message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
            worker: worker,
            executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(task.status == .completed)
        #expect(runs[1].status == .completed)
        #expect(runs[1].output == "Approved workspace note was updated.")
        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "Updated workspace note.\n")
        #expect(task.events.contains {
            $0.type == "local_agent.policy"
                && $0.payload.contains("previously approved")
                && $0.payload.contains("workspace.write_file")
        })
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact"
                && $0.payload.contains("workspace_file_edit")
                && $0.payload.contains("notes.md")
        })
        let rollbackPath = try #require(Self.jsonStringValue("rollback_path", in: artifactEvent.payload))
        let rollbackURL = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(rollbackPath)
        let rollbackText = try String(contentsOf: rollbackURL, encoding: .utf8)
        #expect(rollbackText.contains("Original workspace note."))
        #expect(task.events.contains {
            $0.type == "tool.result"
                && $0.payload.contains("Rollback evidence")
                && $0.payload.contains(rollbackPath)
        })
    }

    @Test("Local MLX experimental agent approves scoped shell execution and records audit artifact")
    func localMLXExperimentalAgentApprovesScopedShellExecutionAndRecordsAuditArtifact() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(.shellExecution)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let listedURL = harness.workspaceURL.appendingPathComponent("notes.md")
        try "Shell-visible workspace note.\n".write(to: listedURL, atomically: true, encoding: .utf8)

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Approved shell listing completed."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "list-workspace",
                    "tool": "shell.exec",
                    "arguments": {
                        "command": "/bin/ls -1",
                        "cwd": ".",
                        "timeout_seconds": 10,
                        "max_output_bytes": 1000
                    }
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-shell-approval-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "List the workspace after approval",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .restricted)

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")

        let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.providerID == .localMLX)
        #expect(approvalPayload.displayMessage.contains("Shell command preview"))
        #expect(approvalPayload.displayMessage.contains("/bin/ls -1"))
        #expect(approvalPayload.displayMessage.contains("Output cap: 1000 bytes per stream"))
        switch approvalPayload.request {
        case .shell(let command, let toolName):
            #expect(command == "/bin/ls -1")
            #expect(toolName == "Bash")
        default:
            Issue.record("Expected shell.exec to request shell approval.")
        }
        let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
        #expect(grants.contains {
            if case .shellCommand(let executable, _) = $0 {
                return executable == "ls"
            }
            return false
        })

        _ = await harness.continueTask(
            task: task,
            message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
            worker: worker,
            executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(task.status == .completed)
        #expect(runs[1].status == .completed)
        #expect(runs[1].output == "Approved shell listing completed.")
        #expect(task.events.contains {
            $0.type == "local_agent.policy"
                && $0.payload.contains("previously approved")
                && $0.payload.contains("shell.exec")
        })
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact"
                && $0.payload.contains("shell_execution")
        })
        #expect(Self.jsonStringValue("command", in: artifactEvent.payload) == "/bin/ls -1")
        #expect(Self.jsonStringValue("exit_code", in: artifactEvent.payload) == "0")
        #expect(Self.jsonStringValue("timed_out", in: artifactEvent.payload) == "false")
        #expect(task.events.contains {
            $0.type == "tool.result"
                && $0.payload.contains("stdout")
                && $0.payload.contains("notes.md")
        })
    }

    @Test("Local MLX experimental agent approves URL scoped network fetch and records audit artifact")
    func localMLXExperimentalAgentApprovesURLScopedNetworkFetchAndRecordsAuditArtifact() async throws {
        let server = PathRoutingHTTPTestServer(routes: [
            .init(
                requestContains: "/local-agent-network",
                responseBody: #"{"ok":true,"source":"local-agent-network"}"#
            )
        ])
        let port = try server.start()
        defer { server.stop() }

        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(.networkFetch)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let fetchURL = "http://127.0.0.1:\(port)/local-agent-network"
        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Approved network fetch completed."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "fetch-local-json",
                    "tool": "network.fetch",
                    "arguments": {
                        "url": "\(fetchURL)",
                        "method": "GET",
                        "timeout_seconds": 10,
                        "max_response_bytes": 1000
                    }
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-network-approval-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Fetch local test JSON after approval",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .restricted)

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")

        let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.providerID == .localMLX)
        #expect(approvalPayload.displayMessage.contains("Network fetch preview"))
        #expect(approvalPayload.displayMessage.contains(fetchURL))
        #expect(approvalPayload.displayMessage.contains("Response cap: 1000 bytes"))
        switch approvalPayload.request {
        case .network(let url, let toolName):
            #expect(url == fetchURL)
            #expect(toolName == "WebFetch")
        default:
            Issue.record("Expected network.fetch to request network approval.")
        }
        let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
        #expect(grants.contains(.networkPattern(pattern: fetchURL)))
        #expect(grants.contains(.providerTool(name: "WebFetch")))

        _ = await harness.continueTask(
            task: task,
            message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
            worker: worker,
            executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(task.status == .completed)
        #expect(runs[1].status == .completed)
        #expect(runs[1].output == "Approved network fetch completed.")
        #expect(task.events.contains {
            $0.type == "local_agent.policy"
                && $0.payload.contains("previously approved")
                && $0.payload.contains("network.fetch")
        })
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact"
                && $0.payload.contains("network_fetch")
        })
        #expect(Self.jsonStringValue("url", in: artifactEvent.payload) == fetchURL)
        #expect(Self.jsonStringValue("status_code", in: artifactEvent.payload) == "200")
        #expect(Self.jsonStringValue("response_truncated", in: artifactEvent.payload) == "false")
        #expect(task.events.contains {
            $0.type == "tool.result"
                && $0.payload.contains("local-agent-network")
        })
    }

    @Test("Local MLX experimental agent rejects task output symlink escape")
    func localMLXExperimentalAgentRejectsTaskOutputSymlinkEscape() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(.taskOutputWrite)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "ASTRA rejected the unsafe task output path."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "write-symlink-escape",
                    "tool": "task.write_output",
                    "arguments": {
                        "path": "linked/escape.md",
                        "content": "should not leave the task folder\\n",
                        "overwrite": True
                    }
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-symlink-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Verify Local Agent rejects unsafe task-output symlink paths",
            model: LocalMLXRuntime.defaultModel
        )
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let outsideDirectory = harness.rootURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: URL(fileURLWithPath: taskFolder).appendingPathComponent("linked").path,
            withDestinationPath: outsideDirectory.path
        )

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .autonomous)
        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "ASTRA rejected the unsafe task output path.")
        #expect(!FileManager.default.fileExists(atPath: outsideDirectory.appendingPathComponent("escape.md").path))
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("task.write_output") && $0.payload.contains("escape.md")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Missing or disallowed `path`")
        })
    }

    @Test("Local MLX experimental agent reads and analyzes Shelf browser through broker")
    func localMLXExperimentalAgentReadsAndAnalyzesShelfBrowserThroughBroker() async throws {
        let harness = try HeadlessChatHarness()
        defer {
            ShelfBrowserBridgeRegistry.shared.reset()
            harness.cleanup()
        }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if len(tool_messages) == 0:
                action = {
                    "type": "tool_call",
                    "id": "read-browser",
                    "tool": "browser.read_page",
                    "arguments": {"format": "markdown", "limit": 5000}
                }
            elif len(tool_messages) == 1:
                action = {
                    "type": "tool_call",
                    "id": "analyze-browser",
                    "tool": "browser.analyze",
                    "arguments": {"query": "Save", "limit": 5}
                }
            else:
                action = {"type": "final", "answer": "Browser evidence and controls were inspected through ASTRA."}

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-browser-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read the current browser page and find the Save control",
            model: LocalMLXRuntime.defaultModel
        )

        let endpoint = BrowserBridgeTestEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "browser-token", route: { request in
            switch (request.method, request.path) {
            case ("GET", "/readPage"):
                return .json([
                    "ok": true,
                    "format": "markdown",
                    "markdown": "# Visible Browser Evidence\nCurrent page content."
                ])
            case ("GET", "/analyze"):
                return .json([
                    "ok": true,
                    "analysisID": "ana_1",
                    "controls": [
                        ["controlID": "save-button", "role": "button", "name": "Save"]
                    ]
                ])
            default:
                return .json(["ok": false, "path": request.path], statusCode: 404)
            }
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }
        let bridgeURL = try await endpoint.waitForURL()
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: bridgeURL.absoluteString,
            currentURL: "https://example.test/document",
            currentTitle: "Document",
            taskID: task.id,
            accessToken: "browser-token",
            isPresented: true,
            isEnabled: true
        )

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Browser evidence and controls were inspected through ASTRA.")
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("browser.read_page")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Visible Browser Evidence")
        })
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("browser.analyze")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("save-button")
        })
        #expect(!task.events.contains { $0.payload.contains("browser-token") })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "browser.read_page" && id == "read-browser"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "browser.analyze" && id == "analyze-browser"
            } else {
                false
            }
        })
    }

    @Test("Local MLX experimental agent approves browser click and records audit artifact")
    func localMLXExperimentalAgentApprovesBrowserClickAndRecordsAuditArtifact() async throws {
        let harness = try HeadlessChatHarness()
        defer {
            ShelfBrowserBridgeRegistry.shared.reset()
            harness.cleanup()
        }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(.browserClick)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Approved browser click completed."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "click-save",
                    "tool": "browser.click",
                    "arguments": {
                        "analysisID": "ana_1",
                        "controlID": "save-button",
                        "role": "button"
                    }
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-browser-click-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Click Save after approval",
            model: LocalMLXRuntime.defaultModel
        )

        let endpoint = BrowserBridgeTestEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "browser-token", route: { request in
            switch (request.method, request.path) {
            case ("POST", "/click"):
                let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
                return .json([
                    "ok": object["analysisID"] as? String == "ana_1"
                        && object["controlID"] as? String == "save-button"
                        && object["allowDangerous"] as? Bool == false,
                    "clicked": true,
                    "summary": "Clicked Save"
                ])
            default:
                return .json(["ok": false, "path": request.path], statusCode: 404)
            }
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }
        let bridgeURL = try await endpoint.waitForURL()
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: bridgeURL.absoluteString,
            currentURL: "https://example.test/document",
            currentTitle: "Document",
            taskID: task.id,
            accessToken: "browser-token",
            isPresented: true,
            isEnabled: true
        )

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .restricted)
        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")

        let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.displayMessage.contains("Browser click preview"))
        #expect(approvalPayload.displayMessage.contains("analysis:ana_1#save-button"))
        #expect(approvalPayload.displayMessage.contains("Dangerous confirmations: disabled"))
        let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
        #expect(grants == [.browserAction(action: "browser.click", target: "analysis:ana_1#save-button")])

        _ = await harness.continueTask(
            task: task,
            message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
            worker: worker,
            executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(task.status == .completed)
        #expect(runs[1].status == .completed)
        #expect(runs[1].output == "Approved browser click completed.")
        #expect(task.events.contains {
            $0.type == "local_agent.policy"
                && $0.payload.contains("previously approved")
                && $0.payload.contains("browser.click")
        })
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact"
                && $0.payload.contains("browser_mutation")
        })
        #expect(Self.jsonStringValue("action", in: artifactEvent.payload) == "click")
        #expect(Self.jsonStringValue("target", in: artifactEvent.payload) == "analysis:ana_1#save-button")
        #expect(Self.jsonStringValue("bridge_ok", in: artifactEvent.payload) == "true")
        #expect(task.events.contains {
            $0.type == "tool.result"
                && $0.payload.contains("Clicked Save")
        })
    }

    @Test("Local MLX experimental agent approves browser typing and records audit artifact")
    func localMLXExperimentalAgentApprovesBrowserTypingAndRecordsAuditArtifact() async throws {
        let harness = try HeadlessChatHarness()
        defer {
            ShelfBrowserBridgeRegistry.shared.reset()
            harness.cleanup()
        }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(.browserType)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Approved browser typing completed."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "type-search",
                    "tool": "browser.type",
                    "arguments": {
                        "selector": "input[name=q]",
                        "text": "Astra search",
                        "clear": True
                    }
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-browser-type-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Type into search after approval",
            model: LocalMLXRuntime.defaultModel
        )

        let endpoint = BrowserBridgeTestEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "browser-token", route: { request in
            switch (request.method, request.path) {
            case ("POST", "/type"):
                let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
                return .json([
                    "ok": object["selector"] as? String == "input[name=q]"
                        && object["text"] as? String == "Astra search"
                        && object["clear"] as? Bool == true
                        && object["allowDangerous"] as? Bool == false,
                    "typed": true,
                    "summary": "Typed search text"
                ])
            default:
                return .json(["ok": false, "path": request.path], statusCode: 404)
            }
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }
        let bridgeURL = try await endpoint.waitForURL()
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: bridgeURL.absoluteString,
            currentURL: "https://example.test/search",
            currentTitle: "Search",
            taskID: task.id,
            accessToken: "browser-token",
            isPresented: true,
            isEnabled: true
        )

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .restricted)
        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")

        let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.displayMessage.contains("Browser typing preview"))
        #expect(approvalPayload.displayMessage.contains("selector:input[name=q]"))
        #expect(approvalPayload.displayMessage.contains("Text length: 12 characters"))
        #expect(approvalPayload.displayMessage.contains("Dangerous confirmations: disabled"))
        let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
        #expect(grants == [.browserAction(action: "browser.type", target: "selector:input[name=q]")])

        _ = await harness.continueTask(
            task: task,
            message: PermissionBroker.resumeMessage(providerID: .localMLX, grants: grants),
            worker: worker,
            executionPolicy: PermissionBroker.executionPolicy(forRuntime: .localMLX, grants: grants)
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(task.status == .completed)
        #expect(runs[1].status == .completed)
        #expect(runs[1].output == "Approved browser typing completed.")
        #expect(task.events.contains {
            $0.type == "local_agent.policy"
                && $0.payload.contains("previously approved")
                && $0.payload.contains("browser.type")
        })
        let artifactEvent = try #require(task.events.last {
            $0.type == "local_agent.tool_artifact"
                && $0.payload.contains("browser_mutation")
        })
        #expect(Self.jsonStringValue("action", in: artifactEvent.payload) == "type")
        #expect(Self.jsonStringValue("target", in: artifactEvent.payload) == "selector:input[name=q]")
        #expect(Self.jsonStringValue("text_chars", in: artifactEvent.payload) == "12")
        #expect(Self.jsonStringValue("bridge_ok", in: artifactEvent.payload) == "true")
        #expect(!artifactEvent.payload.contains("Astra search"))
        #expect(task.events.contains {
            $0.type == "tool.result"
                && $0.payload.contains("Typed search text")
        })
    }

    @Test("Local MLX experimental agent cancels in-flight browser tool request")
    func localMLXExperimentalAgentCancelsInFlightBrowserToolRequest() async throws {
        let harness = try HeadlessChatHarness()
        defer {
            ShelfBrowserBridgeRegistry.shared.reset()
            harness.cleanup()
        }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            action = {
                "type": "tool_call",
                "id": "read-slow-browser",
                "tool": "browser.read_page",
                "arguments": {"format": "markdown", "limit": 5000}
            }
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-browser-cancel-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read a slow browser page until cancelled",
            model: LocalMLXRuntime.defaultModel
        )

        let endpoint = BrowserBridgeTestEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "browser-token", route: { request in
            switch (request.method, request.path) {
            case ("GET", "/readPage"):
                try? await Swift.Task.sleep(nanoseconds: 5_000_000_000)
                return .json(["ok": true, "markdown": "late browser response"])
            default:
                return .json(["ok": false, "path": request.path], statusCode: 404)
            }
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }
        let bridgeURL = try await endpoint.waitForURL()
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: bridgeURL.absoluteString,
            currentURL: "https://example.test/slow",
            currentTitle: "Slow Document",
            taskID: task.id,
            accessToken: "browser-token",
            isPresented: true,
            isEnabled: true
        )

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let execution = Swift.Task { @MainActor in
            await harness.execute(task: task, worker: worker)
        }
        let toolStarted = await harness.waitUntil(task: task, timeoutSeconds: 5) {
            $0.events.contains {
                $0.type == "tool.use" && $0.payload.contains("browser.read_page")
            }
        }
        #expect(toolStarted)

        worker.cancel()
        _ = await execution.value

        let run = try #require(task.runs.first)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.stopReason == "cancelled")
        #expect(task.events.contains {
            $0.type == "local_agent.cancelled" && $0.payload.contains("after tool browser.read_page")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.blocked" && $0.payload.contains("\"reason\":\"cancelled\"")
        })
        #expect(!task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("late browser response")
        })
    }

    @Test("Local MLX experimental agent searches Jira through ASTRA connector broker")
    func localMLXExperimentalAgentSearchesJiraThroughConnectorBroker() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let server = JiraSearchHTTPTestServer(responseBody: """
        {
          "permissions": {
            "BROWSE_PROJECTS": {"havePermission": true},
            "CREATE_ISSUES": {"havePermission": true}
          },
          "issues": [
            {
              "key": "STAR-12246",
              "fields": {
                "summary": "Prepare PAQS response",
                "status": {"name": "In Progress"},
                "assignee": {"displayName": "A. User"},
                "issuetype": {"name": "Story"},
                "updated": "2026-05-28T08:00:00.000-0700"
              }
            }
          ]
        }
        """)
        let port = try server.start()
        defer { server.stop() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Jira summary: STAR-12246 Prepare PAQS response is In Progress."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "search-jira",
                    "tool": "jira.search",
                    "arguments": {"jql": "project = STAR ORDER BY updated DESC", "max_results": 5}
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-agent-jira-session", "model": request.get("model")})
            emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
            emit({"v": 1, "type": "stats", "inputTokens": 5, "outputTokens": 7, "durationMs": 12, "turns": 1})
            emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read the latest STAR stories from Jira and summarize them",
            model: LocalMLXRuntime.defaultModel
        )
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "http://127.0.0.1:\(port)",
            authMethod: "none"
        )
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = ["STAR"]
        task.workspace?.connectors.append(connector)
        harness.context.insert(connector)
        try harness.context.save()

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Jira summary: STAR-12246 Prepare PAQS response is In Progress.")
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("jira.search")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("STAR-12246") && $0.payload.contains("Prepare PAQS response")
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "jira.search" && id == "search-jira"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .toolResult(let id, let content) = $0 {
                id == "search-jira" && content.contains("STAR-12246")
            } else {
                false
            }
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        let requests = try requestFiles.map { url in
            try JSONDecoder().decode(LocalModelRunRequest.self, from: Data(contentsOf: url))
        }
        #expect(requests.contains { request in
            request.messages.contains { $0.role == "tool" && $0.content.contains("STAR-12246") }
        })
    }

    @Test("Local MLX experimental agent searches GitHub through ASTRA connector broker")
    func localMLXExperimentalAgentSearchesGitHubThroughConnectorBroker() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let server = JiraSearchHTTPTestServer(responseBody: """
        {
          "items": [
            {
              "number": 92,
              "title": "Add Local MLX provider",
              "state": "open",
              "html_url": "https://github.com/susom/astra/pull/92",
              "repository_url": "https://api.github.com/repos/susom/astra",
              "pull_request": {"html_url": "https://github.com/susom/astra/pull/92"},
              "user": {"login": "alvaro1"},
              "updated_at": "2026-05-28T20:00:00Z"
            }
          ]
        }
        """)
        let port = try server.start()
        defer { server.stop() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "GitHub summary: susom/astra#92 Add Local MLX provider is open."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "search-github",
                    "tool": "github.search",
                    "arguments": {"query": "local mlx", "repo": "susom/astra", "type": "pr", "state": "open", "max_results": 5}
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-agent-github-session", "model": request.get("model")})
            emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
            emit({"v": 1, "type": "stats", "inputTokens": 5, "outputTokens": 7, "durationMs": 12, "turns": 1})
            emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read open GitHub PRs about Local MLX in susom/astra and summarize them",
            model: LocalMLXRuntime.defaultModel
        )
        let connector = Connector(
            name: "GitHub",
            serviceType: "github",
            baseURL: "http://127.0.0.1:\(port)",
            authMethod: "none"
        )
        connector.configKeys = ["GITHUB_REPOS"]
        connector.configValues = ["susom/astra"]
        task.workspace?.connectors.append(connector)
        harness.context.insert(connector)
        try harness.context.save()

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "GitHub summary: susom/astra#92 Add Local MLX provider is open.")
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("github.search")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("susom/astra#92") && $0.payload.contains("Add Local MLX provider")
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "github.search" && id == "search-github"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .toolResult(let id, let content) = $0 {
                id == "search-github" && content.contains("susom/astra#92")
            } else {
                false
            }
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        let requests = try requestFiles.map { url in
            try JSONDecoder().decode(LocalModelRunRequest.self, from: Data(contentsOf: url))
        }
        #expect(requests.contains { request in
            request.messages.contains { $0.role == "tool" && $0.content.contains("susom/astra#92") }
        })
    }

    @Test("Local MLX experimental agent searches Google Drive through connector broker")
    func localMLXExperimentalAgentSearchesGoogleDriveThroughConnectorBroker() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let server = JiraSearchHTTPTestServer(responseBody: """
        {
          "files": [
            {
              "id": "drive-file-1",
              "name": "Launch Notes",
              "mimeType": "application/vnd.google-apps.document",
              "webViewLink": "https://drive.google.com/document/d/drive-file-1",
              "modifiedTime": "2026-05-28T18:00:00Z",
              "owners": [{"displayName": "A. User"}],
              "size": "128"
            }
          ]
        }
        """)
        let port = try server.start()
        defer { server.stop() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Drive summary: Launch Notes drive-file-1 was updated on 2026-05-28."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "search-drive",
                    "tool": "google_drive.search",
                    "arguments": {"query": "launch notes", "max_results": 5}
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-agent-drive-session", "model": request.get("model")})
            emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
            emit({"v": 1, "type": "stats", "inputTokens": 5, "outputTokens": 7, "durationMs": 12, "turns": 1})
            emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Find launch notes in Google Drive and summarize the matching file",
            model: LocalMLXRuntime.defaultModel
        )
        let connector = Connector(
            name: "Google Drive",
            serviceType: "google_drive",
            baseURL: "http://127.0.0.1:\(port)",
            authMethod: "none"
        )
        task.workspace?.connectors.append(connector)
        harness.context.insert(connector)
        try harness.context.save()

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Drive summary: Launch Notes drive-file-1 was updated on 2026-05-28.")
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("google_drive.search")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Launch Notes") && $0.payload.contains("drive-file-1")
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "google_drive.search" && id == "search-drive"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .toolResult(let id, let content) = $0 {
                id == "search-drive" && content.contains("Launch Notes")
            } else {
                false
            }
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        let requests = try requestFiles.map { url in
            try JSONDecoder().decode(LocalModelRunRequest.self, from: Data(contentsOf: url))
        }
        #expect(requests.contains { request in
            request.messages.contains { $0.role == "tool" && $0.content.contains("drive-file-1") }
        })
    }

    @Test("Local MLX experimental agent searches Gmail through connector broker")
    func localMLXExperimentalAgentSearchesGmailThroughConnectorBroker() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let messageBody = """
        {
          "id": "gmail-msg-1",
          "threadId": "gmail-thread-1",
          "snippet": "Please review the launch meeting summary.",
          "payload": {
            "mimeType": "multipart/alternative",
            "headers": [
              {"name": "Subject", "value": "Launch meeting notes"},
              {"name": "From", "value": "Ada <ada@example.com>"},
              {"name": "To", "value": "Team <team@example.com>"},
              {"name": "Date", "value": "Thu, 28 May 2026 10:00:00 -0700"}
            ],
            "parts": [
              {
                "mimeType": "text/plain",
                "body": {
                  "data": "TGF1bmNoIG1lZXRpbmcgbm90ZXMKUGxlYXNlIHJldmlldyB0aGUgc3VtbWFyeSBiZWZvcmUgRnJpZGF5Lg"
                }
              }
            ]
          }
        }
        """
        let server = PathRoutingHTTPTestServer(routes: [
            .init(requestContains: "/gmail/v1/users/me/messages/gmail-msg-1", responseBody: messageBody),
            .init(requestContains: "/gmail/v1/users/me/messages?", responseBody: """
            {
              "messages": [
                {"id": "gmail-msg-1", "threadId": "gmail-thread-1"}
              ],
              "resultSizeEstimate": 1
            }
            """)
        ])
        let port = try server.start()
        defer { server.stop() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Gmail summary: Launch meeting notes asked the team to review the summary before Friday."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "search-gmail",
                    "tool": "gmail.search",
                    "arguments": {"query": "launch meeting", "max_results": 2}
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-agent-gmail-session", "model": request.get("model")})
            emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
            emit({"v": 1, "type": "stats", "inputTokens": 5, "outputTokens": 7, "durationMs": 12, "turns": 1})
            emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Find launch meeting notes in Gmail and summarize the matching message",
            model: LocalMLXRuntime.defaultModel
        )
        let connector = Connector(
            name: "Gmail",
            serviceType: "gmail",
            baseURL: "http://127.0.0.1:\(port)",
            authMethod: "none"
        )
        task.workspace?.connectors.append(connector)
        harness.context.insert(connector)
        try harness.context.save()

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Gmail summary: Launch meeting notes asked the team to review the summary before Friday.")
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("gmail.search")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Launch meeting notes") && $0.payload.contains("gmail-msg-1")
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "gmail.search" && id == "search-gmail"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .toolResult(let id, let content) = $0 {
                id == "search-gmail" && content.contains("Launch meeting notes")
            } else {
                false
            }
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        let requests = try requestFiles.map { url in
            try JSONDecoder().decode(LocalModelRunRequest.self, from: Data(contentsOf: url))
        }
        #expect(requests.contains { request in
            request.messages.contains { $0.role == "tool" && $0.content.contains("gmail-msg-1") }
        })
    }

    @Test("Local MLX experimental agent searches Slack through connector broker")
    func localMLXExperimentalAgentSearchesSlackThroughConnectorBroker() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let server = PathRoutingHTTPTestServer(routes: [
            .init(requestContains: "/search.messages?", responseBody: """
            {
              "ok": true,
              "messages": {
                "matches": [
                  {
                    "iid": "slack-msg-1",
                    "channel": {"id": "C123", "name": "release"},
                    "user": "U123",
                    "username": "ada",
                    "text": "Release notes are ready.",
                    "ts": "1716920000.000100",
                    "permalink": "https://example.slack.com/archives/C123/p1716920000000100"
                  }
                ]
              }
            }
            """)
        ])
        let port = try server.start()
        defer { server.stop() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Slack summary: Release notes are ready in #release."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "search-slack",
                    "tool": "slack.search",
                    "arguments": {"query": "release notes", "max_results": 2}
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-agent-slack-session", "model": request.get("model")})
            emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
            emit({"v": 1, "type": "stats", "inputTokens": 5, "outputTokens": 7, "durationMs": 12, "turns": 1})
            emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Find release notes in Slack and summarize the matching message",
            model: LocalMLXRuntime.defaultModel
        )
        let connector = Connector(
            name: "Slack",
            serviceType: "slack",
            baseURL: "http://127.0.0.1:\(port)",
            authMethod: "none"
        )
        task.workspace?.connectors.append(connector)
        harness.context.insert(connector)
        try harness.context.save()

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Slack summary: Release notes are ready in #release.")
        #expect(task.events.contains {
            $0.type == "tool.use" && $0.payload.contains("slack.search")
        })
        #expect(task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Release notes are ready.") && $0.payload.contains("slack-msg-1")
        })
        #expect(events.contains {
            if case .toolUse(let name, let id, _) = $0 {
                name == "slack.search" && id == "search-slack"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case .toolResult(let id, let content) = $0 {
                id == "search-slack" && content.contains("Release notes are ready.")
            } else {
                false
            }
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        let requests = try requestFiles.map { url in
            try JSONDecoder().decode(LocalModelRunRequest.self, from: Data(contentsOf: url))
        }
        #expect(requests.contains { request in
            request.messages.contains { $0.role == "tool" && $0.content.contains("slack-msg-1") }
        })
    }

    @Test("Local MLX connector secrets never enter helper replay or task diagnostics")
    func localMLXConnectorSecretsNeverEnterHelperReplayOrTaskDiagnostics() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let server = PathRoutingHTTPTestServer(routes: [
            .init(requestContains: "/search.messages?", responseBody: """
            {
              "ok": true,
              "messages": {
                "matches": [
                  {
                    "iid": "slack-secret-check",
                    "channel": {"id": "C123", "name": "release"},
                    "user": "U123",
                    "username": "ada",
                    "text": "Release notes are ready.",
                    "ts": "1716920000.000100",
                    "permalink": "https://example.slack.com/archives/C123/p1716920000000100"
                  }
                ]
              }
            }
            """)
        ])
        let port = try server.start()
        defer { server.stop() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            messages = request.get("messages", [])
            tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
            if tool_messages:
                action = {"type": "final", "answer": "Secret redaction check complete."}
            else:
                action = {
                    "type": "tool_call",
                    "id": "search-slack-secret",
                    "tool": "slack.search",
                    "arguments": {"query": "release notes", "max_results": 2}
                }

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)

            def emit(payload):
                protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                protocol.flush()

            emit({"v": 1, "type": "started", "sessionID": "local-agent-secret-session", "model": request.get("model")})
            emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
            emit({"v": 1, "type": "stats", "inputTokens": 5, "outputTokens": 7, "durationMs": 12, "turns": 1})
            emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Find release notes in Slack",
            model: LocalMLXRuntime.defaultModel
        )
        let connector = Connector(
            name: "Slack Secret",
            serviceType: "slack",
            baseURL: "http://127.0.0.1:\(port)",
            authMethod: "bearer"
        )
        let secretValue = "super-secret-local-agent-slack-token"
        connector.saveCredential(key: "SLACK_TOKEN", value: secretValue)
        defer { connector.cleanupKeychain() }
        task.workspace?.connectors.append(connector)
        harness.context.insert(connector)
        try harness.context.save()

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        let helperIPC = try requestFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let diagnostics = task.events
            .map(\.payload)
            .joined(separator: "\n")

        #expect(helperIPC.contains("slack-secret-check"))
        #expect(!helperIPC.contains(secretValue))
        #expect(!diagnostics.contains(secretValue))
        #expect(!run.output.contains(secretValue))
    }

    @Test("Local MLX experimental agent cancels in-flight Jira connector request")
    func localMLXExperimentalAgentCancelsInFlightJiraConnectorRequest() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let server = JiraSearchHTTPTestServer(
            responseBody: """
            {
              "permissions": {
                "BROWSE_PROJECTS": {"havePermission": true},
                "CREATE_ISSUES": {"havePermission": true}
              },
              "issues": [
                {
                  "key": "STAR-999",
                  "fields": {
                    "summary": "Late Jira response",
                    "status": {"name": "Done"},
                    "assignee": null,
                    "issuetype": {"name": "Story"},
                    "updated": "2026-05-28T08:00:00.000-0700"
                  }
                }
              ]
            }
            """,
            responseDelay: 5,
            delayedPathContains: "/rest/api/3/search/jql"
        )
        let port = try server.start()
        defer { server.stop() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            action = {
                "type": "tool_call",
                "id": "search-slow-jira",
                "tool": "jira.search",
                "arguments": {"jql": "project = STAR ORDER BY updated DESC", "max_results": 5}
            }
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-jira-cancel-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read the latest STAR stories from Jira until cancelled",
            model: LocalMLXRuntime.defaultModel
        )
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "http://127.0.0.1:\(port)",
            authMethod: "none"
        )
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = ["STAR"]
        task.workspace?.connectors.append(connector)
        harness.context.insert(connector)
        try harness.context.save()

        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)
        let execution = Swift.Task { @MainActor in
            await harness.execute(task: task, worker: worker)
        }
        let toolStarted = await harness.waitUntil(task: task, timeoutSeconds: 5) {
            $0.events.contains {
                $0.type == "tool.use" && $0.payload.contains("jira.search")
            }
        }
        #expect(toolStarted)

        worker.cancel()
        _ = await execution.value

        let run = try #require(task.runs.first)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.stopReason == "cancelled")
        #expect(task.events.contains {
            $0.type == "local_agent.cancelled" && $0.payload.contains("after tool jira.search")
        })
        #expect(!task.events.contains {
            $0.type == "tool.result" && $0.payload.contains("Late Jira response")
        })
    }

    @Test("Local MLX experimental agent rejects action final without a tool observation")
    func localMLXExperimentalAgentRejectsActionFinalWithoutToolObservation() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            action = {"type": "final", "answer": "I will now proceed to read Jira."}
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-missing-tool-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read the latest STAR stories from Jira",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "local_agent_missing_tool_observation")
        #expect(run.output.isEmpty)
        #expect(!task.events.contains { $0.type == "tool.use" })
        #expect(task.events.contains {
            $0.type == "local_agent.missing_tool_observation"
        })
        #expect(task.events.contains {
            $0.type == "local_agent.repair_requested"
                && $0.payload.contains("\"reason\":\"missing_tool_observation\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.blocked"
                && $0.payload.contains("\"reason\":\"missing_tool_observation\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.watchdog"
                && $0.payload.contains("\"reason\":\"missing_tool_observation_repair_budget_exhausted\"")
                && $0.payload.contains("\"recovery\":\"Retry in Local Agent mode with a concrete tool-backed request")
        })
        #expect(task.events.contains {
            $0.type == "error" && $0.payload.contains("No external action was executed")
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        #expect(requestFiles.count == 2)
        let requests = try requestFiles.map { url in
            try JSONDecoder().decode(LocalModelRunRequest.self, from: Data(contentsOf: url))
        }
        #expect(requests.contains { request in
            request.messages.contains { $0.role == "user" && $0.content.contains("requires ASTRA tool observations") }
        })
    }

    @Test("Local MLX experimental agent stops after the tool call budget")
    func localMLXExperimentalAgentStopsAfterToolCallBudget() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        let previousMaxToolCalls = defaults.object(forKey: LocalModelSettingsStore.localAgentMaxToolCallsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(2, forKey: LocalModelSettingsStore.localAgentMaxToolCallsKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
            if let previousMaxToolCalls {
                defaults.set(previousMaxToolCalls, forKey: LocalModelSettingsStore.localAgentMaxToolCallsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.localAgentMaxToolCallsKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            action = {
                "type": "tool_call",
                "id": "list-loop",
                "tool": "workspace.list_files",
                "arguments": {"path": ".", "max_results": 5}
            }
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-tool-budget-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Keep listing workspace files until the local agent budget stops the loop",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "local_agent_tool_budget_exceeded")
        #expect(task.events.contains {
            $0.type == "local_agent.tool_budget_exceeded" && $0.payload.contains("2")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.metrics"
                && $0.payload.contains("\"status\":\"blocked\"")
                && $0.payload.contains("\"stop_reason\":\"local_agent_tool_budget_exceeded\"")
                && $0.payload.contains("\"tool_calls\":\"2\"")
        })
        #expect(task.events.filter { $0.type == "tool.use" }.count == 2)

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        #expect(requestFiles.count == 3)
    }

    @Test("Local MLX experimental agent stops disallowed workspace reads before tool execution")
    func localMLXExperimentalAgentStopsDisallowedWorkspaceReadsBeforeToolExecution() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            action = {
                "type": "tool_call",
                "id": "read-etc",
                "tool": "workspace.read_file",
                "arguments": {"path": "/etc/hosts"}
            }
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-policy-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Read /etc/hosts",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "policy_violation")
        #expect(run.output.isEmpty)
        #expect(task.events.contains {
            $0.type == "permission.denied" && $0.payload.contains("outside the workspace paths")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.policy_decision"
                && $0.payload.contains("\"status\":\"denied\"")
                && $0.payload.contains("\"tool\":\"workspace.read_file\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.blocked"
                && $0.payload.contains("\"reason\":\"policy_violation\"")
                && $0.payload.contains("\"tool\":\"workspace.read_file\"")
        })
        #expect(!task.events.contains { $0.type == "tool.result" })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        #expect(requestFiles.count == 1)
    }

    @Test("Local MLX experimental agent stops high-risk unsupported tools at policy")
    func localMLXExperimentalAgentStopsHighRiskUnsupportedToolsAtPolicy() async throws {
        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let cases: [(name: String, goal: String, callID: String, tool: String, argumentsJSON: String)] = [
            (
                "unsupported browser submit",
                "Submit the current browser form",
                "browser-submit-1",
                "browser.submit",
                #"{"selector":"form.search"}"#
            )
        ]

        for testCase in cases {
            let harness = try HeadlessChatHarness()
            defer { harness.cleanup() }

            let localPath = try harness.writeExecutable(
                named: "astra-local-model",
                script: """
                #!/usr/bin/env python3
                import json
                import os
                import sys

                if "--version" in sys.argv[1:]:
                    print("astra-local-model 0.1.0")
                    sys.exit(0)
                try:
                    request_file = sys.argv[sys.argv.index("--request-file") + 1]
                except (ValueError, IndexError):
                    print("missing request file", file=sys.stderr)
                    sys.exit(64)
                with open(request_file, "r", encoding="utf-8") as handle:
                    request = json.load(handle)

                action = {
                    "type": "tool_call",
                    "id": "\(testCase.callID)",
                    "tool": "\(testCase.tool)",
                    "arguments": \(testCase.argumentsJSON)
                }
                protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
                protocol = os.fdopen(protocol_fd, "w", closefd=False)
                protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-high-risk-policy-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
                protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
                protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
                protocol.flush()
                """
            )

            let task = harness.makeTask(
                runtime: .localMLX,
                goal: testCase.goal,
                model: LocalMLXRuntime.defaultModel
            )
            let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

            _ = await harness.execute(task: task, worker: worker)

            let run = try #require(task.runs.first, "Expected a run for \(testCase.name)")
            #expect(task.status == .pendingUser)
            #expect(run.status == .failed)
            #expect(run.stopReason == "policy_violation")
            #expect(task.events.contains {
                $0.type == "permission.denied" && $0.payload.contains(testCase.tool)
            })
            #expect(task.events.contains {
                $0.type == "local_agent.policy_decision"
                    && $0.payload.contains("\"status\":\"denied\"")
                    && $0.payload.contains("\"tool\":\"\(testCase.tool)\"")
            })
            #expect(task.events.contains {
                $0.type == "local_agent.blocked"
                    && $0.payload.contains("\"reason\":\"policy_violation\"")
                    && $0.payload.contains("\"tool\":\"\(testCase.tool)\"")
            })
            #expect(!task.events.contains { $0.type == "tool.use" && $0.payload.contains(testCase.tool) })
            #expect(!task.events.contains { $0.type == "tool.result" })
        }
    }

    @Test("Local MLX experimental agent blocks disabled high-risk capabilities before approval")
    func localMLXExperimentalAgentBlocksDisabledHighRiskCapabilitiesBeforeApproval() async throws {
        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities()
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            action = {
                "type": "tool_call",
                "id": "disabled-shell",
                "tool": "shell.exec",
                "arguments": {"command": "/bin/echo should-not-run", "cwd": "."}
            }
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-disabled-capability-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Run a disabled shell command",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath, permissionPolicy: .restricted)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "policy_violation")
        #expect(task.events.contains {
            $0.type == "permission.denied"
                && $0.payload.contains("shell commands")
                && $0.payload.contains("disabled in Runtime settings")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.policy_decision"
                && $0.payload.contains("\"status\":\"denied\"")
                && $0.payload.contains("\"tool\":\"shell.exec\"")
        })
        #expect(!task.events.contains { $0.type == "permission.approval.requested" })
        #expect(!task.events.contains { $0.type == "tool.use" && $0.payload.contains("shell.exec") })
        #expect(!task.events.contains { $0.type == "tool.result" })
    }

    @Test("Local MLX experimental agent stops on cancelled lifecycle action")
    func localMLXExperimentalAgentStopsOnCancelledLifecycleAction() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            action = {"type": "cancelled", "id": "cancel-1", "reason": "Cancellation was requested before more local work."}
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-cancelled-action-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Cancel the local agent run",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.stopReason == "cancelled")
        #expect(task.events.contains {
            $0.type == "local_agent.action_proposed"
                && $0.payload.contains("\"action\":\"cancelled\"")
                && $0.payload.contains("\"id\":\"cancel-1\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.cancelled"
                && $0.payload.contains("Cancellation was requested before more local work")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.blocked"
                && $0.payload.contains("\"reason\":\"cancelled\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.metrics"
                && $0.payload.contains("\"status\":\"cancelled\"")
                && $0.payload.contains("\"stop_reason\":\"local_agent_cancelled\"")
        })
    }

    @Test("Local MLX experimental agent repairs malformed action output")
    func localMLXExperimentalAgentRepairsMalformedActionOutput() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            messages = request.get("messages", [])
            repair_requested = any("Repair the previous response" in message.get("content", "") for message in messages)
            text = json.dumps({"type": "final", "answer": "Recovered from malformed local action."}, separators=(",", ":")) if repair_requested else "I will answer in prose first."

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-repair-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": text}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": text}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Answer after repairing malformed local action output",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Recovered from malformed local action.")
        #expect(task.events.contains {
            $0.type == "local_agent.invalid_action" && $0.payload.contains("No JSON action object")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.repair_requested"
                && $0.payload.contains("\"reason\":\"invalid_action\"")
                && $0.payload.contains("\"attempt\":\"1\"")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.final"
                && $0.payload.contains("\"tool_calls\":\"0\"")
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        #expect(requestFiles.count == 2)
    }

    @Test("Local MLX experimental agent reports watchdog after repeated malformed actions")
    func localMLXExperimentalAgentReportsWatchdogAfterRepeatedMalformedActions() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-watchdog-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": "I will answer in prose again."}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": "I will answer in prose again."}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Keep returning malformed local action output until the watchdog reports it",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "local_agent_invalid_action")
        #expect(task.events.contains {
            $0.type == "local_agent.watchdog"
                && $0.payload.contains("\"reason\":\"invalid_action_repair_budget_exhausted\"")
                && $0.payload.contains("\"phase\":\"action_parse\"")
                && $0.payload.contains("\"max_repairs\":\"2\"")
                && $0.payload.contains("\"recovery\":\"Retry with a narrower task")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.metrics"
                && $0.payload.contains("\"stop_reason\":\"local_agent_invalid_action\"")
                && $0.payload.contains("\"watchdog_warnings\":\"1\"")
        })

        let requestDirectory = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".local-agent", isDirectory: true)
        let requestFiles = try FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("request-") }
        #expect(requestFiles.count == 3)
    }

    @Test("Local MLX experimental agent records memory pressure recovery guidance")
    func localMLXExperimentalAgentRecordsMemoryPressureRecoveryGuidance() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defer {
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }

        let localPath = try harness.writeExecutable(
            named: "astra-local-model",
            script: """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            if "--version" in sys.argv[1:]:
                print("astra-local-model 0.1.0")
                sys.exit(0)
            try:
                request_file = sys.argv[sys.argv.index("--request-file") + 1]
            except (ValueError, IndexError):
                print("missing request file", file=sys.stderr)
                sys.exit(64)
            with open(request_file, "r", encoding="utf-8") as handle:
                request = json.load(handle)

            action = {"type": "final", "answer": "Local Agent recovered from memory pressure."}
            protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
            protocol = os.fdopen(protocol_fd, "w", closefd=False)
            protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "local-agent-memory-session", "model": request.get("model")}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "memory", "phase": "generate", "message": "memory pressure: memory limit exceeded"}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
            protocol.flush()
            """
        )

        let task = harness.makeTask(
            runtime: .localMLX,
            goal: "Answer locally and report memory pressure guidance",
            model: LocalMLXRuntime.defaultModel
        )
        let worker = harness.makeWorker(runtime: .localMLX, executablePath: localPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Local Agent recovered from memory pressure.")
        #expect(task.events.contains {
            $0.type == "local_agent.watchdog"
                && $0.payload.contains("\"reason\":\"memory_pressure\"")
                && $0.payload.contains("\"recovery\":\"Open Runtime settings, lower the Local MLX context limit")
        })
        #expect(task.events.contains {
            $0.type == "local_agent.metrics"
                && $0.payload.contains("\"stop_reason\":\"completed\"")
                && $0.payload.contains("\"memory_diagnostics\":\"1\"")
                && $0.payload.contains("\"watchdog_warnings\":\"1\"")
        })
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

    @Test("Headless chat enforces budget guardrails")
    func headlessChatEnforcesBudget() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let largeOutput = String(repeating: "x", count: 600)
        let launchMarker = harness.rootURL.appendingPathComponent("hard-stop-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(largeOutput)"}}'
            sleep 1
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Produce too much output",
            model: "gpt-5",
            tokenBudget: 20
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Copilot hard stop rejects prompt estimate before starting")
    func copilotHardStopRejectsPromptEstimateBeforeLaunch() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("copilot-low-budget-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: String(repeating: "x", count: 400),
            model: "gpt-5",
            tokenBudget: 20
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(!worker.isRunning)
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" && $0.payload.contains("Provider was not started") })
    }

    @Test("Copilot hard stop enforces reported usage")
    func copilotHardStopEnforcesReportedUsage() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("copilot-usage-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":12000,"output_tokens":15},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Use reported usage",
            model: "gpt-5",
            tokenBudget: 10_000
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Headless chat warning budget records warning and keeps running")
    func headlessChatWarningBudgetKeepsRunning() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("warning-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Warning mode still runs"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":30,"output_tokens":15},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Produce output above budget",
            model: "gpt-5",
            tokenBudget: 20
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .warning

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.tokensUsed == 45)
        #expect(task.tokensUsed == 45)
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.warning" })
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Antigravity estimated usage participates in final budget warnings")
    func antigravityEstimatedUsageRecordsFinalBudgetWarning() async throws {
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
            /usr/bin/python3 - <<'PY'
            print("A" * 5000)
            PY
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Produce a long Antigravity response",
            model: "Gemini 3.5 Flash",
            tokenBudget: 1_000
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)
        worker.budgetEnforcementModeOverride = .warning

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.tokensUsed > task.tokenBudget)
        #expect(task.events.contains { $0.type == "task.stats" && $0.payload.contains("estimated tokens") })
        #expect(task.events.contains { $0.type == "budget.warning" })
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Copilot repetition stop is reported separately from token budget")
    func copilotRepetitionStopIsNotBudgetExceeded() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            for i in 1 2 3 4 5 6 7 8 9; do
              printf '%s\\n' '{"type":"tool.execution_complete","data":{"toolCallId":"toolu_repeat","success":true,"result":{"content":"same output"}}}'
            done
            sleep 1
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Trigger repeated provider events",
            model: "gpt-5",
            tokenBudget: 50_000
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .warning

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "repetition_detected")
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("Repetition loop detected") })
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Claude hard stop rejects budgets below launch overhead before starting")
    func claudeHardStopRejectsLowBudgetBeforeLaunch() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("claude-low-budget-launched")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"should not launch","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "This low-budget Claude task should not launch",
            model: "claude-sonnet-4-6",
            tokenBudget: 10_000
        )
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(!worker.isRunning)
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" && $0.payload.contains("Provider was not started") })
    }

    @Test("Permission warning can recover when later provider output arrives")
    func permissionWarningCanRecover() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"event","data":{"type":"permission_request","toolName":"Bash","message":"approval needed for Bash"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Recovered after the warning"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Recover after warning", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.output == "Recovered after the warning")
        #expect(task.events.contains { $0.type == "permission.denied" && $0.payload.contains("Bash") })
        #expect(task.events.contains { $0.type == "agent.response" && $0.payload == "Recovered after the warning" })
    }

    @Test("Permission mode is passed to the provider command")
    func permissionModeIsPassedToProviderCommand() async throws {
        let reviewHarness = try HeadlessChatHarness()
        defer { reviewHarness.cleanup() }
        let reviewArgsURL = reviewHarness.rootURL.appendingPathComponent("review-args.txt")
        let reviewCopilotPath = try reviewHarness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"review mode"}}'
                exit 0
                """,
                argsFile: reviewArgsURL
            )
        )
        let reviewTask = reviewHarness.makeTask(runtime: .copilotCLI, goal: "Run in review mode", model: "gpt-5")
        let reviewWorker = reviewHarness.makeWorker(
            runtime: .copilotCLI,
            executablePath: reviewCopilotPath,
            permissionPolicy: .restricted
        )

        _ = await reviewHarness.execute(task: reviewTask, worker: reviewWorker)

        let reviewArgs = try String(contentsOf: reviewArgsURL, encoding: .utf8)
        #expect(reviewArgs.contains("--allow-tool"))
        #expect(!reviewArgs.contains("--allow-all-tools"))

        let autoHarness = try HeadlessChatHarness()
        defer { autoHarness.cleanup() }
        let autoArgsURL = autoHarness.rootURL.appendingPathComponent("auto-args.txt")
        let autoCopilotPath = try autoHarness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"auto mode"}}'
                exit 0
                """,
                argsFile: autoArgsURL
            )
        )
        let autoTask = autoHarness.makeTask(runtime: .copilotCLI, goal: "Run in auto mode", model: "gpt-5")
        let autoWorker = autoHarness.makeWorker(
            runtime: .copilotCLI,
            executablePath: autoCopilotPath,
            permissionPolicy: .autonomous
        )

        _ = await autoHarness.execute(task: autoTask, worker: autoWorker)

        let autoArgs = try String(contentsOf: autoArgsURL, encoding: .utf8)
        #expect(autoArgs.contains("--allow-all-tools"))

        let skipHarness = try HeadlessChatHarness()
        defer { skipHarness.cleanup() }
        let skipArgsURL = skipHarness.rootURL.appendingPathComponent("skip-args.txt")
        let skipClaudePath = try skipHarness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"skip-session","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"skip mode"}}]}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"skip mode","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: skipArgsURL
            )
        )
        let skipTask = skipHarness.makeTask(
            runtime: .claudeCode,
            goal: "Run with skipPermissions",
            model: "claude-sonnet-4-6"
        )
        let skipWorker = skipHarness.makeWorker(
            runtime: .claudeCode,
            executablePath: skipClaudePath,
            permissionPolicy: .restricted
        )
        skipWorker.skipPermissions = true

        _ = await skipHarness.execute(task: skipTask, worker: skipWorker)

        let skipArgs = try String(contentsOf: skipArgsURL, encoding: .utf8)
        #expect(skipArgs.contains("--dangerously-skip-permissions"))
    }

    @Test("Copilot autonomous provider denial fails without approval loop")
    func copilotAutonomousProviderDenialFailsWithoutApprovalLoop() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"tool.execution_start","data":{"toolCallId":"toolu_denied","toolName":"bash","input":{"command":"cat ~/.zsh_history"}}}'
            printf '%s\\n' '{"type":"tool.execution_complete","data":{"toolCallId":"toolu_denied","success":false,"error":{"message":"Permission denied and could not request permission from user","code":"denied"}}}'
            sleep 1
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Read shell history",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .autonomous
        )

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "provider_permission_denied_broad_permissions")
        #expect(!task.events.contains { $0.type == "permission.approval.requested" })
        #expect(task.events.contains {
            $0.type == "error"
                && $0.payload.contains("--allow-all-tools")
                && $0.payload.contains("cat ~/.zsh_history")
        })
    }

    @Test("Copilot hidden permission prompt pauses for user approval and can continue")
    func copilotHiddenPermissionPromptPausesForUserApprovalAndCanContinue() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("permission-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'write'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Wrote the approved story"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '● I will write the story to the task folder.'
                printf '%s\\n' '✗ Create .astra/tasks/BAD5D673/warriors_story.md'
                printf '%s\\n' 'Permission denied and could not request permission from user' >&2
                exit 15
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a story about golden state warriors",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        _ = await harness.continueTask(
            task: task,
            message: "The user approved the blocked permission.",
            worker: worker,
            executionPolicy: .approvedRuntimePermission(runtime: .copilotCLI, allowedTools: ["Write"])
        )

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(!args.contains("--allow-all-tools"))
        #expect(args.contains("write"))
        #expect(task.status == .completed)
        #expect(runs[1].output == "Wrote the approved story")
    }

    @Test("UI approval resumes a Copilot runtime permission pause")
    func uiApprovalResumesCopilotRuntimePermissionPause() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-permission-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'write'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Approved through UI path"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"event","data":{"type":"permission_request","toolName":"Write","message":"Permission denied and could not request permission from user"}}'
                printf '%s\\n' 'Permission denied and could not request permission from user' >&2
                exit 15
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a story about golden state warriors",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)

        await queue.executeTask(task, modelContext: harness.context)
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 20) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(!args.contains("--allow-all-tools"))
        #expect(args.contains("write"))
        #expect(runs.last?.output == "Approved through UI path")
        #expect(task.events.contains { $0.type == "task.approved" && $0.payload.contains("Runtime permission approved") })
    }

    @Test("UI approval repairs Copilot wrapper shell grants")
    func uiApprovalRepairsCopilotWrapperShellGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-copilot-wrapper-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:search prs *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:auth status *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(mkdir:-p *)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(#:*)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(echo:*)'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reviewed open PRs after repaired approval"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "review my open prs",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)

        let command = """
        set -euo pipefail
        # Check gh auth before running the search
        if ! gh auth status >/dev/null 2>&1; then
          echo '{"error":"gh not authenticated"}'
          exit 0
        fi
        echo "Fetching open PRs"
        gh search prs "author:@me is:open" --limit 100 --json number,title,url
        """
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .copilotCLI,
                request: .shell(command: command, toolName: "bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [
                    .shellCommand(executable: "#", pattern: "*"),
                    .shellCommand(executable: "echo", pattern: "*")
                ]
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("shell(gh:search prs *)"))
        #expect(args.contains("shell(gh:auth status *)"))
        #expect(args.contains("shell(mkdir:-p *)"))
        #expect(!args.contains("shell(#:*)"))
        #expect(!args.contains("shell(echo:*)"))
        #expect(!args.contains("shell(gh:*)"))
        #expect(args.contains("Start shell calls with the approved executable"))
        #expect(runs.last?.output == "Reviewed open PRs after repaired approval")
    }

    @Test("UI approve similar records task-scoped command grant")
    func uiApproveSimilarRecordsTaskScopedCommandGrant() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-copilot-similar-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:search prs *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:auth status *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(mkdir:-p *)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:*)'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reviewed open PRs after task-scoped approval"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "review my open prs",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)

        let command = """
        set -euo pipefail
        if ! gh auth status >/dev/null 2>&1; then
          echo '{"error":"gh not authenticated"}'
          exit 0
        fi
        gh search prs "author:@me is:open" --limit 100 --json number,title,url
        """
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .copilotCLI,
                request: .shell(command: command, toolName: "bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [.shellCommand(executable: "gh", pattern: "*")]
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveSimilarRuntimePermissionForTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("shell(gh:search prs *)"))
        #expect(args.contains("shell(gh:auth status *)"))
        #expect(args.contains("shell(mkdir:-p *)"))
        #expect(!args.contains("shell(gh:*)"))
        #expect(args.contains("task-scoped runtime permission"))
        #expect(task.events.contains { $0.type == TaskRuntimePermissionGrants.eventType })
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task) == [
            .shellCommand(executable: "gh", pattern: "search prs *")
        ])
        #expect(runs.last?.output == "Reviewed open PRs after task-scoped approval")
    }

    @Test("UI approval resumes a Claude ASTRA ask-first shell pause")
    func uiApprovalResumesClaudeAstraAskFirstShellPause() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-claude-policy-approval-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(curl *redcap.stanford.edu*)'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-policy-approved","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Approved curl completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Approved curl completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-policy-needs-approval","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Bash","id":"toolu_curl","input":{"command":"curl https://redcap.stanford.edu/api/"}}]}}'
                /bin/sleep 20
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Read REDCap project info",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)

        await queue.executeTask(task, modelContext: harness.context)
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.stopReason == "permission_approval_required")
        let approvalEvent = try #require(task.events.first {
            $0.type == "permission.approval.requested" && $0.payload.contains("Runtime grant: Bash(curl *redcap.stanford.edu*)")
        })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.providerID == .claudeCode)
        #expect(approvalPayload.grants.contains(.shellCommand(executable: "curl", pattern: "*redcap.stanford.edu*")))
        #expect(approvalPayload.displayMessage.contains("Runtime grant: Bash(curl *redcap.stanford.edu*)"))

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 20) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(!args.contains("--dangerously-skip-permissions"))
        let settingsURL = harness.workspaceURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        let settingsData = try Data(contentsOf: settingsURL)
        let settingsJSON = try #require(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let permissions = try #require(settingsJSON["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(runs.last?.output == "Approved curl completed")
    }

    @Test("UI approval ignores stale broad shell runtime grants")
    func uiApprovalIgnoresStaleBroadShellRuntimeGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-stale-broad-grant-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-sanitized-approval","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Sanitized approval completed"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Sanitized approval completed","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Continue after an old permission request",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: """
            Permission requested for tool: Bash.
            Runtime grant: Bash(*)
            """,
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(completed)
        #expect(!args.contains("Bash(*)"))
        #expect(!args.contains("Bash"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test("UI approval replays structured permission grants")
    func uiApprovalReplaysStructuredPermissionGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-structured-grant-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(curl *redcap.stanford.edu*)'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-structured-approval","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Structured approval completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Structured approval completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Missing structured grant","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Continue after a structured permission request",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)
        let request = PermissionRequest.shell(command: "curl https://redcap.stanford.edu/api/", toolName: "Bash")
        let grants = [PermissionGrant.shellCommand(executable: "curl", pattern: "*")]
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .claudeCode,
                request: request,
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: grants
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(completed)
        #expect(args.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test("UI approval replays only latest runtime permission request")
    func uiApprovalReplaysOnlyLatestRuntimePermissionRequest() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-latest-approval-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(curl *redcap.stanford.edu*)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'Bash(gh search prs *)'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-latest-approval","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Latest approval completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Latest approval completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Stale grant was replayed","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Continue after the latest permission request",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        task.status = .pendingUser

        let oldRun = TaskRun(task: task)
        oldRun.status = .failed
        oldRun.stopReason = "permission_approval_required"
        harness.context.insert(oldRun)
        let oldEvent = TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .claudeCode,
                request: .shell(command: "gh search prs --author @me --state open", toolName: "Bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [.shellCommand(executable: "gh", pattern: "search prs *")]
            ),
            run: oldRun
        )
        oldEvent.timestamp = Date(timeIntervalSince1970: 1)
        harness.context.insert(oldEvent)

        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)
        let latestEvent = TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .claudeCode,
                request: .shell(command: "curl https://redcap.stanford.edu/api/", toolName: "Bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [.shellCommand(executable: "curl", pattern: "*redcap.stanford.edu*")]
            ),
            run: blockedRun
        )
        latestEvent.timestamp = Date(timeIntervalSince1970: 2)
        harness.context.insert(latestEvent)
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(completed)
        #expect(args.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(!args.contains("Bash(gh search prs *)"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test("Claude hidden permission prompt pauses for user approval and can continue")
    func claudeHiddenPermissionPromptPausesForUserApprovalAndCanContinue() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("claude-permission-approval-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Write'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-approved-session","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude continued after approval"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude continued after approval","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Permission denied for tool: Write. approval required"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Permission denied for tool: Write","usage":{"input_tokens":3,"output_tokens":5}}'
                printf '%s\\n' 'Permission denied for tool: Write. approval required' >&2
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "use the write tool after approval",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        _ = await harness.continueTask(
            task: task,
            message: "The user approved the blocked permission.",
            worker: worker,
            executionPolicy: .approvedRuntimePermission(runtime: .claudeCode, allowedTools: ["Write"])
        )

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(args.contains("Write"))
        #expect(task.status == .completed)
        #expect(runs[1].output == "Claude continued after approval")
    }

    @Test("Headless chat can continue a task")
    func headlessChatCanContinueTask() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let countFile = harness.rootURL.appendingPathComponent("call-count.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > \(Self.shQuote(countFile.path))
            if [ "$count" = "1" ]; then
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Initial answer"}}'
            else
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Follow-up answer"}}'
            fi
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":5,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Start a thread", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        _ = await harness.continueTask(task: task, message: "Follow up", worker: worker)

        #expect(task.runs.count == 2)
        #expect(task.runs.contains { $0.output == "Initial answer" })
        #expect(task.runs.contains { $0.output == "Follow-up answer" })
        #expect(task.events.contains { $0.type == "user.message" && $0.payload == "Follow up" })
        #expect(task.status == .completed)
    }

    @Test("Approved plan execution records runtime step progress")
    func approvedPlanExecutionRecordsStepProgress() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Headless plan",
            goal: "Execute one planned step",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Inspect", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.started\\",\\"stepID\\":\\"step-1\\"}\\n"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Plan executed"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(task.runs.first?.output == "Plan executed")
        #expect(state.lifecycleStatus == .completed)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(task.events.contains { $0.type == "plan.execution.started" })
        #expect(task.events.contains { $0.type == "plan.execution.completed" })
        #expect(task.events.contains { $0.type == "plan.step.started" })
        #expect(task.events.contains { $0.type == "plan.step.completed" })
    }

    @Test("Approved plan execution records failure lifecycle on failure")
    func approvedPlanExecutionRecordsFailureLifecycleOnFailure() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Failing plan",
            goal: "Fail during execution",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Run")
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"error","message":"provider failed"}'
            exit 1
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .failed)
        #expect(state.lifecycleStatus == .failed)
        #expect(task.events.contains { $0.type == "plan.execution.failed" })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
    }

    @Test("Approved plan execution uses explicit approval for Copilot Review mode")
    func approvedPlanExecutionUsesExplicitApprovalForCopilotReviewMode() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("review-plan-args.txt")
        let plan = TaskPlanPayload(
            title: "Review plan",
            goal: "Execute in review mode",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"review plan executed"}}'
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let state = TaskPlanService.reconstruct(for: task)
        #expect(!args.contains("--allow-all-tools"))
        #expect(args.contains("--allow-tool"))
        #expect(args.contains("write"))
        #expect(args.contains("ASTRA review mode approved only the next plan step"))
        #expect(args.contains("Execute exactly this approved step and stop: step-1"))
        #expect(args.contains("Do not execute later plan steps"))
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.output == "review plan executed")
        #expect(state.lifecycleStatus == .executing)
        #expect(state.plan?.steps.first(where: { $0.id == "step-1" })?.status == .done)
        #expect(state.plan?.steps.first(where: { $0.id == "step-2" })?.status == .pending)
        #expect(task.events.contains { $0.type == "system.info" && $0.payload.contains("Review the next step") })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
    }

    @Test("Review mode executes the next unfinished plan step on each approval")
    func reviewModeExecutesNextUnfinishedPlanStepOnEachApproval() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("review-next-step-args.txt")
        let countFile = harness.rootURL.appendingPathComponent("review-next-step-count.txt")
        let plan = TaskPlanPayload(
            title: "Two step review plan",
            goal: "Execute one approved step at a time",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
                count=$((count + 1))
                printf '%s' "$count" > \(Self.shQuote(countFile.path))
                printf '%s\\n' "{\\"sessionUpdate\\":\\"agent_message_chunk\\",\\"content\\":{\\"type\\":\\"text\\",\\"text\\":\\"review step $count executed\\"}}"
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)
        #expect(task.status == .pendingUser)

        let stateAfterFirstStep = TaskPlanService.reconstruct(for: task)
        let currentPlan = try #require(stateAfterFirstStep.plan)
        _ = await harness.executeApprovedPlan(task: task, plan: currentPlan, worker: worker, mode: .nextStep)

        let finalState = TaskPlanService.reconstruct(for: task)
        let secondPromptArgs = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(secondPromptArgs.contains("Execute exactly this approved step and stop: step-2"))
        #expect(task.status == .completed)
        #expect(task.runs.count == 2)
        #expect(finalState.lifecycleStatus == .completed)
        #expect(finalState.plan?.steps.allSatisfy { $0.status == .done } == true)
        #expect(task.events.contains { $0.type == "plan.execution.completed" })
    }

    @Test("Review mode preserves blocked plan steps for user approval")
    func reviewModePreservesBlockedPlanStepForUserApproval() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let planID = UUID(uuidString: "73EF73A8-433C-485E-8E76-91881D1D3798")!
        let plan = TaskPlanPayload(
            planID: planID,
            title: "Blocked review plan",
            goal: "Stop when blocked",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.blocked\\",\\"planID\\":\\"\(planID.uuidString)\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"blocked\\",\\"reason\\":\\"Needs credentials\\"}\\n"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Need credentials before continuing."}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(state.lifecycleStatus == .executing)
        #expect(state.plan?.steps.first(where: { $0.id == "step-1" })?.status == .blocked)
        #expect(state.plan?.steps.first(where: { $0.id == "step-2" })?.status == .pending)
        #expect(!task.events.contains { $0.type == "plan.step.completed" && $0.payload.contains("step-1") })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
        #expect(task.events.contains { $0.type == "system.info" && $0.payload.contains("Plan step blocked") })
        #expect(!task.events.contains { $0.type == "system.info" && $0.payload.contains("Plan step complete") })
    }

    @Test("Plan mode runtime policy violation stops provider")
    func planModeRuntimePolicyViolationStopsProvider() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Guarded review plan",
            goal: "Execute a write-only approved step",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"tool_call","tool":"shell","id":"call-1","command":"rm -rf build"}'
            /bin/sleep 20
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let run = try #require(task.runs.first)
        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "policy_violation")
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("violated the run policy") })
        #expect(!task.events.contains { $0.type == "plan.step.completed" })
        #expect(state.plan?.steps.first?.status != .done)
    }

    @Test("Approved plan execution keeps Auto mode autonomous for Copilot")
    func approvedPlanExecutionKeepsAutoModeAutonomousForCopilot() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("auto-plan-args.txt")
        let plan = TaskPlanPayload(
            title: "Auto plan",
            goal: "Execute in auto mode",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"auto plan executed"}}'
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .autonomous
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(args.contains("--allow-all-tools"))
        #expect(!args.contains("--allow-tool"))
        #expect(args.contains("ASTRA auto mode approved the full plan"))
        #expect(args.contains("Execute the remaining approved plan steps"))
        #expect(task.status == .completed)
        #expect(task.runs.first?.output == "auto plan executed")
    }

    @Test("Approved plan execution records step progress with Claude")
    func approvedPlanExecutionRecordsStepProgressWithClaude() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Claude plan",
            goal: "Execute one planned step with Claude",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Inspect", likelyTools: ["Read"])
            ]
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-plan-session","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.started\\",\\"stepID\\":\\"step-1\\"}\\n"}]}}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude plan executed"}]}}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude plan executed","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: plan.goal, model: "claude-sonnet-4-6")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(task.sessionId == "claude-plan-session")
        #expect(task.runs.first?.output == "Claude plan executed")
        #expect(state.lifecycleStatus == .completed)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(task.events.contains { $0.type == "plan.step.started" })
        #expect(task.events.contains { $0.type == "plan.step.completed" })
    }

    @Test("Claude review mode grants approved step tools")
    func claudeReviewModeGrantsApprovedStepTools() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("claude-review-args.txt")
        let plan = TaskPlanPayload(
            title: "Claude write plan",
            goal: "Create an artifact with Claude",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"])
            ]
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-review-session","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude wrote artifact","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: plan.goal, model: "claude-sonnet-4-6")
        let restrictedSkill = Skill(
            name: "Read-only",
            allowedTools: ["Read", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"],
            behaviorInstructions: ""
        )
        harness.context.insert(restrictedSkill)
        task.skills = [restrictedSkill]
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("Write"))

        let settingsURL = harness.workspaceURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        let data = try Data(contentsOf: settingsURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try #require(json["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow.contains("Write(*)"))
    }

    @Test("Claude plan mode runtime policy violation stops provider")
    func claudePlanModeRuntimePolicyViolationStopsProvider() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Guarded Claude review plan",
            goal: "Execute a write-only approved step with Claude",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"])
            ]
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-guard-session","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Bash","id":"toolu_bad","input":{"command":"rm -rf build"}}]}}'
            /bin/sleep 20
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: plan.goal, model: "claude-sonnet-4-6")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let run = try #require(task.runs.first)
        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "policy_violation")
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("violated the run policy") })
        #expect(!task.events.contains { $0.type == "plan.step.completed" })
        #expect(state.plan?.steps.first?.status != .done)
    }

    @Test("Blocked write permission enriches the next approved retry")
    func blockedWritePermissionEnrichesNextApprovedRetry() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("claude-retry-args.txt")
        let blockedFlagURL = harness.rootURL.appendingPathComponent("blocked-once")
        let plan = TaskPlanPayload(
            title: "Retry write plan",
            goal: "Create an HTML file after permission repair",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Create homepage", likelyTools: ["Read"])
            ]
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if [ ! -f \(Self.shQuote(blockedFlagURL.path)) ]; then
                  touch \(Self.shQuote(blockedFlagURL.path))
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-retry-session-1","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.blocked\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"blocked\\",\\"reason\\":\\"Write permission needed to create .astra/tasks/97EF1FD6/index.html.\\"}\\n"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"blocked","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                task_dir="$(find \(Self.shQuote(harness.workspaceURL.appendingPathComponent(".astra/tasks", isDirectory: true).path)) -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
                if [ -n "$task_dir" ]; then
                  printf '%s\\n' '<!doctype html><html><body>Home</body></html>' > "$task_dir/index.html"
                fi
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-retry-session-2","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Created index.html\\"}\\n"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"wrote artifact","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: plan.goal, model: "claude-sonnet-4-6")
        let restrictedSkill = Skill(
            name: "Read-only",
            allowedTools: ["Read", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"],
            behaviorInstructions: ""
        )
        harness.context.insert(restrictedSkill)
        task.skills = [restrictedSkill]
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)
        var state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(state.plan?.steps.first?.status == .blocked)
        #expect(state.plan?.steps.first?.likelyTools.contains("Write") == true)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("Write"))
        state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(state.lifecycleStatus == .completed)
    }

    @Test("Plan mode can be approved and executed after an existing chat turn")
    func planModeCanExecuteAfterExistingChatTurn() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let countFile = harness.rootURL.appendingPathComponent("plan-call-count.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > \(Self.shQuote(countFile.path))
            if [ "$count" = "1" ]; then
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Initial chat answer"}}'
            else
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}}'
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Approved plan executed"}}'
            fi
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":5,"turns":1}'
            exit 0
            """)
        )

        let plan = TaskPlanPayload(
            title: "Mid-thread plan",
            goal: "Execute a plan after chat context exists",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Apply plan", likelyTools: ["Write"])
            ]
        )
        let task = harness.makeTask(runtime: .copilotCLI, goal: "Start normally", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let state = TaskPlanService.reconstruct(for: task)
        #expect(runs.count == 2)
        #expect(runs[0].output == "Initial chat answer")
        #expect(runs[1].output == "Approved plan executed")
        #expect(task.status == .completed)
        #expect(state.lifecycleStatus == .completed)
        #expect(state.plan?.steps.first?.status == .done)
    }

    @Test("Approved plan path permission prompts stop instead of looping")
    func approvedPlanPathPermissionPromptStopsInsteadOfLooping() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Prompt plan",
            goal: "Trigger a hidden permission prompt",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write outside workspace", likelyTools: ["Write"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            /usr/bin/python3 -u - <<'PY'
            import time
            print('The following paths are outside the allowed directories:', flush=True)
            print('  - /Users/example/Documents/Astra\\\\', flush=True)
            print('Allow access to these paths? (y/n):', flush=True)
            time.sleep(20)
            PY
            exit $?
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "provider_permission_unresumable")
        #expect(task.events.contains { $0.type == "permission.denied" && $0.payload.contains("WorkspaceAccess") })
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("does not map to a scoped runtime permission") })
        #expect(!task.events.contains { $0.type == "permission.approval.requested" })
        #expect(!task.events.contains { $0.type == "error" && $0.payload.contains("idle timeout") })
    }

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
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-2","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude follow-up answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":13,"num_turns":1,"result":"Claude follow-up answer","usage":{"input_tokens":5,"output_tokens":7}}'
            exit 0
            """)
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
    }

    private static func copilotScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuote($0.path))" } ?? ""
        return """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        \(recordArgs)
        \(body)
        """
    }

    private static func claudeScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuote($0.path))" } ?? ""
        return """
        #!/bin/sh
        \(recordArgs)
        \(body)
        """
    }

    private static func runProviderParityCompletionScenario(runtime: AgentRuntimeID) async throws {
        if runtime == .localMLX {
            try await withLocalAgentProviderEnabled {
                try await runProviderParityCompletionScenarioWithConfiguredDefaults(runtime: runtime)
            }
        } else {
            try await runProviderParityCompletionScenarioWithConfiguredDefaults(runtime: runtime)
        }
    }

    private static func runProviderParityCompletionScenarioWithConfiguredDefaults(runtime: AgentRuntimeID) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let expectedOutput = "Provider parity complete: Provider parity evidence."
        let executablePath = try providerParityExecutable(
            runtime: runtime,
            expectedOutput: expectedOutput,
            harness: harness
        )
        let task = harness.makeTask(
            runtime: runtime,
            goal: "Use the provider parity evidence and return the shared parity summary",
            model: providerParityModel(for: runtime)
        )
        if runtime == .localMLX {
            try "Provider parity evidence.".write(
                to: harness.workspaceURL.appendingPathComponent("parity.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let worker = harness.makeWorker(runtime: runtime, executablePath: executablePath)
        let events = await harness.execute(task: task, worker: worker)
        let run = try #require(task.runs.first)

        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.runtimeID == runtime.rawValue)
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines) == expectedOutput)
        #expect(task.events.contains { $0.type == "task.started" })
        #expect(task.events.contains { $0.type == "task.completed" })
        #expect(events.contains {
            if case .text(let text) = $0 {
                return text.contains("Provider parity")
            }
            return false
        })

        if runtime == .localMLX {
            #expect(task.events.contains {
                $0.type == "tool.use"
                    && $0.payload.contains("workspace.read_file")
                    && $0.payload.contains("parity.txt")
            })
            #expect(task.events.contains {
                $0.type == "tool.result"
                    && $0.payload.contains("Provider parity evidence.")
            })
            #expect(task.events.contains {
                $0.type == "local_agent.final"
                    && $0.payload.contains("\"tool_calls\":\"1\"")
            })
            let observationEvent = try #require(task.events.first {
                $0.type == "local_agent.observation"
                    && $0.payload.contains("\"tool\":\"workspace.read_file\"")
            })
            let finalEvent = try #require(task.events.first {
                $0.type == "local_agent.final"
            })
            #expect(finalEvent.timestamp >= observationEvent.timestamp)
        } else {
            #expect(AgentRuntimeAdapterRegistry.executionCapabilities(for: runtime).supportsProviderNativeTools)
            #expect(AgentRuntimeAdapterRegistry.executionCapabilities(for: runtime).supportsConnectors)
        }
    }

    private static func runProviderParityDeniedShellScenario(runtime: AgentRuntimeID) async throws {
        if runtime == .localMLX {
            try await withLocalAgentProviderEnabled(capabilities: [.shellExecution]) {
                try await runProviderParityDeniedShellScenarioWithConfiguredDefaults(runtime: runtime)
            }
        } else {
            try await runProviderParityDeniedShellScenarioWithConfiguredDefaults(runtime: runtime)
        }
    }

    private static func runProviderParityDeniedShellScenarioWithConfiguredDefaults(runtime: AgentRuntimeID) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let executablePath = try providerParityDeniedShellExecutable(runtime: runtime, harness: harness)
        let plan = TaskPlanPayload(
            title: "Provider parity guarded plan",
            goal: "Execute a write-only approved step without shell access",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"])
            ]
        )
        let task = harness.makeTask(
            runtime: runtime,
            goal: plan.goal,
            model: providerParityModel(for: runtime)
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: runtime,
            executablePath: executablePath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let run = try #require(task.runs.first)
        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        if runtime == .antigravityCLI {
            #expect(run.stopReason == "permission_approval_required")
        } else {
            #expect(run.stopReason == "policy_violation")
        }
        #expect(!task.events.contains { $0.type == "task.completed" })
        #expect(!task.events.contains { $0.type == "plan.step.completed" })
        #expect(state.plan?.steps.first?.status != .done)

        if runtime == .localMLX {
            #expect(task.events.contains {
                $0.type == "permission.denied" && $0.payload.contains("Bash") && $0.payload.contains("rm -rf build")
            })
            #expect(task.events.contains {
                $0.type == "local_agent.policy_decision"
                    && $0.payload.contains("\"status\":\"denied\"")
                    && $0.payload.contains("\"tool\":\"shell.exec\"")
            })
            #expect(!task.events.contains { $0.type == "tool.use" && $0.payload.contains("shell.exec") })
            #expect(!task.events.contains { $0.type == "tool.result" })
        } else if runtime == .antigravityCLI {
            #expect(task.events.contains {
                $0.type == "permission.approval.requested"
                    && $0.payload.contains("shell")
                    && $0.payload.contains("rm -rf build")
            })
        } else {
            #expect(task.events.contains { $0.type == "error" && $0.payload.contains("violated the run policy") })
        }
    }

    private static func runProviderParityBlockedPlanStepScenario(runtime: AgentRuntimeID) async throws {
        if runtime == .localMLX {
            try await withLocalAgentProviderEnabled {
                try await runProviderParityBlockedPlanStepScenarioWithConfiguredDefaults(runtime: runtime)
            }
        } else {
            try await runProviderParityBlockedPlanStepScenarioWithConfiguredDefaults(runtime: runtime)
        }
    }

    private static func runProviderParityBlockedPlanStepScenarioWithConfiguredDefaults(runtime: AgentRuntimeID) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let planID = UUID(uuidString: "C4AC28AB-0C0B-47D4-B8F1-E02CB964F117")!
        let blockedReason = "Needs a connected account before continuing."
        let plan = TaskPlanPayload(
            planID: planID,
            title: "Provider parity blocked plan",
            goal: "Stop on a shared blocked step",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let executablePath = try providerParityBlockedPlanStepExecutable(
            runtime: runtime,
            planID: planID,
            blockedReason: blockedReason,
            harness: harness
        )
        let task = harness.makeTask(
            runtime: runtime,
            goal: plan.goal,
            model: providerParityModel(for: runtime)
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: runtime, executablePath: executablePath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(state.lifecycleStatus == .executing)
        #expect(state.plan?.steps.first(where: { $0.id == "step-1" })?.status == .blocked)
        #expect(state.plan?.steps.first(where: { $0.id == "step-2" })?.status == .pending)
        #expect(!task.events.contains { $0.type == "task.completed" })
        #expect(!task.events.contains { $0.type == "plan.step.completed" && $0.payload.contains("step-1") })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
        #expect(task.events.contains { $0.type == "plan.step.blocked" && $0.payload.contains(blockedReason) })

        if runtime == .localMLX {
            let run = try #require(task.runs.first)
            #expect(run.status == .failed)
            #expect(run.stopReason == "local_agent_blocked")
            #expect(task.events.contains {
                $0.type == "local_agent.action_proposed"
                    && $0.payload.contains("\"action\":\"blocked\"")
                    && $0.payload.contains("\"id\":\"step-1\"")
            })
            #expect(task.events.contains {
                $0.type == "local_agent.blocked"
                    && $0.payload.contains("\"reason\":\"model_blocked\"")
            })
        }
    }

    private static func runProviderParityWriteApprovalScenario(runtime: AgentRuntimeID) async throws {
        if runtime == .localMLX {
            try await withLocalAgentProviderEnabled(capabilities: [.taskOutputWrite]) {
                try await runProviderParityWriteApprovalScenarioWithConfiguredDefaults(runtime: runtime)
            }
        } else {
            try await runProviderParityWriteApprovalScenarioWithConfiguredDefaults(runtime: runtime)
        }
    }

    private static func runProviderParityWriteApprovalScenarioWithConfiguredDefaults(runtime: AgentRuntimeID) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: runtime,
            goal: "Write the provider parity approval artifact after approval",
            model: providerParityModel(for: runtime),
            tokenBudget: runtime == .localMLX ? nil : 200_000
        )
        let argsURL = harness.rootURL.appendingPathComponent("provider-parity-write-approval-args.txt")
        let outputURL = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent("provider-parity/approved.md")
        let executablePath = try providerParityWriteApprovalExecutable(
            runtime: runtime,
            argsURL: argsURL,
            artifactURL: outputURL,
            harness: harness
        )
        let worker = harness.makeWorker(
            runtime: runtime,
            executablePath: executablePath,
            permissionPolicy: .restricted
        )

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })
        if runtime == .localMLX {
            #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        }

        let approvalEvent = try #require(task.events.last { $0.type == "permission.approval.requested" })
        let grants = PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)
        let executionPolicy: AgentRuntimeExecutionPolicy = runtime == .localMLX
            ? PermissionBroker.executionPolicy(forRuntime: runtime, grants: grants)
            : .approvedRuntimePermission(runtime: runtime, allowedTools: ["Write"])
        let resumeMessage = grants.isEmpty
            ? "The user approved the blocked write permission."
            : PermissionBroker.resumeMessage(providerID: runtime, grants: grants)

        _ = await harness.continueTask(
            task: task,
            message: resumeMessage,
            worker: worker,
            executionPolicy: executionPolicy
        )

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(task.status == .completed)
        #expect(runs[1].status == .completed)
        #expect(runs[1].output.trimmingCharacters(in: .whitespacesAndNewlines) == "Provider parity write approved.")
        #expect(!task.events.contains {
            $0.type == "task.completed" && $0.run === firstRun
        })
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "Provider parity approved artifact.\n")

        if runtime == .localMLX {
            #expect(task.events.contains {
                $0.type == "local_agent.policy" && $0.payload.contains("previously approved") && $0.payload.contains("task.write_output")
            })
        } else if runtime == .antigravityCLI {
            let args = try String(contentsOf: argsURL, encoding: .utf8)
            #expect(args.contains("--sandbox"))
            #expect(!args.contains("--dangerously-skip-permissions"))
        } else {
            let args = try String(contentsOf: argsURL, encoding: .utf8)
            #expect(args.contains(runtime == .copilotCLI ? "write" : "Write"))
            #expect(!args.contains("--allow-all-tools"))
            #expect(!args.contains("--dangerously-skip-permissions"))
        }
    }

    private static func runProviderParityCancellationScenario(runtime: AgentRuntimeID) async throws {
        if runtime == .localMLX {
            try await withLocalAgentProviderEnabled {
                try await runProviderParityCancellationScenarioWithConfiguredDefaults(runtime: runtime)
            }
        } else {
            try await runProviderParityCancellationScenarioWithConfiguredDefaults(runtime: runtime)
        }
    }

    private static func runProviderParityCancellationScenarioWithConfiguredDefaults(runtime: AgentRuntimeID) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let executablePath = try providerParityCancellationExecutable(runtime: runtime, harness: harness)
        let task = harness.makeTask(
            runtime: runtime,
            goal: "Start provider parity work and wait until cancellation",
            model: providerParityModel(for: runtime)
        )
        let worker = harness.makeWorker(runtime: runtime, executablePath: executablePath)

        let execution = Swift.Task { @MainActor in
            await harness.execute(task: task, worker: worker)
        }
        let started = await harness.waitUntil(task: task, timeoutSeconds: 5) {
            $0.events.contains { $0.type == "task.started" }
        }
        #expect(started)

        worker.cancel()
        _ = await execution.value

        let run = try #require(task.runs.first)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.stopReason == "cancelled")
        #expect(!task.events.contains { $0.type == "task.completed" })
        if runtime == .localMLX {
            #expect(task.events.contains {
                $0.type == "local_agent.cancelled"
            })
            #expect(task.events.contains {
                $0.type == "local_agent.metrics"
                    && $0.payload.contains("\"status\":\"cancelled\"")
            })
        }
    }

    private static func providerParityExecutable(
        runtime: AgentRuntimeID,
        expectedOutput: String,
        harness: HeadlessChatHarness
    ) throws -> String {
        switch runtime {
        case .claudeCode:
            return try harness.writeExecutable(
                named: "claude",
                script: claudeScript(body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"provider-parity-claude","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"\(expectedOutput)"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"\(expectedOutput)","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """)
            )
        case .copilotCLI:
            return try harness.writeExecutable(
                named: "copilot",
                script: copilotScript(body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(expectedOutput)"}}'
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
                exit 0
                """)
            )
        case .antigravityCLI:
            return try harness.writeExecutable(
                named: "agy",
                script: """
                #!/bin/sh
                if [ "$1" = "--version" ]; then
                  printf '%s\\n' '1.0.2'
                  exit 0
                fi
                printf '%s\\n' '\(expectedOutput)'
                exit 0
                """
            )
        case .localMLX:
            return try harness.writeExecutable(
                named: "astra-local-model",
                script: """
                #!/usr/bin/env python3
                import json
                import os
                import sys

                if "--version" in sys.argv[1:]:
                    print("astra-local-model 0.1.0")
                    sys.exit(0)
                try:
                    request_file = sys.argv[sys.argv.index("--request-file") + 1]
                except (ValueError, IndexError):
                    print("missing request file", file=sys.stderr)
                    sys.exit(64)
                with open(request_file, "r", encoding="utf-8") as handle:
                    request = json.load(handle)

                messages = request.get("messages", [])
                tool_messages = [message.get("content", "") for message in messages if message.get("role") == "tool"]
                if tool_messages:
                    action = {"type": "final", "answer": "\(expectedOutput)"}
                else:
                    action = {
                        "type": "tool_call",
                        "id": "read-parity-evidence",
                        "tool": "workspace.read_file",
                        "arguments": {"path": "parity.txt", "max_bytes": 4096}
                    }

                protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
                protocol = os.fdopen(protocol_fd, "w", closefd=False)

                def emit(payload):
                    protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                    protocol.flush()

                emit({"v": 1, "type": "started", "sessionID": "provider-parity-local", "model": request.get("model")})
                emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
                emit({"v": 1, "type": "stats", "inputTokens": 5, "outputTokens": 7, "durationMs": 12, "turns": 1})
                emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
                """
            )
        default:
            throw ProviderParityTestError.unsupportedRuntime(runtime.rawValue)
        }
    }

    private static func providerParityWriteApprovalExecutable(
        runtime: AgentRuntimeID,
        argsURL: URL,
        artifactURL: URL,
        harness: HeadlessChatHarness
    ) throws -> String {
        let artifactDirectory = artifactURL.deletingLastPathComponent().path
        let artifactPath = artifactURL.path
        switch runtime {
        case .claudeCode:
            return try harness.writeExecutable(
                named: "claude",
                script: claudeScript(
                    body: """
                    if printf '%s\\n' "$@" | grep -Fxq -- 'Write'; then
                      mkdir -p \(shQuote(artifactDirectory))
                      printf '%s\\n' 'Provider parity approved artifact.' > \(shQuote(artifactPath))
                      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"provider-parity-write-claude-approved","model":"claude-sonnet-4-6"}'
                      printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Provider parity write approved."}]}}'
                      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Provider parity write approved.","usage":{"input_tokens":3,"output_tokens":5}}'
                      exit 0
                    fi
                    printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Permission denied for tool: Write. approval required"}]}}'
                    printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Permission denied for tool: Write","usage":{"input_tokens":3,"output_tokens":5}}'
                    printf '%s\\n' 'Permission denied for tool: Write. approval required' >&2
                    exit 1
                    """,
                    argsFile: argsURL
                )
            )
        case .copilotCLI:
            return try harness.writeExecutable(
                named: "copilot",
                script: copilotScript(
                    body: """
                    if printf '%s\\n' "$@" | grep -Fxq -- 'write'; then
                      mkdir -p \(shQuote(artifactDirectory))
                      printf '%s\\n' 'Provider parity approved artifact.' > \(shQuote(artifactPath))
                      printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Provider parity write approved."}}'
                      printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                      exit 0
                    fi
                    printf '%s\\n' '{"type":"event","data":{"type":"permission_request","toolName":"Write","message":"Permission denied and could not request permission from user"}}'
                    printf '%s\\n' 'Permission denied and could not request permission from user' >&2
                    exit 15
                    """,
                    argsFile: argsURL
                )
            )
        case .antigravityCLI:
            let blockedFlagURL = harness.rootURL.appendingPathComponent("provider-parity-write-antigravity-blocked")
            return try harness.writeExecutable(
                named: "agy",
                script: """
                #!/bin/sh
                printf '%s\\n' "$@" > \(shQuote(argsURL.path))
                if [ "$1" = "--version" ]; then
                  printf '%s\\n' '1.0.2'
                  exit 0
                fi
                if [ ! -f \(shQuote(blockedFlagURL.path)) ]; then
                  touch \(shQuote(blockedFlagURL.path))
                  printf '%s\\n' 'Permission required for tool Write. approve?'
                  exit 15
                fi
                mkdir -p \(shQuote(artifactDirectory))
                printf '%s\\n' 'Provider parity approved artifact.' > \(shQuote(artifactPath))
                printf '%s\\n' 'Provider parity write approved.'
                exit 0
                """
            )
        case .localMLX:
            return try harness.writeExecutable(
                named: "astra-local-model",
                script: """
                #!/usr/bin/env python3
                import json
                import os
                import sys

                if "--version" in sys.argv[1:]:
                    print("astra-local-model 0.1.0")
                    sys.exit(0)
                try:
                    request_file = sys.argv[sys.argv.index("--request-file") + 1]
                except (ValueError, IndexError):
                    print("missing request file", file=sys.stderr)
                    sys.exit(64)
                with open(request_file, "r", encoding="utf-8") as handle:
                    request = json.load(handle)

                tool_messages = [message.get("content", "") for message in request.get("messages", []) if message.get("role") == "tool"]
                if tool_messages:
                    action = {"type": "final", "answer": "Provider parity write approved."}
                else:
                    action = {
                        "type": "tool_call",
                        "id": "provider-parity-write",
                        "tool": "task.write_output",
                        "arguments": {
                            "path": "provider-parity/approved.md",
                            "content": "Provider parity approved artifact.\\n",
                            "overwrite": False
                        }
                    }

                protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
                protocol = os.fdopen(protocol_fd, "w", closefd=False)
                protocol.write(json.dumps({"v": 1, "type": "started", "sessionID": "provider-parity-write-local", "model": request.get("model")}, separators=(",", ":")) + "\\n")
                protocol.write(json.dumps({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
                protocol.write(json.dumps({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))}, separators=(",", ":")) + "\\n")
                protocol.flush()
                """
            )
        default:
            throw ProviderParityTestError.unsupportedRuntime(runtime.rawValue)
        }
    }

    private static func providerParityBlockedPlanStepExecutable(
        runtime: AgentRuntimeID,
        planID: UUID,
        blockedReason: String,
        harness: HeadlessChatHarness
    ) throws -> String {
        switch runtime {
        case .claudeCode:
            return try harness.writeExecutable(
                named: "claude",
                script: claudeScript(body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"provider-parity-blocked-claude","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.blocked\\",\\"planID\\":\\"\(planID.uuidString)\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"blocked\\",\\"reason\\":\\"\(blockedReason)\\"}\\n"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"blocked","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """)
            )
        case .copilotCLI:
            return try harness.writeExecutable(
                named: "copilot",
                script: copilotScript(body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.blocked\\",\\"planID\\":\\"\(planID.uuidString)\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"blocked\\",\\"reason\\":\\"\(blockedReason)\\"}\\n"}}'
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(blockedReason)"}}'
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 0
                """)
            )
        case .antigravityCLI:
            return try harness.writeExecutable(
                named: "agy",
                script: """
                #!/bin/sh
                if [ "$1" = "--version" ]; then
                  printf '%s\\n' '1.0.2'
                  exit 0
                fi
                printf '%s\\n' 'ASTRA_EVENT {"v":1,"type":"plan.step.blocked","planID":"\(planID.uuidString)","stepID":"step-1","status":"blocked","reason":"\(blockedReason)"}'
                printf '%s\\n' '\(blockedReason)'
                exit 0
                """
            )
        case .localMLX:
            return try harness.writeExecutable(
                named: "astra-local-model",
                script: """
                #!/usr/bin/env python3
                import json
                import os
                import sys

                if "--version" in sys.argv[1:]:
                    print("astra-local-model 0.1.0")
                    sys.exit(0)
                try:
                    request_file = sys.argv[sys.argv.index("--request-file") + 1]
                except (ValueError, IndexError):
                    print("missing request file", file=sys.stderr)
                    sys.exit(64)
                with open(request_file, "r", encoding="utf-8") as handle:
                    request = json.load(handle)

                action = {"type": "blocked", "id": "step-1", "reason": "\(blockedReason)"}
                protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
                protocol = os.fdopen(protocol_fd, "w", closefd=False)

                def emit(payload):
                    protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                    protocol.flush()

                emit({"v": 1, "type": "started", "sessionID": "provider-parity-blocked-local", "model": request.get("model")})
                emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
                emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
                """
            )
        default:
            throw ProviderParityTestError.unsupportedRuntime(runtime.rawValue)
        }
    }

    private static func providerParityDeniedShellExecutable(
        runtime: AgentRuntimeID,
        harness: HeadlessChatHarness
    ) throws -> String {
        switch runtime {
        case .claudeCode:
            return try harness.writeExecutable(
                named: "claude",
                script: claudeScript(body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"provider-parity-denied-shell-claude","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Bash","id":"toolu_denied_shell","input":{"command":"rm -rf build"}}]}}'
                /bin/sleep 20
                exit 0
                """)
            )
        case .copilotCLI:
            return try harness.writeExecutable(
                named: "copilot",
                script: copilotScript(body: """
                printf '%s\\n' '{"type":"tool_call","tool":"shell","id":"call-denied-shell","command":"rm -rf build"}'
                /bin/sleep 20
                exit 0
                """)
            )
        case .antigravityCLI:
            return try harness.writeExecutable(
                named: "agy",
                script: """
                #!/bin/sh
                if [ "$1" = "--version" ]; then
                  printf '%s\\n' '1.0.2'
                  exit 0
                fi
                printf '%s\\n' 'This command requires permission: shell(rm -rf build). approve?'
                /bin/sleep 20
                exit 0
                """
            )
        case .localMLX:
            return try harness.writeExecutable(
                named: "astra-local-model",
                script: """
                #!/usr/bin/env python3
                import json
                import os
                import sys

                if "--version" in sys.argv[1:]:
                    print("astra-local-model 0.1.0")
                    sys.exit(0)
                try:
                    request_file = sys.argv[sys.argv.index("--request-file") + 1]
                except (ValueError, IndexError):
                    print("missing request file", file=sys.stderr)
                    sys.exit(64)
                with open(request_file, "r", encoding="utf-8") as handle:
                    request = json.load(handle)

                action = {
                    "type": "tool_call",
                    "id": "denied-shell",
                    "tool": "shell.exec",
                    "arguments": {"command": "rm -rf build"}
                }
                protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
                protocol = os.fdopen(protocol_fd, "w", closefd=False)

                def emit(payload):
                    protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                    protocol.flush()

                emit({"v": 1, "type": "started", "sessionID": "provider-parity-denied-shell-local", "model": request.get("model")})
                emit({"v": 1, "type": "text", "text": json.dumps(action, separators=(",", ":"))})
                emit({"v": 1, "type": "completed", "summary": json.dumps(action, separators=(",", ":"))})
                """
            )
        default:
            throw ProviderParityTestError.unsupportedRuntime(runtime.rawValue)
        }
    }

    private static func providerParityCancellationExecutable(
        runtime: AgentRuntimeID,
        harness: HeadlessChatHarness
    ) throws -> String {
        switch runtime {
        case .claudeCode:
            return try harness.writeExecutable(
                named: "claude",
                script: claudeScript(body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"provider-parity-cancel-claude","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Provider parity cancellation started."}]}}'
                /bin/sleep 20
                exit 0
                """)
            )
        case .copilotCLI:
            return try harness.writeExecutable(
                named: "copilot",
                script: copilotScript(body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Provider parity cancellation started."}}'
                /bin/sleep 20
                exit 0
                """)
            )
        case .antigravityCLI:
            return try harness.writeExecutable(
                named: "agy",
                script: """
                #!/bin/sh
                if [ "$1" = "--version" ]; then
                  printf '%s\\n' '1.0.2'
                  exit 0
                fi
                printf '%s\\n' 'Provider parity cancellation started.'
                /bin/sleep 20
                exit 0
                """
            )
        case .localMLX:
            return try harness.writeExecutable(
                named: "astra-local-model",
                script: """
                #!/usr/bin/env python3
                import json
                import os
                import select
                import sys
                import time

                if "--version" in sys.argv[1:]:
                    print("astra-local-model 0.1.0")
                    sys.exit(0)
                try:
                    request_file = sys.argv[sys.argv.index("--request-file") + 1]
                except (ValueError, IndexError):
                    print("missing request file", file=sys.stderr)
                    sys.exit(64)
                with open(request_file, "r", encoding="utf-8") as handle:
                    request = json.load(handle)

                protocol_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_PROTOCOL_FD", "3"))
                control_fd = int(os.environ.get("ASTRA_LOCAL_MODEL_CONTROL_FD", "4"))
                protocol = os.fdopen(protocol_fd, "w", closefd=False)

                def emit(payload):
                    protocol.write(json.dumps(payload, separators=(",", ":")) + "\\n")
                    protocol.flush()

                emit({"v": 1, "type": "started", "sessionID": "provider-parity-cancel-local", "model": request.get("model")})
                emit({"v": 1, "type": "phase", "phase": "generate", "message": "Provider parity cancellation started."})
                while True:
                    readable, _, _ = select.select([control_fd], [], [], 0.05)
                    if readable:
                        os.read(control_fd, 4096)
                        emit({"v": 1, "type": "cancelled", "message": "cancelled_by_user"})
                        sys.exit(130)
                    time.sleep(0.05)
                """
            )
        default:
            throw ProviderParityTestError.unsupportedRuntime(runtime.rawValue)
        }
    }

    private static func providerParityModel(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            return "claude-sonnet-4-6"
        case .copilotCLI:
            return "gpt-5"
        case .antigravityCLI:
            return "Gemini 3.5 Flash (Low)"
        case .localMLX:
            return LocalMLXRuntime.defaultModel
        default:
            return AgentRuntimeAdapterRegistry.defaultModel(for: runtime)
        }
    }

    private static func withLocalAgentProviderEnabled<T>(
        capabilities: [LocalAgentToolCapability] = [],
        _ body: () async throws -> T
    ) async throws -> T {
        let defaults = UserDefaults.standard
        let previousExperimental = defaults.object(forKey: LocalModelSettingsStore.experimentalToolsKey)
        let previousProviderEnabled = defaults.object(forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        let restoreCapabilities = Self.enableLocalAgentCapabilities(defaults: defaults, capabilities)
        defer {
            restoreCapabilities()
            if let previousExperimental {
                defaults.set(previousExperimental, forKey: LocalModelSettingsStore.experimentalToolsKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.experimentalToolsKey)
            }
            if let previousProviderEnabled {
                defaults.set(previousProviderEnabled, forKey: LocalModelSettingsStore.providerEnabledKey)
            } else {
                defaults.removeObject(forKey: LocalModelSettingsStore.providerEnabledKey)
            }
        }
        return try await body()
    }

    private enum ProviderParityTestError: Error {
        case unsupportedRuntime(String)
    }

    private static func jsonStringValue(_ key: String, in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
    }

    private static func shQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
private final class HeadlessChatHarness {
    let rootURL: URL
    let workspaceURL: URL
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-headless-chat-\(UUID().uuidString)", isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        context = container.mainContext
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func writeExecutable(named name: String, script: String) throws -> String {
        let url = rootURL.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func makeTask(
        runtime: AgentRuntimeID,
        goal: String,
        model: String,
        tokenBudget: Int? = nil
    ) -> AgentTask {
        let workspace = Workspace(name: "Headless", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let resolvedBudget = tokenBudget ?? (runtime == .claudeCode ? 200_000 : 1_000)

        let task = AgentTask(
            title: "Headless \(runtime.rawValue)",
            goal: goal,
            workspace: workspace,
            tokenBudget: resolvedBudget,
            model: model
        )
        task.runtimeID = runtime.rawValue
        task.status = .queued
        context.insert(task)
        try? context.save()
        return task
    }

    func makeWorker(
        runtime: AgentRuntimeID,
        executablePath: String,
        permissionPolicy: PermissionPolicy = .restricted
    ) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker()
        worker.timeoutSeconds = 10
        worker.permissionPolicy = permissionPolicy
        switch runtime {
        case .claudeCode:
            worker.claudePath = executablePath
        case .copilotCLI:
            worker.copilotPath = executablePath
            worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        default:
            worker.setExecutablePath(executablePath, for: runtime)
            worker.setHomeDirectory(
                rootURL.appendingPathComponent("\(runtime.rawValue)-home", isDirectory: true).path,
                for: runtime
            )
        }
        return worker
    }

    func makeWorker(
        claudePath: String,
        copilotPath: String,
        permissionPolicy: PermissionPolicy = .restricted
    ) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker()
        worker.timeoutSeconds = 10
        worker.permissionPolicy = permissionPolicy
        worker.claudePath = claudePath
        worker.copilotPath = copilotPath
        worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        return worker
    }

    func execute(task: AgentTask, worker: AgentRuntimeWorker) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.execute(task: task, modelContext: context) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func continueTask(
        task: AgentTask,
        message: String,
        worker: AgentRuntimeWorker,
        executionPolicy: AgentRuntimeExecutionPolicy = .default
    ) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.continueSession(
            task: task,
            message: message,
            modelContext: context,
            executionPolicy: executionPolicy
        ) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func executeApprovedPlan(
        task: AgentTask,
        plan: TaskPlanPayload,
        worker: AgentRuntimeWorker,
        mode: TaskPlanExecutionMode = .fullPlan
    ) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.executeApprovedPlan(task: task, plan: plan, mode: mode, modelContext: context) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func waitUntil(
        task: AgentTask,
        timeoutSeconds: TimeInterval = 3,
        predicate: @escaping (AgentTask) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate(task) {
                return true
            }
            try? await Swift.Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate(task)
    }
}

private final class JiraSearchHTTPTestServer {
    enum ServerError: Error {
        case startupTimedOut
        case missingPort
    }

    private let responseBody: String
    private let responseDelay: TimeInterval
    private let delayedPathContains: String?
    private let queue = DispatchQueue(label: "astra.tests.jira-search-http")
    private var listener: NWListener?

    init(
        responseBody: String,
        responseDelay: TimeInterval = 0,
        delayedPathContains: String? = nil
    ) {
        self.responseBody = responseBody
        self.responseDelay = responseDelay
        self.delayedPathContains = delayedPathContains
    }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [responseBody, responseDelay, delayedPathContains, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let requestText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let effectiveDelay: TimeInterval
                if let delayedPathContains {
                    effectiveDelay = requestText.contains(delayedPathContains) ? responseDelay : 0
                } else {
                    effectiveDelay = responseDelay
                }
                queue.asyncAfter(deadline: .now() + effectiveDelay) {
                    let bodyData = Data(responseBody.utf8)
                    let header = """
                    HTTP/1.1 200 OK\r
                    Content-Type: application/json\r
                    Content-Length: \(bodyData.count)\r
                    Connection: close\r
                    \r

                    """
                    var responseData = Data(header.utf8)
                    responseData.append(bodyData)
                    connection.send(content: responseData, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw ServerError.startupTimedOut
        }
        if let startupError {
            throw startupError
        }
        guard let port = listener.port?.rawValue else {
            throw ServerError.missingPort
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

final class PathRoutingHTTPTestServer {
    struct Route {
        var requestContains: String
        var responseBody: String
        var statusCode: Int = 200
    }

    enum ServerError: Error {
        case startupTimedOut
        case missingPort
    }

    private let routes: [Route]
    private let queue = DispatchQueue(label: "astra.tests.path-routing-http")
    private var listener: NWListener?

    init(routes: [Route]) {
        self.routes = routes
    }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [routes, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let requestText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let route = routes.first { requestText.contains($0.requestContains) }
                    ?? Route(
                        requestContains: "",
                        responseBody: #"{"error":{"message":"missing test route"}}"#,
                        statusCode: 404
                    )
                queue.async {
                    let bodyData = Data(route.responseBody.utf8)
                    let header = """
                    HTTP/1.1 \(route.statusCode) OK\r
                    Content-Type: application/json\r
                    Content-Length: \(bodyData.count)\r
                    Connection: close\r
                    \r

                    """
                    var responseData = Data(header.utf8)
                    responseData.append(bodyData)
                    connection.send(content: responseData, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw ServerError.startupTimedOut
        }
        if let startupError {
            throw startupError
        }
        guard let port = listener.port?.rawValue else {
            throw ServerError.missingPort
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private actor BrowserBridgeTestEndpoint {
    private var value: String?

    func set(_ nextValue: String?) {
        value = nextValue
    }

    func waitForURL() async throws -> URL {
        for _ in 0..<100 {
            if let value, let url = URL(string: value) {
                return url
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw BrowserBridgeTestError.endpointUnavailable
    }
}

private enum BrowserBridgeTestError: Error {
    case endpointUnavailable
}
