import Foundation

/// One atomic vault value for one Outlook authorization. Refresh changes
/// tokens and expiry, never the captured tenant, client or principal. A new
/// sign-in publishes another generation, even for the same visible account.
public struct OutlookOAuthBundle: Codable, Equatable, Sendable {
    public static let storageKey = "ASTRA_MAIL_OAUTH_BUNDLE_V1"
    public let version: Int
    public let tenantDomain: String
    public let clientID: String
    public let principalID: String
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public init(tenantDomain: String, clientID: String, principalID: String,
                accessToken: String, refreshToken: String?, expiresAt: Date, version: Int = 1) {
        self.version = version
        self.tenantDomain = tenantDomain
        self.clientID = clientID
        self.principalID = principalID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isSupported: Bool {
        version == 1 && !tenantDomain.isEmpty && !clientID.isEmpty && !accessToken.isEmpty
            && expiresAt.timeIntervalSince1970.isFinite
    }

    public func matches(tenantDomain: String, clientID: String, principalID: String?) -> Bool {
        guard isSupported, self.tenantDomain == tenantDomain, self.clientID == clientID else { return false }
        guard let principalID, !principalID.isEmpty else { return true }
        return self.principalID == principalID
    }

    public func refreshed(accessToken: String, refreshToken: String?, expiresAt: Date) -> Self {
        Self(tenantDomain: tenantDomain, clientID: clientID, principalID: principalID,
             accessToken: accessToken,
             refreshToken: refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? self.refreshToken,
             expiresAt: expiresAt, version: version)
    }
}
