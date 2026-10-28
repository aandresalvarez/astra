import Foundation

/// A turn the provider ended itself before finishing it, as its own
/// diagnostics say once it has exited. The exit code and, for a structured
/// stream, even the terminal frame can look exactly like a completed turn, so
/// without this the run settles as completed with partial output.
struct AgentRuntimeProviderSelfStop: Equatable, Sendable {
    /// A declared `TaskRunStopReason`, so the worker can classify it.
    let reason: String
    let message: String
}

extension AgentRuntimeProcessEventParsing {
    func providerSelfStop(stderr _: String) -> AgentRuntimeProviderSelfStop? {
        nil
    }
}

extension AntigravityCLIRuntimeAdapter {
    func providerSelfStop(stderr: String) -> AgentRuntimeProviderSelfStop? {
        AntigravityCLIRuntime.printTimeoutStop(stderr: stderr)
    }
}
