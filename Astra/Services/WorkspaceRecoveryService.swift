import Foundation
import SQLite3
import SwiftData

enum WorkspaceRecoveryService {
    static let recoveryNoticeKey = "lastWorkspaceRecoveryNotice"
    private static let maxRecoveryScanDirectories = 2_500
    private static let skippedRecoveryDirectoryNames: Set<String> = [
        "node_modules",
        "DerivedData",
        "Pods",
        "target",
        "venv"
    ]

    private struct LoadedWorkspaceConfig: @unchecked Sendable {
        var config: WorkspaceConfigManager.WorkspaceConfig
    }

    struct LegacyStoreRepairResult: Equatable {
        var validationStrategyGoalCheckRows = 0
        var validationStrategyDefaultedRows = 0
        var isolationStrategyDefaultedRows = 0
        var taskStatusDefaultedRows = 0
        var runStatusDefaultedRows = 0
        var scheduleTypeDefaultedRows = 0
        var scheduleResultModeDefaultedRows = 0

        var totalRowsChanged: Int {
            validationStrategyGoalCheckRows
                + validationStrategyDefaultedRows
                + isolationStrategyDefaultedRows
                + taskStatusDefaultedRows
                + runStatusDefaultedRows
                + scheduleTypeDefaultedRows
                + scheduleResultModeDefaultedRows
        }

