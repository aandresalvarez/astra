import Foundation

/// Execution intent belongs to the approval, independently of task/run status.
/// Optional envelope fields keep previously persisted requests readable.
public enum PermissionApprovalBehavior: String, Codable, Sendable {
    case continueBlockedTurn
    case futureUse
}

public struct PermissionApprovalContinuation: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case live
        case relaunch
    }

    public var runID: UUID
    public var sourceEventID: UUID?
    public var originalUserRequest: String
    public var mode: Mode

    public init(runID: UUID, sourceEventID: UUID?, originalUserRequest: String, mode: Mode) {
        self.runID = runID
        self.sourceEventID = sourceEventID
        self.originalUserRequest = originalUserRequest
        self.mode = mode
    }
}
