import Foundation

/// Presentation facts derived from the saved grant. Retaining credentials for
/// Sign Out is distinct from having a grant the mail backend can currently use.
struct OutlookAuthorizationReadiness {
    let isStored: Bool
    let canRefresh: Bool
    let accessTokenExpiresAt: Date?

    static let unavailable = Self(isStored: false, canRefresh: false, accessTokenExpiresAt: nil)
    static let refreshMargin: TimeInterval = 120

    func canReadMail(at now: Date = Date()) -> Bool {
        canRefresh || accessTokenExpiresAt.map { Self.canUseAccessToken(expiresAt: $0, at: now) } == true
    }

    static func canUseAccessToken(expiresAt: Date, at now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) > refreshMargin
    }
}
