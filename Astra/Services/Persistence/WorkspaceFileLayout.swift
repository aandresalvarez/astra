import Foundation

enum WorkspaceFileLayout {
    static let supportDirectoryName = ".astra"
    static let workspaceConfigFileName = ".astra-workspace.json"
    static let sshConnectionsFileName = "ssh-connections.json"

    static func supportDirectory(for workspacePath: String) -> String {
        guard !workspacePath.isEmpty else { return "" }
        return (workspacePath as NSString).appendingPathComponent(supportDirectoryName)
    }

    static func workspaceConfigFile(for workspacePath: String) -> String {
        guard !workspacePath.isEmpty else { return "" }
        return (workspacePath as NSString).appendingPathComponent(workspaceConfigFileName)
    }

    static func sshConnectionsFile(for workspacePath: String) -> String {
        let support = supportDirectory(for: workspacePath)
        guard !support.isEmpty else { return "" }
        return (support as NSString).appendingPathComponent(sshConnectionsFileName)
    }

    static func legacySSHConnectionsFile(for workspacePath: String) -> String {
        guard !workspacePath.isEmpty else { return "" }
        return (workspacePath as NSString).appendingPathComponent(sshConnectionsFileName)
    }

    static func taskRoot(for workspacePath: String) -> String {
        let support = supportDirectory(for: workspacePath)
        guard !support.isEmpty else { return "" }
        return (support as NSString).appendingPathComponent("tasks")
    }

    static func appRoot(for workspacePath: String) -> String {
        let support = supportDirectory(for: workspacePath)
        guard !support.isEmpty else { return "" }
        return (support as NSString).appendingPathComponent("apps")
    }

    static func appDirectory(workspacePath: String, appID: String) -> String {
        let root = appRoot(for: workspacePath)
        guard !root.isEmpty else { return "" }
        return (root as NSString).appendingPathComponent(appID)
    }

    static func appManifestFile(workspacePath: String, appID: String) -> String {
        let directory = appDirectory(workspacePath: workspacePath, appID: appID)
        guard !directory.isEmpty else { return "" }
        return (directory as NSString).appendingPathComponent("manifest.json")
    }

    static func appDatabaseFile(workspacePath: String, appID: String) -> String {
        let directory = appDataDirectory(workspacePath: workspacePath, appID: appID)
        guard !directory.isEmpty else { return "" }
        return (directory as NSString).appendingPathComponent("app.sqlite")
    }

    static func appDataDirectory(workspacePath: String, appID: String) -> String {
        let directory = appDirectory(workspacePath: workspacePath, appID: appID)
        guard !directory.isEmpty else { return "" }
        return (directory as NSString).appendingPathComponent("data")
    }

    static func appArtifactExportDirectory(workspacePath: String, appID: String) -> String {
        let directory = appDirectory(workspacePath: workspacePath, appID: appID)
        guard !directory.isEmpty else { return "" }
        return (directory as NSString).appendingPathComponent("exports")
    }

    static func appPackageExportRoot(workspacePath: String) -> String {
        let root = appRoot(for: workspacePath)
        guard !root.isEmpty else { return "" }
        return (root as NSString).appendingPathComponent("exports")
    }

    static func relativeAppDirectory(appID: String) -> String {
        "\(supportDirectoryName)/apps/\(appID)"
    }

    static func relativeAppManifestFile(appID: String) -> String {
        "\(relativeAppDirectory(appID: appID))/manifest.json"
    }

    static func legacyTaskRoot(for workspacePath: String) -> String {
        guard !workspacePath.isEmpty else { return "" }
        return (workspacePath as NSString).appendingPathComponent("tasks")
    }

    static func taskFolder(workspacePath: String, taskID: UUID) -> String {
        let root = taskRoot(for: workspacePath)
        guard !root.isEmpty else { return "" }
        return (root as NSString).appendingPathComponent(String(taskID.uuidString.prefix(8)))
    }

    static func legacyTaskFolder(workspacePath: String, taskID: UUID) -> String {
        let root = legacyTaskRoot(for: workspacePath)
        guard !root.isEmpty else { return "" }
        return (root as NSString).appendingPathComponent(String(taskID.uuidString.prefix(8)))
    }

    static func readableTaskFolder(workspacePath: String, taskID: UUID) -> String {
        let canonical = taskFolder(workspacePath: workspacePath, taskID: taskID)
        let legacy = legacyTaskFolder(workspacePath: workspacePath, taskID: taskID)
        if !FileManager.default.fileExists(atPath: canonical),
           FileManager.default.fileExists(atPath: legacy) {
            return legacy
        }
        return canonical
    }

    @discardableResult
    static func migrateLegacyTaskFolderIfNeeded(workspacePath: String, taskID: UUID) -> String {
        let canonical = taskFolder(workspacePath: workspacePath, taskID: taskID)
        let legacy = legacyTaskFolder(workspacePath: workspacePath, taskID: taskID)
        guard !canonical.isEmpty else { return "" }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: canonical),
           fileManager.fileExists(atPath: legacy) {
            do {
                try fileManager.createDirectory(
                    atPath: taskRoot(for: workspacePath),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(atPath: legacy, toPath: canonical)
                removeLegacyTaskRootIfEmpty(workspacePath: workspacePath)
                AppLogger.audit(.workspaceStoreMigrated, category: "Persistence", taskID: taskID, fields: [
                    "resource": "task_folder",
                    "result": "completed"
                ])
            } catch {
                AppLogger.audit(.workspaceStoreMigrated, category: "Persistence", taskID: taskID, fields: [
                    "resource": "task_folder",
                    "result": "failed",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
        return canonical
    }

    static func ensureSupportDirectory(for workspacePath: String) {
        let support = supportDirectory(for: workspacePath)
        guard !support.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
    }

    private static func removeLegacyTaskRootIfEmpty(workspacePath: String) {
        let root = legacyTaskRoot(for: workspacePath)
        let hostFileAccess = HostFileAccessBroker()
        guard !root.isEmpty,
              let contents = try? hostFileAccess.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                intent: .astraManagedStorage(root: URL(fileURLWithPath: workspacePath, isDirectory: true))
              ),
              contents.isEmpty else {
            return
        }
        try? FileManager.default.removeItem(atPath: root)
    }
}
