import Foundation
import SwiftData
import ASTRAModels

/// Reads attempt identity without deriving permission from the mutable task or
/// from a source event's current run. A missing event is legacy; an invalid
/// recorded reference is never permission to fall back to legacy inference.
@MainActor
public enum TaskRunRequestAssociation {
    public enum Failure: Error {
        case invalidReference
        case conflictingReference
    }

    public static func request(for run: TaskRun, in context: ModelContext) throws -> TaskTurnRequest? {
        guard let task = run.task, task.modelContext === context, run.modelContext === context else {
            throw Failure.invalidReference
        }
        let runID = run.id
        let type = TaskEventTypes.ExecutionRequest.runAssociated.rawValue
        let events = try context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.run?.id == runID && $0.type == type
        })).filter { !$0.isDeleted && $0.run?.persistentModelID == run.persistentModelID }
        var recorded: TaskRunRequestAssociationPayload?
        for event in events {
            guard event.task?.persistentModelID == task.persistentModelID,
                  case .success(let reference) = event.decodePayload(as: TaskRunRequestAssociationPayload.self),
                  reference.version == 1, reference.taskID == task.id, reference.runID == run.id else {
                throw Failure.invalidReference
            }
            if let recorded, recorded != reference { throw Failure.conflictingReference }
            recorded = reference
        }
        guard let recorded else { return nil }
        let requestID = recorded.requestID
        let rows = try context.fetch(FetchDescriptor<TaskTurnRequest>(predicate: #Predicate { $0.id == requestID }))
            .filter { !$0.isDeleted }
        guard rows.count == 1, let request = rows.first, request.sourceEventID == recorded.sourceEventID else {
            throw Failure.invalidReference
        }
        try validate(request, for: run, in: context)
        return request
    }

    /// Validate the relation before writing it, and again whenever it is used.
    /// A source may move to a later attempt; its task and identity may not.
    public static func validate(_ request: TaskTurnRequest, for run: TaskRun, in context: ModelContext) throws {
        guard let task = run.task, task.modelContext === context, run.modelContext === context,
              request.modelContext === context,
              try TaskTurnRequestOwnership.resolve(request, in: context)?.persistentModelID == task.persistentModelID else {
            throw Failure.invalidReference
        }
        let sourceID = request.sourceEventID
        let taskID = task.id
        let sources = try context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate {
            $0.id == sourceID && $0.task?.id == taskID
        })).filter { !$0.isDeleted && $0.task?.persistentModelID == task.persistentModelID }
        guard sources.count == 1 else { throw Failure.invalidReference }
    }
}
