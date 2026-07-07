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
    public init(taskID: UUID, resourceKey: String, accessMode: TaskResourceAccessMode, runMode: String) {
        self.taskID = taskID
        self.resourceKey = resourceKey
        self.accessMode = accessMode
        self.runMode = runMode
    }

    public var taskID: UUID
    public var resourceKey: String
    public var accessMode: TaskResourceAccessMode
    public var runMode: String
}
