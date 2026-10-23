import Foundation
import ASTRACore
import ASTRAPersistence

/// The OAuth client holds one session across the network exchange. Production
/// sessions own the vault lease; a refused save must never return a fresh token.
protocol OutlookTokenSession: AnyObject {
    func load(tenantDomain: String, clientID: String, principalID: String?) throws -> OutlookOAuthBundle?
    func save(_ bundle: OutlookOAuthBundle, allowUserInteraction: Bool) throws -> Bool
}
extension OutlookOAuthVaultSession: OutlookTokenSession {}
