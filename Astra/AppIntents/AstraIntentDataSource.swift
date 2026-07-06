import Foundation
import SwiftData
import ASTRAModels

struct AstraWorkspaceIntentRecord: Equatable, Sendable {
    let id: UUID
    let name: String
    let primaryPath: String
    let icon: String
}

struct AstraTaskIntentRecord: Equatable, Sendable {
    let id: UUID
    let title: String
    let workspaceID: UUID?
    let workspaceName: String
    let status: TaskStatus
    let isDone: Bool
    let updatedAt: Date
}

enum AstraIntentDataSource {
    @MainActor
    static func workspaceRecords() throws -> [AstraWorkspaceIntentRecord] {
        let context = try makeContext()
        let descriptor = FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map { workspace in
            AstraWorkspaceIntentRecord(
                id: workspace.id,
                name: workspace.name,
                primaryPath: workspace.primaryPath,
                icon: workspace.icon
            )
        }
    }

    @MainActor
    static func taskRecords() throws -> [AstraTaskIntentRecord] {
        let context = try makeContext()
        let descriptor = FetchDescriptor<AgentTask>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map { task in
            AstraTaskIntentRecord(
                id: task.id,
                title: task.title,
                workspaceID: task.workspace?.id,
                workspaceName: task.workspace?.name ?? "No Workspace",
                status: task.status,
                isDone: task.isDone,
                updatedAt: task.updatedAt
            )
        }
    }

    @MainActor
    private static func makeContext() throws -> ModelContext {
        let storeURL = WorkspaceRecoveryService.preparePersistentStoreURL()
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        return ModelContext(container)
    }
}
