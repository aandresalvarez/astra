import Foundation
import os

// Value boundary for an explicit connection check. The adapter receives the
// exact captured generation and first-match configuration, never a live row.
public struct ConnectorOutlookFacts: Sendable, Equatable {
    public let id: UUID
    public let credentialNamespaceID: UUID?
    public let outlookCredentialFormat: String?
    public let name: String
    public let serviceType: String
    /// `configKeys`/`configValues` as `Connector` itself stores them -
    /// parallel arrays, not a collapsed dictionary. `Connector.configValue(_:)`
    /// resolves duplicate keys via `firstIndex(of:)` (first match wins); a
    /// `[String: String]` built from `zip(configKeys, configValues)` would
    /// collapse duplicates last-wins instead, silently reading a different
    /// tenant/client/scopes value than the live `self.outlookTenantDomain`/
    /// `.outlookClientID`/etc. would for connectors with duplicate config
    /// rows (verified real risk, not hypothetical - see this seam's
    /// introducing PR review thread).
    public let configKeys: [String]
    public let configValues: [String]

    public init(id: UUID, name: String, serviceType: String, configKeys: [String], configValues: [String], credentialNamespaceID: UUID? = nil, outlookCredentialFormat: String? = nil) {
        self.id = id
        self.credentialNamespaceID = credentialNamespaceID
        self.outlookCredentialFormat = outlookCredentialFormat ?? OutlookCredentialIdentity.format(keys: configKeys, values: configValues)
        self.name = name
        self.serviceType = serviceType
        self.configKeys = configKeys
        self.configValues = configValues
    }
}

public struct OutlookConnectionResult: Sendable {
    public let mail: String?
    public let userPrincipalName: String?
    /// Only the config keys the flow actually wrote (account ID, display
    /// name, email, token-refresh housekeeping, scopes) - never the whole
    /// config state. `Connector.swift` applies each via `setConfigValue`
    /// after the `await` returns, so any other config edit made to the
    /// live connector while the network call was in flight survives -
    /// applying the *full* pre-`await` config snapshot wholesale would
    /// silently roll a concurrent edit back (real risk found in this
    /// seam's introducing PR review, not hypothetical).
    public let changedConfigEntries: [String: String]

    public init(mail: String?, userPrincipalName: String?, changedConfigEntries: [String: String]) {
        self.mail = mail
        self.userPrincipalName = userPrincipalName
        self.changedConfigEntries = changedConfigEntries
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
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return tester
    }
}

public protocol OutlookMailConnectionTesting: Sendable {
    static func testConnection(facts: ConnectorOutlookFacts) async throws -> OutlookConnectionResult
    /// Matches `StanfordOutlookMailRegistry.remove(connectorID:)`, already
    /// primitive (`UUID`-only) in its real form. False when the entry may
    /// still be there, so a durable cleanup can retry it.
    @discardableResult
    static func removeFromRegistry(connectorID: UUID) -> Bool
}
