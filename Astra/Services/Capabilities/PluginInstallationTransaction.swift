import Foundation
import SwiftData
import ASTRACore
import ASTRAPersistence

/// Add/Create prepare literal library and optional approval bytes before any
/// live replacement. Activation writes attach this exact file participant to
/// their receipt. A library-only Create uses a fresh context for its commit.
@MainActor
struct PluginInstallationTransaction {
    let library: CapabilityLibrary
    let approvals: CapabilityApprovalStore
    let definition: PluginLibraryPreparation.Definition
    let files: PluginFileCommit
    let operation: PluginFileOperationContext?

    /// Storage governance is canonical; an asset locator is still needed
    /// to review/copy the bytes. Virtual skill rows keep their inventory kind.
    static func reviewedPackage(_ package: PluginPackage) -> PluginPackage {
        if CapabilityInstaller.syntheticSkillRowID(of: package) != nil { return package }
        var stored = CapabilityPackageImporter.asStored(package)
        if package.iconDescriptor.kind == .asset { stored.sourceMetadata?.url = package.sourceMetadata?.url }
        return stored
    }

    static func prepare(package: PluginPackage, library: CapabilityLibrary, modelContext: ModelContext,
        approvals: CapabilityApprovalStore = CapabilityApprovalStore(), approval: CapabilityApprovalRecord? = nil,
        operation: PluginFileOperationContext? = nil) throws -> Self {
        guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw PluginDefinitionChange.Failure.unavailableStore }
        let sourceURL = package.sourceMetadata?.url
        let assetRoot = sourceURL.map { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()
        }
        let source = CapabilityPackageSource(package: package, manifestURL: sourceURL, assetRootURL: assetRoot)
        let journal = PluginFileOperationJournal(library: library, approvals: approvals)
        let definition = try PluginLibraryPreparation.prepare(source: source, library: library,
            approvalStore: approvals, approvalRecord: approval, storeIdentity: identity, journal: journal,
            operation: operation, clearsStaged: false)
        return Self(library: library, approvals: approvals, definition: definition,
            files: .init(journal: journal, prepared: definition.operation, metadata: operation?.metadata), operation: operation)
    }

    func perform<Result>(modelContext: ModelContext, _ body: (PluginFileCommit) throws -> Result) throws -> Result {
        try files.perform(modelContext: modelContext) {
            guard let pluginID = files.prepared.manifest.pluginIDs.first,
                  let installed = library.installedPackage(id: pluginID),
                  try CapabilityApprovalDigest.digest(for: installed) == definition.reviewedDigest else {
                throw PluginDefinitionChange.Failure.reviewedBytesChanged
            }
            return try body(files)
        }
    }

    func commitWithoutEnabling(modelContext: ModelContext) throws -> PluginPackage {
        let saved = ModelContext(modelContext.container)
        saved.autosaveEnabled = false
        return try PluginDefinitionChange.commit(definition, library: library, journal: files.journal,
            modelContext: saved, kind: .add, approvalRecords: { approvals.records() }, operation: operation)
    }
}
