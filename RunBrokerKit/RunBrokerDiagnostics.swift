import Foundation

public enum RunBrokerDiagnosticEvent: String, Sendable {
    case launchAgentBootoutFailed = "launch_agent_bootout_failed"
    case installFailed = "install_failed"
    case installerLockFailed = "installer_lock_failed"
    case rollbackSelectorFailed = "rollback_selector_failed"
    case rollbackPlistFailed = "rollback_plist_failed"
    case rollbackLaunchStateFailed = "rollback_launch_state_failed"
    case healthCheckFailed = "health_check_failed"
    case peerIdentityReadFailed = "peer_identity_read_failed"
    case frameReadFailed = "frame_read_failed"
    case frameDecodeFailed = "frame_decode_failed"
    case responseEncodeFailed = "response_encode_failed"
    case responseWriteFailed = "response_write_failed"
    case connectionSaturated = "connection_saturated"
    case socketCleanupSkipped = "socket_cleanup_skipped"
    case schedulerOperationFailed = "scheduler_operation_failed"
    case schedulerRecoveryFailed = "scheduler_recovery_failed"
}

public protocol RunBrokerDiagnosing: Sendable {
    /// Implementations receive event and error type only. Request bytes,
    /// nonces, MACs, capability secrets, and command contents are never logged.
    func record(_ event: RunBrokerDiagnosticEvent, error: any Error)
}

public struct NoOpRunBrokerDiagnostics: RunBrokerDiagnosing {
    public init() {}
    public func record(_ event: RunBrokerDiagnosticEvent, error: any Error) {}
}

public final class StandardErrorRunBrokerDiagnostics: RunBrokerDiagnosing, @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func record(_ event: RunBrokerDiagnosticEvent, error: any Error) {
        let line = "astra-run-broker event=\(event.rawValue) error_type=\(String(describing: type(of: error)))\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
