import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Durable event owner for the optional Tier-2 objective assessment.
///
/// `current_state.json` is a derived projection and may be deleted, quarantined,
/// or rebuilt. Persisting assessment changes here prevents a valid pivot from
/// disappearing during recovery and prevents a cleared pivot from resurrecting.
@MainActor
public enum TaskObjectiveAssessmentEventStore {
    public enum WriteResult: Equatable {
        case unchanged
        case persisted
        case persistenceFailed

        public var didPersist: Bool {
            self != .persistenceFailed
        }
    }

    private struct Payload: Codable, Equatable {
        enum Action: String, Codable {
            case recorded
            case cleared
        }

        let schemaVersion: Int
        let action: Action
        let assessment: TaskContextState.ObjectiveAssessment?
        let source: String
        let reason: String?
    }

    private enum Projection: Equatable {
        case recorded(TaskContextState.ObjectiveAssessment)
        case cleared
    }

    public static func record(
        _ assessment: TaskContextState.ObjectiveAssessment,
        task: AgentTask,
        source: String
    ) -> WriteResult {
        if latestProjection(for: task) == .recorded(assessment) {
            return .unchanged
        }
        return persist(
            Payload(
                schemaVersion: 1,
                action: .recorded,
                assessment: assessment,
                source: source,
                reason: nil
            ),
            task: task
        )
    }

    public static func clear(task: AgentTask, reason: String) -> WriteResult {
        if latestProjection(for: task) == .cleared {
            return .unchanged
        }
        return persist(
            Payload(
                schemaVersion: 1,
                action: .cleared,
                assessment: nil,
                source: "astra",
                reason: reason
            ),
            task: task
        )
    }

    /// Reconstructs the capsule projection from durable events. A pre-event
    /// capsule is backfilled once so existing tasks gain the same recovery
    /// guarantee without rewriting or deleting their raw history.
    public static func reconcileProjection(_ state: inout TaskContextState, task: AgentTask) {
        switch latestProjectionResult(for: task) {
        case .projection(.recorded(let assessment)):
            state.objectiveAssessment = assessment
        case .projection(.cleared):
            state.objectiveAssessment = nil
        case .noEvents:
            guard let assessment = state.objectiveAssessment else { return }
            _ = record(assessment, task: task, source: "capsule_backfill")
        case .malformed:
            AuditLoggingSeam.required.audit(.contextStateUpdated, category: "Persistence", taskID: task.id, fields: [
                "operation": "objective_assessment_projection",
                "result": "malformed_latest_event"
            ], level: .error)
        }
    }

    private enum ProjectionResult {
        case noEvents
        case malformed
        case projection(Projection)
    }

    private static func latestProjection(for task: AgentTask) -> Projection? {
        guard case .projection(let projection) = latestProjectionResult(for: task) else {
            return nil
        }
        return projection
    }

    private static func latestProjectionResult(for task: AgentTask) -> ProjectionResult {
        guard let event = task.events
            .filter({ $0.type == TaskEventTypes.Objective.assessmentChanged.rawValue })
            .max(by: eventPrecedes) else {
            return .noEvents
        }
        guard let data = event.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == 1 else {
            return .malformed
        }
        switch payload.action {
        case .recorded:
            guard let assessment = payload.assessment else { return .malformed }
            return .projection(.recorded(assessment))
        case .cleared:
            guard payload.assessment == nil else { return .malformed }
            return .projection(.cleared)
        }
    }

    private static func eventPrecedes(_ lhs: TaskEvent, _ rhs: TaskEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func persist(_ payload: Payload, task: AgentTask) -> WriteResult {
        guard let modelContext = task.modelContext else {
            auditPersistenceFailure(task: task, action: payload.action, reason: "missing_model_context")
            return .persistenceFailed
        }
        let json: String
        switch TaskEvent.encodePayload(payload) {
        case .success(let encoded):
            json = encoded
        case .failure:
            auditPersistenceFailure(task: task, action: payload.action, reason: "payload_encoding_failed")
            return .persistenceFailed
        }
        let previousUpdatedAt = task.updatedAt
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Objective.assessmentChanged,
            payload: json
        )
        modelContext.insert(event)
        let didSave = WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: [
                "operation": "objective_assessment_event",
                "action": payload.action.rawValue,
                "source": payload.source
            ]
        )
        guard didSave else {
            // A failed insert must not remain visible as an in-memory source
            // event, otherwise the next retry would incorrectly deduplicate
            // against state that never reached durable storage.
            modelContext.delete(event)
            task.updatedAt = previousUpdatedAt
            return .persistenceFailed
        }
        return .persisted
    }

    private static func auditPersistenceFailure(task: AgentTask, action: Payload.Action, reason: String) {
        AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: task.id, fields: [
            "operation": "objective_assessment_event",
            "action": action.rawValue,
            "result": reason
        ], level: .error)
    }
}
