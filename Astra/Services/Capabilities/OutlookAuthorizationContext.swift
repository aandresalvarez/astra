import Foundation
import ASTRACore
import ASTRAModels

/// Provider parameters captured independently of an existing stored grant.
/// A deliberate sign-in can replace an unavailable grant without reading it.
struct OutlookOAuthClientContext: Sendable {
    let tenant: String
    let clientID: String
    let scopes: String
    @MainActor init(_ account: Connector) throws {
        guard account.isStanfordOutlookMail, account.hasConfiguredOutlookTenantDomain else { throw StanfordOutlookMailError.missingTenant }
        guard !account.outlookClientID.isEmpty else { throw StanfordOutlookMailError.missingClientID }
        tenant = account.outlookTenantDomain
        clientID = account.outlookClientID
        let configured = account.configValue(StanfordOutlookMail.scopesKey)
        scopes = configured.isEmpty ? StanfordOutlookMail.scopeString : configured
    }
    func oauthURL(_ operation: String) throws -> URL {
        guard operation == "devicecode" || operation == "token" else { throw StanfordOutlookMailError.invalidResponse }
        var url = URLComponents(string: "https://login.microsoftonline.com")!
        url.percentEncodedPath = "/" + Self.pathComponent(tenant) + "/oauth2/v2.0/" + operation
        guard let result = url.url else { throw StanfordOutlookMailError.invalidResponse }
        return result
    }
    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
}

/// An exact stored authorization frozen before any network suspension.
struct OutlookAuthorizationContext: Sendable {
    let client: OutlookOAuthClientContext
    let reference: OutlookCredentialIdentity.Reference
    let principalID: String?
    var tenant: String { client.tenant }
    var clientID: String { client.clientID }
    var scopes: String { client.scopes }
    @MainActor init(_ account: Connector) throws {
        client = try OutlookOAuthClientContext(account)
        guard let reference = OutlookCredentialIdentity.resolve(accountID: account.id,
            credentialNamespaceID: account.credentialNamespaceID, format: account.outlookCredentialFormat) else {
            throw StanfordOutlookMailError.invalidResponse
        }
        self.reference = reference
        let principal = account.configValue(StanfordOutlookMail.accountIDKey)
        principalID = principal.isEmpty ? nil : principal
    }
}
