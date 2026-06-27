import Foundation

struct WorkspaceAppPackageLibraryEntry: Sendable, Equatable {
    var packageURL: URL
    var packageID: String?
    var appName: String?
    var version: String?
    var installState: WorkspaceAppPackageInstallState
    var canInstall: Bool
    var blockerMessages: [String]
    var warningMessages: [String]
    var validationReport: WorkspaceAppPackageValidationReport
}

struct WorkspaceAppPackageLibraryService {
    var fileManager: FileManager = .default
    var packageService = WorkspaceAppPackageService()

    func discoverPackages(in libraryURL: URL) -> [WorkspaceAppPackageLibraryEntry] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children
            .filter(isPackageCandidate)
            .map(entry)
            .sorted(by: sortEntries)
    }

    private func isPackageCandidate(_ url: URL) -> Bool {
        guard isDirectory(url) else { return false }
        if (url.lastPathComponent as NSString).pathExtension == "astra-app" {
            return true
        }
        return fileManager.fileExists(atPath: url.appendingPathComponent("package.json").path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) {
            return values.isDirectory == true
        }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func entry(for packageURL: URL) -> WorkspaceAppPackageLibraryEntry {
        let report = packageService.validatePackage(at: packageURL)
        return WorkspaceAppPackageLibraryEntry(
            packageURL: packageURL,
            packageID: report.package?.packageID,
            appName: report.package?.appName ?? report.manifest?.app.name,
            version: report.package?.version,
            installState: report.installState,
            canInstall: report.canInstall,
            blockerMessages: report.blockers.map(\.message),
            warningMessages: report.warnings.map(\.message),
            validationReport: report
        )
    }

    private func sortEntries(
        _ lhs: WorkspaceAppPackageLibraryEntry,
        _ rhs: WorkspaceAppPackageLibraryEntry
    ) -> Bool {
        let lhsName = lhs.appName ?? lhs.packageURL.deletingPathExtension().lastPathComponent
        let rhsName = rhs.appName ?? rhs.packageURL.deletingPathExtension().lastPathComponent
        let nameComparison = lhsName.localizedStandardCompare(rhsName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.packageURL.lastPathComponent.localizedStandardCompare(rhs.packageURL.lastPathComponent) == .orderedAscending
    }
}
