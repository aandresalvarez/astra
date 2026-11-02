import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// The existing durable task constraints own this opt-in; requests freeze it
/// into their read-only claims. Ordinary readers still require a stable view.
enum TaskWorkspaceConsultationPolicy {
    static let declaration = "ASTRA_WORKSPACE_CONSULTATION=live"
    static let readOnlyDeclaration = "ASTRA_RESOURCE_ACCESS=read_only"
    static let providerGuidance = """
    Workspace consultation for this turn:
    - Workspace files are read-only. Another task may change them while you read; report material uncertainty from changing files.
    - Answer the user's question. Do not change workspace files, run a query or background job, or make changes on remote hosts or connected services.
    - A request to implement changes requires a new turn in Work mode. Do not upgrade this consultation's access.
    """

    static func isEnabled(for task: AgentTask) -> Bool {
        let declarations = Set((task.constraints + task.inputs).compactMap(accessValue))
        return declarations == ["read_only"] && (task.constraints + task.inputs).contains(where: isConsultationDeclaration)
    }

    static func apply(_ enabled: Bool, to task: AgentTask) {
        let wasConsultation = isEnabled(for: task)
        let shouldRemove: (String) -> Bool = {
            isConsultationDeclaration($0) || ((enabled || wasConsultation) && accessValue($0) != nil)
        }
        task.constraints.removeAll(where: shouldRemove)
        task.inputs.removeAll(where: shouldRemove)
        if enabled { task.constraints += [readOnlyDeclaration, declaration] }
    }

    private static func isConsultationDeclaration(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == declaration
    }

    private static func accessValue(_ declaration: String) -> String? {
        let parts = declaration.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == "=" || $0 == ":" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") }
        guard parts.count == 2, parts[0] == "astra_resource_access", ["read_only", "write"].contains(parts[1]) else { return nil }
        return parts[1]
    }

    @MainActor
    static func select(_ enabled: Bool, for task: AgentTask, in context: ModelContext,
                       persist: (() throws -> Void)? = nil) {
        guard task.status != .running, task.status != .queued else { return }
        let previous = task.constraints
        let previousInputs = task.inputs
        let previousUpdatedAt = task.updatedAt
        apply(enabled, to: task)
        task.updatedAt = Date()
        let event = TaskEvent(task: task, eventType: TaskEventTypes.ResourceLock.consultationSelected,
            payload: enabled ? "Consult: read workspace files while other tasks work. Files may change during the answer."
                : "Work: use the normal workspace access policy.")
        context.insert(event)
        do {
            if let persist { try persist() }
            else { try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: task.workspace, modelContext: context) }
        } catch {
            task.constraints = previous
            task.inputs = previousInputs
            task.updatedAt = previousUpdatedAt
            context.delete(event)
            AppLogger.audit(.taskFailed, category: "Runtime", taskID: task.id,
                fields: ["operation": "select_workspace_consultation", "result": "persist_failed"], level: .error)
        }
    }
}
