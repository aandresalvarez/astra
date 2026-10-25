import Foundation

/// A durable outbox entry. Recording a provider observation and publishing its
/// app event are separate stores; its ID makes reconciliation crash-safe.
public struct RemoteWorkspaceJobTransition: Codable, Equatable, Sendable {
    public let id: UUID
    public let jobID: String
    public let at: Date
    public let status: RemoteWorkspaceJobStatus
    public let observation: RemoteWorkspaceJobObservation?
    public let cancellation: Bool
    public let message: String?

    public init(record: RemoteWorkspaceJobRecord, cancellation: Bool = false) {
        id = UUID(); jobID = record.jobID
        at = cancellation ? (record.cancellationRequestedAt ?? Date()) : (record.lastObservation?.at ?? record.createdAt)
        status = record.status; observation = record.lastObservation
        self.cancellation = cancellation; message = record.message
    }
}
