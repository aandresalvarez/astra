import Foundation
import Testing
import SwiftData
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

@Suite("Copilot launch capability discovery")
@MainActor
struct CopilotLaunchDiscoveryTests {
    @Test("Failed Copilot discovery settles the task without launching a provider")
    func failedDiscoveryDoesNotLaunchProvider() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let launched = harness.rootURL.appendingPathComponent("launched")
        let executable = try harness.writeExecutable(named: "copilot", script: """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          echo --output-format=FORMAT --stream=MODE --no-ask-user
          exit 1
        fi
        if [ "$1" = "--version" ]; then
          echo 'copilot fake 1.0'
          exit 0
        fi
        touch '\(launched.path)'
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"unsafe fallback"}}'
        """)
        let task = harness.makeTask(runtime: .copilotCLI, goal: "Say hello", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: executable)
        _ = await harness.execute(task: task, worker: worker)
        #expect(task.status == .failed)
        #expect(task.runs.isEmpty)
        #expect(task.events.contains { $0.payload.contains("Copilot help failed") })
        #expect(!FileManager.default.fileExists(atPath: launched.path))
    }

    @Test("A Claude launch does not query an installed Copilot")
    func unrelatedWorkerDoesNotProbeCopilot() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let counter = harness.rootURL.appendingPathComponent("copilot-probes")
        let copilot = try harness.writeExecutable(named: "copilot", script: """
        #!/bin/sh
        echo probe >> '\(counter.path)'
        exit 1
        """)
        let claude = try harness.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(
            body: #"printf '%s\n' '{"type":"result","result":"hello","is_error":false}'"#))
        let task = harness.makeTask(runtime: .claudeCode, goal: "Say hello", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claude)
        worker.copilotPath = copilot
        _ = await harness.execute(task: task, worker: worker)
        #expect(task.runs.first?.status == .completed)
        #expect(!FileManager.default.fileExists(atPath: counter.path))
    }

    @Test("A Copilot follow-up inside the readiness window asks again instead of launching on a timed-out probe")
    func copilotFollowUpReprobesInsideReadinessWindow() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let release = harness.rootURL.appendingPathComponent("release")
        let help = #"echo "--output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR""#
        func copilotScript(help helpBody: String, answer: String, inputTokens: Int) -> String {
            """
            #!/bin/sh
            if [ "$1" = "help" ]; then
            \(helpBody)
              exit 0
            fi
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(answer)"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":\(inputTokens),"output_tokens":1},"duration_ms":1,"turns":1}'
            exit 0
            """
        }
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: copilotScript(help: "  \(help)", answer: "first answer", inputTokens: 2)
        )
        defer { CopilotCLIRuntime.invalidateCapabilitiesCache(executablePath: copilotPath) }

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Say hello", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        // A hang guard only: two launches took 147 s in one loaded full-suite run.
        worker.timeoutSeconds = 600
        // Production hands the worker the shared verdict cache, so a follow-up inside the
        // window skips the readiness check, and the re-probe that check would make.
        worker.launchReadinessCache = RuntimeLaunchReadinessCache()
        _ = await harness.execute(task: task, worker: worker)
        try #require(task.runs.first?.status == .completed)

        // An in-place upgrade leaves the verdict fresh but changes the binary's identity,
        // and the new `help` cannot answer the main actor's read before the release.
        _ = try harness.writeExecutable(
            named: "copilot",
            script: copilotScript(
                help: CopilotCLICapabilityProbeTests.helpWaitingFor(release, then: help),
                answer: "second answer",
                inputTokens: 5
            )
        )
        #expect(await CopilotCLICapabilityProbeTests.briefCapabilitiesOffMain(executablePath: copilotPath) == .conservative)
        try Data().write(to: release)

        // Launched on that fallback, the follow-up would lose the JSON flags: the usage line
        // would go unparsed and the stream would land as raw JSON.
        _ = await harness.continueTask(task: task, message: "Say it again", worker: worker)
        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        #expect(run.output.contains("second answer"))
        #expect(!run.output.contains("sessionUpdate"))
        #expect(run.inputTokens == 5)
    }

    @Test("A stop during the Copilot capability warm-up launches nothing")
    func stopDuringCapabilityWarmUpLaunchesNothing() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let release = harness.rootURL.appendingPathComponent("release")
        let probes = harness.rootURL.appendingPathComponent("help-probes")
        let launched = harness.rootURL.appendingPathComponent("launched")
        let help = #"echo "--output-format=FORMAT --stream=MODE --no-ask-user""#
        let copilotPath = try harness.writeExecutable(named: "copilot", script: """
            #!/bin/sh
            if [ "$1" = "help" ]; then
              echo probe >> \(Self.shQuote(probes.path))
            \(CopilotCLICapabilityProbeTests.helpWaitingFor(release, then: help))
              exit 0
            fi
            touch \(Self.shQuote(launched.path))
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"launched"}}'
            exit 0
            """)
        defer { CopilotCLIRuntime.invalidateCapabilitiesCache(executablePath: copilotPath) }
        func probeCount() -> Int {
            ((try? String(contentsOf: probes, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        // Leave an unanswered memo so admission's main-actor reads take it, and the only
        // probe the launch starts is the warm-up's.
        #expect(await CopilotCLICapabilityProbeTests.briefCapabilitiesOffMain(executablePath: copilotPath) == .conservative)
        let probesBeforeLaunch = probeCount()

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Say hello", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        let launch = Task { await harness.execute(task: task, worker: worker) }
        // Polls, not seconds: a hang breaker that load can only push later.
        var polls = 0
        while probeCount() == probesBeforeLaunch, polls < 2_400 {
            polls += 1
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(probeCount() > probesBeforeLaunch, "the warm-up never probed")

        // The stop has no process to terminate yet; the warm-up then gets its answer.
        worker.cancel()
        // Do not release help: Stop must itself release the worker and settle durable state.
        _ = await launch.value
        #expect(task.status == .cancelled)
        #expect(!worker.isRunning)

        #expect(task.runs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: launched.path))
    }

    private static func shQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
