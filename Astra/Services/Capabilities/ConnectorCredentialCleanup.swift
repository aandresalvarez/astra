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
    /// The namespaces and connector IDs that stored connectors own.
    struct Ownership {
        let namespaces: Set<String>
        let connectorIDs: Set<UUID>

        init(_ connectors: [Connector]) {
            namespaces = Set(connectors.flatMap { KeychainSecretStore.connectorEntityIDs(for: $0) })
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
    /// everything owed was cleared.
    @discardableResult
    static func run(_ cleanups: [ConnectorKeychainCleanup], ownership: Ownership) -> Bool {
        var cleared = true
        for cleanup in cleanups where !unownedNamespaces(of: cleanup, ownership: ownership).isEmpty {
            cleared = cleanup.run(
                sparing: ownership.namespaces, keepRegistryEntry: ownership.connectorIDs.contains(cleanup.connectorID)
            ) && cleared
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
