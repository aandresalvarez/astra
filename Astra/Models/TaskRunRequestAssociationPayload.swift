import Foundation

/// An immutable identity link for one attempt. The request remains the sole
/// owner of accepted policy and claims after its current-attempt fields move.
public struct TaskRunRequestAssociationPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let taskID: UUID
    public let runID: UUID
    public let requestID: UUID
    public let sourceEventID: UUID

    public init(taskID: UUID, runID: UUID, requestID: UUID, sourceEventID: UUID) {
        version = 1
        self.taskID = taskID
        self.runID = runID
        self.requestID = requestID
        self.sourceEventID = sourceEventID
    }
}
