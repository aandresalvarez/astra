import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Codex usage correction import", .serialized)
@MainActor
struct CodexSessionUsageCorrectionImportTests {
    private typealias Service = CodexSessionUsageCorrectionService

    private func workspace(_ h: HeadlessChatHarness) -> (Workspace, AgentTask) {
        let (task, _, _) = CodexSessionUsageCorrectionSafetyTests().seed(h)
        let workspace = Workspace(name: "Usage import", primaryPath: h.workspaceURL.path)
        h.context.insert(workspace)
        task.workspace = workspace
        return (workspace, task)
    }

    @Test("Native import corrects complete history immediately, then repetition and reload are inert")
    func importRepeatAndReload() async throws {
        let source = try HeadlessChatHarness(); defer { source.cleanup() }
        let (workspace, _) = workspace(source)
        let url = source.workspaceURL.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: source.context, url: url)
        let config = try WorkspaceConfigManager.loadConfig(from: url)
        #expect(config.tasks?.first?.codexUsageHistoryComplete == true)
        let destination = try HeadlessChatHarness(persistentStore: true); defer { destination.cleanup() }
        destination.context.autosaveEnabled = false
        let result = WorkspaceImportOrchestrator(modelContext: destination.context, taskQueue: TaskQueue(poolSize: 0))
            .importWorkspaces(from: [url], existingWorkspaces: []) { _, _ in .skip }
        let task = try #require(result.imported.first?.tasks.first)
        #expect(task.tokensUsed == 330 && task.tokenBudget == 9000)
        #expect(task.events.filter { $0.type == Service.correctedEventType }.count == 1)
        await Service.correct(modelContext: destination.context)
        let reopened = ModelContext(destination.container)
        reopened.autosaveEnabled = false
        let restored = try #require(try reopened.fetch(FetchDescriptor<AgentTask>()).first)
        await Service.correct(modelContext: reopened)
        #expect(restored.tokensUsed == 330 && restored.runs.count == 2)
        #expect(restored.events.filter { $0.type == Service.correctedEventType }.count == 1)
    }

    @Test("A truncated export never replays its first retained cumulative report from zero")
    func truncatedHistoryRemainsUnchanged() async throws {
        let source = try HeadlessChatHarness(); defer { source.cleanup() }
        let (workspace, task) = workspace(source)
        for index in 2..<12 {
            let run = TaskRun(task: task)
            run.providerSessionId = "legacy-session"
            run.startedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60))
            run.status = .completed; run.inputTokens = 100; run.outputTokens = 10; run.tokensUsed = 110
            task.tokensUsed += 110
            source.context.insert(run)
            let total = 300 + (index - 1) * 100
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Task.stats,
                payload: "tokens: \(total + total / 10) (in: \(total), out: \(total / 10))", run: run)
            event.timestamp = run.startedAt
            source.context.insert(event)
        }
        await Service.correct(modelContext: source.context)
        let total = task.tokensUsed
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: source.context))
        #expect(config.tasks?.first?.runs.count == 10)
        #expect(config.tasks?.first?.codexUsageHistoryComplete == false)
        let destination = try HeadlessChatHarness(); defer { destination.cleanup() }
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: destination.context)
        let restored = try #require(imported.tasks.first)
        let outcome = await Service.correct(modelContext: destination.context)
        #expect(outcome.sessionsSkipped == 1 && restored.tokensUsed == total)
        #expect(restored.events.contains { $0.type == CodexUsageHistory.incompleteEventType })
        let reexport = try #require(WorkspaceConfigManager.export(workspace: imported, modelContext: destination.context))
        #expect(reexport.tasks?.first?.codexUsageHistoryComplete == false)
    }

    @Test("Dropping usage events and older mirrors cannot certify a complete baseline", arguments: [true, false])
    func incompleteEvidenceStaysIncomplete(dropEvents: Bool) async throws {
        let source = try HeadlessChatHarness(); defer { source.cleanup() }
        let (workspace, _) = workspace(source)
        if dropEvents, let task = workspace.tasks.first {
            for index in 0..<15 {
                let event = TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: "Message \(index)")
                event.timestamp = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
                source.context.insert(event)
            }
        }
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: source.context))
        if !dropEvents { config.tasks?[0].codexUsageHistoryComplete = nil }
        else { #expect(config.tasks?.first?.codexUsageHistoryComplete == false) }
        let destination = try HeadlessChatHarness(); defer { destination.cleanup() }
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: destination.context)
        await Service.correct(modelContext: destination.context)
        #expect(imported.tasks.first?.tokensUsed == 440)
        #expect(imported.tasks.first?.events.contains { $0.type == CodexUsageHistory.incompleteEventType } == true)
    }

    @Test("A persisted uncertain owner still fences migration after reopening the store")
    func uncertainRestart() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, _, second) = CodexSessionUsageCorrectionSafetyTests().seed(h)
        task.status = .pendingUser; second.status = .failed; second.typedStopReason = .runtimeConnectionLost
        let receipt = try RuntimeRecoveryTestReceipt.install(task: task, run: second, context: h.context, toolsStopped: false)
        try h.context.save()
        let reopened = ModelContext(h.container)
        reopened.autosaveEnabled = false
        let restored = try #require(try reopened.fetch(FetchDescriptor<AgentTask>()).first)
        let result = await Service.correct(modelContext: reopened)
        #expect(result.sessionsDeferred == 1 && restored.tokensUsed == 440)
        #expect(try RuntimeExecutionOwner.existing(task: restored, context: reopened) == receipt)
    }
}
