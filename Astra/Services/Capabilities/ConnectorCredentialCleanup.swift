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
}
