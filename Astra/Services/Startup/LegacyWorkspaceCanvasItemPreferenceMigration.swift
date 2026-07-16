import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// One-time importer for the pre-V14 global UserDefaults map.
///
/// The legacy key is intentionally private to this migration so no runtime
/// path can recreate the unbounded blob. Production uses an isolated context
/// immediately after the persistent container opens, before any shelf restore.
/// Durable task values win, SwiftData is saved before the source is removed,
/// and failures leave the exact source value available for a safe retry.
@MainActor
enum LegacyWorkspaceCanvasItemPreferenceMigration {
    static let legacyDefaultsKey = "astra.workspaceCanvas.activeItemsByConversation.v1"

    typealias Persistence = @MainActor ([AgentTask], ModelContext) throws -> Void

    struct Result: Equatable {
        var sourceFound = false
        var sourceRemoved = false
        var migratedCount = 0
        var existingDurableCount = 0
        var orphanCount = 0
        var malformedIDCount = 0
        var unsupportedValueCount = 0
        var duplicateTaskCount = 0
        var failed = false
    }

    @discardableResult
    static func migrate(
        defaults: UserDefaults = .standard,
        modelContainer: ModelContainer
    ) -> Result {
        migrate(defaults: defaults, modelContext: ModelContext(modelContainer))
    }

    @discardableResult
    static func migrate(
        defaults: UserDefaults = .standard,
        modelContext: ModelContext,
        persist: Persistence? = nil
    ) -> Result {
        guard let source = defaults.object(forKey: legacyDefaultsKey) else {
            return Result()
        }

        var result = Result(sourceFound: true)
        guard let rawValue = source as? String,
              let data = rawValue.data(using: .utf8),
              let entries = decodedLegacyEntries(from: data) else {
            defaults.removeObject(forKey: legacyDefaultsKey)
            result.sourceRemoved = true
            log(result: result, stage: "malformed_source_removed", level: .warning)
            return result
        }

        let tasks: [AgentTask]
        do {
            tasks = try modelContext.fetch(FetchDescriptor<AgentTask>())
        } catch {
            result.failed = true
            log(result: result, stage: "fetch_failed", error: error, level: .error)
            return result
        }

        var tasksByID: [UUID: AgentTask] = [:]
        for task in tasks.sorted(by: taskPrecedes) {
            if tasksByID[task.id] == nil {
                tasksByID[task.id] = task
            } else {
                result.duplicateTaskCount += 1
            }
        }
        var claimedTaskIDs = Set<UUID>()
        var changed: [(task: AgentTask, previousRawValue: String?)] = []

        // Sorting makes collisions such as differently-cased spellings of the
        // same UUID deterministic. The first valid spelling wins.
        for (rawID, rawValue) in entries.sorted(by: { $0.key < $1.key }) {
            guard let taskID = UUID(uuidString: rawID) else {
                result.malformedIDCount += 1
                continue
            }
            guard let itemRawValue = rawValue as? String,
                  let item = WorkspaceCanvasItem(rawValue: itemRawValue) else {
                result.unsupportedValueCount += 1
                continue
            }
            guard let task = tasksByID[taskID] else {
                result.orphanCount += 1
                continue
            }
            guard claimedTaskIDs.insert(taskID).inserted else {
                result.duplicateTaskCount += 1
                continue
            }
            guard task.rememberedWorkspaceCanvasItemRawValue == nil else {
                result.existingDurableCount += 1
                continue
            }

            changed.append((task, task.rememberedWorkspaceCanvasItemRawValue))
            task.rememberedWorkspaceCanvasItemRawValue = item.rawValue
            result.migratedCount += 1
        }

        if !changed.isEmpty {
            do {
                try (persist ?? persistAndExport)(changed.map(\.task), modelContext)
            } catch {
                for change in changed {
                    change.task.rememberedWorkspaceCanvasItemRawValue = change.previousRawValue
                }
                result.failed = true
                result.migratedCount = 0
                log(result: result, stage: "save_failed", error: error, level: .error)
                return result
            }
        }

        defaults.removeObject(forKey: legacyDefaultsKey)
        result.sourceRemoved = true
        log(result: result, stage: "completed", level: .info)
        return result
    }

    /// `WorkspaceCanvasItemPreference` has written a versioned
    /// `{version, nextAccessOrdinal, entries}` envelope for the source key for
    /// some time; only installs that never re-saved after that change still
    /// hold the older flat `[conversationID: item]` map. Both must be
    /// recognized here — treating the envelope's top-level keys as task IDs
    /// yields zero matches, and the source is deleted regardless, silently
    /// discarding every remembered shelf for the common case.
    private struct LegacyStorageEnvelope: Decodable {
        struct Entry: Decodable {
            var itemRawValue: String
        }

        var version: Int
        var entries: [String: Entry]
    }

    private static func decodedLegacyEntries(from data: Data) -> [String: Any]? {
        if let envelope = try? JSONDecoder().decode(LegacyStorageEnvelope.self, from: data),
           envelope.version == 2 {
            return envelope.entries.mapValues { $0.itemRawValue }
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func taskPrecedes(_ lhs: AgentTask, _ rhs: AgentTask) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.goal < rhs.goal
    }

    private static func persistAndExport(_ tasks: [AgentTask], _ modelContext: ModelContext) throws {
        try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
            workspace: nil,
            modelContext: modelContext,
            auditFields: ["operation": "migrate_legacy_workspace_canvas_items"]
        )

        var exportedWorkspaceIDs = Set<UUID>()
        for task in tasks {
            guard let workspace = task.workspace,
                  exportedWorkspaceIDs.insert(workspace.id).inserted else {
                continue
            }
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        }
    }

    private static func log(
        result: Result,
        stage: String,
        error: Error? = nil,
        level: LogLevel
    ) {
        var fields = [
            "migration": "legacy_workspace_canvas_items",
            "stage": stage,
            "migrated_count": String(result.migratedCount),
            "existing_durable_count": String(result.existingDurableCount),
            "orphan_count": String(result.orphanCount),
            "malformed_id_count": String(result.malformedIDCount),
            "unsupported_value_count": String(result.unsupportedValueCount),
            "duplicate_task_count": String(result.duplicateTaskCount)
        ]
        if let error {
            fields["error_type"] = String(describing: type(of: error))
        }
        AppLogger.audit(.dataStoreRecovered, category: "Persistence", fields: fields, level: level)
    }
}
