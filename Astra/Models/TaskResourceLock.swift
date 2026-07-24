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
        requestID: UUID? = nil
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
    }
}

public struct TaskResourceLockClaim: Sendable, Equatable, Hashable {
    public init(
        taskID: UUID,
        resourceKey: String,
        accessMode: TaskResourceAccessMode,
        runMode: String,
        resourceKind: TaskExecutionResourceKind = .workspace,
        requestID: UUID? = nil
    ) {
        self.taskID = taskID
        self.resourceKey = resourceKey
        self.accessMode = accessMode
        self.runMode = runMode
        self.resourceKind = resourceKind
        self.requestID = requestID
    }

    public var taskID: UUID
    public var resourceKey: String
    public var accessMode: TaskResourceAccessMode
    public var runMode: String
    public var resourceKind: TaskExecutionResourceKind
    public var requestID: UUID?
}
