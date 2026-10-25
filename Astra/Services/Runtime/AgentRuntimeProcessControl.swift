import Foundation

protocol AgentRuntimeProcessControl: AnyObject {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    func terminate()
    /// Asks the provider to wind down before it is signalled, and reports
    /// whether there was a channel to ask through.
    ///
    /// A watchdog kill discards everything the run produced, so it is worth one
    /// cheap attempt to let the provider notice the run is over and flush what
    /// it already has. Returns false for process types with no such channel,
    /// so the caller knows not to wait for an answer that cannot come.
    @discardableResult
    func requestGracefulStop() -> Bool
}

extension AgentRuntimeProcessControl {
    @discardableResult
    func requestGracefulStop() -> Bool { false }
}

extension Process: AgentRuntimeProcessControl {}

final class AgentRuntimeProcessControlBox: @unchecked Sendable {
    private let process: AgentRuntimeProcessControl

    init(_ process: AgentRuntimeProcessControl) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        process.terminate()
    }

    func requestGracefulStop() -> Bool {
        process.requestGracefulStop()
    }
}
