import Foundation

enum WorkspaceAppPackageExportError: LocalizedError, Equatable {
    case missingWorkspacePath
    case missingManifest(String)
    case decodeManifestFailed(String)
    case invalidExport(WorkspaceAppPackageValidationReport)

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

        let manifest = try loadManifest(app: app, workspace: workspace)
        let packageURL = try nextPackageURL(appID: app.logicalID, workspacePath: workspace.primaryPath)
        _ = try packageService.exportPackage(
            manifest: manifest,
            to: packageURL,
            packageID: "\(app.logicalID).astra-app",
            version: version,
            mode: mode,
            appStorageDatabaseURL: URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
                workspacePath: workspace.primaryPath,
                appID: app.logicalID
            )),
            createdAt: createdAt
        )
        let report = packageService.validatePackage(at: packageURL)
        guard report.canInstall else {
            throw WorkspaceAppPackageExportError.invalidExport(report)
        }
        return WorkspaceAppPackageExportResult(packageURL: packageURL, validationReport: report)
    }

    private func loadManifest(app: WorkspaceApp, workspace: Workspace) throws -> WorkspaceAppManifest {
        let manifestURL = URL(fileURLWithPath: workspace.primaryPath)
            .appendingPathComponent(app.manifestRelativePath)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw WorkspaceAppPackageExportError.missingManifest(manifestURL.path)
        }
        do {
            return try JSONDecoder().decode(WorkspaceAppManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw WorkspaceAppPackageExportError.decodeManifestFailed(String(describing: error))
        }
    }

    private func nextPackageURL(appID: String, workspacePath: String) throws -> URL {
        let exportRoot = WorkspaceFileLayout.appPackageExportRoot(workspacePath: workspacePath)
        guard !exportRoot.isEmpty else {
            throw WorkspaceAppPackageExportError.missingWorkspacePath
        }
        try fileManager.createDirectory(atPath: exportRoot, withIntermediateDirectories: true)

        let rootURL = URL(fileURLWithPath: exportRoot, isDirectory: true)
        let baseName = "\(appID).astra-app"
        let first = rootURL.appendingPathComponent(baseName, isDirectory: true)
        guard fileManager.fileExists(atPath: first.path) else { return first }

        var suffix = 2
        while true {
            let candidate = rootURL.appendingPathComponent("\(appID)-\(suffix).astra-app", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}
