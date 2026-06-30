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

    static func legacyAppRoot(for workspacePath: String) -> String {
        guard !workspacePath.isEmpty else { return "" }
        return (workspacePath as NSString).appendingPathComponent("apps")
    }

    static func appDirectoryURL(workspacePath: String, appID: String) -> URL? {
        let root = appRoot(for: workspacePath)
        guard !root.isEmpty else { return nil }
        guard WorkspaceAppIDPolicy.isPortableIdentifier(appID) else { return nil }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        let appURL = rootURL.appendingPathComponent(appID, isDirectory: true).standardizedFileURL
        guard isContainedAppDirectory(appURL, inAppRoot: rootURL, workspaceRoot: workspaceURL) else { return nil }
        return appURL
    }

    static func appManifestFileURL(workspacePath: String, appID: String) -> URL? {
        guard let directory = appDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("manifest.json")
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
    }

    static func appDirectory(workspacePath: String, appID: String) -> String {
        appDirectoryURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appManifestFile(workspacePath: String, appID: String) -> String {
        appManifestFileURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appDatabaseFile(workspacePath: String, appID: String) -> String {
        appDatabaseFileURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appDatabaseFileURL(workspacePath: String, appID: String) -> URL? {
        guard let directory = appDataDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("app.sqlite")
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
    }

    static func appDataDirectory(workspacePath: String, appID: String) -> String {
        appDataDirectoryURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appDataDirectoryURL(workspacePath: String, appID: String) -> URL? {
        guard let directory = appDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("data", isDirectory: true)
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
    }

    static func appArtifactExportDirectory(workspacePath: String, appID: String) -> String {
        appArtifactExportDirectoryURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appArtifactExportDirectoryURL(workspacePath: String, appID: String) -> URL? {
        guard let directory = appDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("exports", isDirectory: true)
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
    }

    static func appPackageExportRoot(workspacePath: String) -> String {
        let root = appRoot(for: workspacePath)
        guard !root.isEmpty else { return "" }
        return (root as NSString).appendingPathComponent("exports")
    }

    static func appPackageExportRootURL(workspacePath: String) -> URL? {
        let root = appRoot(for: workspacePath)
        guard !root.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        let exportURL = rootURL.appendingPathComponent("exports", isDirectory: true).standardizedFileURL
        guard isContainedAppDirectory(exportURL, inAppRoot: rootURL, workspaceRoot: workspaceURL) else { return nil }
        return exportURL
    }

    static func relativeAppDirectory(appID: String) -> String {
        guard WorkspaceAppIDPolicy.isPortableIdentifier(appID) else { return "" }
        return "\(supportDirectoryName)/apps/\(appID)"
    }

    static func relativeAppManifestFile(appID: String) -> String {
        let directory = relativeAppDirectory(appID: appID)
        guard !directory.isEmpty else { return "" }
        return "\(directory)/manifest.json"
    }

    // Slice 3 versioning: published-manifest snapshots live under the app directory,
    // so they are removed with the app (deleteApp's recursive remove) — purely local
    // history that travels with nothing.
    static func appVersionsDirectory(workspacePath: String, appID: String) -> String {
        appVersionsDirectoryURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appVersionsDirectoryURL(workspacePath: String, appID: String) -> URL? {
        guard let directory = appDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("versions", isDirectory: true)
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
    }

    static func appVersionFile(workspacePath: String, appID: String, versionNumber: Int) -> String {
        appVersionFileURL(workspacePath: workspacePath, appID: appID, versionNumber: versionNumber)?.path ?? ""
    }

    static func appVersionFileURL(workspacePath: String, appID: String, versionNumber: Int) -> URL? {
        guard let directory = appVersionsDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("v\(versionNumber).json")
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
    }

    static func appVersionsIndexFile(workspacePath: String, appID: String) -> String {
        appVersionsIndexFileURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appVersionsIndexFileURL(workspacePath: String, appID: String) -> URL? {
        guard let directory = appVersionsDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("index.json")
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
    }

    static func relativeAppVersionsDirectory(appID: String) -> String {
        let directory = relativeAppDirectory(appID: appID)
        guard !directory.isEmpty else { return "" }
        return "\(directory)/versions"
    }

    static func isContainedAppDirectory(_ url: URL, workspacePath: String) -> Bool {
        let root = appRoot(for: workspacePath)
        guard !root.isEmpty else { return false }
        return isContainedAppDirectory(
            url.standardizedFileURL,
            inAppRoot: URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL,
            workspaceRoot: URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        )
    }

    static func isContainedStoredAppDirectory(_ url: URL, workspacePath: String) -> Bool {
        isContainedAppDirectory(url, workspacePath: workspacePath)
            || isContainedLegacyAppDirectory(url, workspacePath: workspacePath)
    }

    static func isContainedAppManifestFile(_ url: URL, workspacePath: String) -> Bool {
        url.lastPathComponent == "manifest.json"
            && isContainedAppDirectory(url.deletingLastPathComponent(), workspacePath: workspacePath)
    }

    static func isContainedStoredAppManifestFile(_ url: URL, workspacePath: String) -> Bool {
        url.lastPathComponent == "manifest.json"
            && isContainedStoredAppDirectory(url.deletingLastPathComponent(), workspacePath: workspacePath)
    }

    private static func isContainedLegacyAppDirectory(_ url: URL, workspacePath: String) -> Bool {
        let root = legacyAppRoot(for: workspacePath)
        guard !root.isEmpty else { return false }
        return isContainedAppDirectory(
            url.standardizedFileURL,
            inAppRoot: URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL,
            workspaceRoot: URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        )
    }

    private static func isContainedAppDirectory(_ url: URL, inAppRoot rootURL: URL, workspaceRoot: URL) -> Bool {
        let root = rootURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path,
              candidate.path != root.path else {
            return false
        }
        return !existingPathContainsSymbolicLink(root, below: workspaceRoot)
            && !existingPathContainsSymbolicLink(candidate, below: workspaceRoot)
    }

    private static func existingPathContainsSymbolicLink(_ url: URL, below workspaceRoot: URL) -> Bool {
        let workspacePath = workspaceRoot.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath == workspacePath || targetPath.hasPrefix("\(workspacePath)/") else {
            return true
        }
        let relativePath = String(targetPath.dropFirst(workspacePath.count))
        let components = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        var current = workspaceRoot.standardizedFileURL
        for component in components {
            current.appendPathComponent(component)
            if isSymbolicLink(current) {
                return true
            }
        }
        return false
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    // App Studio conversation journal: the build conversation + per-turn event log live under the
    // app directory (like `versions/`), so `deleteApp`'s recursive remove cleans them and they
    // travel with nothing.
    static func appStudioDirectory(workspacePath: String, appID: String) -> String {
        appStudioDirectoryURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appStudioDirectoryURL(workspacePath: String, appID: String) -> URL? {
        guard let directory = appDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("studio", isDirectory: true)
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
    }

    static func appStudioJournalFile(workspacePath: String, appID: String) -> String {
        appStudioJournalFileURL(workspacePath: workspacePath, appID: appID)?.path ?? ""
    }

    static func appStudioJournalFileURL(workspacePath: String, appID: String) -> URL? {
        guard let directory = appStudioDirectoryURL(workspacePath: workspacePath, appID: appID) else { return nil }
        let url = directory.appendingPathComponent("journal.json")
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard !existingPathContainsSymbolicLink(url, below: workspaceURL) else { return nil }
        return url
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
