import Foundation
import SwiftData

@Model
final class Artifact {
    var id: UUID
    var task: AgentTask?
    var type: String
    var path: String
    var content: String?
    var version: Int
    var createdAt: Date

    init(task: AgentTask, type: String, path: String, content: String? = nil, version: Int = 1) {
        self.id = UUID()
        self.task = task
        self.type = type
        self.path = path
        self.content = content
        self.version = version
        self.createdAt = Date()
    }

    /// Whether the artifact file still exists on disk
    var isStale: Bool {
        !FileManager.default.fileExists(atPath: path)
    }
}
