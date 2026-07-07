import Foundation

struct WorkspaceAppReadPolicy {
    static let maxConnectorReadLimit = 100
    static let defaultConnectorReadLimit = 30

    var rateLimiter: WorkspaceAppConnectorReadRateLimiter

    init(rateLimiter: WorkspaceAppConnectorReadRateLimiter = .shared) {
        self.rateLimiter = rateLimiter
    }

    static func connectorLimit(_ requested: Int?) -> Int {
        min(max(1, requested ?? defaultConnectorReadLimit), maxConnectorReadLimit)
    }

    func admitConnectorRead(
        actionID: String,
        appID: UUID,
        surface: WorkspaceAppBridgeSurface
    ) throws {
        guard rateLimiter.admit(appID: appID) else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(Self.rateLimitMessage(actionID: actionID))
        }
    }

    private static func rateLimitMessage(actionID: String) -> String {
        "\(actionID): connector reads are rate-limited; try again shortly"
    }
}
