import Foundation

enum RuntimeSandboxDenialAudit {
    static func recordTerminal(
        reason: String,
        denial: RuntimeSandboxFileDenial,
        toolName: String,
        taskID: UUID
    ) {
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
            "reason": reason,
            "source": reason == "read_only_resource_write_denied"
                ? "read_only_resource_boundary"
                : "os_sandbox_denial",
            "operation": denial.operation.rawValue,
            "path": denial.path,
            "tool": toolName,
            "detail": denial.detail
        ], level: .error, fieldMaxLength: 360)
    }
}
