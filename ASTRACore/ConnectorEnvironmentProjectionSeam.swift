import Foundation
import os

// Added as part of Track A2.5 (finishing A2's Models cycle-break) so
// `Astra/Models/Skill.swift` can project its connectors' credentials/config
// into task-launch environment variables without depending on
// `Astra/Services/Capabilities/ConnectorRuntimeProjection.swift` (552 lines
// of alias generation, env-var collision detection, credential-exposure-
// policy enforcement, and legacy single-connector fallback — a
// security-relevant decision surface, not simple plumbing).
//
// `ConnectorEnvironmentFacts` carries every field the real
// `ConnectorRuntimeProjection.environmentVariables()` reads off a
// `Connector` (verified by reading the full 552-line implementation, not
// guessed) — including `credentialKeys`/`configKeys`/`configValues` as
// separate, order-preserving arrays exactly as `Connector` stores them:
// `environmentBindings(for:alias:)` iterates `zip(configKeys, configValues)`
// and resolves name collisions in encounter order, so collapsing config
// into an unordered `[String: String]` here would risk producing different
// generated env-var suffixes for connectors with colliding key names.
//
// `Skill.swift`'s only call site uses every default (`KeychainSecretStore()`,
// `CredentialExposurePolicy.none`, `includeLegacySingleConnectorFallback:
// false` — confirmed by reading the call site, not assumed), so this seam's
// method signature omits those knobs entirely rather than plumbing unused
// parameters across the boundary.
public struct ConnectorEnvironmentFacts: Sendable {
    public let id: UUID
    public let name: String
    public let serviceType: String
    public let baseURL: String
    public let authMethod: String
    public let credentialKeys: [String]
    public let configKeys: [String]
    public let configValues: [String]
    public let originPackageID: String?
    public let originComponentID: String?

    public init(
        id: UUID,
        name: String,
        serviceType: String,
        baseURL: String,
        authMethod: String,
        credentialKeys: [String],
        configKeys: [String],
        configValues: [String],
        originPackageID: String?,
        originComponentID: String?
    ) {
        self.id = id
        self.name = name
        self.serviceType = serviceType
        self.baseURL = baseURL
        self.authMethod = authMethod
        self.credentialKeys = credentialKeys
        self.configKeys = configKeys
        self.configValues = configValues
        self.originPackageID = originPackageID
        self.originComponentID = originComponentID
    }
}

public enum ConnectorEnvironmentProjectionSeam {
    private static let storage = OSAllocatedUnfairLock<(any ConnectorEnvironmentProjecting.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ projecting: any ConnectorEnvironmentProjecting.Type) {
        storage.withLock { $0 = projecting }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet. Safe to
    /// gate behind a trap: only reached from `Skill.resolvedAllEnvironmentVariables`,
    /// an explicit task-launch-time read, never a passive default-parameter
    /// construction path.
    public static var required: any ConnectorEnvironmentProjecting.Type {
        guard let projecting = storage.withLock({ $0 }) else {
            preconditionFailure(
                "ConnectorEnvironmentProjectionSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return projecting
    }
}

public protocol ConnectorEnvironmentProjecting {
    static func environmentVariables(for connectors: [ConnectorEnvironmentFacts]) -> [String: String]
}
