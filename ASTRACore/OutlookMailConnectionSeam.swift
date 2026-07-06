import Foundation
import os

// Added as part of Track A2.5 (finishing A2's Models cycle-break) so
// `Astra/Models/Connector.swift` can test/refresh a Stanford Outlook mail
// connection without depending on
// `Astra/Services/Capabilities/StanfordOutlookMail.swift`'s
// `StanfordOutlookMailGraphService`/`StanfordOutlookMailAuthService`/
// `StanfordOutlookMailRegistry` (OAuth token exchange, Keychain-backed
// refresh-token storage, and a JSON-file account registry - all
// deliberately app-side).
//
// Unlike the other Track A2.x seams, the concrete implementation registered
// for this one does NOT hand-translate the existing OAuth/Graph flow into
// primitives - that flow is deeply nested (`validAccessToken` ->
// `refreshAccessToken` -> `saveTokenResponse`, each reading/writing several
// `Connector` config keys) and re-deriving it field-by-field would be far
// more error-prone than reusing it unchanged. Instead, the registered
// implementation reconstructs a throwaway, never-persisted `Connector`
// from `ConnectorOutlookFacts`, runs the real, existing
// `StanfordOutlookMailGraphService.testConnection(connector:)` on it
// unchanged, and reports back the resulting config. This is safe because
// Keychain entries are addressed by a computed entity-ID string (derived
// from `id`/`serviceType`/`baseURL`/origin fields - see
// `KeychainSecretStore.connectorEntityIDs(for:)`), not by Swift object
// identity, so the throwaway connector resolves to the exact same
// Keychain-stored tokens as the real one.
public struct ConnectorOutlookFacts: Sendable {
    public let id: UUID
    public let name: String
    public let serviceType: String
    /// All of the connector's config key/value pairs (tenant domain,
    /// client ID, scopes, previously-stored email, etc.) - enough to
    /// reconstruct a working stand-in `Connector`.
    public let config: [String: String]

    public init(id: UUID, name: String, serviceType: String, config: [String: String]) {
        self.id = id
        self.name = name
        self.serviceType = serviceType
        self.config = config
    }
}

public struct OutlookConnectionResult: Sendable {
    public let mail: String?
    public let userPrincipalName: String?
    /// The full config key/value state after the connection flow (token
    /// refresh, account ID/display name/email discovery, etc.) - apply via
    /// `Connector.setConfigValue` for every entry, mirroring however many
    /// keys the underlying flow actually wrote.
    public let updatedConfig: [String: String]

    public init(mail: String?, userPrincipalName: String?, updatedConfig: [String: String]) {
        self.mail = mail
        self.userPrincipalName = userPrincipalName
        self.updatedConfig = updatedConfig
    }
}

public enum OutlookMailConnectionSeam {
    private static let storage = OSAllocatedUnfairLock<(any OutlookMailConnectionTesting.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ tester: any OutlookMailConnectionTesting.Type) {
        storage.withLock { $0 = tester }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet. Safe to
    /// gate behind a trap: only reached from `Connector.testConnection()`'s
    /// explicit Stanford-Outlook-Mail branch, an explicit user/test action.
    public static var required: any OutlookMailConnectionTesting.Type {
        guard let tester = storage.withLock({ $0 }) else {
            preconditionFailure(
                "OutlookMailConnectionSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return tester
    }
}

public protocol OutlookMailConnectionTesting {
    static func testConnection(facts: ConnectorOutlookFacts) async throws -> OutlookConnectionResult
    /// Matches `StanfordOutlookMailRegistry.remove(connectorID:)`, already
    /// primitive (`UUID`-only) in its real form.
    static func removeFromRegistry(connectorID: UUID)
}
