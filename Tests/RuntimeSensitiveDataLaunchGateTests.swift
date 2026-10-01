import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

private func makeLaunchGateContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@MainActor
@Suite("Runtime Sensitive Data Launch Gate")
struct RuntimeSensitiveDataLaunchGateTests {
    /// Claude Code is the approved runtime throughout; everything else is not.
    private let approvesClaude: (AgentRuntimeID) -> Bool = { $0 == .claudeCode }

    private func task(in context: ModelContext, lastRanOn runtime: AgentRuntimeID?, at date: Date = Date(timeIntervalSince1970: 1_000)) -> AgentTask {
        let task = AgentTask(title: "PHI launch", goal: "test", runtime: .claudeCode)
        context.insert(task)
        if let runtime {
            let run = TaskRun(task: task)
            run.runtimeID = runtime.rawValue
            run.startedAt = date
            context.insert(run)
            task.runs.append(run)
        }
        return task
    }

    private func acknowledge(_ task: AgentTask, to runtime: AgentRuntimeID, at date: Date, in context: ModelContext) {
        let event = TaskComposerCoordinator.sensitiveDataRiskAcknowledgementEvent(
            task: task, previous: .claudeCode, next: runtime, model: "m"
        )
        event.timestamp = date
        context.insert(event)
        if !task.events.contains(where: { $0.id == event.id }) { task.events.append(event) }
    }

    @Test("a launch that would carry an approved conversation to an unapproved runtime is stopped")
    func blocksApprovedToUnapproved() throws {
        let container = try makeLaunchGateContainer()
        let context = container.mainContext
        let task = task(in: context, lastRanOn: .claudeCode)

        let block = RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: .codexCLI, launchRuntime: .codexCLI, isApproved: approvesClaude
        )

        // The conversation's runtime is where the last run went, not the
        // runtime a fallback already rewrote task.runtimeID to.
        #expect(block == .init(previousRuntimeID: AgentRuntimeID.claudeCode.rawValue, target: .codexCLI))
    }

    @Test("a first message rerouted off the approved runtime the user picked is stopped too")
    func blocksFirstRunReroute() throws {
        let container = try makeLaunchGateContainer()
        let task = task(in: container.mainContext, lastRanOn: nil)

        #expect(RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: .claudeCode, launchRuntime: .cursorCLI, isApproved: approvesClaude
        )?.target == .cursorCLI)
        #expect(RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: .claudeCode, launchRuntime: .claudeCode, isApproved: approvesClaude
        ) == nil)
    }

    @Test("only an acknowledgement for that runtime, after the last run, lets it through")
    func acknowledgementMustBeCurrentAndForTheTarget() throws {
        let container = try makeLaunchGateContainer()
        let context = container.mainContext
        let lastRun = Date(timeIntervalSince1970: 1_000)
        let task = task(in: context, lastRanOn: .claudeCode, at: lastRun)

        acknowledge(task, to: .codexCLI, at: lastRun.addingTimeInterval(-10), in: context)
        acknowledge(task, to: .cursorCLI, at: lastRun.addingTimeInterval(10), in: context)
        #expect(RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: .codexCLI, launchRuntime: .codexCLI, isApproved: approvesClaude
        ) != nil)

        acknowledge(task, to: .codexCLI, at: lastRun.addingTimeInterval(10), in: context)
        #expect(RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: .codexCLI, launchRuntime: .codexCLI, isApproved: approvesClaude
        ) == nil)
    }

    @Test("a conversation that already lives on an unapproved runtime is not stopped")
    func unapprovedOriginIsNotStopped() throws {
        let container = try makeLaunchGateContainer()
        let task = task(in: container.mainContext, lastRanOn: .codexCLI)

        #expect(RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: .cursorCLI, launchRuntime: .cursorCLI, isApproved: approvesClaude
        ) == nil)
    }

    @Test("a stopped run keeps the approved runtime, offers the gated switch, and does not launder the next launch")
    func recordedBlockKeepsTheConversationRuntime() throws {
        let container = try makeLaunchGateContainer()
        let context = container.mainContext
        let task = task(in: context, lastRanOn: .claudeCode)
        task.status = .running
        let block = try #require(RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: .codexCLI, launchRuntime: .codexCLI, isApproved: approvesClaude
        ))

        let run = TaskRun(task: task)
        run.runtimeID = AgentRuntimeID.codexCLI.rawValue
        run.startedAt = Date(timeIntervalSince1970: 2_000)
        context.insert(run)
        if !task.runs.contains(where: { $0.id == run.id }) { task.runs.append(run) }
        RuntimeSensitiveDataLaunchGate.record(block, task: task, run: run, modelContext: context, phase: .run)

        #expect(run.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(run.typedStopReason == .runtimeSensitiveDataUnapproved)
        #expect(run.typedStopReason?.isPolicyBlocked == true)
        let payload = try #require(task.events
            .first { $0.type == TaskEventTypes.System.runtimeLaunchBlocked.rawValue }
            .flatMap { TaskRunLaunchBlockPayload.decode(from: $0.payload) })
        #expect(payload.kind == .sensitiveDataUnapproved)
        #expect(payload.suggestedRuntimeID == AgentRuntimeID.codexCLI.rawValue)

        // Retrying without acknowledging stops again; the blocked attempt did
        // not make Codex look like where the conversation lives.
        #expect(RuntimeSensitiveDataLaunchGate.conversationRuntimeID(of: task) == AgentRuntimeID.claudeCode.rawValue)
        #expect(RuntimeSensitiveDataLaunchGate.block(
            task: task, requestedRuntime: .codexCLI, launchRuntime: .codexCLI, isApproved: approvesClaude
        ) != nil)
    }

    @Test("the worker gates before applying a reroute, and restored drafts are gated")
    func workerAndDraftComposerAreWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let worker = try String(contentsOf: root.appendingPathComponent("Astra/Services/Runtime/AgentRuntimeWorker.swift"), encoding: .utf8)
        let chatPanel = try String(contentsOf: root.appendingPathComponent("Astra/Views/ChatPanelView.swift"), encoding: .utf8)

        #expect(worker.contains("sensitiveDataBlock == nil ? runtimeResolution : runtimeResolution.withoutReroute"))
        #expect(worker.contains("RuntimeSensitiveDataLaunchGate.record(sensitiveDataBlock"))
        // A restored draft carries its conversation, so its composer is gated too.
        #expect(chatPanel.contains("sensitiveDataSwitchGuard: draftTask.map(TaskComposerCoordinator.sensitiveDataSwitchGuard(for:))"))
    }
}
