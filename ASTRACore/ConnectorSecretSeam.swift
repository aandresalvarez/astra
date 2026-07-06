import Foundation
import os

// Added as part of Track A2.5 (finishing A2's Models cycle-break) so
// `Astra/Models/Connector.swift` can persist Keychain-backed credentials
// without depending on `Astra/Services/Capabilities/ModelSecretPersistence.swift`.
// Mirrors `SkillSecretSeam` (Track A2.4)'s design exactly.
//
// `ConnectorSecretFacts` carries only the fields the real implementation's
// stable-namespace resolution (`KeychainSecretStore.connectorEntityIDs(for:)`
// -> `stableConnectorEntityID(serviceType:baseURL:originPackageID:originComponentID:)`)
// actually reads off `Connector` - traced exhaustively, not guessed. Every
// other `Connector` field `ConnectorSecretPersistence`'s 6 original methods
// touched (`credentialKeys`/`credentialValues` mutation, `updatedAt`) stays
// in `Connector.swift` itself, which now calls this seam only for the
// Keychain I/O primitives.
public struct ConnectorSecretFacts: Sendable {
    public let id: UUID
    public let name: String
    public let serviceType: String
    public let baseURL: String
    public let originPackageID: String?
    public let originComponentID: String?

    public init(
        id: UUID,
        name: String,
        serviceType: String,
        baseURL: String,
        originPackageID: String?,
        originComponentID: String?
    ) {
        self.id = id
        self.name = name
        self.serviceType = serviceType
        self.baseURL = baseURL
        self.originPackageID = originPackageID
        self.originComponentID = originComponentID
    }
}

public enum ConnectorSecretSeam {
    private static let storage = OSAllocatedUnfairLock<(any ConnectorSecretPersisting.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ persistence: any ConnectorSecretPersisting.Type) {
        storage.withLock { $0 = persistence }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet. Safe to
    /// gate behind a trap (unlike `TaskExecutionDefaults.model` in Track
    /// A2.2): every method here runs from an explicit connector-mutation
    /// action, never a passive default-parameter construction path.
    public static var required: any ConnectorSecretPersisting.Type {
        guard let persistence = storage.withLock({ $0 }) else {
            preconditionFailure(
                "ConnectorSecretSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return persistence
    }
}

public protocol ConnectorSecretPersisting {
    /// Matches `ConnectorSecretPersistence.credentials(for:store:)`: tries
    /// every namespace `facts` resolves to, first match per key wins.
    static func loadAllCredentials(keys: [String], facts: ConnectorSecretFacts, store: SecretStore) -> [String: String]
    @discardableResult
    static func saveCredential(_ value: String, key: String, facts: ConnectorSecretFacts) -> Bool
    @discardableResult
    static func deleteCredential(key: String, facts: ConnectorSecretFacts) -> Bool
    static func credentialExists(key: String, facts: ConnectorSecretFacts) -> Bool
    /// Matches `KeychainService.load(key:connector:)`'s existing quirk:
    /// unlike `loadAllCredentials`, this bypasses the injectable
    /// `SecretStore` and always reads the real Keychain directly - existing
    /// behavior, preserved as-is, not something this seam changes.
    static func loadCredential(key: String, facts: ConnectorSecretFacts) -> String?
    static func deleteAllCredentials(facts: ConnectorSecretFacts)
    /// Matches `KeychainService.synchronizeConnectorCredentialNamespaces(connector:)`:
    /// for every key with a non-empty value in one namespace, backfill it
    /// into every other namespace `facts` resolves to.
    static func synchronizeCredentialNamespaces(keys: [String], facts: ConnectorSecretFacts)
}
