import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Preparation accounting through the worker", .serialized)
@MainActor
struct RuntimePreparationAccountingTests {
    @Test("A real configuration timeout persists zero usage without launching the provider")
    func timeoutDoesNotInventUsage() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let launched = h.rootURL.appendingPathComponent("unexpected-launch")
        let path = try h.writeExecutable(named: "agy", script: """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          printf '%s\\n' '--output-format --sandbox --print --resume'
          exit 0
        fi
        touch '\(launched.path)'
        exit 1
        """)
        let home = h.rootURL.appendingPathComponent("provider-home").path
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home))
        let lock = try await ProviderSharedStateProcessLock.acquire(key)
        defer { withExtendedLifetime(lock) {} }
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        runner.providerStateWaitTimeoutSeconds = 0.05
        let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
        worker.supervisionEnabled = false
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.environmentHealthChecker = EnvironmentHealthChecker(runner: InstantSuccessBinaryRunner())
        worker.mcpServerExecutableIsResolvable = { _ in true }; worker.mcpServerExecutableDetector = { $0 }
        worker.setExecutablePath(path, for: .antigravityCLI); worker.setHomeDirectory(home, for: .antigravityCLI)
        worker.antigravityLaunchPreparation = AntigravityLaunchPreparation(defaults: InMemoryDefaults())
        let task = h.makeTask(runtime: .antigravityCLI, goal: "A prompt that must not be charged before launch", model: "gemini-test", tokenBudget: 80_000)
        _ = await h.execute(task: task, worker: worker)
        let run = try #require(task.runs.first)
        #expect(run.stopReason == RuntimeProviderStateWaitTimeout.stopReason)
        #expect(run.tokensUsed == 0 && task.tokensUsed == 0)
        #expect(!FileManager.default.fileExists(atPath: launched.path))
        #expect(!task.events.contains { $0.payload.hasPrefix("estimated tokens:") })
        let reopened = ModelContext(h.container)
        let saved = try #require(try RuntimeExecutionOwner.store(in: reopened).read(taskID: task.id, taskOwnerID: task.persistentModelID))
        #expect(saved.limits.tokensSpent == 0 && !saved.hasProviderLaunch)
        #expect(saved.state == .notStarted && saved.canReplace)
    }
}
