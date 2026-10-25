import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

struct RuntimeRecoveryReport: Codable, Sendable {
    enum Phase: String, Codable { case intent, resumed, progress, blocked, expired, interrupted }
    let operationID: UUID
    let attemptID: UUID
    let processID: Int32?
    let phase: Phase
    let message: String
    var action = "resume_suspended_process"
}

/// The durable run events own recovery admission. Process-local controllers
/// cannot replay an intent after a crash or admit a second action for this run.
@MainActor
enum RuntimeRecoveryService {
    static func authorize(_ report: RuntimeRecoveryReport, task: AgentTask, run: TaskRun,
                          modelContext: ModelContext, save: (() throws -> Void)? = nil) -> Bool {
        guard !Task.isCancelled, report.phase == .intent, report.processID != nil,
              run.task?.id == task.id, run.status == .running, task.status == .running,
              task.runs.max(by: { $0.startedAt < $1.startedAt })?.id == run.id,
              !task.events.contains(where: { event in
                  event.run?.id == run.id && event.type == TaskEventTypes.System.runtimeRecovery.rawValue
                      && (try? JSONDecoder().decode(RuntimeRecoveryReport.self, from: Data(event.payload.utf8)))?.phase == .intent
              }) else { return false }
        return record(report, task: task, run: run, modelContext: modelContext, save: save)
    }

    @discardableResult
    static func record(_ report: RuntimeRecoveryReport, task: AgentTask, run: TaskRun,
                       modelContext: ModelContext, save: (() throws -> Void)? = nil) -> Bool {
        guard run.task?.id == task.id,
              let data = try? JSONEncoder().encode(report), let payload = String(data: data, encoding: .utf8) else { return false }
        let event = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeRecovery, payload: payload, run: run)
        let info = TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: report.message, run: run)
        modelContext.insert(event); modelContext.insert(info)
        do {
            if let save { try save() }
            else {
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: task.workspace,
                    modelContext: modelContext, taskID: task.id,
                    auditFields: ["operation": "runtime_recovery", "recovery_id": report.operationID.uuidString])
            }
            return true
        } catch {
            // Do not rollback unrelated stream events. Failed intent admission
            // must never authorize a signal, even if a later save succeeds.
            modelContext.delete(event); modelContext.delete(info)
            return false
        }
    }
}
