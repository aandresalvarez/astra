import Foundation

enum TaskResourceAccessMode: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case readOnly = "read_only"
    case write

    var displayName: String {
        switch self {
        case .readOnly: "read-only"
        case .write: "write"
        }
    }
}

enum TaskResourceLockEventTypes {
    static let requested = "resource.lock.requested"
    static let waiting = "resource.lock.waiting"
    static let acquired = "resource.lock.acquired"
    static let released = "resource.lock.released"
}

struct TaskResourceLockPayload: Codable, Sendable, Equatable {
    var version: Int
    var resourceKey: String
    var accessMode: TaskResourceAccessMode
    var runMode: String
    var status: String
    var holderTaskID: UUID?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case resourceKey
        case accessMode
        case runMode
        case status
        case holderTaskID
        case reason
    }
}

struct TaskResourceLockClaim: Sendable, Equatable, Hashable {
    var taskID: UUID
    var resourceKey: String
    var accessMode: TaskResourceAccessMode
    var runMode: String
}
