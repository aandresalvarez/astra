import CryptoKit
import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// What a workspace deletion must remove outside the store: its generated
/// mirrors and its connectors' and skills' Keychain items. It is recorded
/// before the deletion is saved and cleared once that cleanup has run, so a
/// quit in between is settled at the next launch, before startup recovery
/// could reimport the workspace from a mirror left behind.
struct WorkspaceDeletionCleanupRecord: Codable, Equatable {
    let workspaceID: UUID
    let primaryPath: String
    /// The primary folder's physical path when the deletion was recorded.
    /// Mirrors, ownership, and the record's key all use it, so a symlink in
    /// the configured spelling retargeted before a retry can't aim cleanup
    /// at another folder's mirror.
    let physicalFolder: String
    /// The mirror files to remove, pinned when the deletion was recorded:
    /// each one's folder resolved, so a symlinked `.astra` folder retargeted
    /// before a retry can't redirect the removal to another workspace's
    /// mirror, and its own name kept, so a symlinked mirror is itself what
    /// is removed.
    let mirrorFiles: [String]
    let connectors: [ConnectorKeychainCleanup]
    let skills: [SkillKeychainCleanup]
    /// True for a record written before `physicalFolder` or `mirrorFiles`
    /// existed. What it would clean can only be derived from the folder and
    /// `.astra` link as they are now, which may lead elsewhere, so the store
    /// treats it as unreadable: it is kept and settles nothing.
    let folderWasResolvedOnRead: Bool

    private enum CodingKeys: String, CodingKey {
        case workspaceID, primaryPath, physicalFolder, mirrorFiles, connectors, skills
    }

    /// The mirror files of the workspace whose primary folder is `folder`,
    /// as `mirrorFiles` pins them.
    static func pinnedMirrorFiles(for folder: String) -> [String] {
        let files = [
            WorkspaceFileLayout.workspaceConfigFile(for: folder),
            WorkspaceFileLayout.legacyWorkspaceConfigFile(for: folder)
        ].map { file in
            (WorkspacePathPresentation.resolvedPath((file as NSString).deletingLastPathComponent) as NSString)
                .appendingPathComponent((file as NSString).lastPathComponent)
        }
        return files.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    init(
        workspaceID id: UUID, primaryPath path: String,
        connectors connectorCleanups: [ConnectorKeychainCleanup], skills skillCleanups: [SkillKeychainCleanup]
    ) {
        let folder = WorkspacePathPresentation.resolvedPath(path)
        self.init(
            workspaceID: id, primaryPath: path, physicalFolder: folder, mirrorFiles: Self.pinnedMirrorFiles(for: folder),
            connectors: connectorCleanups, skills: skillCleanups
        )
    }

    private init(
        workspaceID id: UUID, primaryPath path: String, physicalFolder folder: String, mirrorFiles files: [String],
        connectors connectorCleanups: [ConnectorKeychainCleanup], skills skillCleanups: [SkillKeychainCleanup]
    ) {
        workspaceID = id
        primaryPath = path
        physicalFolder = folder
        mirrorFiles = files
        connectors = connectorCleanups
        skills = skillCleanups
        folderWasResolvedOnRead = false
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        primaryPath = try container.decode(String.self, forKey: .primaryPath)
        // Records written before the folder was snapshotted resolve it here;
        // the store verifies that against the record's file name.
        let recorded = try container.decodeIfPresent(String.self, forKey: .physicalFolder)
        physicalFolder = recorded ?? WorkspacePathPresentation.resolvedPath(primaryPath)
        let pinned = try container.decodeIfPresent([String].self, forKey: .mirrorFiles)
        mirrorFiles = pinned ?? Self.pinnedMirrorFiles(for: physicalFolder)
        folderWasResolvedOnRead = recorded == nil || pinned == nil
        connectors = try container.decode([ConnectorKeychainCleanup].self, forKey: .connectors)
        skills = try container.decode([SkillKeychainCleanup].self, forKey: .skills)
    }

    /// Both records' credentials, so a cleanup still pending for the same
    /// deletion is never dropped by a later one.
    func merging(_ other: WorkspaceDeletionCleanupRecord) -> WorkspaceDeletionCleanupRecord {
        WorkspaceDeletionCleanupRecord(
            workspaceID: workspaceID, primaryPath: primaryPath, physicalFolder: physicalFolder,
            // A folder's mirrors can move between attempts; both are owed.
            mirrorFiles: mirrorFiles + other.mirrorFiles.filter { !mirrorFiles.contains($0) },
            // By every namespace-defining fact, not only the connector ID: a
            // reimported connector can keep its ID under a new base URL.
            connectors: connectors + other.connectors.filter { !connectors.contains($0) },
            skills: skills + other.skills.filter { new in !skills.contains { $0.skillID == new.skillID } }
        )
    }

    @MainActor
    init(_ workspace: Workspace) {
        workspaceID = workspace.id
        primaryPath = workspace.primaryPath
        physicalFolder = WorkspacePathPresentation.resolvedPath(workspace.primaryPath)
        mirrorFiles = Self.pinnedMirrorFiles(for: physicalFolder)
        connectors = workspace.connectors.map(\.keychainCleanup)
            + workspace.skills.flatMap { $0.connectors.map(\.keychainCleanup) }
        skills = workspace.skills.map(\.keychainCleanup)
        folderWasResolvedOnRead = false
    }
}

/// An app-owned outbox of workspace deletion cleanups, one atomic record per
/// workspace, outside provider-writable paths.
struct WorkspaceDeletionCleanupStore: Sendable {
    let directory: URL

