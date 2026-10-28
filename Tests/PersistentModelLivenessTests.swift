import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Persistent model liveness")
struct PersistentModelLivenessTests {
    @Test("A never-inserted model is live, a deleted one is not, saved or not")
    @MainActor
    func livenessTracksDeletionNotJustTheContext() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext

        let unmanaged = Workspace(name: "Unmanaged", primaryPath: "/tmp/liveness-unmanaged")
        #expect(unmanaged.isLive)

        let workspace = Workspace(name: "Managed", primaryPath: "/tmp/liveness-managed")
        context.insert(workspace)
        #expect(workspace.isLive)
        try context.save()
        #expect(workspace.isLive)

        context.delete(workspace)
        #expect(!workspace.isLive)
        try context.save()
        #expect(!workspace.isLive)
        withExtendedLifetime(container) {}
    }

    @Test("Effective workspace drops a deleted workspace instead of handing it to a view")
    @MainActor
    func effectiveWorkspaceDropsDeletedWorkspace() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Doomed", primaryPath: "/tmp/liveness-doomed")
        context.insert(workspace)
        try context.save()
        #expect(ContentSelectionResolver.effectiveWorkspace(selectedTask: nil, selectedWorkspace: workspace) === workspace)

        context.delete(workspace)
        try context.save()
        #expect(ContentSelectionResolver.effectiveWorkspace(selectedTask: nil, selectedWorkspace: workspace) == nil)
        withExtendedLifetime(container) {}
    }
}
