import Foundation
import SwiftData
import ASTRAModels

@MainActor
enum SidebarTaskExternalRefresh {
    static func fetch(_ context: ModelContext, _ identifiers: [PersistentIdentifier]) throws {
        var descriptor = FetchDescriptor<AgentTask>(
            predicate: #Predicate { identifiers.contains($0.persistentModelID) }
        )
        descriptor.includePendingChanges = false
        _ = try context.fetch(descriptor)
    }
}