        var didRepair: Bool {
            totalRowsChanged > 0
        }
    }

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppChannel.current.appSupportDirectoryName, isDirectory: true)
    }

    static var storeURL: URL {
        applicationSupportDirectory.appendingPathComponent("default.store")
    }

    static var legacyStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("default.store")
    }

    static func preparePersistentStoreURL() -> URL {
        try? FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        migrateLegacyStoreIfNeeded()
        return storeURL
    }

    @discardableResult
    static func repairLegacyStoreValues(at url: URL) -> LegacyStoreRepairResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LegacyStoreRepairResult()
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown"
            if let database {
                sqlite3_close(database)
            }
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "repair": "legacy_enum_raw_values",
                "stage": "open_failed",
                "sqlite_error": message
            ], level: .warning)
            return LegacyStoreRepairResult()
        }
        defer { sqlite3_close(database) }

        _ = executeSQLite(database, "PRAGMA busy_timeout = 5000")

        var result = LegacyStoreRepairResult()
        if sqliteTableExists(database, table: "ZAGENTTASK") {
            if sqliteColumnExists(database, table: "ZAGENTTASK", column: "ZVALIDATIONSTRATEGY") {
                result.validationStrategyGoalCheckRows = executeSQLite(
                    database,
                    "UPDATE ZAGENTTASK SET ZVALIDATIONSTRATEGY = 'ai_check' WHERE ZVALIDATIONSTRATEGY = 'goal_check'"
                )
                result.validationStrategyDefaultedRows = executeSQLite(
                    database,
                    """
                    UPDATE ZAGENTTASK
                    SET ZVALIDATIONSTRATEGY = 'manual'
                    WHERE ZVALIDATIONSTRATEGY IS NULL
                       OR ZVALIDATIONSTRATEGY NOT IN ('manual', 'run_tests', 'ai_check')
                    """
                )
            }
            if sqliteColumnExists(database, table: "ZAGENTTASK", column: "ZISOLATIONSTRATEGY") {
                result.isolationStrategyDefaultedRows = executeSQLite(
                    database,
                    """
                    UPDATE ZAGENTTASK
                    SET ZISOLATIONSTRATEGY = 'same_directory'
                    WHERE ZISOLATIONSTRATEGY IS NULL
                       OR ZISOLATIONSTRATEGY NOT IN ('same_directory', 'git_branch', 'copy')
                    """
                )
            }
            if sqliteColumnExists(database, table: "ZAGENTTASK", column: "ZSTATUS") {
                result.taskStatusDefaultedRows = executeSQLite(
                    database,
                    """
                    UPDATE ZAGENTTASK
                    SET ZSTATUS = 'draft'
                    WHERE ZSTATUS IS NULL
                       OR ZSTATUS NOT IN (
                          'draft', 'queued', 'running', 'pending_user',
                          'completed', 'failed', 'cancelled', 'budget_exceeded'
                       )
                    """
                )
            }
        }

        if sqliteTableExists(database, table: "ZTASKRUN"),
           sqliteColumnExists(database, table: "ZTASKRUN", column: "ZSTATUS") {
            result.runStatusDefaultedRows = executeSQLite(
                database,
                """
                UPDATE ZTASKRUN
                SET ZSTATUS = 'failed'
                WHERE ZSTATUS IS NULL
                   OR ZSTATUS NOT IN (
                      'running', 'completed', 'failed',
                      'cancelled', 'timeout', 'budget_exceeded'
                   )
                """
            )
        }

        if sqliteTableExists(database, table: "ZTASKSCHEDULE") {
            if sqliteColumnExists(database, table: "ZTASKSCHEDULE", column: "ZSCHEDULETYPE") {
                result.scheduleTypeDefaultedRows = executeSQLite(
                    database,
                    """
                    UPDATE ZTASKSCHEDULE
                    SET ZSCHEDULETYPE = 'once'
                    WHERE ZSCHEDULETYPE IS NULL
                       OR ZSCHEDULETYPE NOT IN ('once', 'interval', 'daily', 'weekly')
                    """
                )
            }
            if sqliteColumnExists(database, table: "ZTASKSCHEDULE", column: "ZRESULTMODE") {
                result.scheduleResultModeDefaultedRows = executeSQLite(
                    database,
                    """
                    UPDATE ZTASKSCHEDULE
                    SET ZRESULTMODE = 'same_thread'
                    WHERE ZRESULTMODE IS NULL
                       OR ZRESULTMODE NOT IN ('same_thread', 'new_task', 'schedule_log')
                    """
                )
            }
        }

        if result.didRepair {
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "repair": "legacy_enum_raw_values",
                "rows": String(result.totalRowsChanged),
                "validation_goal_check_rows": String(result.validationStrategyGoalCheckRows),
                "validation_defaulted_rows": String(result.validationStrategyDefaultedRows),
                "task_status_defaulted_rows": String(result.taskStatusDefaultedRows),
                "run_status_defaulted_rows": String(result.runStatusDefaultedRows)
            ])
        }
        return result
    }

    static func backupStore(at url: URL) {
        let formatter = ISO8601DateFormatter()
        let suffix = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        for storeSuffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: url.path + storeSuffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let backup = URL(fileURLWithPath: url.path + ".backup-\(suffix)" + storeSuffix)
            do {
                try FileManager.default.moveItem(at: source, to: backup)
            } catch {
                AppLogger.audit(.workspaceStoreBackedUp, category: "Persistence", fields: [
                    "result": "failed",
                    "file_suffix": storeSuffix.isEmpty ? "store" : storeSuffix,
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
        AppLogger.audit(.workspaceStoreBackedUp, category: "Persistence", fields: [
            "result": "completed"
        ])
    }

    @discardableResult
    static func copyStoreBackup(
        at url: URL,
        backupRoot: URL? = nil,
        label: String = "pre-update"
    ) throws -> [URL] {
        let formatter = ISO8601DateFormatter()
        let suffix = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let root = backupRoot ?? applicationSupportDirectory.appendingPathComponent("Backups", isDirectory: true)
        let backupDirectory = root.appendingPathComponent("\(label)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )

        var copied: [URL] = []
        for storeSuffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: url.path + storeSuffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = backupDirectory.appendingPathComponent(url.lastPathComponent + storeSuffix)
            try FileManager.default.copyItem(at: source, to: destination)
            copied.append(destination)
        }

        AppLogger.audit(.appUpdateBackupCreated, category: "Updater", fields: [
            "file_count": String(copied.count),
            "label": label
        ])
        return copied
    }

    @discardableResult
    static func recoverMissingWorkspaces(
        modelContext: ModelContext,
        extraRoots: [String] = [],
        includeDefaultRoots: Bool = true
    ) -> Int {
        let configs = discoverWorkspaceConfigFiles(extraRoots: extraRoots, includeDefaultRoots: includeDefaultRoots)
        return recoverMissingWorkspaces(modelContext: modelContext, configFiles: configs)
    }

    static func recoverMissingWorkspacesAfterLaunch(
        modelContext: ModelContext,
        extraRoots: [String] = [],
        includeDefaultRoots: Bool = true
    ) {
        Task { @MainActor in
            if extraRoots.isEmpty,
               includeDefaultRoots,
               !fetchExistingWorkspaces(modelContext: modelContext).isEmpty {
                return
            }
            let configs = await withTaskGroup(of: [URL].self, returning: [URL].self) { group in
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return [] }
                    return discoverWorkspaceConfigFiles(extraRoots: extraRoots, includeDefaultRoots: includeDefaultRoots)
                }
                return await group.next() ?? []
            }
            let loadedConfigs = await loadWorkspaceConfigs(configs)
            guard !Task.isCancelled else { return }
            _ = recoverMissingWorkspaces(modelContext: modelContext, loadedConfigs: loadedConfigs)
        }
    }

    private static func loadWorkspaceConfigs(_ configFiles: [URL]) async -> [LoadedWorkspaceConfig] {
        await withTaskGroup(of: LoadedWorkspaceConfig?.self, returning: [LoadedWorkspaceConfig].self) { group in
            for configURL in configFiles {
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return nil }
                    do {
                        var config = try WorkspaceConfigManager.loadConfig(from: configURL)
                        config.primaryPath = configURL.deletingLastPathComponent().standardizedFileURL.path
                        return LoadedWorkspaceConfig(config: config)
                    } catch {
                        AppLogger.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                            "config_file": configURL.lastPathComponent,
                            "error_type": String(describing: type(of: error))
                        ], level: .error)
                        return nil
                    }
                }
            }

            var loadedConfigs: [LoadedWorkspaceConfig] = []
            for await loaded in group {
                do {
                    try Task.checkCancellation()
                } catch {
                    group.cancelAll()
                    return loadedConfigs
                }
                if let loaded {
                    loadedConfigs.append(loaded)
                }
            }
            return loadedConfigs
        }
    }

    @discardableResult
    private static func recoverMissingWorkspaces(
        modelContext: ModelContext,
        configFiles configs: [URL]
    ) -> Int {
        guard !configs.isEmpty else { return 0 }

        var imported = 0
        let existing = fetchExistingWorkspaces(modelContext: modelContext)
        var existingIDs = Set(existing.map { $0.id.uuidString })
        var existingPaths = Set(existing.map { normalizePath($0.primaryPath) })

        for configURL in configs {
            do {
                var config = try WorkspaceConfigManager.loadConfig(from: configURL)
                config.primaryPath = configURL.deletingLastPathComponent().standardizedFileURL.path
                let configID = config.id
                let configPath = normalizePath(config.primaryPath)
                if let configID, existingIDs.contains(configID) {
                    continue
                }
                if !configPath.isEmpty, existingPaths.contains(configPath) {
                    continue
                }
                let workspace = WorkspaceConfigManager.importWorkspace(from: config, modelContext: modelContext)
                existingIDs.insert(workspace.id.uuidString)
                existingPaths.insert(normalizePath(workspace.primaryPath))
                imported += 1
            } catch {
                AppLogger.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                    "config_file": configURL.lastPathComponent,
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }

        saveRecoveryImportCount(imported, modelContext: modelContext)
        return imported
    }

    @discardableResult
    private static func recoverMissingWorkspaces(
        modelContext: ModelContext,
        loadedConfigs configs: [LoadedWorkspaceConfig]
    ) -> Int {
        guard !configs.isEmpty else { return 0 }

        var imported = 0
        let existing = fetchExistingWorkspaces(modelContext: modelContext)
        var existingIDs = Set(existing.map { $0.id.uuidString })
        var existingPaths = Set(existing.map { normalizePath($0.primaryPath) })

        for loaded in configs {
            let config = loaded.config
            let configID = config.id
            let configPath = normalizePath(config.primaryPath)
            if let configID, existingIDs.contains(configID) {
                continue
            }
            if !configPath.isEmpty, existingPaths.contains(configPath) {
                continue
            }
            let workspace = WorkspaceConfigManager.importWorkspace(from: config, modelContext: modelContext)
            existingIDs.insert(workspace.id.uuidString)
            existingPaths.insert(normalizePath(workspace.primaryPath))
            imported += 1
        }

        saveRecoveryImportCount(imported, modelContext: modelContext)
        return imported
    }

    private static func saveRecoveryImportCount(_ imported: Int, modelContext: ModelContext) {
        guard imported > 0 else { return }

        do {
            try modelContext.save()
        } catch {
            AppLogger.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "save_recovered_workspaces",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
        let message = "Recovered \(imported) workspace\(imported == 1 ? "" : "s") from \(WorkspaceFileLayout.workspaceConfigFileName)."
        UserDefaults.standard.set(message, forKey: recoveryNoticeKey)
        AppLogger.audit(.workspaceRecovered, category: "Persistence", fields: [
            "imported_count": String(imported)
        ])
    }

    static func discoverWorkspaceConfigFiles(
        extraRoots: [String] = [],
        includeDefaultRoots: Bool = true
    ) -> [URL] {
        var roots: [String] = []
        if includeDefaultRoots {
            if let configured = UserDefaults.standard.string(forKey: "workspacesRoot"), !configured.isEmpty {
                roots.append(configured)
            }
            roots.append(AppChannel.current.defaultWorkspacesRoot)
        }
        roots.append(contentsOf: extraRoots)

        var seen = Set<String>()
        var configs: [URL] = []
        for root in roots {
            guard !Task.isCancelled else { break }
            let url = URL(fileURLWithPath: expandTilde(root))
            for config in scanForWorkspaceConfigs(root: url, maxDepth: 4) {
                guard !Task.isCancelled else { break }
                let path = normalizePath(config.path)
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                configs.append(config)
            }
        }
        return configs
    }

    private static func migrateLegacyStoreIfNeeded() {
        guard AppChannel.current == .production else { return }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: storeURL.path),
              fileManager.fileExists(atPath: legacyStoreURL.path),
              storeURL.path != legacyStoreURL.path else {
            return
        }

        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: legacyStoreURL.path + suffix)
            let destination = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else {
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                AppLogger.audit(.workspaceStoreMigrated, category: "Persistence", fields: [
                    "result": "failed",
                    "file_suffix": suffix.isEmpty ? "store" : suffix,
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
        AppLogger.audit(.workspaceStoreMigrated, category: "Persistence", fields: [
            "result": "completed"
        ])
    }

    private static func sqliteTableExists(_ database: OpaquePointer, table: String) -> Bool {
        sqliteHasRow(
            database,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            binding: table
        )
    }

    private static func sqliteColumnExists(_ database: OpaquePointer, table: String, column: String) -> Bool {
        sqliteHasRow(
            database,
            sql: "SELECT 1 FROM pragma_table_info(?) WHERE name = ? LIMIT 1",
            bindings: [table, column]
        )
    }

    private static func sqliteHasRow(
        _ database: OpaquePointer,
        sql: String,
        binding: String
    ) -> Bool {
        sqliteHasRow(database, sql: sql, bindings: [binding])
    }

    private static func sqliteHasRow(
        _ database: OpaquePointer,
        sql: String,
        bindings: [String]
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    @discardableResult
    private static func executeSQLite(_ database: OpaquePointer, _ sql: String) -> Int {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "repair": "legacy_enum_raw_values",
                "stage": "statement_failed",
                "sqlite_error": message
            ], level: .warning)
            return 0
        }
        return Int(sqlite3_changes(database))
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func fetchExistingWorkspaces(modelContext: ModelContext) -> [Workspace] {
        let descriptor = FetchDescriptor<Workspace>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func scanForWorkspaceConfigs(root: URL, maxDepth: Int) -> [URL] {
        var remainingBudget = maxRecoveryScanDirectories
        return scanForWorkspaceConfigs(root: root, maxDepth: maxDepth, remainingBudget: &remainingBudget)
    }

    private static func scanForWorkspaceConfigs(
        root: URL,
        maxDepth: Int,
        remainingBudget: inout Int
    ) -> [URL] {
        guard !Task.isCancelled else { return [] }
        guard maxDepth >= 0 else { return [] }
        guard remainingBudget > 0 else { return [] }
        remainingBudget -= 1

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let directConfig = root.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        var results: [URL] = []
        if fileManager.fileExists(atPath: directConfig.path) {
            results.append(directConfig)
        }

        guard maxDepth > 0,
              let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey]
              ) else {
            return results
        }

        for child in children {
            guard !Task.isCancelled else { break }
            guard remainingBudget > 0 else { break }
            guard !skippedRecoveryDirectoryNames.contains(child.lastPathComponent) else { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey])
            guard values?.isDirectory == true,
                  values?.isHidden != true,
                  values?.isPackage != true else {
                continue
            }
            results.append(
                contentsOf: scanForWorkspaceConfigs(
                    root: child,
                    maxDepth: maxDepth - 1,
                    remainingBudget: &remainingBudget
                )
            )
        }
        return results
    }

    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: expandTilde(path)).standardizedFileURL.path
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
