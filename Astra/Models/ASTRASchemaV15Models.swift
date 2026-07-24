import Foundation
import SwiftData

/// Frozen copies of models that were introduced in schema V15.
///
/// V15 originally referenced the live `TaskTurnRequest` declaration. Adding
/// fields for V16 would therefore silently change the model fingerprint of
/// stores already written as 15.0.0. Keep this declaration byte-for-byte
/// aligned with the canonical V15 entity and point `ASTRASchemaV15` at it.
public enum ASTRASchemaV15Models {
    @Model
    public final class TaskTurnRequest {
        public var id: UUID
        public var taskID: UUID
        public var messageEventID: UUID
        public var runID: UUID?
        public var sequence: Int
        public var stateRawValue: String
        public var submittedAt: Date
        public var admittedAt: Date?
        public var startedAt: Date?
        public var terminalAt: Date?
        public var terminalReason: String?
        public var blockingTaskID: UUID?
        public var blockerSummary: String?

        public init() {
            id = UUID()
            taskID = UUID()
            messageEventID = UUID()
            runID = nil
            sequence = 0
            stateRawValue = "waiting_for_worker"
            submittedAt = Date()
            admittedAt = nil
            startedAt = nil
            terminalAt = nil
            terminalReason = nil
            blockingTaskID = nil
            blockerSummary = nil
        }
    }
}
