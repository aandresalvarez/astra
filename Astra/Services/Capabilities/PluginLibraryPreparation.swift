import Foundation
import ASTRACore

/// Canonicalizes a definition in isolated storage, verifies review identity,
/// then captures literal before/after images. Neither preparation nor approval
/// can mutate the installed library before the journal is durable.
@MainActor
enum PluginLibraryPreparation {
    struct Definition {
        let operation: PluginFileOperationJournal.Prepared
        let reviewedDigest: String
    }

    static func prepare(
        source: CapabilityPackageSource, library: CapabilityLibrary,
        approvalStore: CapabilityApprovalStore, approvedBy: String? = nil,
        storeIdentity: String, journal: PluginFileOperationJournal
    ) throws -> Definition {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("astra-plugin-prepare-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var reviewed = source
        reviewed.package = CapabilityPackageImporter.asStored(source.package)
        let reviewedDigest = try CapabilityApprovalDigest.digest(for: reviewed)
        let candidate = CapabilityLibrary(directory: scratch.appendingPathComponent("Library"), publishesChanges: false)
        try candidate.install(source)
        guard let installed = candidate.installedPackage(id: source.package.id),
              try CapabilityApprovalDigest.digest(for: installed) == reviewedDigest else {
            throw PluginDefinitionChange.Failure.reviewedBytesChanged
        }
        var approvalChange: PluginFileOperationJournal.Change?
        if let approvedBy {
            let approvals = CapabilityApprovalStore(directory: scratch.appendingPathComponent("Approvals"), publishesChanges: false)
            let record = try approvals.save(package: installed, status: .approved, approvedBy: approvedBy,
                reviewNotes: "Approved the staged update.")
            approvalChange = .init(root: .approvals, name: approvalStore.recordURL(for: record).lastPathComponent,
                replacement: try PluginFileImage.capture(approvals.recordURL(for: record)))
        }
        // Only the storage URL changes between prepared and live manifests.
        // It is excluded from review identity; icon assets remain literal.
        if installed.iconDescriptor.kind == .asset {
            let url = candidate.packageManifestURL(for: installed.id)
            var stored = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: url))
            stored.sourceMetadata?.url = library.packageManifestURL(for: installed.id)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: url, options: .atomic)
        }
        let name = CapabilityLibrary.safeFileName(for: installed.id)
        var changes: [PluginFileOperationJournal.Change] = [
            .init(root: .library, name: name + ".json", replacement: try PluginFileImage.capture(candidate.packageURL(for: installed.id))),
            .init(root: .library, name: name, replacement: try PluginFileImage.capture(candidate.packageManifestURL(for: installed.id).deletingLastPathComponent())),
            .init(root: .staging, name: name + ".json", replacement: nil),
            .init(root: .staging, name: name, replacement: nil)
        ]
        if let approvalChange { changes.append(approvalChange) }
        let operation = try journal.prepare(storeIdentity: storeIdentity, pluginIDs: [installed.id], changes: changes)
        return Definition(operation: operation, reviewedDigest: reviewedDigest)
    }
}
