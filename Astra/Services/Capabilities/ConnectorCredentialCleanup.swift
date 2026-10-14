import CryptoKit
import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Removes deleted connectors' Keychain items once their deletion is saved,
/// leaving every namespace a stored connector still resolves to. A connector
/// recreated under a new ID shares the old one's stable endpoint or package
/// namespace, so ownership is decided per namespace, never per connector ID.
@MainActor
enum ConnectorCredentialCleanup {
    /// The namespaces stored connectors own, and the IDs of the stored
    /// Outlook connectors, which alone keep a mail-registry entry: an import
    /// that reused an Outlook connector's ID for another service doesn't.
    struct Ownership {
        let namespaces: Set<String>
        let outlookConnectorIDs: Set<UUID>
        let connectorIDs: Set<UUID>

        /// `retained` are connectors a pending workspace deletion still
        /// holds: their mirror may yet be recovered, so what they use stays.
        init(_ connectors: [Connector], retained: [ConnectorKeychainCleanup] = []) {
            namespaces = Set(connectors.flatMap { KeychainSecretStore.connectorEntityIDs(for: $0) })
                .union(retained.flatMap {
                    KeychainSecretStore.connectorEntityIDs(
                        id: $0.connectorID, serviceType: $0.serviceType, baseURL: $0.baseURL,
                        originPackageID: $0.originPackageID, originComponentID: $0.originComponentID
                    )
                })
            outlookConnectorIDs = Set(connectors.filter(\.isStanfordOutlookMail).map(\.id))
                .union(retained.filter(\.isStanfordOutlookMail).map(\.connectorID))
            connectorIDs = Set(connectors.map(\.id))
        }
    }

    /// The namespaces `connector` resolves to that nothing in `ownership`
    /// uses, which are the only ones its cleanup removes.
    static func unownedNamespaces(of connector: ConnectorKeychainCleanup, ownership: Ownership) -> Set<String> {
        Set(KeychainSecretStore.connectorEntityIDs(
            id: connector.connectorID, serviceType: connector.serviceType, baseURL: connector.baseURL,
            originPackageID: connector.originPackageID, originComponentID: connector.originComponentID
        )).subtracting(ownership.namespaces)
    }

    /// Runs each cleanup against `ownership`, attempting every one. True when
    /// everything owed was cleared. A deletion whose credentials all stay
    /// with live owners is still audited, through `auditSkipped`, as the
    /// cleanup it doesn't need would have.
    ///
    /// `committed` is whether the deletion is known to be saved. One that
    /// isn't runs nothing and reports nothing: the store it is judged against
    /// may not be the one it was recorded for, as after a store recovery, so
    /// a connector missing from it proves no deletion. At worst its
    /// credentials are left orphaned, which is recoverable.
    @discardableResult
    static func run(
        _ cleanups: [ConnectorKeychainCleanup], ownership: Ownership, committed: Bool = true,
        auditSkipped: (ConnectorKeychainCleanup) -> Void = { cleanup in
            AuditLoggingSeam.required.audit(.connectorDeleted, category: "Keychain", fields: [
                "connector_id": cleanup.connectorID.uuidString,
                "service_type": cleanup.serviceType,
                "credentials": "kept_for_live_owners"
            ])
        }
    ) -> Bool {
        var cleared = true
        for cleanup in cleanups {
            if !committed { continue }
            let keepRegistryEntry = ownership.outlookConnectorIDs.contains(cleanup.connectorID)
            // Owed when a namespace has no live owner, or a mail-registry
            // entry no live Outlook connector claims.
            let ownsRegistryEntry = cleanup.isStanfordOutlookMail && !keepRegistryEntry
            guard ownsRegistryEntry || !unownedNamespaces(of: cleanup, ownership: ownership).isEmpty else {
                auditSkipped(cleanup)
                continue
            }
            cleared = cleanup.run(sparing: ownership.namespaces, keepRegistryEntry: keepRegistryEntry) && cleared
        }
        return cleared
    }

