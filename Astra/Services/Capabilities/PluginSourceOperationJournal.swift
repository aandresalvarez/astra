import CryptoKit
import Foundation
import Darwin
import SwiftData
import ASTRAPersistence

/// Prepared provenance work shares the file operation's UUID and store. The
/// receipt is the only commit proof; equal old/new plugin bytes decide nothing.
/// No active provenance changes until the matching domain commit is confirmed.
@MainActor
struct PluginSourceOperationJournal {
    enum Failure: Error { case invalidRecord, changedRoot, wrongStore, changedOwnership, missingFileProof, missingReceipt }
    struct Record: Codable {
        let version: Int
        let id: UUID
        let pluginID: String
        let storeIdentity: String
        let rootIdentity: String
        let before: PluginSourceStore.Provenance?
        let after: PluginSourceStore.Provenance?
    }
    struct Prepared {
        let record: Record
        let digest: String
        var id: UUID { record.id }
    }
    struct Result { var completed = 0; var deferred = 0 }

    let store: PluginSourceStore
    private var directory: URL { store.root.appendingPathComponent("OperationIntents", isDirectory: true) }
    private let maximumBytes = 262_144

    func prepare(id: UUID = UUID(), pluginID: String, after: PluginSourceStore.Provenance?, modelContext: ModelContext) throws -> Prepared {
        guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw Failure.wrongStore }
        try store.fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try pendingIDs().isEmpty else { throw Failure.invalidRecord }
        let record = Record(version: 1, id: id, pluginID: pluginID, storeIdentity: identity,
            rootIdentity: try rootIdentity(), before: try store.savedProvenance()[pluginID], after: after)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= maximumBytes else { throw Failure.invalidRecord }
        try data.write(to: url(id), options: .atomic)
        try store.fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(id).path)
        return Prepared(record: record, digest: Self.digest(data))
    }

    func load(_ id: UUID) throws -> Prepared {
        guard try store.fileManager.attributesOfItem(atPath: url(id).path)[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.invalidRecord
        }
        let descriptor = open(url(id).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw Failure.invalidRecord }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1, record.id == id, !record.pluginID.isEmpty else { throw Failure.invalidRecord }
        return Prepared(record: record, digest: Self.digest(data))
    }

    func pendingIDs() throws -> [UUID] {
        guard store.fileManager.fileExists(atPath: directory.path) else { return [] }
        return try store.fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                guard let id = UUID(uuidString: $0.deletingPathExtension().lastPathComponent) else { throw Failure.invalidRecord }
                return id
            }
    }

    /// The caller holds sourceStore.exclusively while replaying a definition.
    func handler(modelContext: ModelContext) -> PluginFileOperationRecovery.MetadataHandler {
        .init(reconcile: { file, receipt in
            let source = try matching(file, modelContext: modelContext)
            if let receipt {
                try validate(receipt, file: file, source: source)
                guard receipt.completedAt == nil else { return }
                try store.replaceProvenance(pluginID: source.record.pluginID,
                    before: source.record.before, after: source.record.after)
            } else {
                // Provenance is published only after the commit. If something
                // else changed this owner, never overwrite that later edit.
                guard try store.savedProvenance()[source.record.pluginID] == source.record.before else {
                    throw Failure.changedOwnership
                }
            }
        }, finish: { file, receipt in
            let source = try matching(file, modelContext: modelContext)
            if let receipt {
                try validate(receipt, file: file, source: source)
                guard receipt.completedAt != nil else { throw Failure.missingReceipt }
            }
            try discard(source)
        })
    }

    /// A quit before file preparation leaves only this intent. A quit after
    /// confirmed completion may leave only its garbage. Neither case grants
    /// permission to replay a missing file manifest or overwrite new metadata.
    @discardableResult
    func resumeOrphans(modelContext: ModelContext, files: PluginFileOperationJournal) -> Result {
        guard let ids = try? pendingIDs(), let identity = PersistentStoreIdentity.current(for: modelContext) else {
            return Result(deferred: 1)
        }
        var result = Result()
        for id in ids {
            do {
                if try files.pendingIDs().contains(id) { continue }
                let source = try load(id)
                guard source.record.storeIdentity == identity else { throw Failure.wrongStore }
                try validateRoot(source)
                if let receipt = try PluginOperationCommit.read(id, container: modelContext.container) {
                    guard receipt.pluginIDs == [source.record.pluginID], receipt.completedAt != nil else { throw Failure.missingFileProof }
                } else {
                    guard try store.savedProvenance()[source.record.pluginID] == source.record.before else { throw Failure.changedOwnership }
                }
                try discard(source)
                result.completed += 1
            } catch { result.deferred += 1 }
        }
        return result
    }

    private func matching(_ file: PluginFileOperationJournal.Prepared, modelContext: ModelContext) throws -> Prepared {
        let source = try load(file.id)
        guard source.digest == file.manifest.linkedMetadataDigest,
              file.manifest.pluginIDs == [source.record.pluginID] else { throw Failure.invalidRecord }
        guard let identity = PersistentStoreIdentity.current(for: modelContext),
              source.record.storeIdentity == identity, file.manifest.storeIdentity == identity else { throw Failure.wrongStore }
        try validateRoot(source)
        return source
    }
    private func validate(_ receipt: PluginOperationCommit.Snapshot, file: PluginFileOperationJournal.Prepared, source: Prepared) throws {
        guard receipt.id == source.id, receipt.manifestDigest == file.digest,
              receipt.pluginIDs == [source.record.pluginID] else { throw Failure.invalidRecord }
    }
    private func validateRoot(_ source: Prepared) throws {
        guard try rootIdentity() == source.record.rootIdentity else { throw Failure.changedRoot }
    }
    private func rootIdentity() throws -> String {
        let root = store.root.standardizedFileURL.resolvingSymlinksInPath()
        guard try store.fileManager.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory,
              let identity = WorkspaceFileLayout.itemIdentity(at: root.path) else { throw Failure.changedRoot }
        return root.path + "|" + identity
    }
    private func discard(_ source: Prepared) throws {
        try validateRoot(source)
        guard try load(source.id).digest == source.digest else { throw Failure.invalidRecord }
        try store.fileManager.removeItem(at: url(source.id))
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
