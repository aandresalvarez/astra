import Foundation
import ASTRACore

struct CapabilityPackageImportResult {
    var package: PluginPackage
    var report: CapabilityPackageValidationReport
    var installedURL: URL
}

struct CapabilityPackageImportError: LocalizedError {
    var report: CapabilityPackageValidationReport

    var errorDescription: String? {
        report.summary
    }
}

struct CapabilityPackageImporter {
    let library: CapabilityLibrary
    let fileManager: FileManager

    init(
        library: CapabilityLibrary = CapabilityLibrary(),
        fileManager: FileManager = .default
    ) {
        self.library = library
        self.fileManager = fileManager
    }

    func validateFile(
        at url: URL,
        checkPrerequisites: Bool = true
    ) -> CapabilityPackageValidationReport {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return CapabilityPackageValidationReport(
                package: nil,
                sourceURL: url,
                issues: [
                    CapabilityPackageValidationIssue(
                        severity: .blocker,
                        code: .unreadableFile,
                        title: "Unreadable package",
                        message: "ASTRA could not read \(url.path): \(error.localizedDescription)",
                        component: url.lastPathComponent
                    )
                ]
            )
        }
        return CapabilityPackageValidator.validate(
            data: data,
            sourceURL: url,
            installedPackages: library.installedPackages(),
            checkPrerequisites: checkPrerequisites
        )
    }

    @discardableResult
    func importFile(
        at url: URL,
        checkPrerequisites: Bool = true
    ) throws -> CapabilityPackageImportResult {
        let report = validateFile(at: url, checkPrerequisites: checkPrerequisites)
        return try importValidatedPackage(report)
    }

    @discardableResult
    func importValidatedPackage(
        _ report: CapabilityPackageValidationReport
    ) throws -> CapabilityPackageImportResult {
        guard report.canInstall, let package = report.package else {
            throw CapabilityPackageImportError(report: report)
        }
        let currentReport = CapabilityPackageValidator.validate(
            package: package,
            sourceURL: report.sourceURL,
            installedPackages: library.installedPackages(),
            checkPrerequisites: false
        )
        guard currentReport.canInstall else {
            throw CapabilityPackageImportError(report: currentReport)
        }
        try library.install(package, sourceMetadata: .localLibrary())
        return CapabilityPackageImportResult(
            package: package,
            report: report,
            installedURL: library.packageURL(for: package.id)
        )
    }
}
