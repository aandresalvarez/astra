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
    /// The cleanup runs at once only while `cleansNow`, by default whenever
    /// launch recovery vouches for the store: before that, a connector that
    /// exists only in a mirror not yet imported could share a namespace, so
    /// the intent waits for the trusted launch's `resumePending`.
    @discardableResult
    static func deleteThenClean(
        _ cleanups: [ConnectorKeychainCleanup],
        modelContext: ModelContext,
        store: ConnectorCredentialCleanupStore? = nil,
        cleansNow: Bool? = nil,
        save: () -> Bool
    ) -> Bool {
        let cleansNow = cleansNow ?? WorkspaceRecoveryTrust.allowsCleanup
        let store = store ?? ConnectorCredentialCleanupStore(for: modelContext)
        let recorded: [URL]
        do {
            recorded = try store?.record(cleanups, storeIdentity: PersistentStoreIdentity.current(for: modelContext)) ?? []
        } catch {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "intent_unwritable",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return false
        }
        guard save() else {
            store?.remove(recorded)
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
            store?.remove(store?.recordURLs(for: cleanups) ?? recorded)
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
    static func resumePending(modelContext: ModelContext, store: ConnectorCredentialCleanupStore? = nil) -> Int {
        guard let store = store ?? ConnectorCredentialCleanupStore(for: modelContext) else { return 0 }
        guard let pending = store.pending() else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "outbox_unreadable"
            ], level: .error)
            return 0
        }
        // A record that can't be read stays for a later launch, but never
        // holds back the ones that can.
        if !pending.complete {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "intent_unreadable"
            ], level: .error)
        }
        guard let storedIDs = (try? ModelContext(modelContext.container).fetch(FetchDescriptor<Connector>())).map({ Set($0.map(\.id)) })
        else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "store_unreadable"
            ], level: .error)
            return 0
        }
        let currentStore = PersistentStoreIdentity.current(for: modelContext)
        var cleared = 0
        for record in pending.records {
            let stored = storedIDs.contains(record.cleanup.connectorID)
            let sameStore = record.storeIdentity != nil && record.storeIdentity == currentStore
            if !record.committed, !stored, !sameStore {
                AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                    "scope": "connector_cleanup", "reason": "intent_unconfirmed_after_store_change",
                    "connector_id": record.cleanup.connectorID.uuidString
                ], level: .error)
            }
            let committed = record.committed || (!stored && sameStore)
            guard run([record.cleanup], modelContext: ModelContext(modelContext.container), committed: committed) else { continue }
            store.remove([record.url])
            cleared += 1
        }
        return cleared
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
        guard !cleanups.isEmpty else { return [] }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var added: [URL] = []
        do {
            for cleanup in cleanups {
                let data = try Self.encode(cleanup)
                let url = recordURL(for: cleanup, data: data)
                do {
                    _ = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard try JSONDecoder().decode(ConnectorKeychainCleanup.self, from: Data(contentsOf: url)) == cleanup
                    else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
                    continue
                } catch where WorkspaceFileLayout.isMissingFile(error) {}
                try data.write(to: url, options: .atomic)
                added.append(url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                if let storeIdentity { try Data(storeIdentity.utf8).write(to: Self.storeMark(for: url), options: .atomic) }
            }
        } catch {
            remove(added)
            throw error
        }
        return added
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
            return Pending(records: [], complete: true)
        }
        var records: [Pending.Record] = []
        var complete = true
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            guard let cleanup = try? JSONDecoder().decode(ConnectorKeychainCleanup.self, from: Data(contentsOf: url)) else {
                complete = false
                continue
            }
            // A mark that can't be checked leaves the record for later.
            let committed: Bool
            do {
                _ = try FileManager.default.attributesOfItem(atPath: Self.commitMark(for: url).path)
                committed = true
            } catch where WorkspaceFileLayout.isMissingFile(error) {
                committed = false
            } catch {
                complete = false
                continue
            }
            let storeIdentity = (try? Data(contentsOf: Self.storeMark(for: url))).map { String(decoding: $0, as: UTF8.self) }
            records.append(Pending.Record(url: url, cleanup: cleanup, committed: committed, storeIdentity: storeIdentity))
        }
        return Pending(records: records, complete: complete)
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
