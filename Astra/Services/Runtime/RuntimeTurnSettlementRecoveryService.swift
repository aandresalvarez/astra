import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

@MainActor
enum RuntimeTurnSettlementRecoveryService {
    /// Runs before orphan recovery. A saved approval without a captured result
    /// cannot prove whether the process used it; preserve authority and require
    /// reconciliation rather than automatically executing external work again.
    static func prepare(modelContext: ModelContext, autoExport: Bool = true) {
        let type = TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue
        guard let events = try? modelContext.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.type == type })) else { return }
        for event in events {
            guard let task = event.task, let run = event.run, !task.isDone,
                  task.status != .cancelled,
                  RuntimeTurnSettlementService.verdict(for: run, task: task) == nil,
                  !RuntimeTurnSettlementService.hasUnsettledResult(task: task, run: run),
                  let commit = try? JSONDecoder().decode(LivePermissionApprovalRecovery.Commit.self, from: Data(event.payload.utf8)),
                  (try? TaskPermissionContinuation.isCurrent(commit.binding, task: task, modelContext: modelContext)) == true,
                  run.status == .running || !LivePermissionApprovalRecovery.hasDeliveryReceipt(requestID: commit.requestID, task: task, run: run)
            else { continue }
            RuntimeTurnSettlementService.pauseForReconciliation(task: task, run: run, modelContext: modelContext)
        }
        if autoExport {
            for workspace in Dictionary(events.compactMap { $0.task?.workspace }.map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first }).values {
                WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
            }
        } else {
            WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: modelContext)
        }
    }

    /// Resumes only local outcome/plan settlement. The queue is signalled after
    /// every verdict is saved; no original provider process is launched here.
    static func resume(modelContext: ModelContext, taskQueue: TaskQueue, autoExport: Bool = true) async {
        let captured = TaskEventTypes.System.runtimeResultCaptured.rawValue
        let settled = TaskEventTypes.System.runtimeTurnSettled.rawValue
        guard let events = try? modelContext.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.type == captured || $0.type == settled })) else { return }
        var seenRuns: Set<UUID> = []
        for event in events {
            guard let task = event.task, let run = event.run, !task.isDone, seenRuns.insert(run.id).inserted,
                  task.runs.max(by: { $0.startedAt < $1.startedAt })?.id == run.id else { continue }
            if RuntimeTurnSettlementService.verdict(for: run, task: task) == nil {
                do {
                    guard let checkpoint = try RuntimeTurnSettlementService.checkpoint(for: run, task: task) else { continue }
                    guard await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: task,
                        run: run, modelContext: modelContext, autoExport: autoExport) else { continue }
                } catch {
                    RuntimeTurnSettlementService.reportPersistenceFailure(task: task, run: run, modelContext: modelContext)
                    continue
                }
            }
            RuntimeSettlementProgress.pruneSettledCaptures(task: task, modelContext: modelContext)
            RuntimeTurnSettlementService.dispatchChainedTask(task: task, run: run, modelContext: modelContext)
            if let id = RuntimeTurnSettlementService.verdict(for: run, task: task)?.scheduleID {
                taskQueue.routeScheduleResult(task: task, scheduleID: id, modelContext: modelContext)
            }
        }
    }
}
