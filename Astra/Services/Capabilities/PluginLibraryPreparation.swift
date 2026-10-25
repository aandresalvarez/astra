import Foundation
import ASTRACore

/// Canonicalizes a definition in isolated storage, verifies review identity,
/// then captures literal before/after images. Neither preparation nor approval
/// can mutate the installed library before the journal is durable.
@MainActor
enum PluginLibraryPreparation {
    enum Destination: Equatable { case installed, staged }
    struct Definition {
        let operation: PluginFileOperationJournal.Prepared
        let reviewedDigest: String
    }

    static func prepare(
        source: CapabilityPackageSource, library: CapabilityLibrary,
        approvalStore: CapabilityApprovalStore, approvedBy: String? = nil,
        approvalRecord: CapabilityApprovalRecord? = nil,
        storeIdentity: String, journal: PluginFileOperationJournal,
        operation: PluginFileOperationContext? = nil, destination: Destination = .installed,
        clearsStaged: Bool = true
    ) throws -> Definition {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("astra-plugin-prepare-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let reviewedDigest = try reviewDigest(source)
        let candidate = CapabilityLibrary(directory: scratch.appendingPathComponent("Library"), publishesChanges: false)
        try candidate.install(source)
        guard let installed = candidate.installedPackage(id: source.package.id),
              try CapabilityApprovalDigest.digest(for: installed) == reviewedDigest else {
            throw PluginDefinitionChange.Failure.reviewedBytesChanged
        }
        var approvalChange: PluginFileOperationJournal.Change?
        if approvedBy != nil || approvalRecord != nil {
            let approvals = CapabilityApprovalStore(directory: scratch.appendingPathComponent("Approvals"), publishesChanges: false)
            let record = try approvals.save(package: installed, status: approvalRecord?.status ?? .approved,
                approvedBy: approvalRecord?.approvedBy ?? approvedBy!,
                reviewNotes: approvalRecord?.reviewNotes ?? "Approved the staged update.",
                approvedAt: approvalRecord?.approvedAt ?? Date())
            if let expected = approvalRecord, expected != record { throw PluginDefinitionChange.Failure.reviewedBytesChanged }
            approvalChange = .init(root: .approvals, name: approvalStore.recordURL(for: record).lastPathComponent,
                replacement: try PluginFileImage.capture(approvals.recordURL(for: record)))
        }
        // Only the storage URL changes between prepared and live manifests.
        // It is excluded from review identity; icon assets remain literal.
        if installed.iconDescriptor.kind == .asset {
            let url = candidate.packageManifestURL(for: installed.id)
            var stored = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: url))
            stored.sourceMetadata?.url = (destination == .staged ? library.staging : library).packageManifestURL(for: installed.id)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: url, options: .atomic)
        }
        let name = CapabilityLibrary.safeFileName(for: installed.id)
        let target: PluginFileOperationJournal.Root = destination == .staged ? .staging : .library
        var changes: [PluginFileOperationJournal.Change] = [
            .init(root: target, name: name + ".json", replacement: try PluginFileImage.capture(candidate.packageURL(for: installed.id))),
            .init(root: target, name: name, replacement: try PluginFileImage.capture(candidate.packageManifestURL(for: installed.id).deletingLastPathComponent()))
        ]
        if destination == .installed, clearsStaged {
            changes += [.init(root: .staging, name: name + ".json", replacement: nil), .init(root: .staging, name: name, replacement: nil)]
        }
        if let approvalChange { changes.insert(approvalChange, at: 0) }
        let prepared = try journal.prepare(id: operation?.id ?? UUID(), storeIdentity: storeIdentity, pluginIDs: [installed.id],
            changes: changes, linkedMetadataDigest: operation?.metadataDigest)
        return Definition(operation: prepared, reviewedDigest: reviewedDigest)
    }
    static func reviewDigest(_ source: CapabilityPackageSource) throws -> String {
        var reviewed = source
        reviewed.package = CapabilityPackageImporter.asStored(source.package)
        return try CapabilityApprovalDigest.digest(for: reviewed)
    }

}
