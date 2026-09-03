import Foundation
import SwiftData
import ASTRACore

/// `isRuntimeSafe(_:)` stays out of `ASTRACore/ConnectorSecurityPolicy.swift`
/// since it takes the `Connector` `@Model` type, which cannot appear in
/// `ASTRACore` (the pure, string-only `credentialTransportViolation` lives
/// there instead). Moved here from
/// `Astra/Services/Runtime/SecurityPolicies.swift` for Track A4
/// (`ASTRAPersistence`), which needs it from `WorkspaceConfigManager.swift`.
public extension ConnectorSecurityPolicy {
    static func isRuntimeSafe(_ connector: Connector) -> Bool {
        credentialTransportViolation(
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            credentialKeys: connector.credentialKeys
        ) == nil
    }
}

/// Why a credential write did or did not land. Replaces the bare `Bool` for
/// callers that need to tell "the Keychain refused us" (retryable, and the
/// user may need to grant access) apart from "this value is not a credential
/// for this service" (never retryable — the user must paste something else).
public enum ConnectorCredentialSaveOutcome: Sendable, Equatable {
    case saved
    case rejected(ConnectorCredentialAdmissionVerdict)
    case keychainWriteFailed

    public var isSaved: Bool { self == .saved }

    public var rejection: ConnectorCredentialAdmissionVerdict? {
        if case .rejected(let verdict) = self { return verdict }
        return nil
    }
}

/// Result of looking for other connectors that already hold a value, with
/// enough bookkeeping to say honestly how much of the store was actually
/// examined — a scan that silently stopped early must not read as "clean".
public struct ConnectorCredentialReuseScan: Sendable {
    public let sites: [ConnectorCredentialReuseSite]
    public let scannedConnectorCount: Int
    public let wasTruncated: Bool

    public static let notPerformed = ConnectorCredentialReuseScan(
        sites: [], scannedConnectorCount: 0, wasTruncated: false
    )
}

public extension ConnectorSecurityPolicy {
    /// Upper bound on connectors probed in one save. Each probe is a
    /// synchronous keychain read per declared key, and this runs inline on a
    /// button press; a workspace with more connectors than this reports the
    /// scan as truncated rather than pretending it found nothing.
    static let credentialReuseScanLimit = 128

    /// Finds connectors *other than* `connector` whose stored credentials
    /// already hold `value`.
    ///
    /// Only connectors of a **different** service type are probed. That is
    /// both the cheap filter (it removes almost all keychain I/O) and the
    /// correct one: ASTRA's stable keychain namespace deliberately shares one
    /// secret between equivalent same-service rows, and
    /// `CapabilitySharing.copyCredentials` duplicates a token on purpose when
    /// a connector is copied to another workspace. Same-service reuse is a
    /// feature; cross-service reuse is always a mistake.
    static func credentialReuseScan(
        for value: String,
        excluding connector: Connector,
        in context: ModelContext,
        store: SecretStore = SecretStoreSeam.required
    ) -> ConnectorCredentialReuseScan {
        let needle = ConnectorCredentialAdmission.normalized(value)
        guard !needle.isEmpty else { return .notPerformed }

        let ownService = ConnectorCredentialAdmission.normalizedServiceType(connector.serviceType)
        guard let all = try? context.fetch(FetchDescriptor<Connector>()) else {
            return .notPerformed
        }

        let candidates = all.filter { other in
            other.id != connector.id
                && ConnectorCredentialAdmission.normalizedServiceType(other.serviceType) != ownService
                && !other.credentialKeys.isEmpty
        }

        let probed = candidates.prefix(credentialReuseScanLimit)
        var sites: [ConnectorCredentialReuseSite] = []
        for other in probed {
            for (key, storedValue) in other.credentials(store: store)
            where ConnectorCredentialAdmission.normalized(storedValue) == needle {
                sites.append(ConnectorCredentialReuseSite(
                    connectorID: other.id,
                    connectorName: other.name,
                    serviceType: other.serviceType,
                    credentialKey: key
                ))
            }
        }

        return ConnectorCredentialReuseScan(
            sites: sites,
            scannedConnectorCount: probed.count,
            wasTruncated: candidates.count > probed.count
        )
    }
}
