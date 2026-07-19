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
    public init(version: Int, resourceKey: String, accessMode: TaskResourceAccessMode, runMode: String, status: String, holderTaskID: UUID? = nil, reason: String? = nil) {
        self.version = version
        self.resourceKey = resourceKey
        self.accessMode = accessMode
        self.runMode = runMode
        self.status = status
        self.holderTaskID = holderTaskID
        self.reason = reason
    }

    public var version: Int
    public var resourceKey: String
    public var accessMode: TaskResourceAccessMode
    public var runMode: String
    public var status: String
    public var holderTaskID: UUID?
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case resourceKey
        case accessMode
        case runMode
        case status
        case holderTaskID
        case reason
    }
}

public struct TaskResourceLockClaim: Sendable, Equatable, Hashable {
    public init(
        taskID: UUID,
        resourceKey: String,
        accessMode: TaskResourceAccessMode,
        runMode: String,
        operationID: UUID? = nil
    ) {
        self.taskID = taskID
        self.resourceKey = resourceKey
        self.accessMode = accessMode
        self.runMode = runMode
        self.operationID = operationID
    }

    public var taskID: UUID
    public var resourceKey: String
    public var accessMode: TaskResourceAccessMode
    public var runMode: String
    /// The external operation this claim is FOR, when it originates from a
    /// wake/validation continuation (`AgentRuntimeExecutionPolicy.externalOperationID`).
    /// `nil` for ordinary task work. Lets exclusion distinguish "this exact
    /// operation's own continuation" from "a DIFFERENT nonterminal operation
    /// on the same task" — see `TaskQueue.canAcquireResourceLock`.
    public var operationID: UUID?
}
