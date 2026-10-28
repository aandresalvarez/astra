import Foundation
import SwiftData
import ASTRAModels

/// Derived identity of the model that owns Browser access. The portable UUID
/// alone is not an authority: imported copies can legitimately retain it.
struct ShelfBrowserOwner: Hashable, Sendable, Codable {
    let taskID: UUID
    let modelID: PersistentIdentifier?

    init(taskID: UUID, modelID: PersistentIdentifier? = nil) {
        self.taskID = taskID
        self.modelID = modelID
    }

    var leaseKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self).base64EncodedString()) ?? "invalid-owner"
    }

    init(_ task: AgentTask) {
        taskID = task.id
        modelID = task.launchSourceTaskOwnerID ?? task.persistentModelID
    }
}
