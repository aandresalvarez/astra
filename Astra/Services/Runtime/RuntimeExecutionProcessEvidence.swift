import Foundation
import ASTRACore

/// Derived evidence for one owned process, never a second execution owner.
/// Unknown work and native tools remain sticky: their response does not attest
/// that detached commands or remote work have ended.
final class RuntimeExecutionProcessEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private let runtime: AgentRuntimeID
    private var toolsOrUnknownExecution = false
    private var unaccountedExecution = false
    private var managedHelper: RuntimeManagedSSHHelperEvidence?
    private var terminalFrameSeen = false
    private var openCodeStopSeen = false
    /// Uncertainty ASTRA raised itself: invalid accounting, an unverified
    /// native session, a stream that never closed. Not a question about local processes.
    private var ownedUncertainty = false
    /// Log-only: the first inputs that left cleanup unproven. Not evidence.
    private var uncertaintyCauses: [String] = []

    private func note(_ cause: @autoclosure () -> String) {
        guard uncertaintyCauses.count < RuntimeExecutionUncertaintyCause.limit else { return }
        let cause = cause()
        if !uncertaintyCauses.contains(cause) { uncertaintyCauses.append(cause) }
    }

    init(runtime: AgentRuntimeID = .claudeCode, managedSSHBroker: RuntimeManagedSSHBrokerEvidence? = nil) {
        self.runtime = runtime
        self.managedHelper = managedSSHBroker.map(RuntimeManagedSSHHelperEvidence.init)
    }

    /// Explicit ASTRA-owned events (including interactive permission tools).
    func observe(_ event: ParsedEvent) {
        lock.withLock {
            if Self.uncertain(event) { toolsOrUnknownExecution = true; unaccountedExecution = true; ownedUncertainty = true; note("owned_event") }
            switch event {
            case .result: terminalFrameSeen = true
            case .text, .thinking, .systemInit: terminalFrameSeen = false; openCodeStopSeen = false
            case .control: toolsOrUnknownExecution = true; unaccountedExecution = true; ownedUncertainty = true; note("owned_control_event")
            default: break
            }
        }
    }

    func observeFrame(_ line: String, parsesJSONLines: Bool, events: [ParsedEvent]) {
        guard parsesJSONLines, !events.isEmpty,
              let frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            let unparsed = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            lock.withLock {
                toolsOrUnknownExecution = true
                unaccountedExecution = true
                terminalFrameSeen = false
                openCodeStopSeen = false
                if !parsesJSONLines { note("plain_text_stream") }
                else if let unparsed { note(RuntimeExecutionUncertaintyCause.frame("no_parsed_events", unparsed)) }
                else { note("line_not_json") }
            }
            return
        }
        let kind = RuntimeProviderFrameEvidence.classify(frame, runtime: runtime)
        let containsWork = RuntimeStreamExecutionHints.containsWork(frame)
        lock.withLock {
            if containsWork { note(RuntimeExecutionUncertaintyCause.frame("work_hint", frame)) }
            if events.contains(where: Self.uncertain) { note(RuntimeExecutionUncertaintyCause.frame("uncertain_event", frame)) }
            switch kind {
            case .uncertain: note(RuntimeExecutionUncertaintyCause.frame("unclassified", frame))
            case .postTurnReport: note(RuntimeExecutionUncertaintyCause.frame("post_turn_report", frame))
            case .terminalWithoutCleanupProof: note(RuntimeExecutionUncertaintyCause.frame("terminal_without_cleanup_proof", frame))
            default: break
            }
            let managed = managedHelper?.observe(frame, runtime: runtime) == true
            if !managed && (containsWork || events.contains(where: Self.uncertain)
                || kind == .uncertain || kind == .postTurnReport || kind == .terminalWithoutCleanupProof) {
                unaccountedExecution = true
            }
            if containsWork || events.contains(where: Self.uncertain) { toolsOrUnknownExecution = true }
            switch kind {
            case .uncertain:
                toolsOrUnknownExecution = true
                terminalFrameSeen = false
                openCodeStopSeen = false
            case .activity: terminalFrameSeen = false; openCodeStopSeen = false
            case .bookkeeping: break
            case .postTurnReport: toolsOrUnknownExecution = true
            case .terminal: terminalFrameSeen = true
            case .terminalWithoutCleanupProof:
                terminalFrameSeen = true
                toolsOrUnknownExecution = true
            case .openCodeStop: openCodeStopSeen = true
            }
        }
    }

    /// A final OpenCode model step is provisional until the owned CLI exits
    /// without a stop request and stdout reaches EOF. A timeout/kill cannot
    /// promote the step, even if a SIGTERM handler chooses exit code zero.
    func processExited(naturally: Bool, stdoutEOF: Bool) {
        lock.withLock {
            if !stdoutEOF {
                toolsOrUnknownExecution = true
                unaccountedExecution = true
                terminalFrameSeen = false
                ownedUncertainty = true
                note("no_stdout_eof")
            }
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

    /// A terminal response can coexist with an unverified tool or external job.
    var providerTurnEnded: Bool { lock.withLock { terminalFrameSeen } }
    var toolsStopped: Bool {
        lock.withLock { terminalFrameSeen && !toolsOrUnknownExecution && managedHelper?.hasBrokerActivity != true }
    }
    /// Why `toolsStopped` is false, or empty when it is true. For the log only.
    var cleanupUncertainty: [String] {
        lock.withLock {
            let brokerActivity = managedHelper?.hasBrokerActivity == true
            guard !terminalFrameSeen || toolsOrUnknownExecution || brokerActivity else { return [] }
            return uncertaintyCauses + (terminalFrameSeen ? [] : ["no_terminal_frame"])
                + (brokerActivity ? ["managed_helper_broker_activity"] : [])
        }
    }
    /// The provider reported its turn finished and stdout closed; all that is
    /// unproven is whether tools the stream showed, or frames ASTRA could not
    /// classify, left local work behind. Only that can be asked of the process
    /// table. A killed or lost turn, ASTRA's own doubts and remote helper work cannot.
    var localObservationCanSettle: Bool {
        lock.withLock { terminalFrameSeen && !ownedUncertainty && managedHelper?.hasBrokerActivity != true }
    }
    var managedSSHOnly: Bool {
        lock.withLock { terminalFrameSeen && toolsOrUnknownExecution && !unaccountedExecution && managedHelper?.fullyAccounted == true }
    }
}
