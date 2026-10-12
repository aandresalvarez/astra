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

        init(_ connectors: [Connector]) {
            namespaces = Set(connectors.flatMap { KeychainSecretStore.connectorEntityIDs(for: $0) })
            outlookConnectorIDs = Set(connectors.filter(\.isStanfordOutlookMail).map(\.id))
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
    /// everything owed was cleared.
    @discardableResult
    static func run(_ cleanups: [ConnectorKeychainCleanup], ownership: Ownership) -> Bool {
        var cleared = true
        for cleanup in cleanups {
            let keepRegistryEntry = ownership.outlookConnectorIDs.contains(cleanup.connectorID)
            // Owed when a namespace has no live owner, or a mail-registry
            // entry no live Outlook connector claims.
            let ownsRegistryEntry = cleanup.isStanfordOutlookMail && !keepRegistryEntry
            guard ownsRegistryEntry || !unownedNamespaces(of: cleanup, ownership: ownership).isEmpty else { continue }
            cleared = cleanup.run(sparing: ownership.namespaces, keepRegistryEntry: keepRegistryEntry) && cleared
        }
        return cleared
    }

    /// Runs `cleanups` against the connectors `modelContext` stores, which
    /// must already reflect the saved deletion. When they can't be read
    /// nothing is removed: an orphaned credential is recoverable, one a
    /// live connector still reads is not.
    @discardableResult
    static func run(_ cleanups: [ConnectorKeychainCleanup], modelContext: ModelContext) -> Bool {
        guard !cleanups.isEmpty else { return true }
        guard let stored = try? modelContext.fetch(FetchDescriptor<Connector>()) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "store_unreadable",
                "connector_count": String(cleanups.count)
            ], level: .error)
            return false
        }
        return run(cleanups, ownership: Ownership(stored))
    }

    /// Deletes connectors durably: `cleanups` are recorded before `save`,
    /// taken back when it fails, and cleared once they run. Any that don't
    /// clear wait in `store`, by default the outbox beside `modelContext`'s
    /// store, for `resumePending`. False, with nothing recorded, when the
    /// deletion wasn't saved; the caller rolls it back.
    @discardableResult
    static func deleteThenClean(
        _ cleanups: [ConnectorKeychainCleanup],
        modelContext: ModelContext,
        store: ConnectorCredentialCleanupStore? = nil,
        save: () -> Bool
    ) -> Bool {
        let store = store ?? ConnectorCredentialCleanupStore(beside: modelContext)
        let recorded: [URL]
        do {
            recorded = try store?.record(cleanups) ?? []
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
        if run(cleanups, modelContext: modelContext) { store?.remove(recorded) }
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
    /// connector a mirror still owns counts. A record whose deletion was
    /// never saved is harmless: its connector is stored and keeps all it uses.
    @discardableResult
    static func resumePending(modelContext: ModelContext, store: ConnectorCredentialCleanupStore? = nil) -> Int {
        guard let store = store ?? ConnectorCredentialCleanupStore(beside: modelContext) else { return 0 }
        guard let pending = store.pending() else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_cleanup", "reason": "intent_unreadable"
            ], level: .error)
            return 0
        }
        var cleared = 0
        for (url, cleanup) in pending where run([cleanup], modelContext: ModelContext(modelContext.container)) {
            store.remove([url])
            cleared += 1
        }
        return cleared
    }
}

/// An app-owned outbox of connector credential cleanups, one atomic record
/// per cleanup, outside provider-writable paths.
struct ConnectorCredentialCleanupStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// The outbox beside the SwiftData store `modelContext` writes to, so
    /// its records always describe that store's deletions. Nil for a store
    /// kept only in memory, whose deletions no record should outlive.
    @MainActor
    init?(beside modelContext: ModelContext) {
        guard let configuration = modelContext.container.configurations.first(where: { !$0.isStoredInMemoryOnly })
        else { return nil }
        self.init(directory: configuration.url.deletingLastPathComponent()
            .appendingPathComponent("ConnectorCredentialCleanup", isDirectory: true))
    }

    /// Writes each cleanup not already pending and returns the files this
    /// call added, which are all a failed save takes back. One already
    /// there, or one that can't be checked, is left as it is.
    func record(_ cleanups: [ConnectorKeychainCleanup]) throws -> [URL] {
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
                    continue
                } catch where WorkspaceFileLayout.isMissingFile(error) {}
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                added.append(url)
            }
        } catch {
            remove(added)
            throw error
        }
        return added
    }

    func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Every pending cleanup, or nil when the outbox or a record can't be
    /// read, since what it owes is then unknown.
    func pending() -> [(url: URL, cleanup: ConnectorKeychainCleanup)]? {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            return WorkspaceFileLayout.isMissingFile(error) ? [] : nil
        }
        var pending: [(url: URL, cleanup: ConnectorKeychainCleanup)] = []
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            guard let cleanup = try? JSONDecoder().decode(ConnectorKeychainCleanup.self, from: Data(contentsOf: url)) else {
                return nil
            }
            pending.append((url, cleanup))
        }
        return pending
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
