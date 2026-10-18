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

/// An Update whose installed copy couldn't be copied aside is refused: a
/// reconciliation that failed afterwards could not put it back.
struct CapabilityPackageSnapshotUnavailable: LocalizedError, Equatable {
    var packageID: String

    var errorDescription: String? {
        "ASTRA couldn't keep a copy of the installed \(packageID) to go back to, so it didn't update it. Try again."
    }
}

/// The library took the new version but couldn't read it back, so nothing
/// could be reconciled with it; the previous entry is put back.
struct CapabilityPackageInstallUnreadable: LocalizedError, Equatable {
    var packageID: String

    var errorDescription: String? {
        "ASTRA couldn't read back the new version of \(packageID), so it kept the version you had. Try again."
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
        if modelContext != nil, !previousStorage.canRestore {
            throw CapabilityPackageSnapshotUnavailable(packageID: package.id)
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
            library.discardPackageStorageSnapshot(previousStorage)
            throw CapabilityPackageImportError(report: currentReport)
        }
        do {
            if let source = currentReport.source {
                try library.install(source)
            } else {
                try library.install(package, sourceMetadata: .localLibrary())
            }
            if let modelContext {
                // The activations are reconciled with the definition as the
                // library stores it: one that can't be read back fails the
                // import, rather than reconciling nothing and reporting it kept.
                guard let installed = library.installedPackage(id: package.id) else {
                    throw CapabilityPackageInstallUnreadable(packageID: package.id)
                }
                // The person chose this version: what it dropped is released.
                try PluginUpdateService.reconcileAll(modelContext: modelContext, packages: [installed], mode: .release)
            }
        } catch {
            // The snapshot outlives a restore only when the restore fails.
            library.restorePackageStorage(previousStorage)
            throw error
        }
        library.discardPackageStorageSnapshot(previousStorage)
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
