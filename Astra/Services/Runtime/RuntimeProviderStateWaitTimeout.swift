import Foundation

struct RuntimeProviderStateWaitTimeout: LocalizedError {
    static let stopReason = "provider_shared_state_timeout"
    var errorDescription: String? {
        "The provider did not start because waiting for its shared configuration exceeded the preparation limit. Your message and work are preserved. Review the task reserving this configuration, then send a new instruction."
    }
}
