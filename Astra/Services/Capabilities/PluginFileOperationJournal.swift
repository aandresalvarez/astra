import CryptoKit
import Foundation
import ASTRAPersistence

/// Prepared file work, bound to one store and pinned storage roots. Only
/// single-child slots of caller-supplied roots are writable; a decoded manifest
/// can never supply an arbitrary restore destination. The manifest owns both
/// directions until the domain receipt and every mirror confirm completion.
struct PluginFileOperationJournal {
    enum Failure: Error { case pendingOperation, invalidManifest, changedRoot, missingJournal }
    enum Root: String, Codable, CaseIterable { case library, staging, approvals }
    struct Change {
        let root: Root
        let name: String
        let replacement: PluginFileImage?
    }
    struct Entry: Codable {
        let root: Root
        let name: String
        let before: PluginFileImage?
        let after: PluginFileImage?
    }
    struct Pin: Codable, Equatable { let path: String; let identity: String }
    struct Manifest: Codable {
        let version: Int
        let id: UUID
        let storeIdentity: String
        let pluginIDs: [String]
        let roots: [String: Pin]
        let entries: [Entry]
        let linkedMetadataDigest: String?
    }
    struct Prepared {
        let manifest: Manifest
        let digest: String
        var id: UUID { manifest.id }
    }

    let roots: [Root: URL]
    let directory: URL
    private let manager: FileManager
    private static let maximumManifestBytes = 96 * 1_024 * 1_024

    init(library: CapabilityLibrary, approvals: CapabilityApprovalStore) {
        manager = library.fileManager
        roots = [.library: library.directory.standardizedFileURL.resolvingSymlinksInPath(),
                 .staging: library.directory.deletingLastPathComponent()
                    .appendingPathComponent(library.directory.lastPathComponent + "Staged", isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath(),
                 .approvals: approvals.directory.standardizedFileURL.resolvingSymlinksInPath()]
        directory = library.directory.deletingLastPathComponent()
            .appendingPathComponent(library.directory.lastPathComponent + "Operations", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    func prepare(id: UUID = UUID(), storeIdentity: String, pluginIDs: [String], changes: [Change], linkedMetadataDigest: String? = nil) throws -> Prepared {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try pendingIDs().isEmpty else { throw Failure.pendingOperation }
        var pins: [String: Pin] = [:]
        for root in Set(changes.map(\.root)) {
            let url = roots[root]!
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            pins[root.rawValue] = try pin(url)
        }
        guard !changes.isEmpty, changes.count <= 32 else { throw Failure.invalidManifest }
        var names = Set<String>()
        var bytes = 0
        let entries = try changes.map { change in
            guard validName(change.name), names.insert(change.root.rawValue + "/" + change.name).inserted else {
                throw Failure.invalidManifest
            }
            let before = try PluginFileImage.capture(roots[change.root]!.appendingPathComponent(change.name))
            let after = try change.replacement?.validated()
            bytes += (before?.files.values.reduce(0, { $0 + $1.count }) ?? 0)
                + (after?.files.values.reduce(0, { $0 + $1.count }) ?? 0)
            guard bytes <= 64 * 1_024 * 1_024 else { throw Failure.invalidManifest }
            return Entry(root: change.root, name: change.name, before: before, after: after)
        }
        let manifest = Manifest(version: linkedMetadataDigest == nil ? 1 : 2, id: id, storeIdentity: storeIdentity,
            pluginIDs: Array(Set(pluginIDs)).sorted(), roots: pins, entries: entries, linkedMetadataDigest: linkedMetadataDigest)
        let data = try encode(manifest)
        guard data.count <= Self.maximumManifestBytes else { throw Failure.invalidManifest }
        try data.write(to: url(id), options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(id).path)
        return Prepared(manifest: manifest, digest: Self.digest(data))
    }

    func pendingIDs() throws -> [UUID] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map {
            guard let id = UUID(uuidString: $0.deletingPathExtension().lastPathComponent) else { throw Failure.invalidManifest }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func load(_ id: UUID) throws -> Prepared {
        let handle = try FileHandle(forReadingFrom: url(id))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumManifestBytes + 1) ?? Data()
        guard data.count <= Self.maximumManifestBytes else { throw Failure.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard (manifest.version == 1 && manifest.linkedMetadataDigest == nil)
                || (manifest.version == 2 && manifest.linkedMetadataDigest?.isEmpty == false) else { throw Failure.invalidManifest }
        guard manifest.id == id, !manifest.entries.isEmpty,
              manifest.entries.count <= 32, !manifest.storeIdentity.isEmpty else { throw Failure.invalidManifest }
        var seen = Set<String>()
        for entry in manifest.entries {
            guard validName(entry.name), seen.insert(entry.root.rawValue + "/" + entry.name).inserted else { throw Failure.invalidManifest }
            _ = try entry.before?.validated()
            _ = try entry.after?.validated()
        }
        return Prepared(manifest: manifest, digest: Self.digest(data))
    }

    /// Re-read the prepared bytes and root identities before every attempt.
    /// A failed or interrupted replacement leaves the journal for another try.
    func apply(_ prepared: Prepared, forward: Bool) throws {
        let saved = try load(prepared.id)
        guard saved.digest == prepared.digest else { throw Failure.invalidManifest }
        try validateRoots(saved.manifest)
        for entry in saved.manifest.entries {
            try validateRoots(saved.manifest)
            let root = roots[entry.root]!
            let target = root.appendingPathComponent(entry.name)
            let scratch = root.appendingPathComponent(".astra-operation-\(prepared.id)-\(UUID())")
            defer { try? manager.removeItem(at: scratch) }
            if let image = forward ? entry.after : entry.before { try image.write(to: scratch) }
            // Refuse links, sockets and other unexpected live storage, even
            // when this image represents deleting a newly-created file.
            _ = try PluginFileImage.capture(target)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            if manager.fileExists(atPath: scratch.path) { try manager.moveItem(at: scratch, to: target) }
        }
    }

    func discard(_ prepared: Prepared) throws {
        guard try load(prepared.id).digest == prepared.digest else { throw Failure.invalidManifest }
        try validateRoots(prepared.manifest)
        try manager.removeItem(at: url(prepared.id))
    }

    private func validateRoots(_ manifest: Manifest) throws {
        let usedRoots = Set(manifest.entries.map(\.root))
        guard Set(manifest.roots.keys) == Set(usedRoots.map(\.rawValue)) else { throw Failure.changedRoot }
        for root in usedRoots {
            guard try pin(roots[root]!) == manifest.roots[root.rawValue] else { throw Failure.changedRoot }
        }
    }

    private func pin(_ url: URL) throws -> Pin {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              url.standardizedFileURL.resolvingSymlinksInPath().path == url.path,
              let identity = WorkspaceFileLayout.itemIdentity(at: url.path) else { throw Failure.changedRoot }
        return Pin(path: url.path, identity: identity)
    }

    private func validName(_ name: String) -> Bool { PluginFileImage.valid(name) && !name.contains("/") }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func encode(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
