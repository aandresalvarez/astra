import Foundation

public enum TaskResourceAccessMode: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case readOnly = "read_only"
    case write

    public var displayName: String {
        switch self {
        case .readOnly: "read-only"
        case .write: "write"
        }
    }
}

public enum TaskResourceLockEventTypes {
    public static let requested = TaskEventTypes.ResourceLock.requested.rawValue
    public static let waiting = TaskEventTypes.ResourceLock.waiting.rawValue
    public static let acquired = TaskEventTypes.ResourceLock.acquired.rawValue
    public static let released = TaskEventTypes.ResourceLock.released.rawValue
}

public struct TaskResourceLockPayload: Codable, Sendable, Equatable {
    public init(
        version: Int,
        resourceKey: String,
        accessMode: TaskResourceAccessMode,
        runMode: String,
        status: String,
        holderTaskID: UUID? = nil,
        reason: String? = nil,
        resourceKind: TaskExecutionResourceKind? = nil,
        requestID: UUID? = nil,
        readConsistency: TaskResourceReadConsistency? = nil
    ) {
        self.version = version
        self.resourceKey = resourceKey
        self.accessMode = accessMode
        self.runMode = runMode
        self.status = status
        self.holderTaskID = holderTaskID
        self.reason = reason
        self.resourceKind = resourceKind
        self.requestID = requestID
        self.readConsistency = readConsistency
    }

    public var version: Int
    public var resourceKey: String
    public var accessMode: TaskResourceAccessMode
    public var runMode: String
    public var status: String
    public var holderTaskID: UUID?
    public var reason: String?
    public var resourceKind: TaskExecutionResourceKind?
    public var requestID: UUID?
    public var readConsistency: TaskResourceReadConsistency?

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case resourceKey
        case accessMode
        case runMode
        case status
        case holderTaskID
        case reason
        case resourceKind
        case requestID
        case readConsistency
    }
}

public struct TaskResourceLockClaim: Codable, Sendable, Equatable, Hashable {
    public init(
        taskID: UUID,
        resourceKey: String,
        accessMode: TaskResourceAccessMode,
        runMode: String,
        resourceKind: TaskExecutionResourceKind = .workspace,
        requestID: UUID? = nil,
        leaseID: UUID? = nil,
        readConsistency: TaskResourceReadConsistency? = nil
    ) {
        self.taskID = taskID
        self.resourceKey = resourceKey
        self.accessMode = accessMode
        self.runMode = runMode
        self.resourceKind = resourceKind
        self.requestID = requestID
        self.leaseID = leaseID
        self.readConsistency = readConsistency
    }

    public var taskID: UUID
    public var resourceKey: String
    public var accessMode: TaskResourceAccessMode
    public var runMode: String
    public var resourceKind: TaskExecutionResourceKind
    public var requestID: UUID?
    /// The one acquisition this claim belongs to. Two admissions of the same
    /// task can request identical claims; the lease id keeps a late release
    /// from the first from freeing the second's hold.
    public var leaseID: UUID?
    public var readConsistency: TaskResourceReadConsistency?

    /// Only an enforced read-only workspace observation can overlap a writer.
    /// Flags on other resource kinds or on writers never weaken their locks.
    public var isLiveWorkspaceReader: Bool {
        resourceKind == .workspace && accessMode == .readOnly && readConsistency == .live
    }

    public func coversAccess(of other: TaskResourceLockClaim) -> Bool {
        accessMode == .write || (other.accessMode == .readOnly && (!isLiveWorkspaceReader || other.isLiveWorkspaceReader))
    }

    public func leased(_ leaseID: UUID) -> TaskResourceLockClaim {
        var claim = self
        claim.leaseID = leaseID
        return claim
    }
}
