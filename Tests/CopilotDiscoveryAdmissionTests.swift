import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Copilot discovery admission")
@MainActor
struct CopilotDiscoveryAdmissionTests {
    @Test("A removed or non-executable CLI keeps its typed setup block and failed run", arguments: [false, true])
    func missingExecutableKeepsAdmission(nonExecutable: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let invocations = harness.rootURL.appendingPathComponent("provider-calls")
        let executable = try harness.writeExecutable(named: "copilot", script: HeadlessChatScenarioTests.copilotScript(body: """
            echo called >> '\(invocations.path)'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}'
            """))
        let task = harness.makeTask(runtime: .copilotCLI, goal: "Say hello", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: executable)
        worker.launchReadinessCache = RuntimeLaunchReadinessCache()
        _ = await harness.execute(task: task, worker: worker)
        try #require(task.runs.first?.status == .completed)
        if nonExecutable {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable)
        } else { try FileManager.default.removeItem(atPath: executable) }
        _ = await harness.continueTask(task: task, message: "Say hello again", worker: worker)
        let run = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(task.runs.count == 2)
        #expect(run.status == .failed)
        #expect(run.stopReason == "missing_copilot")
        #expect(task.events.contains { $0.type == TaskEventTypes.System.runtimeLaunchBlocked.rawValue })
        #expect(try String(contentsOf: invocations, encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test("Failed discovery blocks Copilot Send while an unrelated provider stays eligible", arguments: [false, true])
    func failedDiscoveryBlocksPreview(emptyHelp: Bool) async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let executable = try harness.writeExecutable(named: "copilot", script: emptyHelp
            ? "#!/bin/sh\nexit 0\n"
            : "#!/bin/sh\necho --output-format=FORMAT\nexit 1\n")
        var settings = ProviderSettingsSnapshot.headlessScenario
        settings.providerSettings.setExecutablePath(executable, for: .copilotCLI)
        let task = harness.makeTask(runtime: .copilotCLI, goal: "Say hello", model: "gpt-5")
        let states: [AgentRuntimeID: RuntimeReadinessState] = [.copilotCLI: .ready, .claudeCode: .ready]
        func request() -> RuntimeEligibilityPreviewRequest {
            .existingTask(task: task, messageText: "Say hello", attachedFiles: [],
                selectedPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue, skipPermissions: true,
                providerSettings: settings, readinessStates: states, eventRevision: 0)
        }
        let copilot = request()
        let snapshot = try #require(await copilot.evaluate(candidateRuntimes: [.copilotCLI]))
        #expect(!snapshot.selectedCandidate.isEligible)
        #expect(snapshot.launchBlock?.message.contains("Copilot help failed") == true)
        let preview = RuntimeEligibilityPreviewState.evaluated(signature: copilot.signature, snapshot: snapshot)
        #expect(!RuntimeEligibilitySubmissionPolicy.canExecute(hasInput: true, runtime: .copilotCLI,
            readinessStates: states, previewState: preview, signature: copilot.signature))
        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        let other = request()
        let broad = try #require(await other.evaluate(candidateRuntimes: [.claudeCode, .copilotCLI]))
        #expect(broad.selectedCandidate.isEligible)
        #expect(broad.candidates[.copilotCLI]?.isEligible == false)
    }
}
