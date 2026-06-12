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
        CapabilityPackageValidator.validateSource(
            at: url,
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
        var currentSource = report.source ?? CapabilityPackageSource(
            package: package,
            manifestURL: report.sourceURL,
            assetRootURL: report.sourceURL?.deletingLastPathComponent()
        )
        currentSource.package = package
        let currentReport = CapabilityPackageValidator.validate(
            source: currentSource,
            installedPackages: library.installedPackages(),
            checkPrerequisites: false
        )
        guard currentReport.canInstall else {
            throw CapabilityPackageImportError(report: currentReport)
        }
        if let source = currentReport.source {
            try library.install(source)
        } else {
            try library.install(package, sourceMetadata: .localLibrary())
        }
        return CapabilityPackageImportResult(
            package: package,
            report: report,
            installedURL: package.iconDescriptor.kind == .asset
                ? library.packageManifestURL(for: package.id)
                : library.packageURL(for: package.id)
        )
    }
}
