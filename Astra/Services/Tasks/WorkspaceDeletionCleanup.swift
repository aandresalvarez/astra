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
    /// The mirror files' item identities, pinned once the deletion is saved
    /// and no export can rewrite them, so a mirror whose workspace folder was
    /// moved since is still recognized as this deletion's.
    let mirrorFileIDs: [String]
    let connectors: [ConnectorKeychainCleanup]
    let skills: [SkillKeychainCleanup]
    /// True for a record written before `physicalFolder` or `mirrorFiles`
    /// existed. What it would clean can only be derived from the folder and
    /// `.astra` link as they are now, which may lead elsewhere, so the store
    /// treats it as unreadable: it is kept and settles nothing.
    let folderWasResolvedOnRead: Bool

    private enum CodingKeys: String, CodingKey {
        case workspaceID, primaryPath, physicalFolder, mirrorFiles, mirrorFileIDs, connectors, skills
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

    fileprivate init(
        workspaceID id: UUID, primaryPath path: String, physicalFolder folder: String, mirrorFiles files: [String],
        mirrorFileIDs ids: [String] = [],
        connectors connectorCleanups: [ConnectorKeychainCleanup], skills skillCleanups: [SkillKeychainCleanup]
    ) {
        workspaceID = id
        primaryPath = path
        physicalFolder = folder
        mirrorFiles = files
        mirrorFileIDs = ids
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
        mirrorFileIDs = try container.decodeIfPresent([String].self, forKey: .mirrorFileIDs) ?? []
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
            mirrorFileIDs: mirrorFileIDs + other.mirrorFileIDs.filter { !mirrorFileIDs.contains($0) },
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
        mirrorFileIDs = []
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
    func record(
        _ record: WorkspaceDeletionCleanupRecord,
        attributes: (String) throws -> [FileAttributeKey: Any] = { try FileManager.default.attributesOfItem(atPath: $0) }
    ) throws -> WorkspaceDeletionCleanupRecord {
        let stored = try existing(matching: record, attributes: attributes).map { $0.merging(record) } ?? record
        try write(stored)
        return stored
    }

    /// The pending record with `record`'s key, if any. One that can't be read,
    /// or even checked, throws rather than reading as absent.
    func existing(
        matching record: WorkspaceDeletionCleanupRecord,
        attributes: (String) throws -> [FileAttributeKey: Any] = { try FileManager.default.attributesOfItem(atPath: $0) }
    ) throws -> WorkspaceDeletionCleanupRecord? {
        let url = recordURL(for: record)
        do {
            _ = try attributes(url.path)
        } catch {
            if WorkspaceFileLayout.isMissingFile(error) { return nil }
            throw error
        }
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

    /// Pins the identities of `record`'s mirror files as they are now, merged
    /// into what is stored. Called once the deletion is saved and queued
    /// exports are retired, so the files no longer change. Only a mirror
    /// confirmed missing is left out; one whose identity can't be read
    /// throws, so the deletion isn't saved with a mirror recovery and
    /// cleanup couldn't recognize.
    @discardableResult
    func pinMirrorIdentities(
        for record: WorkspaceDeletionCleanupRecord,
        identity: (String) throws -> String? = WorkspaceFileLayout.itemIdentityConfirmingAbsence(at:)
    ) throws -> WorkspaceDeletionCleanupRecord {
        let stored = try existing(matching: record) ?? record
        let ids = try stored.mirrorFiles.compactMap(identity)
        let pinned = stored.merging(WorkspaceDeletionCleanupRecord(
            workspaceID: stored.workspaceID, primaryPath: stored.primaryPath, physicalFolder: stored.physicalFolder,
            mirrorFiles: [], mirrorFileIDs: ids, connectors: [], skills: []
        ))
        try write(pinned)
        return pinned
    }

    /// Every pending deletion's mirror identities, which startup recovery
    /// must not import wherever the mirror now is. Nil when a record can't
    /// be read.
    func pendingMirrorIdentities() -> Set<String>? {
        guard let present = outboxPresent() else { return nil }
        guard present else { return [] }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        var ids = Set<String>()
        for url in urls where url.pathExtension == "json" {
            guard let record = try? read(url) else { return nil }
            ids.formUnion(record.mirrorFileIDs)
        }
        return ids
    }

    /// Whether the outbox folder exists: false only when it is confirmed
    /// missing, nil when it can't be checked, as behind a folder that can't
    /// be traversed, since its records would then go unseen.
    func outboxPresent() -> Bool? {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: directory.path)
            return true
        } catch {
            return WorkspaceFileLayout.isMissingFile(error) ? false : nil
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
        guard let present = outboxPresent() else { return nil }
        guard present else { return [] }
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
    ///
    /// `movedMirrors` are mirrors startup recovery found elsewhere carrying
    /// one of the record's pinned identities; they are removed too, after
    /// their identity is checked again.
    ///
    /// A mirror whose identity can't be read keeps the record: it may be a
    /// replacement at the pinned path, or the moved mirror itself.
    static func settle(
        _ record: WorkspaceDeletionCleanupRecord, modelContext: ModelContext, movedMirrors: [String] = [],
        identity: (String) throws -> String? = WorkspaceFileLayout.itemIdentityConfirmingAbsence(at:)
    ) -> Bool {
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()),
              let connectors = try? modelContext.fetch(FetchDescriptor<Connector>()),
              let skills = try? modelContext.fetch(FetchDescriptor<Skill>()) else { return false }
        // The mirror files pinned at deletion, compared with the ones each
        // stored workspace resolves to now, so an alias such as /tmp for
        // /private/tmp or a symlinked folder still names the same live
        // mirror, and a symlink retargeted since never redirects the removal.
        // A live mirror that is itself a link counts by its target too,
        // while its folder is unchanged, so a survivor whose mirror links to
        // the deleted workspace's keeps it.
        let liveMirrors = Set(workspaces.flatMap {
            WorkspaceDeletionCleanupRecord.pinnedMirrorFiles(for: WorkspacePathPresentation.resolvedPath($0.primaryPath))
        }.flatMap { file -> [String] in
            let folder = (file as NSString).deletingLastPathComponent
            return WorkspacePathPresentation.resolvedPath(folder) == folder
                ? [file, WorkspacePathPresentation.resolvedPath(file)] : [file]
        })
        // A mirror left behind would let recovery reimport the workspace, so
        // the record, and the credentials it needs, are kept for a retry.
        var identityUnreadable = false
        func currentIdentity(_ path: String) -> String?? {
            do { return .some(try identity(path)) } catch {
                identityUnreadable = true
                return nil
            }
        }
        let moved = movedMirrors.filter { path in
            guard !liveMirrors.contains(path), !liveMirrors.contains(WorkspacePathPresentation.resolvedPath(path)),
                  case .some(.some(let current)) = currentIdentity(path) else { return false }
            return record.mirrorFileIDs.contains(current)
        }
        // A pinned path whose file has another identity than the one pinned
        // is a mirror created there since, such as a new workspace's after
        // the folder was replaced, and is left alone. A missing one is
        // confirmed absent by the removal.
        let pinnedFiles = record.mirrorFiles.filter { path in
            guard !liveMirrors.contains(path) else { return false }
            guard !record.mirrorFileIDs.isEmpty else { return true }
            switch currentIdentity(path) {
            case .none: return false
            case .some(.none): return true
            case .some(.some(let current)): return record.mirrorFileIDs.contains(current)
            }
        }
        if identityUnreadable {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "mirror_identity_unreadable"
            ], level: .error)
            return false
        }
        if !removeMirrors(pinnedFiles) || !removeMovedMirrors(moved) {
            AuditLoggingSeam.required.audit(.workspaceRecoveryFailed, category: "Persistence", fields: [
                "operation": "delete_workspace", "reason": "mirror_removal_failed"
            ], level: .error)
            return false
        }
        // Only a live Outlook connector keeps the mail-registry entry its ID
        // names; an import that reused the ID for another service doesn't.
        let liveOutlookConnectors = Set(connectors.filter(\.isStanfordOutlookMail).map(\.id))
        // A recreated connector can share a stable endpoint or package
        // namespace under a new ID, so ownership is per namespace.
        let liveNamespaces = Set(connectors.flatMap { KeychainSecretStore.connectorEntityIDs(for: $0) })
        let liveSkills = Set(skills.map(\.id))
        // Every credential is attempted; any that couldn't be cleared keeps
        // the record for an idempotent retry.
        var cleared = true
        for connector in record.connectors {
            let keepRegistryEntry = liveOutlookConnectors.contains(connector.connectorID)
            // Owed when a namespace has no live owner, or a mail-registry
            // entry no live Outlook connector claims.
            let ownsRegistryEntry = connector.isStanfordOutlookMail && !keepRegistryEntry
            guard ownsRegistryEntry || !unownedNamespaces(of: connector, liveNamespaces: liveNamespaces).isEmpty
            else { continue }
            cleared = connector.run(sparing: liveNamespaces, keepRegistryEntry: keepRegistryEntry) && cleared
        }
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

    /// The Keychain namespaces `connector` resolves to that no live
    /// connector uses, which are the only ones its cleanup removes.
    static func unownedNamespaces(of connector: ConnectorKeychainCleanup, liveNamespaces: Set<String>) -> Set<String> {
        Set(KeychainSecretStore.connectorEntityIDs(
            id: connector.connectorID, serviceType: connector.serviceType, baseURL: connector.baseURL,
            originPackageID: connector.originPackageID, originComponentID: connector.originComponentID
        )).subtracting(liveNamespaces)
    }

    /// Settles deletions a quit interrupted, reading committed state through
    /// a fresh context. Startup runs this before mirror recovery.
    @discardableResult
    static func resumePending(
        modelContext: ModelContext,
        store: WorkspaceDeletionCleanupStore = WorkspaceDeletionCleanupStore(),
        movedMirrors: [String] = []
    ) -> Int {
        var settled = 0
        for record in store.pending()
        where settle(record, modelContext: ModelContext(modelContext.container), movedMirrors: movedMirrors) {
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
    /// Removes mirrors found away from their pinned path, each already
    /// matched by identity; false when one couldn't be removed.
    static func removeMovedMirrors(_ paths: [String]) -> Bool {
        paths.allSatisfy(removeConfirmingAbsence)
    }

    static func removeMirrors(_ mirrorPaths: [String]) -> Bool {
        var removedAll = true
        for path in mirrorPaths {
            switch pinnedFolderState((path as NSString).deletingLastPathComponent) {
            case .replaced: continue
            case .unknown: removedAll = false
            case .unchanged: removedAll = removeConfirmingAbsence(path) && removedAll
            }
        }
        return removedAll
    }

    /// Removes `path` itself, never what a link points to. Only a confirmed
    /// missing file counts as already removed: a stat or removal that fails
    /// for another reason, such as a folder that can't be traversed, keeps
    /// the record, since the mirror may still be there.
    private static func removeConfirmingAbsence(_ path: String) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return isMissingFile(error)
        }
    }

    private static func isMissingFile(_ error: any Error) -> Bool { WorkspaceFileLayout.isMissingFile(error) }

    enum PinnedFolder { case unchanged, replaced, unknown }

    /// Whether a pinned mirror folder, resolved when it was pinned, is still
    /// that folder: `.replaced` when it now resolves elsewhere, as after a
    /// part of it was replaced by a link, and `.unknown` when a part of it
    /// can't be read, so neither can be told. A missing part is unchanged,
    /// as nothing beneath it is left to remove.
    static func pinnedFolderState(_ folder: String) -> PinnedFolder {
        var current = folder
        while !current.isEmpty, current != "/" {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: current)
            } catch {
                guard isMissingFile(error) else { return .unknown }
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return WorkspacePathPresentation.resolvedPath(folder) == folder ? .unchanged : .replaced
    }
}
