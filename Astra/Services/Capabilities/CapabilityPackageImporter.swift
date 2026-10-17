import Foundation
import SwiftData
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

@MainActor
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
        checkPrerequisites: Bool = true,
        modelContext: ModelContext? = nil
    ) throws -> CapabilityPackageImportResult {
        let report = validateFile(at: url, checkPrerequisites: checkPrerequisites)
        return try importValidatedPackage(report, modelContext: modelContext)
    }

    /// Installs a validated package. With a model context, a newer version
    /// of an installed plugin is an Update: refused when a workspace that has
    /// it on would refuse the new version, and every activation is
    /// reconciled with the new definition right after the library changes
    /// (the previous library entry is restored if that fails).
    @discardableResult
    func importValidatedPackage(
        _ report: CapabilityPackageValidationReport,
        modelContext: ModelContext? = nil
    ) throws -> CapabilityPackageImportResult {
        guard report.canInstall, let package = report.package else {
            throw CapabilityPackageImportError(report: report)
        }
        if let modelContext, let refusal = PluginUpdateService.refusals(for: package, modelContext: modelContext).first {
            throw refusal
        }
        let previousStorage = library.makePackageStorageSnapshot(for: package.id)
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
        if let modelContext {
            do {
                // The person chose this version: what it dropped is released.
                try PluginUpdateService.reconcileAll(
                    modelContext: modelContext,
                    packages: library.installedPackages().filter { $0.id == package.id },
                    mode: .release
                )
            } catch {
                library.restorePackageStorage(previousStorage)
                throw error
            }
        }
        CapabilityCatalogPersistenceEvents.post(.global)
        return CapabilityPackageImportResult(
            package: package,
            report: report,
            installedURL: package.iconDescriptor.kind == .asset
                ? library.packageManifestURL(for: package.id)
                : library.packageURL(for: package.id)
        )
    }
}
