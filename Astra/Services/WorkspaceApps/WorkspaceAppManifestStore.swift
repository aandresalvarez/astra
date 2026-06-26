import Foundation

struct WorkspaceAppManifestLocation: Equatable {
    var manifestURL: URL
    var appDirectoryURL: URL

    var databaseURL: URL {
        appDirectoryURL
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("app.sqlite")
    }
}

struct WorkspaceAppLoadedManifest {
    var manifest: WorkspaceAppManifest
    var location: WorkspaceAppManifestLocation
}

struct WorkspaceAppManifestStore {
    var fileManager: FileManager = .default

    func canonicalAppDirectoryURL(app: WorkspaceApp, workspace: Workspace) -> URL {
        URL(fileURLWithPath: WorkspaceFileLayout.appDirectory(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ), isDirectory: true)
    }

    func canonicalManifestURL(app: WorkspaceApp, workspace: Workspace) -> URL {
        URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
    }

    func readableManifestURL(app: WorkspaceApp, workspace: Workspace) -> URL {
        existingManifestURL(app: app, workspace: workspace)
            ?? canonicalManifestURL(app: app, workspace: workspace)
    }

    func existingManifestURL(app: WorkspaceApp, workspace: Workspace) -> URL? {
        manifestCandidates(app: app, workspace: workspace)
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    func appDirectoryURL(app: WorkspaceApp, workspace: Workspace) -> URL {
        let canonical = canonicalAppDirectoryURL(app: app, workspace: workspace)
        if let manifest = existingManifestURL(app: app, workspace: workspace) {
            return manifest.deletingLastPathComponent()
        }
        if let stored = storedAppDirectoryURL(app: app, workspace: workspace),
           fileManager.fileExists(atPath: stored.path) {
            return stored
        }
        if fileManager.fileExists(atPath: canonical.path) {
            return canonical
        }
        return canonical
    }

    func loadManifest(app: WorkspaceApp, workspace: Workspace) throws -> WorkspaceAppLoadedManifest {
        let manifestURL = readableManifestURL(app: app, workspace: workspace)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        return WorkspaceAppLoadedManifest(
            manifest: manifest,
            location: WorkspaceAppManifestLocation(
                manifestURL: manifestURL,
                appDirectoryURL: manifestURL.deletingLastPathComponent()
            )
        )
    }

    private func manifestCandidates(app: WorkspaceApp, workspace: Workspace) -> [URL] {
        unique([canonicalManifestURL(app: app, workspace: workspace), storedManifestURL(app: app, workspace: workspace)])
    }

    private func storedManifestURL(app: WorkspaceApp, workspace: Workspace) -> URL? {
        guard !app.manifestRelativePath.isEmpty else { return nil }
        return URL(fileURLWithPath: workspace.primaryPath)
            .appendingPathComponent(app.manifestRelativePath)
    }

    private func storedAppDirectoryURL(app: WorkspaceApp, workspace: Workspace) -> URL? {
        guard !app.appDirectoryRelativePath.isEmpty else { return nil }
        return URL(fileURLWithPath: workspace.primaryPath)
            .appendingPathComponent(app.appDirectoryRelativePath, isDirectory: true)
    }

    private func unique(_ urls: [URL?]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls.compactMap({ $0 }) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(url)
        }
        return result
    }
}
