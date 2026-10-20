import Foundation
import SwiftData
import ASTRACore
import ASTRAPersistence

struct CapabilityPackageImportResult {
    var package: PluginPackage
    var report: CapabilityPackageValidationReport
    var installedURL: URL
    /// The import is a draft kept beside an approved installed copy
    /// (`CapabilityLibrary.stage`): nothing changed until it is approved.
    var staged = false
}

struct CapabilityPackageImportError: LocalizedError {
    var report: CapabilityPackageValidationReport

    var errorDescription: String? {
        report.summary
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

/// An Update failed and its previous version couldn't be put back either:
/// the plugin has no installed definition until the copy kept at
/// `snapshotPath` is restored.
struct CapabilityPackageUpdateNotRolledBack: LocalizedError, Equatable {
    var packageID: String
    var snapshotPath: String
    var updateError: String

    var errorDescription: String? {
        "\(updateError) ASTRA also couldn't put back the version of \(packageID) you had, so it isn't installed now. "
            + "A copy of it is kept at \(snapshotPath)."
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
    ///
    /// `replacesInstalledCopy` is set only for a plugin from a source whose
    /// installed copy came from that same source (plugin sources, T5, T7):
    /// it replaces that copy whatever its version.
    @discardableResult
    func importValidatedPackage(
        _ report: CapabilityPackageValidationReport,
        modelContext: ModelContext? = nil,
        replacesInstalledCopy: Bool = false,
        approvalRecords: [CapabilityApprovalRecord]? = nil
    ) throws -> CapabilityPackageImportResult {
        guard report.canInstall, let package = report.package else {
            throw CapabilityPackageImportError(report: report)
        }
        // Over an approved installed copy, a draft no approval covers is
        // staged, not installed: the approved copy keeps resolving in every
        // workspace until the draft's approval commits it.
        let records = approvalRecords ?? CapabilityApprovalStore().records()
        if let installed = library.installedPackages().first(where: { $0.id == package.id }),
           Self.isApproved(installed, records: records) {
            var draft = report.source ?? CapabilityPackageSource(
                package: package, manifestURL: report.sourceURL, assetRootURL: report.sourceURL?.deletingLastPathComponent()
            )
            draft.package = package
            if !Self.isApproved(Self.asStored(draft.package), records: records) {
                try library.stage(draft)
                CapabilityCatalogPersistenceEvents.post(.global)
                return CapabilityPackageImportResult(
                    package: package, report: report, installedURL: library.staging.packageURL(for: package.id), staged: true
                )
            }
        }
        if let modelContext, let refusal = PluginUpdateService.refusals(for: package, modelContext: modelContext).first {
            throw refusal
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
            allowReplacingExistingPackageID: replacesInstalledCopy,
            checkPrerequisites: false
        )
        guard currentReport.canInstall else {
            throw CapabilityPackageImportError(report: currentReport)
        }
        if let modelContext {
            let approvals = CapabilityApprovalStore()
            let journal = PluginFileOperationJournal(library: library, approvals: approvals)
            guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw PluginDefinitionChange.Failure.unavailableStore }
            let definition = try PluginLibraryPreparation.prepare(source: currentReport.source ?? currentSource,
                library: library, approvalStore: approvals, storeIdentity: identity, journal: journal)
            _ = try PluginDefinitionChange.commit(definition, library: library, journal: journal,
                modelContext: modelContext, kind: .update, approvalRecords: { records })
            return CapabilityPackageImportResult(package: package, report: report,
                installedURL: package.iconDescriptor.kind == .asset
                    ? library.packageManifestURL(for: package.id) : library.packageURL(for: package.id))
        }
        // Compatibility callers without a domain store perform a library-only
        // write. They cannot reconcile activations or claim a domain commit.
        let previousStorage = library.makePackageStorageSnapshot(for: package.id)
        do {
            if let source = currentReport.source {
                try library.install(source)
            } else {
                try library.install(package, sourceMetadata: .localLibrary())
            }
        } catch {
            // The snapshot outlives a restore only when the restore fails,
            // and that failure is the outcome: the definition is gone.
            if let failure = library.restorePackageStorage(previousStorage) {
                throw CapabilityPackageUpdateNotRolledBack(
                    packageID: failure.packageID,
                    snapshotPath: failure.snapshotDirectory.path,
                    updateError: error.localizedDescription
                )
            }
            throw error
        }
        library.discardPackageStorageSnapshot(previousStorage)
        // An earlier staged draft of it is superseded by what was installed.
        library.discardStaged(id: package.id)
        CapabilityCatalogPersistenceEvents.post(.global)
        return CapabilityPackageImportResult(
            package: package,
            report: report,
            installedURL: package.iconDescriptor.kind == .asset
                ? library.packageManifestURL(for: package.id)
                : library.packageURL(for: package.id)
        )
    }

    /// Whether `package` needs no further review to run
    /// (`PluginUpdateService.awaitsReview`).
    static func isApproved(_ package: PluginPackage, records: [CapabilityApprovalRecord]) -> Bool {
        !PluginUpdateService.awaitsReview(package, records: records)
    }

    /// `package` as the library would read it back: a local copy's
    /// self-declared governance is a draft's (`CapabilityLibrary`).
    static func asStored(_ package: PluginPackage) -> PluginPackage {
        var stored = package
        if stored.sourceMetadata == nil { stored.sourceMetadata = .localLibrary() }
        if !CapabilityLibrary.trustedBuiltInPackageIDs.contains(stored.id) { _ = CapabilityGovernanceNormalizer.clampToLocalDraft(&stored) }
        return stored
    }
}
