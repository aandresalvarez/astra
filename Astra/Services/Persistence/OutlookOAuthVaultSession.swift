import Foundation
import ASTRACore

/// One fixed authorization in ASTRA's dedicated vault. Keep this object alive
/// across a refresh request and its final write. Cleanup takes the same lease.
public final class OutlookOAuthVaultSession {
    public enum Failure: Error { case unavailable, invalidSession, contextMismatch }
    public let reference: OutlookCredentialIdentity.Reference
    private let lease: KeychainOAuthSessionLease
    private var service: String { KeychainSecretStore.connectorEntityID(for: reference.namespaceID) }

    public init(reference: OutlookCredentialIdentity.Reference) throws {
        self.reference = reference
        lease = try KeychainOAuthSessionLease.acquire(namespaceID: reference.namespaceID)
    }

    /// Only a provably absent bundle in the historical logical namespace may
    /// use legacy fields. Corrupt or unavailable bundles never trigger fallback.
    public func load(tenantDomain: String, clientID: String, principalID: String?) throws -> OutlookOAuthBundle? {
        switch AstraSecureKeychainStore.read(service: service, account: OutlookOAuthBundle.storageKey) {
        case .unavailable: throw Failure.unavailable
        case .value(let json):
            guard let data = json.data(using: .utf8), let bundle = try? JSONDecoder().decode(OutlookOAuthBundle.self, from: data),
                  bundle.isSupported else { throw Failure.invalidSession }
            guard bundle.matches(tenantDomain: tenantDomain, clientID: clientID, principalID: principalID) else { throw Failure.contextMismatch }
            return bundle
        case .missing:
            guard case .legacy = reference else { return nil }
            let fields = try OutlookCredentialIdentity.legacyTokenKeys.map { key -> String? in
                switch AstraSecureKeychainStore.read(service: service, account: key) {
                case .unavailable: throw Failure.unavailable
                case .missing: return nil
                case .value(let value): return value
                }
            }
            guard fields.contains(where: { $0 != nil }) else { return nil }
            guard let access = fields[0], !access.isEmpty, let expiry = fields[2].flatMap(TimeInterval.init), expiry.isFinite,
                  !tenantDomain.isEmpty, !clientID.isEmpty else { throw Failure.invalidSession }
            return OutlookOAuthBundle(tenantDomain: tenantDomain, clientID: clientID, principalID: principalID ?? "",
                accessToken: access, refreshToken: fields[1], expiresAt: Date(timeIntervalSince1970: expiry))
        }
    }

    /// One item replacement is atomic. Tokens never enter credentialKeys or
    /// the agent environment, and failed writes leave the prior item intact.
    @discardableResult
    public func save(_ bundle: OutlookOAuthBundle, allowUserInteraction: Bool = false) throws -> Bool {
        guard bundle.isSupported else { throw Failure.invalidSession }
        switch AstraSecureKeychainStore.read(service: service, account: OutlookOAuthBundle.storageKey) {
        case .unavailable: throw Failure.unavailable
        case .missing: break
        case .value(let json):
            guard let data = json.data(using: .utf8), let previous = try? JSONDecoder().decode(OutlookOAuthBundle.self, from: data),
                  previous.isSupported else { throw Failure.invalidSession }
            guard previous.tenantDomain == bundle.tenantDomain, previous.clientID == bundle.clientID,
                  previous.principalID == bundle.principalID else { throw Failure.contextMismatch }
        }
        let data = try JSONEncoder().encode(bundle)
        guard let json = String(data: data, encoding: .utf8) else { throw Failure.invalidSession }
        return AstraSecureKeychainStore.saveAtomically(service: service, account: OutlookOAuthBundle.storageKey, value: json,
            label: "Astra Mail authorization", allowUserInteraction: allowUserInteraction)
    }
}