    init(directory: URL = AppChannelStoragePaths.applicationSupportDirectory()
        .appendingPathComponent("WorkspaceDeletionCleanup", isDirectory: true)) {
        self.directory = directory.standardizedFileURL
    }

    /// Records `record` and returns what is now stored. Records are keyed by
    /// workspace and primary path, since imports reuse workspace IDs, and a
    /// pending record with the same key is merged rather than replaced. One
    /// that can't be read stops the deletion instead of being overwritten.
    @discardableResult
    func record(_ record: WorkspaceDeletionCleanupRecord) throws -> WorkspaceDeletionCleanupRecord {
        let stored = try existing(matching: record).map { $0.merging(record) } ?? record
        try write(stored)
        return stored
    }

    /// The pending record with `record`'s key, if any. One that can't be read
    /// throws rather than reading as absent.
    func existing(matching record: WorkspaceDeletionCleanupRecord) throws -> WorkspaceDeletionCleanupRecord? {
        let url = recordURL(for: record)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(url)
    }

    struct UnverifiableFolder: Error {}

    /// Decodes the record at `url`. One written before its folder and mirror
    /// files were pinned reads as unreadable and fails closed: a symlink
    /// retargeted since would aim its cleanup at another folder's mirror.
    private func read(_ url: URL) throws -> WorkspaceDeletionCleanupRecord {
        let record = try JSONDecoder().decode(WorkspaceDeletionCleanupRecord.self, from: Data(contentsOf: url))
        guard !record.folderWasResolvedOnRead else { throw UnverifiableFolder() }
        return record
    }

