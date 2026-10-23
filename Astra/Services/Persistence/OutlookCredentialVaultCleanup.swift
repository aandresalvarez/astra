import Foundation
import ASTRACore

/// OAuth has fixed internal fields that are deliberately not credentialKeys.
/// Cleanup and renewal must exclude each other before ANY service deletion.
enum OutlookCredentialVaultCleanup {
    static func perform(facts: ConnectorSecretFacts, sparing: Set<String>, generic: () -> Bool) -> Bool {
        guard facts.serviceType == OutlookCredentialIdentity.serviceType, facts.includesOutlookCredentials else { return generic() }
        guard let reference = OutlookCredentialIdentity.resolve(accountID: facts.id,
            credentialNamespaceID: facts.credentialNamespaceID, format: facts.outlookCredentialFormat) else { return false }
        let service = KeychainSecretStore.connectorEntityID(for: reference.namespaceID)
        guard !sparing.contains(service) else { return generic() }
        guard let lease = try? KeychainOAuthSessionLease.acquire(namespaceID: reference.namespaceID) else { return false }
        return withExtendedLifetime(lease) {
            let cleared = generic()
            let fields = OutlookCredentialIdentity.tokenKeys.map { AstraSecureKeychainStore.delete(service: service, account: $0) }
            return cleared && !fields.contains(false)
        }
    }
}
