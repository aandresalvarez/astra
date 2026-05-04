import Foundation
import SwiftData

enum WorkspaceRecoveryService {
    static let recoveryNoticeKey = "lastWorkspaceRecoveryNotice"

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
        guard !configs.isEmpty else { return 0 }

        var imported = 0
        let existing = fetchExistingWorkspaces(modelContext: modelContext)
        var existingIDs = Set(existing.map { $0.id.uuidString })
        var existingPaths = Set(existing.map { normalizePath($0.primaryPath) })

        for configURL in configs {
            do {
                let config = try WorkspaceConfigManager.loadConfig(from: configURL)
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

        if imported > 0 {
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
        return imported
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
            let url = URL(fileURLWithPath: expandTilde(root))
            for config in scanForWorkspaceConfigs(root: url, maxDepth: 4) {
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

    private static func fetchExistingWorkspaces(modelContext: ModelContext) -> [Workspace] {
        let descriptor = FetchDescriptor<Workspace>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func scanForWorkspaceConfigs(root: URL, maxDepth: Int) -> [URL] {
        guard maxDepth >= 0 else { return [] }
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
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey]
              ) else {
            return results
        }

        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            guard values?.isDirectory == true, values?.isHidden != true else { continue }
            results.append(contentsOf: scanForWorkspaceConfigs(root: child, maxDepth: maxDepth - 1))
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
