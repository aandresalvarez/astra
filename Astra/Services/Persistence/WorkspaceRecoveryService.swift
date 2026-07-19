import Foundation
import SQLite3
import SwiftData
import ASTRACore
import ASTRAModels

public enum WorkspaceRecoveryService {
    public enum ActiveStorePointerState: Equatable {
        case absent
        case valid(URL)
        case invalid
    }

    public enum PersistentStorePreparationError: Error, Equatable {
        case invalidActiveStorePointer
        case migrationSourceMissing
        case migrationDestinationExists
        case migrationFailed(String)
    }

    public static let recoveryNoticeKey = "lastWorkspaceRecoveryNotice"
    /// A deliberate storage boundary for binaries that predate durable store
    /// ownership. Older ASTRA Dev bundles only know the channel-root store and
    /// therefore cannot reset the current generation's store by mistake.
    public static let storeGeneration = "g2"
    private static let maxRecoveryScanDirectories = 2_500
    private static let skippedRecoveryDirectoryNames: Set<String> = [
        "node_modules",
        "DerivedData",
        "Pods",
        "target",
        "venv"
    ]

    private struct LoadedWorkspaceConfig: @unchecked Sendable {
        public var config: WorkspaceConfigManager.WorkspaceConfig
    }

    public struct LegacyStoreRepairResult: Equatable {
        public var validationStrategyGoalCheckRows = 0
        public var validationStrategyDefaultedRows = 0
        public var isolationStrategyDefaultedRows = 0
        public var taskStatusDefaultedRows = 0
        public var runStatusDefaultedRows = 0
        public var scheduleTypeDefaultedRows = 0
        public var scheduleResultModeDefaultedRows = 0

        public var totalRowsChanged: Int {
            validationStrategyGoalCheckRows
                + validationStrategyDefaultedRows
                + isolationStrategyDefaultedRows
                + taskStatusDefaultedRows
                + runStatusDefaultedRows
                + scheduleTypeDefaultedRows
                + scheduleResultModeDefaultedRows
        }

        public var didRepair: Bool {
            totalRowsChanged > 0
        }
    }

    public static var applicationSupportDirectory: URL {
        resolvedApplicationSupportDirectory()
    }

    public static func resolvedApplicationSupportDirectory(
        channel: AppChannel = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        AppChannelStoragePaths.applicationSupportDirectory(
            for: channel,
            environment: environment,
            fileManager: fileManager
        )
    }

