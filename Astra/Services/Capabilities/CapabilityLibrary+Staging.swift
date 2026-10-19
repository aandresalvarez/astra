import Foundation
import ASTRACore

/// A draft waiting for review over an approved installed plugin.
///
/// A file import of a newer version over an approved plugin can't take its
/// place yet: the runtime resolves only an approved definition, so every
/// workspace would lose the plugin until the draft is approved. The library
/// keeps the draft beside it instead, in its own directory, durably: the
/// approved copy stays what resolves until approval commits the draft
/// (`commitStaged`), the only step that replaces it, and a crash before then
/// leaves both as they were. Staged drafts are never listed as installed,
/// and their governance is always a draft's.
extension CapabilityLibrary {
    /// The library of staged drafts, beside this one.
    var staging: CapabilityLibrary {
        CapabilityLibrary(
            directory: directory.deletingLastPathComponent()
                .appendingPathComponent(directory.lastPathComponent + "Staged", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// The drafts waiting for review.
    func stagedPackages() -> [PluginPackage] {
        staging.installedPackages(trustedBuiltInIDs: [])
    }

    func stagedPackage(id: String) -> PluginPackage? {
        stagedPackages().first { $0.id == id }
    }

    /// Keeps `source` as the draft for its plugin, replacing an earlier one.
    /// The installed copy is not touched.
    func stage(_ source: CapabilityPackageSource) throws {
        try staging.ensureDirectoryExists()
        try staging.install(source)
    }

    /// Replaces the installed copy with the staged draft (the one write that
    /// does), then drops the draft. Returns the definition now installed.
    /// One a crash left staged after it was installed is committed again,
    /// harmlessly, by the next approval.
    @discardableResult
    func commitStaged(id: String) throws -> PluginPackage {
        guard let draft = stagedPackage(id: id) else { throw RemovalError.notInstalled(id) }
        var committed = draft
        // A staged copy's clamped draft governance is not part of what it
        // declares: the library clamps it again on load.
        committed.governance = CapabilityGovernance.defaultGovernance(for: committed.sourceMetadata)
        try install(CapabilityPackageSource(
            package: committed,
            manifestURL: nil,
            assetRootURL: draft.sourceMetadata?.url?.deletingLastPathComponent()
        ))
        discardStaged(id: id)
        guard let installed = installedPackages().first(where: { $0.id == id }) else { throw RemovalError.notInstalled(id) }
        return installed
    }

    /// Drops the staged draft of `id`, if any.
    func discardStaged(id: String) {
        try? removeStaged(id: id)
    }

    /// Removes the staged draft of `id` (one that can't be read is moved
    /// aside); throws while one is still there, so a Remove keeps its intent.
    func removeStaged(id: String) throws {
        if stagedPackage(id: id) != nil { _ = try staging.removePackage(id: id, trustedBuiltInIDs: []) }
        try staging.quarantineUnreadableEntry(id: id)
        guard stagedPackage(id: id) == nil, !staging.holdsUnreadableEntry(id: id) else { throw RemovalError.notInstalled(id) }
    }
}

/// A library entry that can't be read (malformed, unreadable) still holds
/// its plugin's storage name: nothing lists it, but a reinstall or an
/// import under that name is refused. Forgetting such a plugin moves the
/// raw entry aside, beside the library, rather than deleting what may be
/// the person's only copy.
extension CapabilityLibrary {
    var quarantineDirectory: URL {
        directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "Quarantine", isDirectory: true)
    }

    /// Whether `id`'s storage name is taken by an entry that doesn't read.
    func holdsUnreadableEntry(id: String) -> Bool {
        !installedPackages().contains { $0.id == id }
            && occupiedStorageNames().contains(Self.safeFileName(for: id).lowercased())
    }

    /// Moves `id`'s unreadable storage (its JSON file or its directory) into
    /// the quarantine folder. Throws when it can't, so the caller keeps its
    /// intent for a retry.
    func quarantineUnreadableEntry(id: String) throws {
        guard holdsUnreadableEntry(id: id) else { return }
        try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970))
        for url in [packageURL(for: id), packageManifestURL(for: id).deletingLastPathComponent()]
        where fileManager.fileExists(atPath: url.path) {
            let destination = quarantineDirectory.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
            try fileManager.moveItem(at: url, to: destination)
        }
        guard !holdsUnreadableEntry(id: id) else { throw RemovalError.notInstalled(id) }
        NotificationCenter.default.post(name: .capabilityPackagesChanged, object: nil)
    }
}
