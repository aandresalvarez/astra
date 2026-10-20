import Foundation

/// The launch/preview owns one observation, including an unsuccessful one.
/// A failed observation must never be converted into permission to launch.
enum CopilotCapabilityResolution: Equatable, Sendable {
    case answered(CopilotCLICapabilities)
    case unavailable(String)

    var capabilities: CopilotCLICapabilities? {
        guard case .answered(let value) = self else { return nil }
        return value
    }

    var failureReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}
