import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Opt-in, in-memory development presentation fixtures. No providers are enqueued.
@MainActor
enum RuntimeLaunchUIFixture {
    static func install(workspace: Workspace, context: ModelContext) -> AgentTask {
        var first: AgentTask?
        for (title, stage, cancelled) in [
            ("QA · Cancelled before provider start", "waiting_for_provider", true),
            ("QA · Preparing execution", "preparing", false),
            ("QA · Waiting for Antigravity configuration", "waiting_for_provider", false)
        ] {
            let task = AgentTask(title: title, goal: "Synthetic launch presentation", workspace: workspace, runtime: .antigravityCLI)
            context.insert(task)
            TaskStateMachine.enqueueFromUITestSeed(task, modelContext: context)
            TaskStateMachine.admitQueuedTaskToRuntime(task, modelContext: context)
            WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context)
            let owner = cancelled ? RuntimeExecutionOwner.acquire(task: task, context: context, maxRunSeconds: 120) : nil
            let run = TaskRun(task: task); context.insert(run)
            run.startedAt = Date().addingTimeInterval(-90)
            if let owner {
                try? owner.bind(run: run)
                try? owner.waitingForProviderState(.init(runtime: .antigravityCLI, identifier: "synthetic-settings.json"))
                owner.requestCancellation()
                try? owner.beginSettlement()
                try? owner.completeSettlement(localWorkStopped: true, toolsStopped: true)
                TaskStateMachine.cancelFromLifecycle(task, modelContext: context)
                RuntimeSettlementCancellation.applyIfNeeded(task: task, run: run, context: context)
                run.completedAt = Date()
                owner.finish()
            } else {
                let payload = "{\"state\":\"preparing\",\"preparationStage\":\"\(stage)\",\"preparationResource\":\"antigravity_cli:synthetic-settings.json\"}"
                context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: payload, run: run))
            }
            if first == nil { first = task }
        }
        return first!
    }
}
