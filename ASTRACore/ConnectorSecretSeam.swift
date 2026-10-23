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
public struct ConnectorSecretFacts: Sendable, Equatable {
    public let id: UUID
    /// Nil retains the historical UUID/endpoint aliases. A generation is
    /// exclusive: it never falls back into another account's legacy slots.
    public let credentialNamespaceID: UUID?
    /// Interpretation of Outlook's internal token store; generic credential
    /// reads never use this to add fallback namespaces.
    public let outlookCredentialFormat: String?
    public let includesOutlookCredentials: Bool
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
        originComponentID: String?,
        credentialNamespaceID: UUID? = nil,
        outlookCredentialFormat: String? = nil,
        includesOutlookCredentials: Bool = true
    ) {
        self.id = id
        self.credentialNamespaceID = credentialNamespaceID
        self.outlookCredentialFormat = outlookCredentialFormat
        self.includesOutlookCredentials = includesOutlookCredentials
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
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return persistence
    }
}

public protocol ConnectorSecretPersisting: Sendable {
    /// Matches `ConnectorSecretPersistence.credentials(for:store:)`: tries
    /// every namespace `facts` resolves to, first match per key wins.
    static func loadAllCredentials(keys: [String], facts: ConnectorSecretFacts, store: SecretStore) -> [String: String]
    /// A refused vault read must not be treated as an unconfigured key.
    static func readCredential(key: String, facts: ConnectorSecretFacts, store: SecretStore) -> SecretReadOutcome
    @discardableResult
    static func saveCredential(_ value: String, key: String, facts: ConnectorSecretFacts, allowUserInteraction: Bool) -> Bool
    /// The same write, reporting why it failed rather than only that it did.
    /// Callers with a human waiting on the answer should use this one; see
    /// `KeychainWriteOutcome`.
    @discardableResult
    static func saveCredentialReportingFailure(
        _ value: String,
        key: String,
        facts: ConnectorSecretFacts,
        allowUserInteraction: Bool
    ) -> KeychainWriteOutcome
    /// Store-injectable twin of `saveCredential(_:key:facts:allowUserInteraction:)`,
    /// used only by `Connector`'s test seam (`saveCredential(key:value:store:)`)
    /// so tests can exercise the same per-namespace fan-out with a fake
    /// `SecretStore` instead of the real Keychain.
    @discardableResult
    static func saveCredential(_ value: String, key: String, facts: ConnectorSecretFacts, store: SecretStore) -> Bool
    @discardableResult
    static func deleteCredential(key: String, facts: ConnectorSecretFacts) -> Bool
    /// Store-injectable twin of `deleteCredential(key:facts:)`, as
    /// `saveCredential(_:key:facts:store:)` is of the save: every namespace
    /// `facts` resolves to.
    @discardableResult
    static func deleteCredential(key: String, facts: ConnectorSecretFacts, store: SecretStore) -> Bool
    static func credentialExists(key: String, facts: ConnectorSecretFacts) -> Bool
    /// Matches `KeychainService.load(key:connector:)`'s existing quirk:
    /// unlike `loadAllCredentials`, this bypasses the injectable
    /// `SecretStore` and always reads the real Keychain directly - existing
    /// behavior, preserved as-is, not something this seam changes.
    static func loadCredential(key: String, facts: ConnectorSecretFacts) -> String?
    static func deleteAllCredentials(facts: ConnectorSecretFacts)
    /// A requirement, so the registered persistence's real result is used.
    /// Namespaces in `sparing` are kept.
    static func deleteAllCredentialsReportingResult(facts: ConnectorSecretFacts, sparing: Set<String>) -> Bool
    /// Matches `KeychainService.synchronizeConnectorCredentialNamespaces(connector:)`:
    /// for every key with a non-empty value in one namespace, backfill it
    /// into every other namespace `facts` resolves to.
    static func synchronizeCredentialNamespaces(keys: [String], facts: ConnectorSecretFacts)
}

public extension ConnectorSecretPersisting {
    static func readCredential(key: String, facts: ConnectorSecretFacts, store: SecretStore) -> SecretReadOutcome {
        loadAllCredentials(keys: [key], facts: facts, store: store)[key].map(SecretReadOutcome.value) ?? .missing
    }

    /// `deleteAllCredentials` reporting whether every namespace was cleared.
    /// Defaulted to success so test fakes keep compiling; a fake can't
    /// delete selectively, so it deletes nothing while anything is spared.
    static func deleteAllCredentialsReportingResult(facts: ConnectorSecretFacts, sparing: Set<String>) -> Bool {
        if sparing.isEmpty { deleteAllCredentials(facts: facts) }
        return true
    }

    /// Defaulted so a conformer that has no real Keychain under it — every test
    /// fake — keeps compiling and keeps behaving exactly as before. "It failed
    /// and I have nothing to say about why" is the honest answer from a fake,
    /// and it is the answer the UI already assumes when no diagnosis arrives.
    @discardableResult
    static func saveCredentialReportingFailure(
        _ value: String,
        key: String,
        facts: ConnectorSecretFacts,
        allowUserInteraction: Bool
    ) -> KeychainWriteOutcome {
        saveCredential(value, key: key, facts: facts, allowUserInteraction: allowUserInteraction)
            ? .written
            : .failed(diagnosis: nil)
    }
}
