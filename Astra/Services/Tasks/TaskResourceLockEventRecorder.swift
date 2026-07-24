import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Persists and audits resource-lease lifecycle evidence without becoming a
/// second lock authority. Durable request claims own admission intent; the
/// queue supplies its current process-local holders for diagnostic metadata.
enum TaskResourceLockEventRecorder {
    @MainActor
    static func record(
        type: String,
        auditEvent: AuditEvent,
        task: AgentTask,
        claim: TaskResourceLockClaim,
        status: String,
        reason: String? = nil,
        modelContext: ModelContext?,
        activeClaims: [TaskResourceLockClaim],
        autoExport: Bool = true
    ) {
        let holder = activeClaims.first {
            $0.taskID != claim.taskID && TaskExecutionResourceBroker.conflicts($0, claim)
        }?.taskID
        let payload = TaskResourceLockPayload(
            version: 2,
            resourceKey: claim.resourceKey,
            accessMode: claim.accessMode,
            runMode: claim.runMode,
            status: status,
            holderTaskID: holder,
            reason: reason,
            resourceKind: claim.resourceKind,
            requestID: claim.requestID
        )
        if let modelContext {
            modelContext.insert(TaskEvent(task: task, type: type, payload: encode(payload)))
            // Pre-admission events must not race the authoritative terminal
            // workspace export. Only the final release in a lease auto-exports.
            if autoExport {
                WorkspacePersistenceCoordinator.saveAndAutoExport(
                    workspace: task.workspace,
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: ["operation": "resource_lock_event"]
                )
            } else {
                WorkspacePersistenceCoordinator.saveWithoutAutoExport(
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: ["operation": "resource_lock_event"]
                )
            }
        }
        AppLogger.audit(auditEvent, category: "Queue", taskID: task.id, fields: [
            "resource_kind": claim.resourceKind.rawValue,
            "resource_key": claim.resourceKey,
            "access_mode": claim.accessMode.rawValue,
            "run_mode": claim.runMode,
            "status": status,
            "holder_task_id": holder?.uuidString ?? "none",
            "reason": reason ?? "none"
        ], level: type == TaskResourceLockEventTypes.waiting ? .warning : .info)
    }

    private static func encode(_ payload: TaskResourceLockPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
