import Foundation
import Testing
import SwiftData
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Runtime supervision durable worker flow", .serialized)
@MainActor
struct RuntimeSupervisionWorkerTests {
    @Test("A real worker preserves partial files, records model identity and settles a supervised stop")
    func durableStop() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let path = try harness.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(body: """
        printf '%s' 'partial work' > partial.txt
        sleep 20
        """))
        let task = harness.makeTask(runtime: .claudeCode, goal: "Create a report", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: path)
        worker.timeoutSeconds = 0.1
        worker.supervisionEnabled = true
        worker.supervisionInvestigatorOverride = { evidence in
            #expect(evidence.remoteCoverage.contains("unknown"))
            return .init(assessment: .suspectedStalled, explanation: "The synthetic runtime is stalled", evidenceIDs: ["runtime"])
        }
        _ = await harness.execute(task: task, worker: worker)
        let run = try #require(task.runs.first)
        #expect(run.status == .failed)
        #expect(run.stopReason == "provider_supervisor_stalled")
        #expect(task.status == .failed)
        let reports = try task.events.filter { $0.type == TaskEventTypes.System.runtimeSupervision.rawValue }.map {
            try JSONDecoder().decode(RuntimeSupervisionReport.self, from: Data($0.payload.utf8))
        }
        #expect(reports.map(\.phase).contains(.checking))
        #expect(reports.map(\.phase).contains(.stopping))
        #expect(reports.allSatisfy { $0.investigatorRuntime != nil && $0.investigatorModel != nil })
        #expect(Set(reports.map(\.attemptID)).count == 1)
        #expect(task.events.contains { $0.type == TaskEventTypes.System.info.rawValue && $0.payload.contains("independent model") })
        #expect(task.events.contains { $0.type == TaskEventTypes.System.runtimeSupervisionUsage.rawValue })
        let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: task.events, runs: task.runs)
        let visibleUpdates = snapshot.conversationItems.compactMap { item -> String? in
            if case .systemInfo(let text, _, _) = item { return text }
            return nil
        }
        #expect(visibleUpdates.contains { $0.contains("independent model") })
        #expect(visibleUpdates.contains { $0.contains("likely stall") })
        #expect(run.tokensUsed >= 16_384)
        let before = task.tokensUsed
        RuntimeSupervisionUsageRecorder.record(16_384, task: task, run: run, modelContext: harness.context)
        #expect(task.tokensUsed == before)
        #expect(FileManager.default.fileExists(atPath: harness.workspaceURL.appendingPathComponent("partial.txt").path))
    }

    @Test("An unavailable independent Antigravity verifier does not consume a model allocation")
    func sharedVerifierLock() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }
        let task = harness.makeTask(runtime: .antigravityCLI, goal: "Answer", model: "gemini-2.5-pro")
        let run = TaskRun(task: task)
        harness.context.insert(run)
        let context = RuntimeSupervisionContext.make(task: task, run: run, modelContext: harness.context,
            runtime: .antigravityCLI, configuration: .init(runtime: .antigravityCLI),
            pendingEvents: OrderedMainActorTaskQueue(), remoteRoute: nil)
        #expect(context.tokenReservation == 0)
        let result = await context.investigator(.init(goal: "Answer", runtime: "antigravity_cli",
            observation: .init(progressRevision: 0, quietSeconds: 600, stdoutBytes: 0, stderrBytes: 0,
                unknownFrames: 0, activeTools: [], managedJobs: [], recentOutput: ""),
            changedFiles: [], fileCoverage: "Known", remoteCoverage: "Unknown"))
        #expect(result.assessment == .inconclusive)
        #expect(result.explanation.contains("different provider"))
    }
}
