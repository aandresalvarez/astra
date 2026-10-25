import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// OAuth participates in the account's existing generation transaction. The
/// source lease remains alive until its complete bundle has been copied.
@MainActor
struct OutlookCredentialGenerationPreparation {
    enum Change { case preserve, authorize(OutlookOAuthBundle), signOut }
    enum Failure: Error { case invalidAuthorization }
    let format: String?
    let ownsOAuth: Bool
    let bundle: OutlookOAuthBundle?
    private let sourceSession: OutlookOAuthVaultSession?

    static func prepare(source: Connector, isNew: Bool, copying: Bool, change: Change) throws -> Self {
        guard source.isStanfordOutlookMail else {
            guard case .preserve = change else { throw Failure.invalidAuthorization }
            return Self(format: nil, ownsOAuth: false, bundle: nil, sourceSession: nil)
        }
        switch change {
        case .authorize(let bundle):
            guard bundle.isSupported, !bundle.principalID.isEmpty,
                  bundle.tenantDomain == source.outlookTenantDomain,
                  bundle.clientID == source.outlookClientID else { throw Failure.invalidAuthorization }
            return Self(format: OutlookCredentialIdentity.generationFormat, ownsOAuth: true, bundle: bundle, sourceSession: nil)
        case .signOut:
            return Self(format: OutlookCredentialIdentity.generationFormat, ownsOAuth: true, bundle: nil, sourceSession: nil)
        case .preserve:
            if isNew && !copying {
                return Self(format: OutlookCredentialIdentity.generationFormat, ownsOAuth: true, bundle: nil, sourceSession: nil)
            }
            guard let reference = OutlookCredentialIdentity.resolve(accountID: source.id,
                credentialNamespaceID: source.credentialNamespaceID, format: source.outlookCredentialFormat) else {
                throw Failure.invalidAuthorization
            }
            // An ordinary credential edit has no authority to move the legacy
            // logical OAuth session. A deliberate duplicate makes a new copy.
            if case .legacy = reference, !copying {
                return Self(format: nil, ownsOAuth: false, bundle: nil, sourceSession: nil)
            }
            let session = try OutlookOAuthVaultSession(reference: reference)
            let bundle = try session.load(tenantDomain: source.outlookTenantDomain, clientID: source.outlookClientID,
                principalID: source.configValue(StanfordOutlookMail.accountIDKey))
            return Self(format: OutlookCredentialIdentity.generationFormat, ownsOAuth: true, bundle: bundle, sourceSession: session)
        }
    }

    func copyBundle(to namespace: UUID, allowUserInteraction: Bool = false) throws {
        try withExtendedLifetime(sourceSession) {
            guard let bundle else { return }
            let target = try OutlookOAuthVaultSession(reference: .generation(namespace))
            guard try target.save(bundle, allowUserInteraction: allowUserInteraction) else { throw Failure.invalidAuthorization }
        }
    }
}