    /// Runs `cleanups` against the connectors `modelContext` stores, which
    /// must already reflect the saved deletion, and those pending workspace
    /// deletions still hold (`retained`, by default read from the app's
    /// deletion outbox). When either can't be read nothing is removed: an
    /// orphaned credential is recoverable, one a live connector still reads
    /// is not.
    @discardableResult
    static func run(
        _ cleanups: [ConnectorKeychainCleanup], modelContext: ModelContext, retained: [ConnectorKeychainCleanup]? = nil,
        committed: Bool = true
    ) -> Bool {
        guard !cleanups.isEmpty else { return true }
        guard let retained = retained ?? retainedByPendingWorkspaceDeletions(modelContext: modelContext) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "workspace_deletion_unreadable",
                "connector_count": String(cleanups.count)
            ], level: .error)
            return false
        }
        guard let stored = try? modelContext.fetch(FetchDescriptor<Connector>()) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "store_unreadable",
                "connector_count": String(cleanups.count)
            ], level: .error)
            return false
        }
        return run(cleanups, ownership: Ownership(stored, retained: retained), committed: committed)
    }

    /// The connectors pending workspace deletions hold, whose mirrors startup
    /// left out of recovery. Read only by the app, which tracks recovery; a
    /// process that doesn't, such as a test, has none. Nil when a record
    /// can't be read.
    private static func retainedByPendingWorkspaceDeletions(modelContext: ModelContext) -> [ConnectorKeychainCleanup]? {
        guard WorkspaceRecoveryTrust.state != .notTracked else { return [] }
        return WorkspaceDeletionCleanupStore(for: modelContext).pendingConnectors()
    }

    /// Deletes connectors durably: `cleanups` are recorded before `save`,
    /// taken back when it fails, and cleared once they run. Any that don't
    /// clear wait in `store`, by default the outbox for `modelContext`'s
    /// store, for `resumePending`. False, with nothing recorded, when the
    /// deletion wasn't saved; the caller rolls it back.
    ///
    /// The cleanup runs at once only while `cleansNow`. In the app it never
    /// does by default: a connector only a mirror not yet imported holds
    /// could share a namespace, and the workspace mirrors this deletion
    /// rewrites are exported after the save, off this path, so one may still
    /// name the connector. The intent waits for the next trusted launch's
    /// `resumePending`, by which time an export that landed has dropped it
    /// and one that didn't restores a connector that then owns what it uses.
    /// A process that doesn't track recovery, as a test, cleans at once.
    @discardableResult
    static func deleteThenClean(
        _ cleanups: [ConnectorKeychainCleanup],
        modelContext: ModelContext,
        store: ConnectorCredentialCleanupStore? = nil,
        cleansNow: Bool? = nil,
        save: () -> Bool
    ) -> Bool {
        let cleansNow = cleansNow ?? (WorkspaceRecoveryTrust.state == .notTracked)
        let store = store ?? ConnectorCredentialCleanupStore(for: modelContext)
        // A retry can tell a saved deletion from one never saved only by the
        // store it was recorded against, so one that can't be identified
        // isn't deleted.
        let storeIdentity = PersistentStoreIdentity.current(for: modelContext)
        if store != nil, storeIdentity == nil {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "store_unidentified"
            ], level: .error)
            return false
        }
        let recorded: ConnectorCredentialCleanupStore.Recording
        do {
            recorded = try store?.begin(cleanups, storeIdentity: storeIdentity) ?? ConnectorCredentialCleanupStore.Recording()
        } catch {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "intent_unwritable",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return false
        }
        guard save() else {
            store?.undo(recorded)
            return false
        }
        // Marked saved, so a retry tells this deletion from an intent whose
        // save never happened. One a quit or a failed write leaves unmarked
        // is still known saved by a retry against the same store.
        store?.markCommitted(cleanups)
        // Without an outbox there is nothing to defer to, so it runs now.
        // Once it has, the matching records go, including one an earlier
        // identical deletion left, which this run has just settled.
        if cleansNow || store == nil, run(cleanups, modelContext: modelContext) {
            store?.remove(store?.recordURLs(for: cleanups) ?? recorded.added)
        }
        return true
    }

    /// Deletes `connector` from the Configure surface. A deletion that isn't
    /// saved is rolled back with the workspace's membership arrays, which
    /// rollback doesn't restore, so no later save commits it without its
    /// cleanup. False when it was rolled back.
    @discardableResult
    static func deleteConnector(
        _ connector: Connector, in workspace: Workspace, modelContext: ModelContext,
        store: ConnectorCredentialCleanupStore? = nil,
        save: () -> Bool
    ) -> Bool {
        let membership = WorkspaceCapabilityMembershipSnapshot(workspace)
        workspace.enabledGlobalConnectorIDs.removeAll { $0 == connector.id.uuidString }
        let cleanup = connector.keychainCleanup
        modelContext.delete(connector)
        guard deleteThenClean([cleanup], modelContext: modelContext, store: store, save: save) else {
            modelContext.rollback()
            membership.restore(to: workspace)
            return false
        }
        return true
    }

    /// Retries the cleanups a failed run or a quit left, against what the
    /// store holds now. Startup calls it only once recovery is trusted, so a
    /// connector a mirror still owns counts.
    ///
    /// A record not marked saved was saved anyway when the store is the one
    /// it was recorded against and no longer holds its connector: only the
    /// saved deletion removed it. One whose connector is still stored was
    /// never saved and is dropped without running or reporting anything. One
    /// whose store has changed since, as by a recovery, can't be told apart;
    /// it is dropped too and reported, since running it could remove what a
    /// connector in the earlier store still uses, while an orphaned
    /// credential is recoverable.
    @discardableResult
    static func resumePending(
        modelContext: ModelContext, store: ConnectorCredentialCleanupStore? = nil, extraMirrors: [String]? = nil
    ) -> Int {
        guard let store = store ?? ConnectorCredentialCleanupStore(for: modelContext) else { return 0 }
        guard let pending = store.pending() else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "outbox_unreadable"
            ], level: .error)
            return 0
        }
        // A record that can't be read stays for a later launch, but never
        // holds back the ones that can.
        // A record that can't be decoded may name an owner no other record
        // shows, so nothing runs until it can be read.
        guard pending.complete else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "intent_unreadable"
            ], level: .error)
            return 0
        }
        guard let storedIDs = (try? ModelContext(modelContext.container).fetch(FetchDescriptor<Connector>())).map({ Set($0.map(\.id)) })
        else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "store_unreadable"
            ], level: .error)
            return 0
        }
        guard let workspaceRetained = retainedByPendingWorkspaceDeletions(modelContext: modelContext) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "workspace_deletion_unreadable"
            ], level: .error)
            return 0
        }
        // A deletion saved just before a quit may not have reached the
        // mirrors, and recovery leaves a stored workspace's mirror as it is;
        // a later recovery from that mirror would restore the connector
        // without its credentials. So a cleanup waits, as an owner, while a
        // stored workspace's mirror still lists its connector, and that
        // workspace is exported again for the next launch.
        guard let mirrored = connectorsInStoredMirrors(modelContext: modelContext, extraMirrors: extraMirrors) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "workspace_mirror_unreadable"
            ], level: .error)
            return 0
        }
        let classified = classify(pending.records, storedIDs: storedIDs, modelContext: modelContext)
        // One whose connector is stored again, as restored from that very
        // mirror, isn't stale: the stored connector owns what it uses.
        let stale = classified.filter {
            $0.committed && mirrored.ids.contains($0.record.cleanup.connectorID) && !storedIDs.contains($0.record.cleanup.connectorID)
        }
        let unconfirmed = classified.filter(\.unconfirmed).map(\.record.cleanup) + pending.heldBack + stale.map(\.record.cleanup)
            + mirrored.unidentified
        let staleIDs = Set(stale.map(\.record.cleanup.connectorID))
        for (workspace, listed) in mirrored.byWorkspace where !listed.isDisjoint(with: staleIDs) {
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        }
        var cleared = 0
        for entry in classified where !(entry.committed && staleIDs.contains(entry.record.cleanup.connectorID)) {
            if entry.unconfirmed {
                AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                    "scope": "connector_cleanup", "reason": "intent_unconfirmed_after_store_change",
                    "connector_id": entry.record.cleanup.connectorID.uuidString
                ], level: .error)
            }
            guard run(
                [entry.record.cleanup], modelContext: ModelContext(modelContext.container),
                retained: workspaceRetained + unconfirmed, committed: entry.committed
            ) else { continue }
            store.remove([entry.record.url])
            cleared += 1
        }
        return cleared
    }

    /// The connector IDs each stored workspace's mirror lists, and every
    /// other mirror this launch's recovery loaded (`extraMirrors`, by default
    /// those it recorded), such as an old folder's or a copy's that recovery
    /// skipped because the workspace is stored: a later recovery could
    /// restore from any of them. As owners of the namespaces they resolve
    /// to, also the connectors one lists without a valid ID, which an import
    /// gives a new ID. A missing mirror lists none; nil when one that exists
    /// can't be read.
    static func connectorsInStoredMirrors(
        modelContext: ModelContext, extraMirrors: [String]? = nil
    ) -> (ids: Set<UUID>, byWorkspace: [(Workspace, Set<UUID>)], unidentified: [ConnectorKeychainCleanup])? {
        struct Listed: Decodable {
            struct Entry: Decodable {
                let id: String?
                let name: String?
                let serviceType: String?
                let baseURL: String?
                let originPackageID: String?
                let originComponentID: String?
            }
            let connectors: [Entry]?
        }
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()) else { return nil }
        var all = Set<UUID>()
        var byWorkspace: [(Workspace, Set<UUID>)] = []
        var unidentified: [ConnectorKeychainCleanup] = []
        // Only a stored workspace's own mirror can be exported again.
        var files: [(workspace: Workspace?, path: String)] = workspaces.flatMap { workspace in
            [
                WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath),
                WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspace.primaryPath)
            ].filter { !$0.isEmpty }.map { (workspace, $0) }
        }
        let own = Set(files.map { WorkspacePathPresentation.resolvedPath($0.path) })
        for extra in Set(extraMirrors ?? WorkspaceRecoveryTrust.loadedMirrors)
        where !own.contains(WorkspacePathPresentation.resolvedPath(extra)) {
            files.append((nil, extra))
        }
        for (workspace, file) in files {
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: file))
            } catch {
                if WorkspaceFileLayout.isMissingFile(error) { continue }
                return nil
            }
            guard let listed = try? JSONDecoder().decode(Listed.self, from: data) else { return nil }
            var ids = Set<UUID>()
            for entry in listed.connectors ?? [] {
                if let id = entry.id.flatMap(UUID.init(uuidString:)) {
                    ids.insert(id)
                    continue
                }
                // Unmanaged and never inserted: only its facts are read.
                let connector = Connector(
                    name: entry.name ?? "", serviceType: entry.serviceType ?? "", baseURL: entry.baseURL ?? ""
                )
                connector.originPackageID = entry.originPackageID
                connector.originComponentID = entry.originComponentID
                unidentified.append(connector.keychainCleanup)
            }
            all.formUnion(ids)
            if let workspace { byWorkspace.append((workspace, ids)) }
        }
        return (all, byWorkspace, unidentified)
    }

    private struct Classified {
        let record: ConnectorCredentialCleanupStore.Pending.Record
        let committed: Bool
        /// From a store since replaced and not confirmed saved: its
        /// connector may still be in that store, so it keeps what it uses
        /// while the others run, even when a connector with its ID is stored
        /// now, since that one may resolve elsewhere.
        let unconfirmed: Bool
    }

    private static func classify(
        _ records: [ConnectorCredentialCleanupStore.Pending.Record], storedIDs: Set<UUID>, modelContext: ModelContext
    ) -> [Classified] {
        let currentStore = PersistentStoreIdentity.current(for: modelContext)
        return records.map { record in
            let stored = storedIDs.contains(record.cleanup.connectorID)
            let sameStore = record.storeIdentity != nil && record.storeIdentity == currentStore
            let committed = record.committed || (!stored && sameStore)
            return Classified(record: record, committed: committed, unconfirmed: !committed && !sameStore)
        }
    }

    /// The pending intents that can't be confirmed, which every other
    /// credential cleanup, a workspace deletion's included, must spare. Nil
    /// when the outbox, a record in it, or the store can't be read.
    static func unconfirmedOwners(
        modelContext: ModelContext, store: ConnectorCredentialCleanupStore? = nil
    ) -> [ConnectorKeychainCleanup]? {
        guard let store = store ?? ConnectorCredentialCleanupStore(for: modelContext) else { return [] }
        guard let pending = store.pending(), pending.complete,
              let storedIDs = (try? ModelContext(modelContext.container).fetch(FetchDescriptor<Connector>()))
                .map({ Set($0.map(\.id)) }) else { return nil }
        // Also those a stored workspace's mirror still lists, which the
        // connector pass will hold, and connectors such a mirror lists
        // without an ID, which recovery could restore from it.
        guard let mirrored = connectorsInStoredMirrors(modelContext: modelContext) else { return nil }
        return classify(pending.records, storedIDs: storedIDs, modelContext: modelContext)
            .filter {
                $0.unconfirmed || ($0.committed && mirrored.ids.contains($0.record.cleanup.connectorID)
                    && !storedIDs.contains($0.record.cleanup.connectorID))
            }
            .map(\.record.cleanup) + pending.heldBack + mirrored.unidentified
    }
}

