import Foundation
import SwiftData

/// Common fields used to decode a live source event or its immutable record.
public protocol TaskEventValue {
    var id: UUID { get }
    var type: String { get }
    var payload: String { get }
    var timestamp: Date { get }
}

extension TaskEvent: TaskEventValue {}

/// An immutable event value read from the caller's current model context.
public struct TaskEventRecord: TaskEventValue, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let runID: UUID?
    public let type: String
    public let payload: String
    public let timestamp: Date

    public init(id: UUID, runID: UUID?, type: String, payload: String, timestamp: Date) {
        self.id = id
        self.runID = runID
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }

    public init(event: TaskEvent) {
        self.init(id: event.id, runID: event.run?.id, type: event.type, payload: event.payload, timestamp: event.timestamp)
    }

    /// `TaskEvent.decodePayload(as:)` for a record.
    public func decodePayload<T: Decodable>(
        as type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) -> Result<T, TaskEventPayloadDecodeError> {
        guard let data = payload.data(using: .utf8) else { return .failure(.invalidUTF8) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
    }

    /// Oldest first; ties broken by id so every reader agrees on one order.
    public static func isChronologicallyOrdered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public struct TaskRunRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let runStatus: RunStatus
    public let stopReason: String

    public init(id: UUID, startedAt: Date, runStatus: RunStatus, stopReason: String) {
        self.id = id
        self.startedAt = startedAt
        self.runStatus = runStatus
        self.stopReason = stopReason
    }
}
