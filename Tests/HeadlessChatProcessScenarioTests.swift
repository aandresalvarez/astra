import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

extension HeadlessChatScenarioTests {
    @Test("Copilot process crash sets failed status and records error event")
    func copilotProcessCrashSetsFailedStatus() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Partial output before crash"}}'
            exit 42
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Task that crashes", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "failed")
        #expect(!worker.isRunning)
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("42") })
    }

    @Test("Claude process crash sets failed status and records error event")
    func claudeProcessCrashSetsFailedStatus() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-crash","model":"claude-sonnet-4-6"}'
            exit 1
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Task that crashes", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "failed")
        #expect(!worker.isRunning)
        #expect(task.events.contains { $0.type == "error" })
    }

    @Test("Antigravity process crash sets failed status and records error event")
    func antigravityProcessCrashSetsFailedStatus() async throws {
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
            printf '%s\\n' 'Partial output'
            exit 137
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Task that crashes",
            model: "Gemini 3.5 Flash"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "failed")
        #expect(!worker.isRunning)
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("137") })
    }

    @Test("Copilot idle timeout kills process and records timeout status")
    func copilotIdleTimeoutKillsProcess() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("copilot-timeout-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Started"}}'
            sleep 60
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Task that hangs", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.timeoutSeconds = 2

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.status == .failed)
        #expect(run.status == .timeout)
        #expect(run.stopReason == "timeout")
        #expect(!worker.isRunning)
        #expect(task.events.contains { $0.type == "error" && $0.payload.lowercased().contains("timeout") })
    }

    @Test("Claude idle timeout kills process and records failed status")
    func claudeIdleTimeoutKillsProcess() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("claude-timeout-launched")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf 'launched\\n' > \(Self.shQuoteSandboxPath(launchMarker.path))
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-timeout","model":"claude-sonnet-4-6"}'
            sleep 60
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Task that hangs", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)
        worker.timeoutSeconds = 2

        let executeTask = Task { @MainActor in
            await harness.execute(task: task, worker: worker)
        }

        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if FileManager.default.fileExists(atPath: launchMarker.path) { break }
        }
        #expect(FileManager.default.fileExists(atPath: launchMarker.path), "Process should have launched")

        _ = await executeTask.value

        let run = try #require(task.runs.first)
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        // Claude's idle timeout is classified as "no semantic progress" by the runtime monitor,
        // which is treated as a terminal runtime stop rather than a raw timeout.
        #expect(run.stopReason == "provider_no_semantic_progress")
        #expect(!worker.isRunning)
        #expect(task.events.contains { $0.type == "error" })
    }

    @Test("Antigravity idle timeout kills process and records timeout status")
    func antigravityIdleTimeoutKillsProcess() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("agy-timeout-launched")
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' 'Started working'
            sleep 60
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Task that hangs",
            model: "Gemini 3.5 Flash"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)
        worker.timeoutSeconds = 2

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.status == .failed)
        #expect(run.status == .timeout)
        #expect(run.stopReason == "timeout")
        #expect(!worker.isRunning)
        #expect(task.events.contains { $0.type == "error" && $0.payload.lowercased().contains("timeout") })
    }

    // MARK: - Task cancellation mid-run

    @Test("Copilot task cancellation mid-run kills process and sets cancelled status")
    func copilotCancellationMidRun() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("copilot-cancel-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Working..."}}'
            sleep 30
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Should never appear"}}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Long running Copilot task", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        let executeTask = Task { @MainActor in
            await harness.execute(task: task, worker: worker)
        }

        // Wait for the process to actually start
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if FileManager.default.fileExists(atPath: launchMarker.path) { break }
        }
        #expect(FileManager.default.fileExists(atPath: launchMarker.path), "Process should have launched")

        worker.cancel()
        _ = await executeTask.value

        let run = try #require(task.runs.first)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.stopReason == "cancelled")
        #expect(!worker.isRunning)
        #expect(!run.output.contains("Should never appear"))
    }

    @Test("Claude task cancellation mid-run kills process and sets cancelled status")
    func claudeCancellationMidRun() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("claude-cancel-launched")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-cancel","model":"claude-sonnet-4-6"}'
            sleep 30
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Should never appear","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Long running Claude task", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        let executeTask = Task { @MainActor in
            await harness.execute(task: task, worker: worker)
        }

        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if FileManager.default.fileExists(atPath: launchMarker.path) { break }
        }
        #expect(FileManager.default.fileExists(atPath: launchMarker.path), "Process should have launched")

        worker.cancel()
        _ = await executeTask.value

        let run = try #require(task.runs.first)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.stopReason == "cancelled")
        #expect(!worker.isRunning)
        #expect(!run.output.contains("Should never appear"))
    }

    @Test("Antigravity task cancellation mid-run kills process and sets cancelled status")
    func antigravityCancellationMidRun() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("agy-cancel-launched")
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' 'Working on it...'
            sleep 30
            printf '%s\\n' 'Should never appear'
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Long running Antigravity task",
            model: "Gemini 3.5 Flash"
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        let executeTask = Task { @MainActor in
            await harness.execute(task: task, worker: worker)
        }

        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if FileManager.default.fileExists(atPath: launchMarker.path) { break }
        }
        #expect(FileManager.default.fileExists(atPath: launchMarker.path), "Process should have launched")

        worker.cancel()
        _ = await executeTask.value

        let run = try #require(task.runs.first)
        #expect(task.status == .cancelled)
        #expect(run.status == .cancelled)
        #expect(run.stopReason == "cancelled")
        #expect(!worker.isRunning)
        #expect(!run.output.contains("Should never appear"))
    }
}
