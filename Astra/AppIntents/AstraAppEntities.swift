#if ASTRA_ENABLE_APP_INTENTS
import ASTRAModels
import AppIntents
import Foundation

struct AstraWorkspaceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Workspace"
    static var defaultQuery = AstraWorkspaceEntityQuery()

    let id: UUID
    let name: String
    let primaryPath: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(primaryPath)"
        )
    }

    init(id: UUID, name: String, primaryPath: String) {
        self.id = id
        self.name = name
        self.primaryPath = primaryPath
    }

    init(record: AstraWorkspaceIntentRecord) {
        self.init(id: record.id, name: record.name, primaryPath: record.primaryPath)
    }
}

struct AstraWorkspaceEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    func entities(for identifiers: [AstraWorkspaceEntity.ID]) async throws -> [AstraWorkspaceEntity] {
        let records = try await workspaceRecords()
        let wanted = Set(identifiers)
        return records
            .filter { wanted.contains($0.id) }
            .map(AstraWorkspaceEntity.init(record:))
    }

    func entities(matching string: String) async throws -> [AstraWorkspaceEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let records = try await workspaceRecords()
        guard !needle.isEmpty else {
            return records.map(AstraWorkspaceEntity.init(record:))
        }
        return records
            .filter { record in
                record.name.lowercased().contains(needle)
                    || record.primaryPath.lowercased().contains(needle)
            }
            .map(AstraWorkspaceEntity.init(record:))
    }

    func allEntities() async throws -> [AstraWorkspaceEntity] {
        try await workspaceRecords().map(AstraWorkspaceEntity.init(record:))
    }

    func suggestedEntities() async throws -> [AstraWorkspaceEntity] {
        try await allEntities()
    }

    private func workspaceRecords() async throws -> [AstraWorkspaceIntentRecord] {
        try await MainActor.run {
            try AstraIntentDataSource.workspaceRecords()
        }
    }
}

struct AstraTaskEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static var defaultQuery = AstraTaskEntityQuery()

    let id: UUID
    let title: String
    let workspaceName: String
    let status: TaskStatus
    let isDone: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(workspaceName) - \(status.rawValue)"
        )
    }

    init(id: UUID, title: String, workspaceName: String, status: TaskStatus, isDone: Bool) {
        self.id = id
        self.title = title
        self.workspaceName = workspaceName
        self.status = status
        self.isDone = isDone
    }

    init(record: AstraTaskIntentRecord) {
        self.init(
            id: record.id,
            title: record.title,
            workspaceName: record.workspaceName,
            status: record.status,
            isDone: record.isDone
        )
    }
}

struct AstraTaskEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    func entities(for identifiers: [AstraTaskEntity.ID]) async throws -> [AstraTaskEntity] {
        let records = try await taskRecords()
        let wanted = Set(identifiers)
        return records
            .filter { wanted.contains($0.id) }
            .map(AstraTaskEntity.init(record:))
    }

    func entities(matching string: String) async throws -> [AstraTaskEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let records = try await taskRecords()
        guard !needle.isEmpty else {
            return records.map(AstraTaskEntity.init(record:))
        }
        return records
            .filter { record in
                record.title.lowercased().contains(needle)
                    || record.workspaceName.lowercased().contains(needle)
                    || record.status.rawValue.lowercased().contains(needle)
            }
            .map(AstraTaskEntity.init(record:))
    }

    func allEntities() async throws -> [AstraTaskEntity] {
        try await taskRecords().map(AstraTaskEntity.init(record:))
    }

    func suggestedEntities() async throws -> [AstraTaskEntity] {
        try await allEntities()
    }

    private func taskRecords() async throws -> [AstraTaskIntentRecord] {
        try await MainActor.run {
            try AstraIntentDataSource.taskRecords()
        }
    }
}
#endif