    /// Replaces whatever is stored under the record's key.
    func write(_ record: WorkspaceDeletionCleanupRecord) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let url = recordURL(for: record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Undoes a `record` whose deletion wasn't saved: what was pending before
    /// it is put back, so a retry that rolls back never drops cleanup an
    /// earlier saved deletion still owes. With nothing before it, the record
    /// is removed. A write that fails keeps the merged record, which only
    /// ever names more to clean.
    func restore(_ previous: WorkspaceDeletionCleanupRecord?, replacing record: WorkspaceDeletionCleanupRecord) throws {
        if let previous {
            try write(previous)
        } else {
            remove(record)
        }
    }

    func remove(_ record: WorkspaceDeletionCleanupRecord) {
        try? FileManager.default.removeItem(at: recordURL(for: record))
    }

    /// Readable records; an unreadable one stays on disk and is skipped.
    func pending() -> [WorkspaceDeletionCleanupRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { try? read($0) }
    }

    /// The mirror files of every unsettled deletion, which startup recovery
    /// must not reimport. Nil when a record can't be read, since then which
    /// mirror it guards is unknown.
    func pendingMirrorPaths() -> Set<String>? {
        // No outbox means nothing pending; one that can't be listed is unknown.
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        var mirrors = Set<String>()
        for url in urls where url.pathExtension == "json" {
            guard let record = try? read(url) else { return nil }
            // The pinned path itself, never re-resolved through its folders:
            // a folder replaced by a link since would turn it into another
            // workspace's mirror and keep that survivor out of recovery. Only
            // while its folder is unchanged is a link at the file itself,
            // which is the deleted workspace's own, followed too.
            for file in record.mirrorFiles {
                mirrors.insert(file)
                let folder = (file as NSString).deletingLastPathComponent
                if WorkspacePathPresentation.resolvedPath(folder) == folder {
                    mirrors.insert(WorkspacePathPresentation.resolvedPath(file))
                }
            }
        }
        return mirrors
    }

    func recordURL(for record: WorkspaceDeletionCleanupRecord) -> URL {
        let path = record.physicalFolder
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(record.workspaceID.uuidString.lowercased() + "-" + digest + ".json")
    }
}

@MainActor
enum WorkspaceDeletionCleanupService {
    /// Removes what `record` names that nothing stored still owns. Mirrors go
    /// before credentials, so a quit between them leaves only unreachable
    /// Keychain items. Ownership is read from the committed store, never
    /// from whether this deletion was saved: a mirror at a primary path a
    /// stored workspace resolves to is spared, as is every Keychain
    /// namespace a stored connector resolves to and the items of a skill
    /// whose ID survives. So a deletion that was never saved, or a workspace
    /// reimported at the same path before a retry, keeps everything it
    /// uses, and only what no one owns is removed. Returns false, keeping
    /// the record, when the store can't be read or anything owed remains.
    @discardableResult
    static func settle(_ record: WorkspaceDeletionCleanupRecord, modelContext: ModelContext) -> Bool {
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()),
              let connectors = try? modelContext.fetch(FetchDescriptor<Connector>()),
              let skills = try? modelContext.fetch(FetchDescriptor<Skill>()) else { return false }
        // The mirror files pinned at deletion, compared with the ones each
        // stored workspace resolves to now, so an alias such as /tmp for
        // /private/tmp or a symlinked folder still names the same live
        // mirror, and a symlink retargeted since never redirects the removal.
        let liveMirrors = Set(workspaces.flatMap {
            WorkspaceDeletionCleanupRecord.pinnedMirrorFiles(for: WorkspacePathPresentation.resolvedPath($0.primaryPath))
        })
        // A mirror left behind would let recovery reimport the workspace, so
        // the record, and the credentials it needs, are kept for a retry.
        if !removeMirrors(record.mirrorFiles.filter { !liveMirrors.contains($0) }) {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "mirror_removal_failed"
            ], level: .error)
            return false
        }
        let liveSkills = Set(skills.map(\.id))
        // Every credential is attempted; any that couldn't be cleared keeps
        // the record for an idempotent retry. A recreated connector can share
        // a stable endpoint or package namespace under a new ID, so
        // connector ownership is per namespace.
        var cleared = ConnectorCredentialCleanup.run(
            record.connectors, ownership: ConnectorCredentialCleanup.Ownership(connectors)
        )
        for skill in record.skills where !liveSkills.contains(skill.skillID) {
            cleared = skill.run() && cleared
        }
        if !cleared {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "credential_cleanup_failed"
            ], level: .error)
        }
        return cleared
    }

    /// Settles deletions a quit interrupted, reading committed state through
    /// a fresh context. Startup runs this before mirror recovery.
    @discardableResult
    static func resumePending(
        modelContext: ModelContext,
        store: WorkspaceDeletionCleanupStore = WorkspaceDeletionCleanupStore()
    ) -> Int {
        var settled = 0
        for record in store.pending() where settle(record, modelContext: ModelContext(modelContext.container)) {
            store.remove(record)
            settled += 1
        }
        return settled
    }

    /// False when a mirror that exists couldn't be removed. Existence is
    /// checked without following links: a dangling symlink is still a
    /// mirror, since its target could come back and be reimported, so the
    /// link itself is removed.
    ///
    /// Each path's folder was resolved when it was pinned. One that resolves
    /// elsewhere now had a folder replaced by a link since, so the file at
    /// that spelling is someone else's; it is left alone, as the pinned file
    /// went with the replaced folder.
    static func removeMirrors(_ mirrorPaths: [String]) -> Bool {
        var removedAll = true
        let unmoved = mirrorPaths.filter { path in
            let folder = (path as NSString).deletingLastPathComponent
            return WorkspacePathPresentation.resolvedPath(folder) == folder
        }
        for path in unmoved where (try? FileManager.default.attributesOfItem(atPath: path)) != nil {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                removedAll = false
            }
        }
        return removedAll
    }
}