    public static var storeGenerationDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("Stores", isDirectory: true)
            .appendingPathComponent(storeGeneration, isDirectory: true)
    }

    public static var defaultStoreURL: URL {
        storeGenerationDirectory.appendingPathComponent("default.store")
    }

    public static var activeStorePointerURL: URL {
        storeGenerationDirectory.appendingPathComponent("active-store.json")
    }

    public static var storeLeaseURL: URL {
        storeGenerationDirectory.appendingPathComponent("store.lock")
    }

    private static var storeGenerationEstablishedURL: URL {
        storeGenerationDirectory.appendingPathComponent("generation-established.json")
    }

    public static var storeURL: URL {
        if case .valid(let url) = activeStorePointerState() {
            return url
        }
        return defaultStoreURL
    }

    /// The pre-generation, channel-scoped location. Pre-fix development builds
    /// still target this path, so the current app only copies from it once.
    public static var channelLegacyStoreURL: URL {
        applicationSupportDirectory.appendingPathComponent("default.store")
    }

    /// The original production-only, pre-channel store location.
    public static var legacyStoreURL: URL {
        AppChannelStoragePaths.applicationSupportBaseDirectory(for: .current)
            .appendingPathComponent("default.store")
    }

    public static func preparePersistentStoreDirectory() throws {
        try FileManager.default.createDirectory(
            at: storeGenerationDirectory,
            withIntermediateDirectories: true
        )
    }

    public static func preparePersistentStoreURL() throws -> URL {
        switch activeStorePointerState() {
        case .invalid:
            throw PersistentStorePreparationError.invalidActiveStorePointer
        case .valid(let url):
            return url
        case .absent:
            break
        }

        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try preparePersistentStoreDirectory()
        try migratePreChannelLegacyStoreIfNeeded()
        try migrateChannelStoreToGenerationIfNeeded()
        return storeURL
    }

    public static func existingPersistentStoreURL(
        pointerURL: URL = activeStorePointerURL,
        storeRoot: URL = storeGenerationDirectory,
        fallbackStoreURL: URL = defaultStoreURL,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidate: URL
        switch activeStorePointerState(
            pointerURL: pointerURL,
            storeRoot: storeRoot,
            fileManager: fileManager
        ) {
        case .valid(let url):
            candidate = url
        case .absent:
            candidate = fallbackStoreURL
        case .invalid:
            return nil
        }
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// True only during this generation's one-time migration window. It lets
    /// a new build recover from workspace mirrors when a legacy store belongs
    /// to a newer, incompatible pre-generation binary, while future g2
    /// downgrade attempts still fail closed.
    public static var hasPendingLegacyStoreMigration: Bool {
        !FileManager.default.fileExists(atPath: storeGenerationEstablishedURL.path) &&
            FileManager.default.fileExists(atPath: defaultStoreURL.path) &&
            FileManager.default.fileExists(atPath: channelLegacyStoreURL.path)
    }

    public static func markStoreGenerationEstablished() {
        let payload = ["generation": storeGeneration, "established_at": ISO8601DateFormatter().string(from: Date())]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: storeGenerationEstablishedURL, options: .atomic)
    }

    /// Creates a fresh recovery target without touching the active store. The
    /// caller must create and validate a ModelContainer at this URL before
    /// calling `activateRecoveryStore(at:)`.
    public static func makeRecoveryStoreURL() throws -> URL {
        let directory = storeGenerationDirectory
            .appendingPathComponent("recoveries", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("default.store")
    }

    /// Atomically selects a validated recovery store. The previous active
    /// store stays in place for forensic recovery and rollback.
    public static func activateRecoveryStore(
        at url: URL,
        compatibility: PersistentStoreCompatibilityMetadata? = nil
    ) throws {
        let standardizedRoot = storeGenerationDirectory.standardizedFileURL.path
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.path.hasPrefix(standardizedRoot + "/"),
              FileManager.default.fileExists(atPath: standardizedURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let resolvedRoot = storeGenerationDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = standardizedURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/") else {
            throw CocoaError(.fileReadNoPermission)
        }
        let relativePath = String(standardizedURL.path.dropFirst(standardizedRoot.count + 1))
        let data = try JSONEncoder().encode(ActiveStorePointer(
            relativePath: relativePath,
            compatibility: compatibility
        ))
        if let compatibility {
            try PersistentStoreCompatibilityService.writeMetadata(compatibility, for: standardizedURL)
        }
        // The pointer is the final commit record. A failed sidecar write leaves
        // the old active store selected; a failed pointer write may leave only
        // an unreferenced recovery copy, which is safe to inspect or remove.
        try data.write(to: activeStorePointerURL, options: .atomic)
        markStoreGenerationEstablished()
        AuditLoggingSeam.required.audit(.dataStoreRecovered, category: "Persistence", fields: [
            "result": "recovery_store_activated",
            "store_generation": storeGeneration
        ])
    }

    public static func sqliteIntegrityIsValid(at url: URL) -> Bool {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        _ = sqlite3_busy_timeout(database, 5_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            return false
        }
        return String(cString: text).lowercased() == "ok"
    }

    @discardableResult
    public static func repairLegacyStoreValues(at url: URL) -> LegacyStoreRepairResult {
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
            AuditLoggingSeam.required.audit(.dataStoreRecovered, category: "App", fields: [
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
                          'completed', 'failed', 'cancelled', 'budget_exceeded',
                          'waiting_external'
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
            AuditLoggingSeam.required.audit(.dataStoreRecovered, category: "App", fields: [
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

    /// Compatibility entry point retained for callers that previously asked to
    /// "back up" a store. Backups now copy files; they never move a store that
    /// another process could still have open.
    public static func backupStore(at url: URL) {
        do {
            _ = try copyStoreBackup(at: url, label: "recovery")
            AuditLoggingSeam.required.audit(.workspaceStoreBackedUp, category: "Persistence", fields: [
                "result": "completed"
            ])
        } catch {
            AuditLoggingSeam.required.audit(.workspaceStoreBackedUp, category: "Persistence", fields: [
                "result": "failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }

    @discardableResult
    public static func exportReadableWorkspacesBeforeStoreReset(
        at url: URL,
        schema: Schema = ASTRASchema.current,
        migrationPlan: (any SchemaMigrationPlan.Type)? = ASTRAMigrationPlan.self
    ) -> [WorkspaceConfigManager.WorkspaceConfigExportResult] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let readOnlyConfig = ModelConfiguration(url: url, allowsSave: false)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: migrationPlan,
                configurations: [readOnlyConfig]
            )
            let context = ModelContext(container)
            let workspaces = try context.fetch(FetchDescriptor<Workspace>())
            let results = workspaces.compactMap { workspace -> WorkspaceConfigManager.WorkspaceConfigExportResult? in
                let target = WorkspaceConfigManager.autoExportTarget(for: workspace.primaryPath)
                guard let targetURL = target.url else {
                    AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                        "result": "recovery_export_skipped",
                        "reason": target.reason,
                        "workspace_id": workspace.id.uuidString
                    ], level: .warning)
                    return nil
                }
                return WorkspaceConfigManager.exportToFileResult(
                    workspace: workspace,
                    modelContext: context,
                    url: targetURL
                )
            }
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "pre_reset_recovery_export_completed",
                "workspace_count": String(workspaces.count),
                "exported_count": String(results.filter(\.didExport).count)
            ])
            return results
        } catch {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "pre_reset_read_only_export",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return []
        }
    }

    /// Preserves every recoverable representation before switching away from
    /// a store proven corrupt. Read-only workspace export runs first so a
    /// partially readable database can recreate mirrors; the byte-for-byte
    /// backup then preserves the original SQLite artifacts for forensics.
    @discardableResult
    public static func preserveReadableStoreBeforeRecovery(
        at url: URL,
        backupRoot: URL? = nil
    ) throws -> [WorkspaceConfigManager.WorkspaceConfigExportResult] {
        let exports = exportReadableWorkspacesBeforeStoreReset(at: url)
        _ = try copyStoreBackup(at: url, backupRoot: backupRoot, label: "verified-corruption")
        return exports
    }

    @discardableResult
    public static func copyStoreBackup(
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

        AuditLoggingSeam.required.audit(.appUpdateBackupCreated, category: "Updater", fields: [
            "file_count": String(copied.count),
            "label": label
        ])
        return copied
    }

    @discardableResult
    @MainActor
    public static func recoverMissingWorkspaces(
        modelContext: ModelContext,
        extraRoots: [String] = [],
        includeDefaultRoots: Bool = true,
        privacyHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Int {
        let configs = discoverWorkspaceConfigFiles(
            extraRoots: extraRoots,
            includeDefaultRoots: includeDefaultRoots,
            privacyHomeDirectory: privacyHomeDirectory
        )
        return recoverMissingWorkspaces(modelContext: modelContext, configFiles: configs)
    }

    public static func recoverMissingWorkspacesAfterLaunch(
        modelContext: ModelContext,
        extraRoots: [String] = [],
        includeDefaultRoots: Bool = true,
        privacyHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
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
                    return discoverWorkspaceConfigFiles(
                        extraRoots: extraRoots,
                        includeDefaultRoots: includeDefaultRoots,
                        privacyHomeDirectory: privacyHomeDirectory
                    )
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
                        var config = try WorkspaceConfigManager.loadConfig(
                            from: configURL,
                            accessIntent: .implicitScan(root: nil)
                        )
                        config.primaryPath = WorkspaceFileLayout.workspaceRoot(forConfigFile: configURL)
                            .standardizedFileURL
                            .path
                        return LoadedWorkspaceConfig(config: config)
                    } catch {
                        AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
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
    @MainActor
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
                var config = try WorkspaceConfigManager.loadConfig(
                    from: configURL,
                    accessIntent: .implicitScan(root: nil)
                )
                config.primaryPath = WorkspaceFileLayout.workspaceRoot(forConfigFile: configURL)
                    .standardizedFileURL
                    .path
                let configID = config.id
                let configPath = normalizePath(config.primaryPath)
                if let configID, existingIDs.contains(configID) {
                    continue
                }
                if !configPath.isEmpty, existingPaths.contains(configPath) {
                    continue
                }
                let workspace = WorkspaceConfigManager.importWorkspace(
                    from: config,
                    modelContext: modelContext,
                    scheduleTrustPolicy: .preserveEnabledState
                )
                existingIDs.insert(workspace.id.uuidString)
                existingPaths.insert(normalizePath(workspace.primaryPath))
                imported += 1
            } catch {
                AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                    "config_file": configURL.lastPathComponent,
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }

        saveRecoveryImportCount(imported, modelContext: modelContext)
        return imported
    }

    @discardableResult
    @MainActor
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
            let workspace = WorkspaceConfigManager.importWorkspace(
                from: config,
                modelContext: modelContext,
                scheduleTrustPolicy: .preserveEnabledState
            )
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
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "save_recovered_workspaces",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
        let message = "Recovered \(imported) workspace\(imported == 1 ? "" : "s") from \(WorkspaceFileLayout.workspaceConfigFileName)."
        UserDefaults.standard.set(message, forKey: recoveryNoticeKey)
        AuditLoggingSeam.required.audit(.workspaceRecovered, category: "Persistence", fields: [
            "imported_count": String(imported)
        ])
    }

    public static func discoverWorkspaceConfigFiles(
        extraRoots: [String] = [],
        includeDefaultRoots: Bool = true,
        privacyHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
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
            for config in scanForWorkspaceConfigs(
                root: url,
                maxDepth: 4,
                privacyHomeDirectory: privacyHomeDirectory
            ) {
                guard !Task.isCancelled else { break }
                let path = normalizePath(config.path)
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                configs.append(config)
            }
        }
        return configs
    }

    private struct ActiveStorePointer: Codable {
        let relativePath: String
        let compatibility: PersistentStoreCompatibilityMetadata?

        init(relativePath: String, compatibility: PersistentStoreCompatibilityMetadata? = nil) {
            self.relativePath = relativePath
            self.compatibility = compatibility
        }
    }

    public static func activeStorePointerState(
        pointerURL: URL = activeStorePointerURL,
        storeRoot: URL = storeGenerationDirectory,
        fileManager: FileManager = .default
    ) -> ActiveStorePointerState {
        guard fileManager.fileExists(atPath: pointerURL.path) else {
            return .absent
        }
        guard let data = try? Data(contentsOf: pointerURL),
              let pointer = try? JSONDecoder().decode(ActiveStorePointer.self, from: data),
              !pointer.relativePath.isEmpty,
              !pointer.relativePath.contains("..") else {
            return .invalid
        }

        let lexicalRoot = storeRoot.standardizedFileURL
        let lexicalCandidate = lexicalRoot.appendingPathComponent(pointer.relativePath).standardizedFileURL
        guard lexicalCandidate.path.hasPrefix(lexicalRoot.path + "/") else {
            return .invalid
        }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = lexicalCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/"),
              fileManager.fileExists(atPath: resolvedCandidate.path) else {
            return .invalid
        }
        return .valid(resolvedCandidate)
    }

    private static func migratePreChannelLegacyStoreIfNeeded() throws {
        guard AppChannel.current == .production else { return }
        guard !FileManager.default.fileExists(atPath: channelLegacyStoreURL.path) else { return }
        guard FileManager.default.fileExists(atPath: legacyStoreURL.path) else { return }
        try copyStoreSnapshot(from: legacyStoreURL, to: channelLegacyStoreURL)
        AuditLoggingSeam.required.audit(.workspaceStoreMigrated, category: "Persistence", fields: [
            "result": "copied",
            "source": "pre_channel",
            "store_generation": storeGeneration
        ])
    }

    private static func migrateChannelStoreToGenerationIfNeeded() throws {
        guard activeStorePointerState() == .absent,
              !FileManager.default.fileExists(atPath: defaultStoreURL.path) else {
            return
        }
        guard FileManager.default.fileExists(atPath: channelLegacyStoreURL.path) else { return }
        try copyStoreSnapshot(from: channelLegacyStoreURL, to: defaultStoreURL)
        AuditLoggingSeam.required.audit(.workspaceStoreMigrated, category: "Persistence", fields: [
            "result": "copied",
            "source": "channel_legacy",
            "store_generation": storeGeneration
        ])
    }

    /// Copies a live SQLite store through SQLite's backup API into an atomic
    /// temporary destination. Copying the database file and its WAL/SHM files
    /// independently can produce a snapshot that never existed on disk.
    public static func copyStoreSnapshot(from sourceStore: URL, to destinationStore: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceStore.path) else {
            throw PersistentStorePreparationError.migrationSourceMissing
        }
        let destinationArtifacts = ["", "-shm", "-wal"].map { suffix in
            destinationStore.path + suffix
        }
        guard destinationArtifacts.allSatisfy({ !fileManager.fileExists(atPath: $0) }) else {
            throw PersistentStorePreparationError.migrationDestinationExists
        }

        let temporaryDirectory = destinationStore.deletingLastPathComponent()
            .appendingPathComponent(".migration-" + UUID().uuidString, isDirectory: true)
        let temporaryStore = temporaryDirectory.appendingPathComponent(destinationStore.lastPathComponent)
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try backupSQLiteDatabase(from: sourceStore, to: temporaryStore)
            guard sqliteIntegrityIsValid(at: temporaryStore) else {
                throw PersistentStorePreparationError.migrationFailed("SQLite quick_check failed")
            }
            try fileManager.moveItem(at: temporaryStore, to: destinationStore)
        } catch let error as PersistentStorePreparationError {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw PersistentStorePreparationError.migrationFailed(String(describing: error))
        }
        try? fileManager.removeItem(at: temporaryDirectory)
    }

    private static func backupSQLiteDatabase(from sourceStore: URL, to destinationStore: URL) throws {
        var sourceDatabase: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            sourceStore.path,
            &sourceDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceResult == SQLITE_OK, let sourceDatabase else {
            if let sourceDatabase { sqlite3_close(sourceDatabase) }
            throw PersistentStorePreparationError.migrationFailed("source SQLite open returned \(sourceResult)")
        }
        defer { sqlite3_close(sourceDatabase) }
        _ = sqlite3_busy_timeout(sourceDatabase, 5_000)

        var destinationDatabase: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destinationStore.path,
            &destinationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destinationDatabase else {
            if let destinationDatabase { sqlite3_close(destinationDatabase) }
            throw PersistentStorePreparationError.migrationFailed("destination SQLite open returned \(destinationResult)")
        }
        defer { sqlite3_close(destinationDatabase) }
        _ = sqlite3_busy_timeout(destinationDatabase, 5_000)

        guard let backup = sqlite3_backup_init(destinationDatabase, "main", sourceDatabase, "main") else {
            throw PersistentStorePreparationError.migrationFailed("SQLite backup initialization failed")
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw PersistentStorePreparationError.migrationFailed(
                "SQLite backup failed with step \(stepResult), finish \(finishResult)"
            )
        }

        // A backup inherits the source header, including WAL mode. Normalize
        // the staged copy before moving it so the atomic destination consists
        // of one self-contained database file rather than a file plus sidecars
        // that would otherwise have to be moved independently.
        var errorMessage: UnsafeMutablePointer<CChar>?
        let journalResult = sqlite3_exec(
            destinationDatabase,
            "PRAGMA journal_mode = DELETE",
            nil,
            nil,
            &errorMessage
        )
        guard journalResult == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw PersistentStorePreparationError.migrationFailed(
                "SQLite journal normalization failed: \(message)"
            )
        }
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
            AuditLoggingSeam.required.audit(.dataStoreRecovered, category: "App", fields: [
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

    private static func scanForWorkspaceConfigs(
        root: URL,
        maxDepth: Int,
        privacyHomeDirectory: URL
    ) -> [URL] {
        var remainingBudget = maxRecoveryScanDirectories
        let hostFileAccess = HostFileAccessBroker(homeDirectory: privacyHomeDirectory)
        return scanForWorkspaceConfigs(
            root: root,
            maxDepth: maxDepth,
            remainingBudget: &remainingBudget,
            hostFileAccess: hostFileAccess
        )
    }

    private static func scanForWorkspaceConfigs(
        root: URL,
        maxDepth: Int,
        remainingBudget: inout Int,
        hostFileAccess: HostFileAccessBroker
    ) -> [URL] {
        guard !Task.isCancelled else { return [] }
        guard maxDepth >= 0 else { return [] }
        guard remainingBudget > 0 else { return [] }
        let intent = HostFileAccessIntent.implicitScan(root: nil)
        guard !hostFileAccess.shouldSkip(root, intent: intent) else {
            return []
        }
        remainingBudget -= 1

        var isDirectory: ObjCBool = false
        guard hostFileAccess.fileExists(at: root, isDirectory: &isDirectory, intent: intent),
              isDirectory.boolValue else {
            return []
        }

        let directConfig = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        let legacyConfig = URL(fileURLWithPath: WorkspaceFileLayout.legacyWorkspaceConfigFile(for: root.path))
        var results: [URL] = []
        if hostFileAccess.fileExists(at: directConfig, intent: intent) {
            results.append(directConfig)
        } else if hostFileAccess.fileExists(at: legacyConfig, intent: intent) {
            results.append(legacyConfig)
        }

        guard maxDepth > 0,
              let children = try? hostFileAccess.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey],
                intent: intent
              ) else {
            return results
        }

        for child in children {
            guard !Task.isCancelled else { break }
            guard remainingBudget > 0 else { break }
            guard !skippedRecoveryDirectoryNames.contains(child.lastPathComponent) else { continue }
            guard !hostFileAccess.shouldSkip(child, intent: intent) else {
                continue
            }
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
                    remainingBudget: &remainingBudget,
                    hostFileAccess: hostFileAccess
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
