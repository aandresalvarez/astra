import Foundation
import ASTRACore

/// Derived evidence for one owned process, never a second execution owner.
/// Unknown work and native tools remain sticky: their response does not attest
/// that detached commands or remote work have ended.
final class RuntimeExecutionProcessEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private let runtime: AgentRuntimeID
    private var toolsOrUnknownExecution = false
    private var terminalFrameSeen = false
    private var openCodeStopSeen = false

    init(runtime: AgentRuntimeID = .claudeCode) { self.runtime = runtime }

    /// Explicit ASTRA-owned events (including interactive permission tools).
    func observe(_ event: ParsedEvent) {
        lock.withLock {
            if Self.uncertain(event) { toolsOrUnknownExecution = true }
            switch event {
            case .result: terminalFrameSeen = true
            case .text, .thinking, .systemInit: terminalFrameSeen = false; openCodeStopSeen = false
            case .control: toolsOrUnknownExecution = true
            default: break
            }
        }
    }

    func observeFrame(_ line: String, parsesJSONLines: Bool, events: [ParsedEvent]) {
        guard parsesJSONLines, !events.isEmpty,
              let frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            lock.withLock { toolsOrUnknownExecution = true }
            return
        }
        let kind = RuntimeProviderFrameEvidence.classify(frame, runtime: runtime)
        lock.withLock {
            if events.contains(where: Self.uncertain) { toolsOrUnknownExecution = true }
            switch kind {
            case .uncertain: toolsOrUnknownExecution = true
            case .activity: terminalFrameSeen = false; openCodeStopSeen = false
            case .bookkeeping: break
            case .terminal: terminalFrameSeen = true
            case .openCodeStop: openCodeStopSeen = true
            }
        }
    }

    /// A final OpenCode model step is provisional until the owned CLI exits
    /// without a stop request and stdout reaches EOF. A timeout/kill cannot
    /// promote the step, even if a SIGTERM handler chooses exit code zero.
    func processExited(naturally: Bool, stdoutEOF: Bool) {
        lock.withLock {
            if !stdoutEOF { toolsOrUnknownExecution = true }
            if runtime == .openCodeCLI { terminalFrameSeen = naturally && stdoutEOF && openCodeStopSeen }
        }
    }

    private static func uncertain(_ event: ParsedEvent) -> Bool {
        switch event {
        case .toolUse, .toolResult, .permissionDenied, .teammateStarted, .teammateCompleted,
             .teamCreated, .teamDeleted, .teamMessage, .unknown, .astraProtocol: true
        default: false
        }
    }

    var toolsStopped: Bool { lock.withLock { terminalFrameSeen && !toolsOrUnknownExecution } }
}
