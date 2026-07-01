import Foundation

struct TaskCanvasRefreshSignature: Equatable, Hashable, Sendable, CustomStringConvertible {
    static let none = TaskCanvasRefreshSignature(rawValue: "none")

    let rawValue: String

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
            String(task.events.count),
            Self.joinFields(task.inputs),
            task.title,
            task.goal,
            Self.joinFields(task.constraints),
            Self.joinFields(task.acceptanceCriteria)
        ]))
    }

    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    private static func joinFields(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
