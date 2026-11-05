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

    /// A saved draft is shared across windows. Local selection owns only the
    /// new composer before a durable draft exists.
    static func composerSelection(for draft: AgentTask?, newTaskSelection: Bool) -> Bool {
        draft.map(isEnabled(for:)) ?? newTaskSelection
    }

    /// A window's Goal toggle cannot override another window's saved Consult
    /// selection. Use the same derived value for presentation and new sends.
    static func goalModeSelection(for task: AgentTask, localSelection: Bool) -> Bool {
        localSelection && !isEnabled(for: task)
    }

    /// Check the current selection immediately before synchronous acceptance.
    /// Work accepted here may finish after a later selection change; the
    /// asynchronous result does not constitute a new planning submission.
    @MainActor
    static func acceptPlanningSubmission(for task: AgentTask, submit: () throws -> Bool) rethrows -> Bool {
        guard goalModeSelection(for: task, localSelection: true) else { return false }
        return try submit()
    }

    static func isRequired(by request: TaskTurnRequest?, task: AgentTask) -> Bool {
        // Once accepted, the request owns this intent even if the composer is
        // changed before admission. Direct launches use their launch snapshot.
        request.map { $0.resourceClaims.contains { $0.kind == .workspace && $0.readConsistency == .live } }
            ?? isEnabled(for: task)
    }

    static func hasCommandAssertions(in plan: TaskPlanPayload?) -> Bool {
        plan?.validationContract?.assertions.contains { $0.method == .command } == true
    }

    static func acceptedPlan(for request: TaskTurnRequest?, task: AgentTask) -> TaskPlanPayload? {
        guard let request, let event = TaskHistoryRead.event(id: request.messageEventID, in: task) else { return nil }
        return ExecutionRequestSubmissionService.decodeSourcePayload(event)?.planSnapshot
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
