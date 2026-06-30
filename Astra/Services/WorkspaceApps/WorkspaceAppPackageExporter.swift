import Foundation

enum WorkspaceAppPackageExportError: LocalizedError, Equatable {
    case missingWorkspacePath
    case missingManifest(String)
    case decodeManifestFailed(String)
    case invalidExport(WorkspaceAppPackageValidationReport)
    case unsafeExportPath(String)

    var errorDescription: String? {
        switch self {
        case .missingWorkspacePath:
            return "Workspace path is unavailable."
        case .missingManifest(let path):
            return "Workspace app manifest is missing at \(path)."
        case .decodeManifestFailed(let message):
            return "Could not decode workspace app manifest: \(message)"
        case .invalidExport(let report):
            let messages = report.blockers.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "Exported workspace app package did not validate.\n\(messages)"
        case .unsafeExportPath(let path):
            return "Workspace app package export path is outside the managed app root: \(path)"
        }
    }
}

struct WorkspaceAppPackageExportResult: Equatable {
    var packageURL: URL
    var validationReport: WorkspaceAppPackageValidationReport
}

struct WorkspaceAppPackageExporter {
    var fileManager: FileManager = .default
    var packageService = WorkspaceAppPackageService()

    func exportTemplatePackage(
        app: WorkspaceApp,
        workspace: Workspace,
        version: String = "1.0.0",
        mode: WorkspaceAppPackageExportMode = .templateOnly,
        createdAt: Date = Date()
    ) throws -> WorkspaceAppPackageExportResult {
        guard !workspace.primaryPath.isEmpty else {
            throw WorkspaceAppPackageExportError.missingWorkspacePath
        }
        try validateExportRoot(workspacePath: workspace.primaryPath)

        let loaded = try loadManifest(app: app, workspace: workspace)
        let databaseURL = try exportDatabaseURL(for: loaded.location, workspacePath: workspace.primaryPath, mode: mode)
        let packageURL = try nextPackageURL(appID: app.logicalID, workspacePath: workspace.primaryPath)
        _ = try packageService.exportPackage(
            manifest: loaded.manifest,
            to: packageURL,
            packageID: "\(Self.packageDirectoryStem(for: app.logicalID)).astra-app",
            version: version,
            mode: mode,
            appStorageDatabaseURL: databaseURL,
            createdAt: createdAt
        )
        let report = packageService.validatePackage(at: packageURL)
        guard report.canInstall else {
            throw WorkspaceAppPackageExportError.invalidExport(report)
        }
        return WorkspaceAppPackageExportResult(packageURL: packageURL, validationReport: report)
    }

    private func exportDatabaseURL(
        for location: WorkspaceAppManifestLocation,
        workspacePath: String,
        mode: WorkspaceAppPackageExportMode
    ) throws -> URL? {
        guard mode != .templateOnly else { return nil }
        guard let databaseURL = WorkspaceFileLayout.appDatabaseFileURL(
            appDirectoryURL: location.appDirectoryURL,
            workspacePath: workspacePath
        ) else {
            throw WorkspaceAppPackageExportError.unsafeExportPath(location.databaseURL.path)
        }
        return databaseURL
    }

    private func validateExportRoot(workspacePath: String) throws {
        let displayExportRoot = WorkspaceFileLayout.appPackageExportRoot(workspacePath: workspacePath)
        guard !displayExportRoot.isEmpty else {
            throw WorkspaceAppPackageExportError.missingWorkspacePath
        }
        guard WorkspaceFileLayout.appPackageExportRootURL(workspacePath: workspacePath) != nil else {
            throw WorkspaceAppPackageExportError.unsafeExportPath(displayExportRoot)
        }
    }

    private func loadManifest(app: WorkspaceApp, workspace: Workspace) throws -> WorkspaceAppLoadedManifest {
        let manifestStore = WorkspaceAppManifestStore(fileManager: fileManager)
        guard let manifestURL = manifestStore.readableManifestURL(app: app, workspace: workspace) else {
            throw WorkspaceAppPackageExportError.missingManifest(app.manifestRelativePath)
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw WorkspaceAppPackageExportError.missingManifest(manifestURL.path)
        }
        do {
            return try manifestStore.loadManifest(app: app, workspace: workspace)
        } catch {
            throw WorkspaceAppPackageExportError.decodeManifestFailed(String(describing: error))
        }
    }

    private func nextPackageURL(appID: String, workspacePath: String) throws -> URL {
        let displayExportRoot = WorkspaceFileLayout.appPackageExportRoot(workspacePath: workspacePath)
        guard !displayExportRoot.isEmpty else {
            throw WorkspaceAppPackageExportError.missingWorkspacePath
        }
        guard let rootURL = WorkspaceFileLayout.appPackageExportRootURL(workspacePath: workspacePath) else {
            throw WorkspaceAppPackageExportError.unsafeExportPath(displayExportRoot)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let packageStem = Self.packageDirectoryStem(for: appID)
        let baseName = "\(packageStem).astra-app"
        let first = rootURL.appendingPathComponent(baseName, isDirectory: true)
        guard fileManager.fileExists(atPath: first.path) else { return first }

        var suffix = 2
        while true {
            let candidate = rootURL.appendingPathComponent("\(packageStem)-\(suffix).astra-app", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func packageDirectoryStem(for appID: String) -> String {
        let pathNormalized = appID.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = pathNormalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? appID
        let sanitizedScalars = lastComponent.unicodeScalars.map { scalar -> Character in
            WorkspaceAppIDPolicy.allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(sanitizedScalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_ \n\t\r"))
        guard WorkspaceAppIDPolicy.isPortableIdentifier(collapsed) else {
            return "workspace-app"
        }
        return collapsed
    }
}
