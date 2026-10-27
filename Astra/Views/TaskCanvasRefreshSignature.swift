import Foundation
import SwiftData
import ASTRAModels

struct TaskCanvasRefreshSignature: Equatable, Hashable, Sendable, CustomStringConvertible {
    static let none = TaskCanvasRefreshSignature(rawValue: "none")

    let rawValue: String
    let ownerID: PersistentIdentifier?

    var description: String { rawValue }

    init(task: AgentTask?) {
        guard let task else {
            self = .none
            return
        }

        self.init(rawValue: Self.joinFields([
            task.id.uuidString,
            task.status.rawValue,
            String(task.updatedAt.timeIntervalSince1970),
            Self.joinFields(task.inputs),
            task.title,
            task.goal,
            Self.joinFields(task.constraints),
            Self.joinFields(task.acceptanceCriteria)
        ]), ownerID: task.persistentModelID)
    }

    private init(rawValue: String, ownerID: PersistentIdentifier? = nil) {
        self.rawValue = rawValue
        self.ownerID = ownerID
    }

    private static func joinFields(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
