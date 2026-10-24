import Foundation
import SwiftData
import ASTRAModels
@testable import ASTRAPersistence

/// Call after joining fixture workers/queues and any other save producers.
/// Retiring the epoch fences suspended reads; the reader actor then joins any
/// synchronous SwiftData traversal before its backing files are removed.
@MainActor
enum TestWorkspaceStoreCleanup {
    static func schedule(context: ModelContext, roots: [URL],
                         reader: WorkspaceSavedAutoExport = .shared) -> Task<Void, Never> {
        context.autosaveEnabled = false
        let container = context.container
        let workspaceIDs = ((try? context.fetch(FetchDescriptor<Workspace>())) ?? []).map(\.id)
        for id in workspaceIDs { WorkspaceAutoExportGate.shared.retire(workspaceID: id.uuidString) }
        return Task { @MainActor in
            defer { withExtendedLifetime(container) {} }
            await reader.removeTestFixtureFiles(roots)
        }
    }
}

extension WorkspaceSavedAutoExport {
    /// Runs behind any active synchronous snapshot traversal on this actor.
    func removeTestFixtureFiles(_ roots: [URL]) {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }
}