/// Whether this launch's workspace recovery vouches for the store, so a
/// cleanup that decides ownership from it may run. Only the app tracks it:
/// `pending` from the start of launch recovery, then `trusted`,
/// `vouchedWithoutScan`, or `untrusted`. A process that never starts one, as
/// a test, isn't tracked and cleans at once.
@MainActor
enum WorkspaceRecoveryTrust {
    /// `vouchedWithoutScan`: the store held workspaces and nothing was
    /// pending, so no mirror was scanned. A workspace only a mirror holds may
    /// still share a namespace, so a cleanup waits in its outbox, whose record
    /// makes the next launch scan before it runs.
    enum State { case notTracked, pending, trusted, vouchedWithoutScan, untrusted }
    private(set) static var state: State = .notTracked

    static var allowsCleanup: Bool { allowsCleanup(in: state) }

    static func allowsCleanup(in state: State) -> Bool { state == .notTracked || state == .trusted }

    static func set(_ state: State) { self.state = state }

    /// The mirror files this launch's recovery loaded, which credential
    /// cleanup reconciles along with the stored workspaces' own.
    private(set) static var loadedMirrors: [String] = []

    static func recordLoadedMirrors(_ mirrors: [String]) { loadedMirrors = mirrors }
}

/// An app-owned outbox of connector credential cleanups, one atomic record
/// per cleanup, outside provider-writable paths.
struct ConnectorCredentialCleanupStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// The outbox for the SwiftData store `modelContext` writes to. Nil for
    /// a store kept only in memory, whose deletions no record should outlive.
    @MainActor
    init?(for modelContext: ModelContext) {
        guard let configuration = modelContext.container.configurations.first(where: { !$0.isStoredInMemoryOnly })
        else { return nil }
        self.init(directory: Self.directory(
            forStoreAt: configuration.url, applicationSupport: WorkspaceRecoveryService.applicationSupportDirectory
        ))
    }

    /// The app's own store, the active one or a recovery's replacement, both
    /// inside its Application Support folder, shares one outbox there: a
    /// recovery that moves the store must not strand deletions it already
    /// committed. Any other store, such as a scratch copy, keeps one beside it.
    static func directory(forStoreAt store: URL, applicationSupport: URL) -> URL {
        let support = applicationSupport.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = store.standardizedFileURL.resolvingSymlinksInPath().path
        let root = resolved.hasPrefix(support.path + "/") ? support : store.deletingLastPathComponent()
        return root.appendingPathComponent("ConnectorCredentialCleanup", isDirectory: true)
    }

    /// Writes each cleanup not already pending and returns the files this
    /// call added, which are all a failed save takes back. One already
    /// there must read back as the same cleanup; one that can't, or can't
    /// be checked at all, throws, so the deletion isn't saved behind an
    /// intent that could never be retried.
    ///
    /// `storeIdentity` is the store the deletion is about to be saved to,
    /// kept beside each new record: a retry against that same store can then
    /// tell a deletion saved just before a quit from one never saved.
    func record(_ cleanups: [ConnectorKeychainCleanup], storeIdentity: String? = nil) throws -> [URL] {
        try begin(cleanups, storeIdentity: storeIdentity).added
    }

    /// What one `begin` changed: the records it added, and the store marks
    /// of reused records it rewrote, with what they held before.
    struct Recording {
        var added: [URL] = []
        var replacedStoreMarks: [(record: URL, previous: Data?)] = []
    }

    /// `record`, returning what a failed save must take back with `undo`.
    func begin(_ cleanups: [ConnectorKeychainCleanup], storeIdentity: String? = nil) throws -> Recording {
        var recording = Recording()
        guard !cleanups.isEmpty else { return recording }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        do {
            for cleanup in cleanups {
                let data = try Self.encode(cleanup)
                let url = recordURL(for: cleanup, data: data)
                do {
                    _ = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard try JSONDecoder().decode(ConnectorKeychainCleanup.self, from: Data(contentsOf: url)) == cleanup
                    else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
                    // Reused for this attempt, so it names this attempt's store;
                    // a failed save puts the earlier one back.
                    if let storeIdentity {
                        let mark = Self.storeMark(for: url)
                        let previous: Data?
                        do {
                            previous = try Data(contentsOf: mark)
                        } catch where WorkspaceFileLayout.isMissingFile(error) {
                            previous = nil
                        }
                        try Data(storeIdentity.utf8).write(to: mark, options: .atomic)
                        recording.replacedStoreMarks.append((url, previous))
                    }
                    continue
                } catch where WorkspaceFileLayout.isMissingFile(error) {}
                try data.write(to: url, options: .atomic)
                recording.added.append(url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                if let storeIdentity { try Data(storeIdentity.utf8).write(to: Self.storeMark(for: url), options: .atomic) }
            }
        } catch {
            undo(recording)
            throw error
        }
        return recording
    }

    /// Takes back what `begin` changed, for a deletion that wasn't saved.
    func undo(_ recording: Recording) {
        remove(recording.added)
        for (record, previous) in recording.replacedStoreMarks {
            let mark = Self.storeMark(for: record)
            if let previous {
                try? previous.write(to: mark, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: mark)
            }
        }
    }

    func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: Self.commitMark(for: url))
            try? FileManager.default.removeItem(at: Self.storeMark(for: url))
        }
    }

    /// Where the records of `cleanups` are, whether or not they exist.
    func recordURLs(for cleanups: [ConnectorKeychainCleanup]) -> [URL] {
        cleanups.compactMap { cleanup in (try? Self.encode(cleanup)).map { recordURL(for: cleanup, data: $0) } }
    }

    /// Marks the records of `cleanups` as deletions that were saved, beside
    /// each record, so its own content and name stay what `record` wrote.
    func markCommitted(_ cleanups: [ConnectorKeychainCleanup]) {
        for record in recordURLs(for: cleanups) {
            let mark = Self.commitMark(for: record)
            do {
                try Data().write(to: mark, options: .atomic)
            } catch {
                AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                    "scope": "connector_cleanup", "reason": "commit_mark_unwritable",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
    }

    private static func commitMark(for record: URL) -> URL {
        record.appendingPathExtension("committed")
    }

    private static func storeMark(for record: URL) -> URL {
        record.appendingPathExtension("store")
    }

    /// Every readable pending cleanup, and whether that was all of them: a
    /// record that can't be read is left on disk and only marks the listing
    /// incomplete, so it never holds back the others. Nil when the outbox
    /// itself can't be listed.
    func pending() -> Pending? {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            guard WorkspaceFileLayout.isMissingFile(error) else { return nil }
            return Pending(records: [], heldBack: [], complete: true)
        }
        var records: [Pending.Record] = []
        var heldBack: [ConnectorKeychainCleanup] = []
        var complete = true
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            guard let cleanup = try? JSONDecoder().decode(ConnectorKeychainCleanup.self, from: Data(contentsOf: url)) else {
                complete = false
                continue
            }
            // A mark that can't be checked leaves the record for later, and
            // its cleanup held back as an owner of what it names meanwhile:
            // the store it names may still hold that connector.
            let committed: Bool
            do {
                _ = try FileManager.default.attributesOfItem(atPath: Self.commitMark(for: url).path)
                committed = true
            } catch where WorkspaceFileLayout.isMissingFile(error) {
                committed = false
            } catch {
                heldBack.append(cleanup)
                continue
            }
            // Only a store mark confirmed missing is unknown.
            let storeIdentity: String?
            do {
                storeIdentity = String(decoding: try Data(contentsOf: Self.storeMark(for: url)), as: UTF8.self)
            } catch where WorkspaceFileLayout.isMissingFile(error) {
                storeIdentity = nil
            } catch {
                heldBack.append(cleanup)
                continue
            }
            records.append(Pending.Record(url: url, cleanup: cleanup, committed: committed, storeIdentity: storeIdentity))
        }
        return Pending(records: records, heldBack: heldBack, complete: complete)
    }

    struct Pending {
        struct Record {
            let url: URL
            let cleanup: ConnectorKeychainCleanup
            /// Whether its deletion is marked saved.
            let committed: Bool
            /// The store it was recorded against, when known.
            let storeIdentity: String?
        }
        let records: [Record]
        /// Readable cleanups whose marks can't be read: not run, but owners
        /// of what they name until they can be.
        let heldBack: [ConnectorKeychainCleanup]
        /// False when a record couldn't be read and was left out.
        let complete: Bool
    }

    private static func encode(_ cleanup: ConnectorKeychainCleanup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(cleanup)
    }

    /// Keyed by content, so a connector deleted again under the same ID
    /// with other namespaces keeps both cleanups.
    private func recordURL(for cleanup: ConnectorKeychainCleanup, data: Data) -> URL {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(cleanup.connectorID.uuidString.lowercased() + "-" + digest + ".json")
    }
}
