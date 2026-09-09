import Foundation
import ASTRACore
protocol AgentRuntimeProcessControl: AnyObject {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    func terminate()
    /// Asks the provider to wind down before it is signalled.
    ///
    /// A watchdog kill discards everything the run produced, so it is worth one
    /// cheap attempt to let the provider notice the run is over and flush what
    /// it already has. Defaults to a no-op for process types with no such
    /// channel.
    func requestGracefulStop()
}

extension AgentRuntimeProcessControl {
    func requestGracefulStop() {}
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

    func requestGracefulStop() {
        process.requestGracefulStop()
    }
}

final class AgentLockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }

    func append(_ string: String) {
        lock.lock()
        _value += string
        lock.unlock()
    }

    func appendLocked(_ string: String) {
        _value += string
    }

    /// Runs `body` while holding the buffer's lock, so a caller can fold an
    /// external read (draining a pipe's `readabilityHandler` vs. a process's
    /// `terminationHandler`, both of which race to read the same fd) and the
    /// resulting buffer mutation into one atomic step. Without this, a reader
    /// that already consumed bytes via its own `read()`/`availableData()` call
    /// but hasn't yet reached the buffer can lose a race against a concurrent
    /// reader that finds the fd and buffer both empty and concludes there is
    /// nothing left to process — see the `*Locked` methods below, which must
    /// be called only from inside a `synchronized` block (they assume the
    /// lock is already held and are not reentrant-safe on their own).
    func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func appendAndDrainLines(_ string: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return appendAndDrainLinesLocked(string)
    }

    func appendAndDrainLinesLocked(_ string: String) -> [String] {
        _value += string
        var lines: [String] = []
        while let newlineIndex = _value.firstIndex(of: "\n") {
            let line = String(_value[_value.startIndex..<newlineIndex])
            lines.append(line)
            _value = String(_value[_value.index(after: newlineIndex)...])
        }
        return lines
    }

    func appendAndProcessLines(_ string: String, _ processLine: (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        appendAndProcessLinesLocked(string, processLine)
    }

    func appendAndProcessLinesLocked(_ string: String, _ processLine: (String) -> Void) {
        _value += string
        while let newlineIndex = _value.firstIndex(of: "\n") {
            let line = String(_value[_value.startIndex..<newlineIndex])
            _value = String(_value[_value.index(after: newlineIndex)...])
            processLine(line)
        }
    }

    func drainRemaining() -> String {
        lock.lock()
        defer { lock.unlock() }
        return drainRemainingLocked()
    }

    func drainRemainingLocked() -> String {
        let remaining = _value
        _value = ""
        return remaining
    }
}

struct AgentRuntimeStreamTelemetrySnapshot: Sendable {
    let rawLineCount: Int
    let jsonLineCount: Int
    let plainTextLineCount: Int
    let parsedEventCount: Int
    let emittedEventCount: Int
    let textEventCount: Int
    let thinkingEventCount: Int
    let toolUseEventCount: Int
    let toolResultEventCount: Int
    let statsEventCount: Int
    let completedEventCount: Int
    let failedEventCount: Int
    let unknownEventCount: Int
    let unknownTypeCounts: [String: Int]
    let unknownSamples: [(type: String, sample: String)]

    var fields: [String: String] {
        [
            "raw_lines": String(rawLineCount),
            "json_lines": String(jsonLineCount),
            "plain_text_lines": String(plainTextLineCount),
            "parsed_events": String(parsedEventCount),
            "emitted_events": String(emittedEventCount),
            "text_events": String(textEventCount),
            "thinking_events": String(thinkingEventCount),
            "tool_use_events": String(toolUseEventCount),
            "tool_result_events": String(toolResultEventCount),
            "stats_events": String(statsEventCount),
            "completed_events": String(completedEventCount),
            "failed_events": String(failedEventCount),
            "unknown_events": String(unknownEventCount),
            "unknown_types": unknownTypeCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        ]
    }
}

final class AgentRuntimeStreamTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private let maxUnknownSamples: Int

    private var rawLineCount = 0
    private var jsonLineCount = 0
    private var plainTextLineCount = 0
    private var parsedEventCount = 0
    private var emittedEventCount = 0
    private var textEventCount = 0
    private var thinkingEventCount = 0
    private var toolUseEventCount = 0
    private var toolResultEventCount = 0
    private var statsEventCount = 0
    private var completedEventCount = 0
    private var failedEventCount = 0
    private var unknownEventCount = 0
    private var unknownTypeCounts: [String: Int] = [:]
    private var unknownSamples: [(type: String, sample: String)] = []

    init(maxUnknownSamples: Int = 3) {
        self.maxUnknownSamples = maxUnknownSamples
    }

    func recordRawLine(parsesJSONLines: Bool) {
        lock.lock()
        rawLineCount += 1
        if parsesJSONLines {
            jsonLineCount += 1
        } else {
            plainTextLineCount += 1
        }
        lock.unlock()
    }

    func recordParsed(_ events: [AgentEvent]) {
        lock.lock()
        parsedEventCount += events.count
        for event in events {
            record(event)
        }
        lock.unlock()
    }

    func recordEmitted(_ events: [AgentEvent]) {
        lock.lock()
        emittedEventCount += events.count
        lock.unlock()
    }

    func snapshot() -> AgentRuntimeStreamTelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AgentRuntimeStreamTelemetrySnapshot(
            rawLineCount: rawLineCount,
            jsonLineCount: jsonLineCount,
            plainTextLineCount: plainTextLineCount,
            parsedEventCount: parsedEventCount,
            emittedEventCount: emittedEventCount,
            textEventCount: textEventCount,
            thinkingEventCount: thinkingEventCount,
            toolUseEventCount: toolUseEventCount,
            toolResultEventCount: toolResultEventCount,
            statsEventCount: statsEventCount,
            completedEventCount: completedEventCount,
            failedEventCount: failedEventCount,
            unknownEventCount: unknownEventCount,
            unknownTypeCounts: unknownTypeCounts,
            unknownSamples: unknownSamples
        )
    }

    private func record(_ event: AgentEvent) {
        switch event {
        case .control:
            break
        case .started:
            break
        case .thinking:
            thinkingEventCount += 1
        case .text:
            textEventCount += 1
        case .toolUse:
            toolUseEventCount += 1
        case .toolResult:
            toolResultEventCount += 1
        case .fileChange:
            break
        case .permissionRequested:
            break
        case .stats:
            statsEventCount += 1
        case .astraProtocol:
            break
        case .completed:
            completedEventCount += 1
        case .failed:
            failedEventCount += 1
        case .teamEvent:
            break
        case .unknown(_, let type, let raw):
            unknownEventCount += 1
            unknownTypeCounts[type, default: 0] += 1
            if unknownSamples.count < maxUnknownSamples,
               !unknownSamples.contains(where: { $0.type == type }) {
                unknownSamples.append((type: type, sample: raw))
            }
        }
    }
}

final class AgentRuntimeEventPipelineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: AgentRuntimeEventPipeline

    init(supportsAstraRunProtocol: Bool) {
        pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: supportsAstraRunProtocol)
    }

    func process(_ event: ParsedEvent) -> [ParsedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return pipeline.process(event)
    }

    func process(_ event: AgentEvent) -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return pipeline.process(event)
    }

    func flushParsedEvents() -> [ParsedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return pipeline.flushParsedEvents()
    }

    func flushAgentEvents() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return pipeline.flushAgentEvents()
    }
}

/// Encapsulates budget enforcement, repetition circuit breaker, and idle timeout
/// for agent runtime processes.
nonisolated final class AgentProcessMonitor: @unchecked Sendable {
    private struct ToolUseContext {
        let id: String
        let name: String
        let summary: String?
    }

    private struct ManagedWorkspaceJobContext {
        let id: String
        var status: String
        var heartbeatPath: String?
        var resultPath: String?
        var lastObservedAt: Date
        var lastHeartbeatAt: Date?

        var isTerminal: Bool {
            Self.isTerminal(status: status)
        }

        static func isTerminal(status: String) -> Bool {
            switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "succeeded", "failed", "cancelled", "timed_out", "timedout":
                return true
            default:
                return false
            }
        }
    }

    private struct ManagedWorkspaceJobFileState {
        var status: String?
        var timestamp: Date?
    }

    enum RuntimeProgressKind: String {
        case lifecycleMetadata = "lifecycle_metadata"
        case providerLiveness = "provider_liveness"
        case visibleProgress = "visible_progress"
        case actionableProgress = "actionable_progress"
        case accounting = "accounting"
        case terminal = "terminal"
        case diagnostic = "diagnostic"
    }

    let tokenBudget: Int
    let budgetEnforcementMode: BudgetEnforcementMode
    /// False when `tokenBudget` is the implicit runaway ceiling rather than a
    /// number the user chose. See `effectiveBudgetEnforcementMode`.
    let isUserConfiguredBudget: Bool
    let maxTurns: Int
    let maxRepetitions: Int
    let idleTimeoutSeconds: TimeInterval
    let noSemanticProgressTimeoutSeconds: TimeInterval
    let activeToolIdleTimeoutSeconds: TimeInterval
    let managedWorkspaceJobIdleTimeoutSeconds: TimeInterval
    let terminalProgressExitGraceSeconds: TimeInterval
    /// Hard ceiling on the whole run's wall clock. Every other timeout here
    /// measures *silence*, so a provider that keeps emitting can hold them all
    /// off forever. This is the one bound that cannot be talked out of firing.
    let maxRunSeconds: TimeInterval
    let taskID: UUID
    let policyGuard: AgentRuntimePolicyGuard?
    /// True when the provider's live permission prompt (the stdio control
    /// channel) gates ask-first tools before they run. When set, the post-hoc
    /// guard stops re-flagging ask-first approvals — the live channel already
    /// owns them — so it can't double-prompt or kill a run whose command simply
    /// can't be reduced to a replayable scoped grant. Hard denies still stop.
    let liveApprovalsActive: Bool
    let sandboxDiagnosticContext: RuntimeSandboxDiagnosticContext
    let readOnlyBoundaryReceipt: ReadOnlyResourceBoundaryReceipt?
    private let lock = NSLock()

    private var _estimatedTokens: Int = 0
    private var _turnCount: Int = 0
    private var _budgetExceeded: Bool = false
    private var _budgetWarning: Bool = false
    private var _finalReportedBudgetExceededAfterCompletion: Bool = false
    private var _terminatedAfterTerminalProgress: Bool = false
    private var _maxTurnsExceeded: Bool = false
    private var _timedOut: Bool = false
    private var _repetitionKilled: Bool = false
    private var _policyViolation: Bool = false
    private var _policyViolationMessage: String?
    private var _policyApprovalRequired: Bool = false
    private var _policyApprovalMessage: String?
    private var _runtimeStopReason: String?
    private var _runtimeStopMessage: String?
    private var _sawAstraComplete: Bool = false

    private var browserToolUseIDs: Set<String> = []
    private var browserShellIDs: Set<String> = []
    private var activeToolUseIDs: Set<String> = []
    private var activeManagedWorkspaceJobs: [String: ManagedWorkspaceJobContext] = [:]
    private var toolUseContextsByID: [String: ToolUseContext] = [:]
    /// Insertion order for `toolUseContextsByID`, used to evict the oldest
    /// entries so the keyed map can't grow unbounded across a long run.
    private var toolUseContextOrder: [String] = []
    /// Cap on retained keyed tool-use contexts. A tool_result almost always
    /// follows its tool_use within the same turn, so this is far more than
    /// needed; a result for an evicted (very old) id falls back to
    /// `recentToolUseContexts.last`, exactly as it does today on a miss.
    private static let maxTrackedToolUseContexts = 256
    private var recentToolUseContexts: [ToolUseContext] = []
    private var sawGoogleDocsVisiblePageRead = false
    private var ignoredGoogleDocsFullReadRequirementAfterVisibleRead = false
    private var lastEventSignature: String = ""
    private var repetitionCount: Int = 0
    private var lastActivityTime = Date()
    private var lastAnyActivityTime = Date()
    private var lastTerminalProgressTime: Date?
    private var hasSeenAnyActivity = false
    private var hasSeenProviderLivenessActivity = false
    private var hasSeenProgressActivity = false
    private var watchdogRunning = false
    private let runStartedAt = Date()

    /// Raw stdout volume, used as a parser-independent progress signal. Shape
    /// analysis can only recognise frames some parser already models; byte
    /// count keeps working when the provider changes its stream format.
    private var cumulativeStreamBytes = 0
    private var streamBytesAtLastProgress = 0

    /// Unrecognised frames seen in the current silence window. Their presence
    /// means the taxonomy is out of date, so it is not trustworthy enough to
    /// justify an aggressive kill.
    private var unknownEventCount = 0
    private var lastUnknownEventTime: Date?

    /// Which silence window's unrecognised-stream deferrals have been traced,
    /// and for which reasons within it.
    ///
    /// The deferral is a diagnostic, not a decision: it advances no clock and
    /// records no state, so re-entering it differs in nothing from the last
    /// time. The watchdog polls at least every 30 seconds, and a provider that
    /// keeps sending unrecognised frames refreshes the outer idle timeout as it
    /// goes — so without this the single "the parser is behind" trace becomes
    /// hundreds of identical lines over a four-hour run, which is the kind of
    /// log wall the rest of this branch exists to remove. Keyed on the window
    /// start (`lastActivityTime`, which moves only when progress is observed or
    /// forgiven) so a genuinely new window traces again, and on the reason so a
    /// window that changes character is not silently swallowed. Reset per
    /// window, so it holds at most one entry per silence branch.
    private var tracedDeferralWindowStart: Date?
    private var tracedDeferralReasons: Set<String> = []
    private var _unrecognizedDeferralTraceCount = 0

    /// Semantic-window breaches forgiven so far. The first breach buys one
    /// extension rather than a kill.
    private var semanticProgressExtensionsUsed = 0

    /// When the current reprieve runs out, or nil if none is live.
    ///
    /// The generic idle timeout stands down while this is in the future. The
    /// semantic window is always the shorter of the two, so without this the
    /// extension would be handed out and then immediately overruled by the
    /// backstop — the reprieve has to cover both clocks to mean anything.
    private var semanticProgressExtensionExpiresAt: Date?

    /// One extension per run. Two consecutive full windows of genuine silence
    /// is a real stall; one is usually a provider about to produce output.
    static let maxSemanticProgressExtensions = 1

    var estimatedTokens: Int { lock.lock(); defer { lock.unlock() }; return _estimatedTokens }
    var turnCount: Int { lock.lock(); defer { lock.unlock() }; return _turnCount }
    var budgetExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _budgetExceeded }
    var budgetWarning: Bool { lock.lock(); defer { lock.unlock() }; return _budgetWarning }
    var finalReportedBudgetExceededAfterCompletion: Bool { lock.lock(); defer { lock.unlock() }; return _finalReportedBudgetExceededAfterCompletion }
    var terminatedAfterTerminalProgress: Bool { lock.lock(); defer { lock.unlock() }; return _terminatedAfterTerminalProgress }
    var maxTurnsExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _maxTurnsExceeded }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
    var repetitionKilled: Bool { lock.lock(); defer { lock.unlock() }; return _repetitionKilled }
    var policyViolation: Bool { lock.lock(); defer { lock.unlock() }; return _policyViolation }
    var policyViolationMessage: String? { lock.lock(); defer { lock.unlock() }; return _policyViolationMessage }
    var policyApprovalRequired: Bool { lock.lock(); defer { lock.unlock() }; return _policyApprovalRequired }
    var policyApprovalMessage: String? { lock.lock(); defer { lock.unlock() }; return _policyApprovalMessage }
    var runtimeStopReason: String? { lock.lock(); defer { lock.unlock() }; return _runtimeStopReason }
    var runtimeStopMessage: String? { lock.lock(); defer { lock.unlock() }; return _runtimeStopMessage }
    var runtimeStopped: Bool { lock.lock(); defer { lock.unlock() }; return _runtimeStopReason?.isEmpty == false }
    /// Which enforcement mode actually applies to `tokenBudget`.
    ///
    /// `budgetEnforcementMode` is a preference about *the user's* budget: in
    /// `.warning` mode ASTRA says "you have gone past what you asked for" and
    /// keeps going, which is the right answer for a number the user chose and
    /// can revise. The implicit runaway ceiling is not that number. It exists
    /// only to bound a provider that has stopped making sense, the user never
    /// set it, and no preference they expressed was about it — so warning on it
    /// would log a line nobody asked for and then let the run keep spending. It
    /// stops, whatever the mode says.
    private var effectiveBudgetEnforcementMode: BudgetEnforcementMode {
        isUserConfiguredBudget ? budgetEnforcementMode : .hardStop
    }
    init(
        tokenBudget: Int,
        budgetEnforcementMode: BudgetEnforcementMode = .hardStop,
        isUserConfiguredBudget: Bool = true,
        maxTurns: Int = 0,
        maxRepetitions: Int = 8,
        idleTimeoutSeconds: TimeInterval = 600,
        noSemanticProgressTimeoutSeconds: TimeInterval? = nil,
        activeToolIdleTimeoutSeconds: TimeInterval? = nil,
        managedWorkspaceJobIdleTimeoutSeconds: TimeInterval? = nil,
        terminalProgressExitGraceSeconds: TimeInterval? = nil,
        maxRunSeconds: TimeInterval? = nil,
        taskID: UUID = UUID(),
        policyGuard: AgentRuntimePolicyGuard? = nil,
        liveApprovalsActive: Bool = false,
        sandboxDiagnosticContext: RuntimeSandboxDiagnosticContext = .none,
        readOnlyBoundaryReceipt: ReadOnlyResourceBoundaryReceipt? = nil
    ) {
        self.tokenBudget = tokenBudget
        self.budgetEnforcementMode = budgetEnforcementMode
        self.isUserConfiguredBudget = isUserConfiguredBudget
        self.maxTurns = maxTurns
        self.maxRepetitions = maxRepetitions
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.noSemanticProgressTimeoutSeconds = noSemanticProgressTimeoutSeconds ?? min(idleTimeoutSeconds, 180)
        let resolvedActiveToolIdleTimeoutSeconds = activeToolIdleTimeoutSeconds ?? max(idleTimeoutSeconds, 3600)
        self.activeToolIdleTimeoutSeconds = resolvedActiveToolIdleTimeoutSeconds
        self.managedWorkspaceJobIdleTimeoutSeconds = managedWorkspaceJobIdleTimeoutSeconds ?? max(resolvedActiveToolIdleTimeoutSeconds, 6 * 3600)
        self.terminalProgressExitGraceSeconds = terminalProgressExitGraceSeconds ?? min(self.noSemanticProgressTimeoutSeconds, 30)
        self.maxRunSeconds = maxRunSeconds ?? RuntimeProgressSignals.defaultMaxRunSeconds
        self.taskID = taskID
        self.policyGuard = policyGuard
        self.liveApprovalsActive = liveApprovalsActive
        self.sandboxDiagnosticContext = sandboxDiagnosticContext
        self.readOnlyBoundaryReceipt = readOnlyBoundaryReceipt
    }

    static func estimatedTokenCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, text.count / 4)
    }

    func processEvent(_ parsed: ParsedEvent, process: AgentRuntimeProcessControl?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        lastAnyActivityTime = now
        hasSeenAnyActivity = true
        let progressKind = Self.progressKind(for: parsed)
        if Self.refreshesRuntimeActivity(progressKind) {
            markSemanticProgressLocked(now: now)
        } else if progressKind == .providerLiveness || progressKind == .accounting {
            hasSeenProviderLivenessActivity = true
        }
        if case .unknown = parsed {
            // The taxonomy just failed to describe something the provider sent.
            // Remember it: the kill branches below consult this before deciding
            // that "no recognised progress" means "no progress".
            unknownEventCount += 1
            lastUnknownEventTime = now
        }
        if Self.isSuccessfulTerminalProgress(parsed) {
            lastTerminalProgressTime = now
        }

        if case .astraProtocol(.valid(.complete)) = parsed {
            _sawAstraComplete = true
            return false
        }

        if case .astraProtocol = parsed {
            return false
        }

        if case .toolUse(let name, let id, let input) = parsed {
            rememberToolUse(name: name, id: id, input: input)
            if !id.isEmpty {
                activeToolUseIDs.insert(id)
                let isBrowserTool = Self.isBrowserToolUse(name: name, input: input)
                let isBrowserShellContinuation = Self.browserShellIDs(fromToolInput: input).contains { browserShellIDs.contains($0) }
                if isBrowserTool || isBrowserShellContinuation {
                    browserToolUseIDs.insert(id)
                }
            }
        }

        if let violation = policyGuard?.violation(for: parsed) {
            // When the live channel gates ask-first tools at the provider's
            // permission prompt, it has already approved (or denied) anything
            // that ran. Re-flagging an ask-first approval here would double-
            // prompt the user or, when the command can't be reduced to a
            // replayable scoped grant, kill the run outright. Defer to the live
            // channel for approvals; every non-approval violation (denies,
            // out-of-scope paths) still terminates as a backstop.
            if violation.requiresApproval, liveApprovalsActive {
                // Silently dropping this is right, but silently *losing* it is
                // not: this is the one branch where ASTRA decides a policy
                // observation needs no user-visible outcome, so leave a trace.
                // Reconstructing why a run did or didn't stop should not require
                // reading the SQLite store.
                AppLogger.audit(.runtimeCommandPlanned, category: "Worker", taskID: taskID, fields: [
                    "policy_observation": "deferred_to_live_channel",
                    "violation_category": violation.violationCategory,
                    "tool": violation.toolName ?? "unknown"
                ], level: .debug)
                return false
            }
            return recordPolicyViolation(violation, process: process)
        }

        if case .permissionDenied(let tool, let reason) = parsed,
           Self.isProviderPermissionDenial(reason) {
            return recordProviderPermissionDenial(
                toolID: nil,
                explicitToolName: tool,
                detail: reason,
                process: process
            )
        }

        if case .toolResult(let toolID, let content, let isError) = parsed {
            if !toolID.isEmpty {
                activeToolUseIDs.remove(toolID)
            }
            if let jobContext = Self.managedWorkspaceJobContext(fromToolResult: content, observedAt: now) {
                if jobContext.isTerminal {
                    activeManagedWorkspaceJobs.removeValue(forKey: jobContext.id)
                } else {
                    activeManagedWorkspaceJobs[jobContext.id] = jobContext
                }
            }
            if Self.isProviderPermissionDenial(content) {
                return recordProviderPermissionDenial(
                    toolID: toolID,
                    explicitToolName: nil,
                    detail: content,
                    process: process
                )
            }
            if let denial = RuntimeSandboxDenialDiagnostics.fileDenial(
                in: content, currentDirectory: sandboxDiagnosticContext.workingDirectory,
                operationContext: toolContext(for: toolID)?.summary
            ) {
                return recordOSSandboxFileDenial(denial, toolID: toolID, toolResultWasError: isError, process: process)
            }
            let isKnownBrowserTool = !toolID.isEmpty && browserToolUseIDs.contains(toolID)
            if isKnownBrowserTool {
                for shellID in Self.browserShellIDs(fromToolResult: content) {
                    browserShellIDs.insert(shellID)
                }
            }
            if Self.isSuccessfulGoogleDocsVisiblePageRead(content) {
                sawGoogleDocsVisiblePageRead = true
            }
            if let stop = Self.browserTerminalStop(content: content, isKnownBrowserTool: isKnownBrowserTool) {
                if stop.reason == "google_docs_controlled_browser_required",
                   sawGoogleDocsVisiblePageRead,
                   !ignoredGoogleDocsFullReadRequirementAfterVisibleRead {
                    ignoredGoogleDocsFullReadRequirementAfterVisibleRead = true
                    AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
                        "reason": stop.reason,
                        "source": "browser_terminal_error_ignored_after_visible_page_read",
                        "message": "A Google Docs visible-page read already succeeded, so ASTRA allowed the runtime to continue and summarize the partial content."
                    ], level: .warning)
                    return false
                }
                return recordRuntimeStop(reason: stop.reason, message: stop.message, process: process)
            }
        }

        if let stop = BrowserBridgeRuntimeLaunchGuard.transcriptStop(from: parsed) {
            return recordRuntimeStop(reason: stop.reason, message: stop.message, process: process)
        }

        if case .result = parsed {
            _turnCount += 1
            if maxTurns > 0 && _turnCount >= maxTurns {
                AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: [
                    "reason": "max_turns_reached",
                    "turns": String(_turnCount),
                    "max_turns": String(maxTurns)
                ], level: .error)
                _maxTurnsExceeded = true
                process?.terminate()
                return true
            }
        }

        if let signature = Self.repetitionSignature(parsed) {
            if signature == lastEventSignature {
                repetitionCount += 1
                if repetitionCount >= maxRepetitions {
                    AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: [
                        "reason": "repetition_detected",
                        "event_kind": Self.progressKind(for: parsed).rawValue,
                        "event_signature": LogSanitizer.sanitize(signature, maxLength: 240),
                        "repetition_count": String(repetitionCount),
                        "semantic_activity_age_seconds": String(Int(now.timeIntervalSince(lastActivityTime)))
                    ], level: .error, fieldMaxLength: 260)
                    _repetitionKilled = true
                    process?.terminate()
                    return true
                }
            } else {
                lastEventSignature = signature
                repetitionCount = 1
            }
        }

        if case .usage(let totalInput, let totalOutput) = parsed {
            let totalTokens = totalInput + totalOutput
            if totalTokens > tokenBudget {
                if effectiveBudgetEnforcementMode == .warning {
                    return recordBudgetWarning(
                        reason: "stream_usage_budget_exceeded",
                        fields: [
                            "reported_tokens": String(totalTokens),
                            "token_budget": String(tokenBudget)
                        ],
                        process: process
                    )
                }
                return recordBudgetOverage(
                    reason: "stream_usage_budget_exceeded",
                    fields: [
                        "reported_tokens": String(totalTokens),
                        "token_budget": String(tokenBudget)
                    ],
                    process: process
                )
            }
        } else if case .result(_, _, let totalInput, let totalOutput, _, _, let isError) = parsed {
            let totalTokens = totalInput + totalOutput
            if totalTokens > tokenBudget {
                if effectiveBudgetEnforcementMode == .warning {
                    return recordBudgetWarning(
                        reason: "reported_budget_exceeded",
                        fields: [
                            "reported_tokens": String(totalTokens),
                            "token_budget": String(tokenBudget)
                        ],
                        process: process
                    )
                } else if _sawAstraComplete && !isError {
                    _finalReportedBudgetExceededAfterCompletion = true
                    return false
                }
                return recordBudgetOverage(
                    reason: "reported_budget_exceeded",
                    fields: [
                        "reported_tokens": String(totalTokens),
                        "token_budget": String(tokenBudget)
                    ],
                    process: process
                )
            }
        }

        switch parsed {
        case .text(let text):
            _estimatedTokens += Self.estimatedTokenCount(for: text)
        case .thinking(let text):
            _estimatedTokens += Self.estimatedTokenCount(for: text)
        case .toolUse:
            _estimatedTokens += 100
        case .toolResult:
            _estimatedTokens += 200
        case .usage:
            break
        case .teamMessage(_, _, let content):
            _estimatedTokens += max(50, content.count / 4)
        case .teammateStarted, .teammateCompleted, .teamCreated, .teamDeleted:
            _estimatedTokens += 50
        case .permissionDenied:
            _estimatedTokens += 50
        case .control, .astraProtocol: break
        case .systemInit, .unknown:
            _estimatedTokens += 20
        case .result:
            break
        }

        if _estimatedTokens > tokenBudget {
            let fields = [
                "estimated_tokens": String(_estimatedTokens),
                "token_budget": String(tokenBudget)
            ]
            if effectiveBudgetEnforcementMode == .warning {
                return recordBudgetWarning(
                    reason: "estimated_budget_exceeded",
                    fields: fields,
                    process: process
                )
            }
            return recordBudgetOverage(
                reason: "estimated_budget_exceeded",
                fields: fields,
                process: process
            )
        }

        return false
    }

    private func rememberToolUse(name: String, id: String, input: [String: Any]?) {
        let context = ToolUseContext(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: Self.toolUseSummary(name: name, input: input)
        )
        if !id.isEmpty {
            if toolUseContextsByID[id] == nil {
                toolUseContextOrder.append(id)
            }
            toolUseContextsByID[id] = context
            if toolUseContextOrder.count > Self.maxTrackedToolUseContexts {
                let overflow = toolUseContextOrder.count - Self.maxTrackedToolUseContexts
                for evictedID in toolUseContextOrder.prefix(overflow) {
                    toolUseContextsByID.removeValue(forKey: evictedID)
                }
                toolUseContextOrder.removeFirst(overflow)
            }
        }
        recentToolUseContexts.append(context)
        if recentToolUseContexts.count > 8 {
            recentToolUseContexts.removeFirst(recentToolUseContexts.count - 8)
        }
    }

    private static func toolUseSummary(name _: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let command = commandString(in: input) {
            return command
        }
        if let summary = input["summary"] as? String {
            if let parsedCommand = commandString(fromJSONString: summary) {
                return parsedCommand
            }
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
        }
        return String(valueSignature(input).prefix(500))
    }

    private static func commandString(in dictionary: [String: Any]) -> String? {
        for key in ["command", "cmd"] {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        for key in ["input", "arguments", "args", "data", "payload"] {
            if let nested = dictionary[key] as? [String: Any],
               let command = commandString(in: nested) {
                return command
            }
        }
        return nil
    }

    private static func commandString(fromJSONString value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return commandString(in: object)
    }

    private func toolContext(for toolID: String?) -> ToolUseContext? {
        if let toolID, !toolID.isEmpty, let context = toolUseContextsByID[toolID] {
            return context
        }
        return recentToolUseContexts.last
    }

    private static func managedWorkspaceJobContext(fromToolResult content: String, observedAt: Date) -> ManagedWorkspaceJobContext? {
        let fields = managedWorkspaceJobFields(in: content)
        guard let jobID = fields["job_id"],
              let status = fields["status"] else {
            return nil
        }
        let heartbeatPath = usableManagedWorkspaceJobPath(fields["heartbeat"])
        let resultPath = usableManagedWorkspaceJobPath(fields["result"])
        let heartbeatTimestamp = fields["last_heartbeat_at"].flatMap(parseISO8601Date)
        return ManagedWorkspaceJobContext(
            id: jobID,
            status: status,
            heartbeatPath: heartbeatPath,
            resultPath: resultPath,
            lastObservedAt: heartbeatTimestamp ?? observedAt,
            lastHeartbeatAt: heartbeatTimestamp
        )
    }

    private static func managedWorkspaceJobFields(in content: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separatorIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = String(line[line.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    private static func usableManagedWorkspaceJobPath(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "<unavailable>" else { return nil }
        return trimmed
    }

    private static func managedWorkspaceJobFileState(atPath path: String) -> ManagedWorkspaceJobFileState? {
        guard let data = safeManagedWorkspaceJobFileData(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let status = object["status"] as? String
        let timestampString = (object["timestamp"] as? String) ?? (object["completedAt"] as? String)
        return ManagedWorkspaceJobFileState(
            status: status,
            timestamp: timestampString.flatMap(parseISO8601Date)
        )
    }

    private static func fileModificationDate(atPath path: String) -> Date? {
        guard let statInfo = safeManagedWorkspaceJobFileStat(atPath: path) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec) + TimeInterval(statInfo.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func safeManagedWorkspaceJobFileData(atPath path: String) -> Data? {
        guard let expectedStat = safeManagedWorkspaceJobFileStat(atPath: path) else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var openedStat = stat()
        guard fstat(fd, &openedStat) == 0,
              sameManagedWorkspaceJobFile(openedStat, expectedStat),
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_nlink == 1 else {
            return nil
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return data
    }

    private static func safeManagedWorkspaceJobFileStat(atPath path: String) -> stat? {
        var statInfo = stat()
        guard lstat(path, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFREG,
              statInfo.st_nlink == 1 else {
            return nil
        }
        return statInfo
    }

    private static func sameManagedWorkspaceJobFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isBrowserToolUse(name: String, input: [String: Any]?) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedName == "astra-browser" || normalizedName.contains("astra-browser") {
            return true
        }
        guard let input else { return false }
        return inputContainsAstraBrowser(input)
    }

    private static func inputContainsAstraBrowser(_ value: Any) -> Bool {
        if let string = value as? String {
            return string.lowercased().contains("astra-browser")
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains(where: inputContainsAstraBrowser)
        }
        if let array = value as? [Any] {
            return array.contains(where: inputContainsAstraBrowser)
        }
        return false
    }

    private static func browserShellIDs(fromToolInput input: [String: Any]?) -> Set<String> {
        guard let input else { return [] }
        return browserShellIDs(fromInputValue: input)
    }

    private static func browserShellIDs(fromInputValue value: Any) -> Set<String> {
        var ids: Set<String> = []
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let normalizedKey = key.lowercased().replacingOccurrences(of: "_", with: "")
                if normalizedKey == "shellid", let shellID = browserShellID(fromValue: nested) {
                    ids.insert(shellID)
                }
                ids.formUnion(browserShellIDs(fromInputValue: nested))
            }
        } else if let array = value as? [Any] {
            for nested in array {
                ids.formUnion(browserShellIDs(fromInputValue: nested))
            }
        }
        return ids
    }

    private static func browserShellID(fromValue value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let int = value as? Int {
            return String(int)
        }
        if let int64 = value as? Int64 {
            return String(int64)
        }
        if let double = value as? Double, double.rounded(.towardZero) == double {
            return String(Int(double))
        }
        return nil
    }

    private static func browserShellIDs(fromToolResult content: String) -> Set<String> {
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let pattern = #"\bshellId\b\s*[:=]\s*["']?([A-Za-z0-9_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var ids: Set<String> = []
        for match in regex.matches(in: content, range: nsRange) {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: content) else {
                continue
            }
            ids.insert(String(content[range]))
        }
        return ids
    }

    private static func isSuccessfulGoogleDocsVisiblePageRead(_ content: String) -> Bool {
        let lower = content.lowercased()
        guard lower.contains("googledocsmode"),
              lower.contains("visible_page"),
              lower.contains("partialsummaryallowed"),
              lower.contains(#""ok""#),
              !lower.contains(#""ok" : false"#),
              !lower.contains(#""ok":false"#) else {
            return false
        }
        return true
    }

    private static func browserTerminalStop(content: String, isKnownBrowserTool: Bool) -> (reason: String, message: String)? {
        let code = isKnownBrowserTool
            ? browserTerminalStopCode(inRawContent: content)
            : browserTerminalStopCode(inStructuredContent: content)
        guard let code else { return nil }

        switch code {
        case "drive_file_name_mismatch":
            return (
                code,
                "ASTRA stopped browser control because Google Drive opened a different file than the requested name. It did not continue into read or edit actions on the wrong file."
            )
        case "drive_file_not_opened":
            return (
                code,
                "ASTRA stopped browser control because the Google Drive open helper could not open the requested file. It did not fall back to generic row clicks or editor probing."
            )
        case "google_docs_browser_copy_unavailable":
            return (
                code,
                "ASTRA stopped browser control because it could not safely copy/read the Google Docs content from the browser. It did not fall back to manual probing or destructive editor shortcuts."
            )
        case "google_docs_controlled_browser_required":
            return (
                code,
                "ASTRA stopped browser control because full-document Google Docs read/replace requires Controlled mode. Embedded WebKit cannot verify a fresh clipboard copy from the Docs editor iframe, so ASTRA did not select or replace document content."
            )
        case "google_docs_safe_edit_unavailable":
            return (
                code,
                "ASTRA stopped browser control because the safe Google Docs browser read/replace helper is unavailable. It did not fall back to manual select-all/delete. Use the controlled browser, handle the document manually, or retry with a narrower non-destructive edit."
            )
        case "google_docs_safe_edit_verification_failed":
            return (
                code,
                "ASTRA stopped browser control because the Google Docs safe edit path could not verify the final document content. It did not fall back to manual select-all/delete."
            )
        case "controlled_browser_unavailable":
            return (
                code,
                "ASTRA stopped browser control because Google Drive/Docs automation requires controlled Chromium, but controlled browser was unavailable. Fix controlled browser setup or permissions before retrying."
            )
        case "unauthorized_browser_bridge_request":
            return (
                code,
                "ASTRA stopped browser control because the astra-browser command could not authenticate to the Shelf browser bridge. Restart or reattach the Shelf browser, then retry."
            )
        case "browser_action_budget_exceeded":
            return (
                code,
                "ASTRA stopped browser control because the browser action budget was exceeded. Inspect the browser logs or start a new task with a more specific browser strategy before retrying."
            )
        case "dangerous_keypress_sequence":
            return (
                code,
                "ASTRA stopped browser control because the browser bridge blocked a destructive keyboard sequence in an editor. Use a safe site-specific helper or explicit non-destructive edit path instead."
            )
        default:
            return nil
        }
    }

    private static let browserTerminalStopCodes = [
        "google_docs_controlled_browser_required",
        "google_docs_browser_copy_unavailable",
        "drive_file_name_mismatch",
        "drive_file_not_opened",
        "google_docs_safe_edit_unavailable",
        "google_docs_safe_edit_verification_failed",
        "controlled_browser_unavailable",
        "unauthorized_browser_bridge_request",
        "browser_action_budget_exceeded",
        "dangerous_keypress_sequence"
    ]

    private static func browserTerminalStopCode(inRawContent content: String) -> String? {
        let lower = content.lowercased()
        return browserTerminalStopCodes.first { lower.contains($0) }
    }

    private static func browserTerminalStopCode(inStructuredContent content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let object = jsonObject(fromExactContent: trimmed),
           let code = browserTerminalStopCode(inJSONObject: object) {
            return code
        }
        for line in trimmed.split(whereSeparator: \.isNewline) {
            let line = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let object = jsonObject(fromExactContent: line),
                  let code = browserTerminalStopCode(inJSONObject: object) else {
                continue
            }
            return code
        }
        return nil
    }

    private static func jsonObject(fromExactContent content: String) -> [String: Any]? {
        guard content.hasPrefix("{"), content.hasSuffix("}"),
              let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func browserTerminalStopCode(inJSONObject object: [String: Any]) -> String? {
        if looksLikeStructuredBrowserResponse(object) {
            for key in ["error", "stopReason"] {
                if let code = browserTerminalStopCode(fromExactValue: object[key]) {
                    return code
                }
            }
        }

        for key in ["content", "output", "stdout"] {
            guard let string = object[key] as? String,
                  let nested = jsonObject(fromExactContent: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let code = browserTerminalStopCode(inJSONObject: nested) else {
                continue
            }
            return code
        }

        for key in ["result", "response", "data"] {
            if let nested = object[key] as? [String: Any],
               let code = browserTerminalStopCode(inJSONObject: nested) {
                return code
            }
        }

        return nil
    }

    private static func looksLikeStructuredBrowserResponse(_ object: [String: Any]) -> Bool {
        object["ok"] != nil
            || object["browserTrace"] != nil
            || object["debugCapture"] != nil
            || object["requiredEngine"] != nil
            || object["selectedEngine"] != nil
            || (object["source"] as? String)?.lowercased().contains("browser") == true
    }

    private static func browserTerminalStopCode(fromExactValue value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return browserTerminalStopCodes.contains(normalized) ? normalized : nil
    }

    private static func isProviderPermissionDenial(_ content: String) -> Bool {
        let lower = content.lowercased()
        return lower.contains("permission denied and could not request permission from user")
            || lower.contains("this command requires approval")
            || lower.contains("command requires approval")
            || (lower.contains("allow access to these paths") && lower.contains("(y/n)"))
    }

    private func recordProviderPermissionDenial(
        toolID: String?,
        explicitToolName: String?,
        detail: String,
        process: AgentRuntimeProcessControl?
    ) -> Bool {
        guard !_policyViolation,
              !_policyApprovalRequired,
              _runtimeStopReason == nil else {
            return false
        }

        let context = toolContext(for: toolID)
        let toolName = Self.nonEmpty(explicitToolName?.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? Self.nonEmpty(context?.name)
            ?? "ToolApproval"
        let providerName = policyGuard?.providerID.displayName ?? "The provider"
        let providerDetail = LogSanitizer.sanitize(detail, maxLength: 360)
        let requestText = context?.summary
            .map { "\nRecent request: \(LogSanitizer.sanitize($0, maxLength: 500))" }
            ?? ""
        let providerID = policyGuard?.providerID ?? .claudeCode
        let permissionRequest = Self.providerPermissionRequest(toolName: toolName, context: context)
        let policyProbeViolation = Self.shouldPolicyProbeProviderPermission(toolName: toolName, context: context)
            ? policyGuard?.violation(for: Self.providerPermissionPolicyProbe(toolName: toolName, toolID: toolID, context: context))
            : nil
        if let policyProbeViolation, !policyProbeViolation.requiresApproval {
            return recordPolicyViolation(policyProbeViolation, process: process)
        }
        let approvalGrants = PermissionBroker.approvalGrants(
            for: policyProbeViolation?.permissionRequest ?? permissionRequest
        )

        if policyGuard?.usesBroadProviderPermissions == true {
            let message = """
            \(providerName) denied a tool request even though ASTRA launched it with broad provider permissions (`--allow-all` / `--allow-all-tools`). This is a provider-side, account, organization, or CLI policy denial, not an ASTRA permission that another approval can expand.
            Tool: \(toolName).\(requestText)
            Provider detail: \(providerDetail)
            """
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
                "reason": "provider_permission_denied_broad_permissions",
                "tool": toolName,
                "tool_id": toolID ?? "unknown",
                "detail": providerDetail
            ], level: .error, fieldMaxLength: 360)
            _runtimeStopReason = "provider_permission_denied_broad_permissions"
            _runtimeStopMessage = message
        } else if approvalGrants.isEmpty {
            let message = """
            \(providerName) requested a native permission prompt that ASTRA cannot safely approve in the non-interactive runtime.
            Tool: \(toolName).\(requestText)
            Provider detail: \(providerDetail)

            ASTRA stopped this run instead of offering an approval because this provider request does not map to a scoped runtime permission that can be applied on retry. Review the workspace paths or policy settings, then retry with the needed access already in scope.
            """
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
                "reason": "provider_permission_unresumable",
                "tool": toolName,
                "tool_id": toolID ?? "unknown",
                "detail": providerDetail
            ], level: .error, fieldMaxLength: 360)
            _runtimeStopReason = "provider_permission_unresumable"
            _runtimeStopMessage = message
        } else if policyGuard?.hasAppliedApprovalGrants(approvalGrants) == true {
            let providerGrantSummary = PermissionBroker.providerGrantStrings(
                for: approvalGrants,
                runtime: providerID
            ).joined(separator: ",")
            let message = """
            \(providerName) denied the tool request after ASTRA had already applied the scoped approval for this run.
            Tool: \(toolName).\(requestText)
            Applied grant: \(providerGrantSummary.isEmpty ? "the requested runtime permission" : providerGrantSummary)
            Provider detail: \(providerDetail)

            ASTRA stopped instead of asking for the same approval again. This usually means the provider CLI, account policy, or organization policy rejected the request after ASTRA allowed the scoped operation.
            """
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
                "reason": "provider_permission_denied_after_approval",
                "tool": toolName,
                "tool_id": toolID ?? "unknown",
                "approval_grant": providerGrantSummary.isEmpty ? "none" : providerGrantSummary,
                "detail": providerDetail
            ], level: .error, fieldMaxLength: 360)
            _runtimeStopReason = "provider_permission_denied_after_approval"
            _runtimeStopMessage = message
        } else {
            let message = PermissionBroker.approvalPayloadString(
                providerID: providerID,
                request: permissionRequest,
                reason: "\(providerName) reported a tool permission prompt that ASTRA cannot answer inside the non-interactive runtime.",
                providerDetail: providerDetail,
                grants: approvalGrants
            )
            let providerGrantSummary = PermissionBroker.providerGrantStrings(
                for: approvalGrants,
                runtime: providerID
            ).joined(separator: ",")
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
                "reason": "provider_permission_approval_required",
                "tool": toolName,
                "tool_id": toolID ?? "unknown",
                "approval_grant": providerGrantSummary.isEmpty ? "none" : providerGrantSummary,
                "detail": providerDetail
            ], level: .warning, fieldMaxLength: 360)
            _policyApprovalRequired = true
            _policyApprovalMessage = message
        }

        process?.terminate()
        return true
    }

    private static func providerPermissionRequest(toolName: String, context: ToolUseContext?) -> PermissionRequest {
        let contextToolName = context?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToolName = nonEmpty(contextToolName) ?? toolName
        let contextSummary = context.flatMap { nonEmpty($0.summary) }
        if isShellToolName(effectiveToolName) || isShellToolName(toolName) {
            let command = providerPermissionCommandHint(toolName: effectiveToolName, context: context)
                ?? providerPermissionCommandHint(toolName: toolName, context: context)
            if let command {
                return .shell(command: command, toolName: effectiveToolName)
            }
        }
        return PermissionBroker.providerNativePromptRequest(
            toolName: effectiveToolName,
            context: contextSummary
        )
    }

    private static func providerPermissionPolicyProbe(
        toolName: String,
        toolID: String?,
        context: ToolUseContext?
    ) -> ParsedEvent {
        let contextToolName = context?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToolName = nonEmpty(contextToolName) ?? toolName
        let isShell = isShellToolName(effectiveToolName) || isShellToolName(toolName)
        let probeToolName = isShell ? "Bash" : effectiveToolName
        var input: [String: Any] = [:]
        if isShell,
           let command = providerPermissionCommandHint(toolName: effectiveToolName, context: context)
            ?? providerPermissionCommandHint(toolName: toolName, context: context) {
            input["command"] = command
            input["summary"] = command
        } else if let summary = nonEmpty(context?.summary) {
            input["summary"] = summary
        }
        return .toolUse(name: probeToolName, id: toolID ?? "", input: input.isEmpty ? nil : input)
    }

    private static func shouldPolicyProbeProviderPermission(toolName: String, context: ToolUseContext?) -> Bool {
        let contextToolName = context?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToolName = nonEmpty(contextToolName) ?? toolName
        if isShellToolName(effectiveToolName) || isShellToolName(toolName) {
            return true
        }
        switch effectiveToolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read", "view", "write", "create", "edit", "multiedit", "multi_edit", "apply_patch", "webfetch", "websearch":
            return true
        default:
            return false
        }
    }

    private static func providerPermissionCommandHint(toolName: String, context: ToolUseContext?) -> String? {
        if let summary = nonEmpty(context?.summary) {
            if let command = commandHintFromJSONSummary(summary) {
                return command
            }
            return summary
        }
        return AgentRuntimePolicyGuard.commandHintFromShellPermissionToolName(toolName)
    }

    private static func commandHintFromJSONSummary(_ summary: String) -> String? {
        guard let object = jsonObject(fromExactContent: summary) else { return nil }
        for key in ["command", "cmd"] {
            if let value = object[key] as? String,
               let command = nonEmpty(value) {
                return command
            }
        }
        return nil
    }

    private static func isShellToolName(_ toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "bash"
            || normalized == "shell"
            || normalized.hasPrefix("shell(")
            || normalized.hasPrefix("bash(")
    }

    private static func canonicalProviderToolName(_ toolName: String) -> String {
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read", "view": return "Read"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "write": return "Write"
        case "edit": return "Edit"
        case "multiedit", "multi_edit": return "MultiEdit"
        case "bash", "shell": return "Bash"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        case "agent": return "Agent"
        default: return toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func recordPolicyViolation(_ violation: AgentRuntimePolicyViolation, process: AgentRuntimeProcessControl?) -> Bool {
        guard !_policyViolation, !_policyApprovalRequired else { return false }
        let redactedDetail = violation.detail.map { LogSanitizer.sanitize($0, maxLength: 240) }
        let reason = violation.requiresApproval ? "runtime_policy_approval_required" : "runtime_policy_violation"
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
            "reason": reason,
            "violation_category": violation.violationCategory,
            "tool": violation.toolName ?? "unknown",
            "message": violation.reason,
            "approval_grant": PermissionBroker.providerGrantStrings(
                for: violation.approvalGrants,
                runtime: policyGuard?.providerID ?? .claudeCode
            ).joined(separator: ","),
            "detail": redactedDetail ?? "none"
        ], level: violation.requiresApproval ? .warning : .error)
        if violation.requiresApproval {
            let providerID = policyGuard?.providerID ?? .claudeCode
            let request = violation.permissionRequest
                ?? PermissionBroker.providerNativePromptRequest(
                    toolName: violation.toolName ?? "ToolApproval",
                    context: redactedDetail
                )
            let grants = violation.approvalGrants.isEmpty
                ? PermissionBroker.approvalGrants(for: request)
                : violation.approvalGrants
            guard !grants.isEmpty else {
                _runtimeStopReason = "permission_unresumable"
                _runtimeStopMessage = """
                ASTRA stopped this run because the requested action requires approval but does not map to a scoped runtime permission that can be replayed safely.
                Tool: \(violation.toolName ?? "unknown").
                \(redactedDetail.map { "Detail: \($0)" } ?? "")
                """
                process?.terminate()
                return true
            }
            let message = PermissionBroker.approvalPayloadString(
                providerID: providerID,
                request: request,
                reason: violation.reason,
                grants: grants
            )
            _policyApprovalRequired = true
            _policyApprovalMessage = message
        } else {
            let message = AgentRuntimePolicyViolation(
                reason: violation.reason,
                toolName: violation.toolName,
                detail: redactedDetail,
                violationCategory: violation.violationCategory,
                requiresApproval: violation.requiresApproval,
                permissionRequest: violation.permissionRequest,
                approvalGrants: violation.approvalGrants
            ).userMessage
            _policyViolation = true
            _policyViolationMessage = message
        }
        process?.terminate()
        return true
    }

    private func recordOSSandboxFileDenial(
        _ denial: RuntimeSandboxFileDenial,
        toolID: String?,
        toolResultWasError: Bool,
        process: AgentRuntimeProcessControl?
    ) -> Bool {
        // Receipt-protected input writes are terminal only from a failed tool result.
        guard sandboxDiagnosticContext.appliedBoundaryExplains(denial)
                || (toolResultWasError && denial.operation == .write && readOnlyBoundaryReceipt?.protects(denial.path) == true),
              !_policyViolation, !_policyApprovalRequired, _runtimeStopReason == nil else { return false }
        let context = toolContext(for: toolID)
        let toolName = Self.nonEmpty(context?.name) ?? "Tool"
        let requestText = RuntimeSandboxDenialApproval.requestText(for: context?.summary)
        let decision = RuntimeSandboxDenialApproval.resolve(
            denial: denial, toolName: toolName, requestText: requestText,
            approvalWasApplied: policyGuard?.hasAppliedApprovalGrants([
                .sandboxPath(path: ExecutionSandbox.canonicalize(denial.path) ?? denial.path, access: "read")
            ]) == true,
            readOnlyBoundaryReceipt: readOnlyBoundaryReceipt, denialReflectsToolFailure: toolResultWasError
        )
        guard case .request(let request, let grants) = decision else {
            guard case .terminal(let reason, let message) = decision else { return false }
            RuntimeSandboxDenialAudit.recordTerminal(reason: reason, denial: denial, toolName: toolName, taskID: taskID)
            _runtimeStopReason = reason
            _runtimeStopMessage = message
            process?.terminate()
            return true
        }
        let providerID = policyGuard?.providerID ?? .claudeCode
        let message = PermissionBroker.approvalPayloadString(
            providerID: providerID,
            request: request,
            reason: "ASTRA's applied execution sandbox blocked a bounded local read required by this operation.",
            providerDetail: denial.detail,
            grants: grants
        )
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
            "reason": denial.stopReason,
            "source": "execution_sandbox_denial",
            "operation": denial.operation.rawValue,
            "path": denial.path,
            "tool": toolName,
            "detail": denial.detail
        ], level: .warning, fieldMaxLength: 360)
        _policyApprovalRequired = true
        _policyApprovalMessage = message
        process?.terminate()
        return true
    }
    private func recordRuntimeStop(
        reason: String,
        message: String,
        process: AgentRuntimeProcessControl?,
        source: String = "browser_terminal_error"
    ) -> Bool {
        guard _runtimeStopReason == nil else { return false }
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
            "reason": reason,
            "source": source,
            "message": message
        ], level: .error, fieldMaxLength: 260)
        _runtimeStopReason = reason
        _runtimeStopMessage = message
        process?.terminate()
        return true
    }

    private func recordBudgetOverage(reason: String, fields: [String: String], process: AgentRuntimeProcessControl?) -> Bool {
        var auditFields = fields
        auditFields["reason"] = reason
        auditFields["enforcement"] = BudgetEnforcementMode.hardStop.rawValue
        // Without this, a hard stop under an app configured for Warning Only
        // reads as a bug in the log. It isn't: the ceiling that fired is the
        // implicit one, which the mode does not govern.
        auditFields["budget_source"] = isUserConfiguredBudget ? "user" : "runaway_ceiling"
        AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: auditFields, level: .error)
        _budgetExceeded = true
        process?.terminate()
        return true
    }

    private func recordBudgetWarning(reason: String, fields: [String: String], process _: AgentRuntimeProcessControl?) -> Bool {
        guard !_budgetWarning else { return false }
        var auditFields = fields
        auditFields["reason"] = reason
        auditFields["enforcement"] = BudgetEnforcementMode.warning.rawValue
        AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: auditFields, level: .warning)
        _budgetWarning = true
        return false
    }

    func recordActivity() {
        lock.lock()
        let now = Date()
        lastAnyActivityTime = now
        hasSeenAnyActivity = true
        hasSeenProviderLivenessActivity = true
        markSemanticProgressLocked(now: now)
        lock.unlock()
    }

    /// Records raw stream volume, independent of what the bytes parsed into.
    ///
    /// This is the fix for the whole class of "the parser did not recognise the
    /// frame, so the watchdog concluded the provider was idle" failures. A
    /// provider that has pushed a meaningful amount of output since the last
    /// recognised progress event is observably working, so the semantic clock
    /// advances on volume alone. The run-wall-clock ceiling is what keeps this
    /// from becoming an unbounded licence to burn tokens.
    func recordStreamVolume(bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        cumulativeStreamBytes += bytes
        guard cumulativeStreamBytes - streamBytesAtLastProgress
                >= RuntimeProgressSignals.semanticProgressByteThreshold else {
            return
        }

        let now = Date()
        lastAnyActivityTime = now
        hasSeenAnyActivity = true
        markSemanticProgressLocked(now: now)
    }

    var streamBytesObserved: Int { lock.lock(); defer { lock.unlock() }; return cumulativeStreamBytes }
    var unrecognizedEventCount: Int { lock.lock(); defer { lock.unlock() }; return unknownEventCount }

    /// The single place the semantic-progress clock advances, so the byte mark
    /// and the escalation budget can never drift out of step with it. Callers
    /// must already hold `lock`.
    private func markSemanticProgressLocked(now: Date) {
        lastActivityTime = now
        hasSeenProgressActivity = true
        streamBytesAtLastProgress = cumulativeStreamBytes
        semanticProgressExtensionsUsed = 0
        semanticProgressExtensionExpiresAt = nil
    }

    /// Read live rather than from the evaluation's opening snapshot: a semantic
    /// branch earlier in the same pass may have just granted the reprieve.
    private func hasLiveSemanticExtension(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expiry = semanticProgressExtensionExpiresAt else { return false }
        return now < expiry
    }

    func startWatchdog(process: AgentRuntimeProcessControl) {
        lock.lock()
        guard !watchdogRunning else { lock.unlock(); return }
        watchdogRunning = true
        lock.unlock()

        let processBox = AgentRuntimeProcessControlBox(process)
        let checkInterval = Self.watchdogCheckInterval(
            idleTimeoutSeconds: idleTimeoutSeconds,
            noSemanticProgressTimeoutSeconds: noSemanticProgressTimeoutSeconds
        )
        DispatchQueue.global().async { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: checkInterval)
                guard let self, processBox.isRunning else { return }

                if self.evaluateWatchdogTimeout(
                    gracefulStop: { processBox.requestGracefulStop() },
                    awaitGracefulExit: {
                        Self.waitForExit(processBox, timeout: Self.gracefulStopGraceSeconds)
                    },
                    terminate: { processBox.terminate() }
                ) {
                    return
                }
            }
        }
    }

    /// How long a provider gets to act on stdin EOF before the signal ladder
    /// starts. Short enough that a wedged provider is not held onto, long
    /// enough for an event loop to come round and write a buffered result.
    static let gracefulStopGraceSeconds: TimeInterval = 2

    /// Polls, because `AgentRuntimeProcessControl` publishes liveness and gives
    /// nothing to block on. It costs nothing: this runs on the watchdog's own
    /// thread, which spends the rest of the run asleep.
    private static func waitForExit(
        _ process: AgentRuntimeProcessControlBox,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    static func watchdogCheckInterval(
        idleTimeoutSeconds: TimeInterval,
        noSemanticProgressTimeoutSeconds: TimeInterval
    ) -> TimeInterval {
        let shortestTimeout = min(idleTimeoutSeconds, noSemanticProgressTimeoutSeconds)
        guard shortestTimeout.isFinite, shortestTimeout > 0 else { return 1 }
        return min(shortestTimeout, max(0.1, min(30, shortestTimeout / 4)))
    }

    /// `awaitGracefulExit` defaults to "it did not exit", so a test still
    /// observes the terminate it is asserting on without sleeping through the
    /// real grace period.
    @discardableResult
    func evaluateWatchdogTimeoutForTesting(
        process: AgentRuntimeProcessControl? = nil,
        awaitGracefulExit: () -> Bool = { false }
    ) -> Bool {
        evaluateWatchdogTimeout(
            gracefulStop: { process?.requestGracefulStop() },
            awaitGracefulExit: awaitGracefulExit,
            terminate: { process?.terminate() }
        )
    }

    @discardableResult
    private func evaluateWatchdogTimeout(
        gracefulStop: () -> Void = {},
        awaitGracefulExit: () -> Bool = { false },
        terminate: () -> Void
    ) -> Bool {
        lock.lock()
        let now = Date()
        let idleDuration = now.timeIntervalSince(lastActivityTime)
        let anyIdleDuration = now.timeIntervalSince(lastAnyActivityTime)
        let terminalIdleDuration = lastTerminalProgressTime.map { now.timeIntervalSince($0) }
        let stalledManagedWorkspaceJob = refreshManagedWorkspaceJobs(now: now)
        let hasMetadataOnlyActivity = hasSeenAnyActivity
            && !hasSeenProviderLivenessActivity
            && !hasSeenProgressActivity
        let hasProviderLivenessOnlyActivity = hasSeenProviderLivenessActivity
            && !hasSeenProgressActivity
        let hasActiveToolUse = !activeToolUseIDs.isEmpty
        let hasActiveManagedWorkspaceJob = !activeManagedWorkspaceJobs.isEmpty
        let hasActiveRuntimeWork = hasActiveToolUse || hasActiveManagedWorkspaceJob
        // `anyIdleDuration < idleTimeoutSeconds` is a precedence rule, not a
        // second deadline: a provider that has gone *completely* silent past the
        // outer idle timeout is a plain timeout, and that branch should own the
        // kill rather than this one. But the semantic timeout is
        // `min(idleTimeoutSeconds, 180)`, so any idle timeout at or below 180s
        // makes the two deadlines identical — and then this predicate is false
        // at the very moment it should be true, every time. The run falls
        // through to the idle branch and is killed outright, never receiving the
        // one extension this watchdog exists to grant. When the deadlines
        // coincide there is no precedence question to answer, and this branch is
        // the better-informed of the two: it knows progress happened earlier,
        // and it escalates before it stops.
        let deadlinesCoincide = noSemanticProgressTimeoutSeconds >= idleTimeoutSeconds
        let hasStalledAfterProgress = hasSeenProgressActivity
            && terminalIdleDuration == nil
            && !hasActiveRuntimeWork
            && (deadlinesCoincide || anyIdleDuration < idleTimeoutSeconds)
            && idleDuration >= noSemanticProgressTimeoutSeconds
        // Letting the branch above own the kill is not enough when its deadline
        // lands *after* the idle one. `semanticProgressTimeout` returns
        // `idleTimeout * 2` for a task that owes a deliverable, so every idle
        // timeout below 360s puts the artifact window past the idle deadline —
        // and the generic branch below would fire first, every time. The window
        // that was widened to give a resumed deliverable room to write was
        // therefore unreachable for exactly the short-timeout runs it was
        // widened for: an idle timeout of 120s yields a 240s window and a kill
        // at 120s.
        //
        // So the generic deadline waits while that first window is still live.
        // It is not waived: once the window is spent, `hasStalledAfterProgress`
        // above takes the kill, and it escalates once before it stops. Bounded
        // at two windows, and only for a run that produced visible progress and
        // then went quiet — a provider that never produced any is still owned by
        // the metadata-only and liveness-only branches on their own deadlines.
        let hasPendingArtifactWindow = hasSeenProgressActivity
            && terminalIdleDuration == nil
            && !hasActiveRuntimeWork
            && noSemanticProgressTimeoutSeconds > idleTimeoutSeconds
            && idleDuration < noSemanticProgressTimeoutSeconds
        // An unrecognised frame inside the current silence window means the
        // event taxonomy is behind the provider's stream format. "No recognised
        // progress" then stops being evidence of "no progress", so the
        // aggressive kills stand down and the outer idle timeout takes over.
        let hasUnrecognizedTrafficInWindow = lastUnknownEventTime.map { $0 >= lastActivityTime } ?? false
        let runDuration = now.timeIntervalSince(runStartedAt)
        let progressDiagnostics = [
            "stream_bytes": String(cumulativeStreamBytes),
            "stream_bytes_since_progress": String(cumulativeStreamBytes - streamBytesAtLastProgress),
            "unknown_events": String(unknownEventCount),
            "run_seconds": String(Int(runDuration))
        ]
        lock.unlock()

        // Checked before every silence-based branch: those all measure how long
        // the provider has been quiet, so a chatty runaway never reaches them.
        if maxRunSeconds > 0, runDuration >= maxRunSeconds {
            let reason = "provider_run_wall_clock_exceeded"
            let message = """
            ASTRA stopped the provider because the run hit its \(Int(maxRunSeconds / 60))-minute wall-clock ceiling.
            Every other runtime timeout measures silence, so a provider that keeps streaming can hold them off indefinitely; this ceiling bounds the run regardless of how busy it looks.
            """
            AppLogger.audit(.workerTimeout, category: "Worker", taskID: taskID, fields: progressDiagnostics.merging([
                "reason": reason,
                "limit_seconds": String(Int(maxRunSeconds))
            ]) { _, new in new }, level: .error)
            lock.lock()
            if _runtimeStopReason == nil {
                _runtimeStopReason = reason
                _runtimeStopMessage = message
            }
            lock.unlock()
            Self.stopProvider(gracefulStop: gracefulStop, awaitGracefulExit: awaitGracefulExit, terminate: terminate)
            return true
        }

        if let terminalIdleDuration,
           terminalIdleDuration >= terminalProgressExitGraceSeconds {
            lock.lock()
            _terminatedAfterTerminalProgress = true
            lock.unlock()
            terminate()
            return true
        }

        if let stalledManagedWorkspaceJob {
            let reason = "provider_workspace_job_stalled"
            let lastObservedAge = max(0, Int(now.timeIntervalSince(stalledManagedWorkspaceJob.lastObservedAt)))
            let message = """
            ASTRA stopped the provider because managed workspace job \(stalledManagedWorkspaceJob.id) stopped producing a fresh heartbeat for \(lastObservedAge) seconds.
            Long-running Docker workspace commands can run for hours, but ASTRA requires the managed job heartbeat or result file to keep changing so hangs remain detectable.
            """
            AppLogger.audit(.workerTimeout, category: "Worker", taskID: taskID, fields: [
                "reason": reason,
                "job_id": stalledManagedWorkspaceJob.id,
                "job_status": stalledManagedWorkspaceJob.status,
                "last_observed_age_seconds": String(lastObservedAge),
                "limit_seconds": String(Int(managedWorkspaceJobIdleTimeoutSeconds))
            ], level: .error)
            lock.lock()
            if _runtimeStopReason == nil {
                _runtimeStopReason = reason
                _runtimeStopMessage = message
            }
            lock.unlock()
            terminate()
            return true
        }

        if hasActiveToolUse && anyIdleDuration >= activeToolIdleTimeoutSeconds {
            let reason = "provider_active_tool_stalled"
            let message = """
            ASTRA stopped the provider because a tool call was still running but produced no provider event or tool output for \(Int(anyIdleDuration)) seconds.
            Long-running commands should stream periodic output or finish within \(Int(activeToolIdleTimeoutSeconds)) seconds.
            """
            AppLogger.audit(.workerTimeout, category: "Worker", taskID: taskID, fields: [
                "reason": reason,
                "active_tool_idle_seconds": String(Int(anyIdleDuration)),
                "limit_seconds": String(Int(activeToolIdleTimeoutSeconds))
            ], level: .error)
            lock.lock()
            if _runtimeStopReason == nil {
                _runtimeStopReason = reason
                _runtimeStopMessage = message
            }
            lock.unlock()
            terminate()
            return true
        }

        let sharedIdleFields = progressDiagnostics.merging([
            "semantic_idle_seconds": String(Int(idleDuration)),
            "last_event_age_seconds": String(Int(anyIdleDuration)),
            "limit_seconds": String(Int(noSemanticProgressTimeoutSeconds))
        ]) { _, new in new }

        if !hasActiveRuntimeWork && hasMetadataOnlyActivity && idleDuration >= noSemanticProgressTimeoutSeconds {
            if escalateOrStopForSilence(
                reason: "provider_no_semantic_progress",
                message: """
                ASTRA stopped the provider because it emitted startup or lifecycle metadata but never produced semantic progress such as text, tool use, tool output, usage, or a result.
                Metadata-only activity continued for \(Int(idleDuration)) seconds; the last provider event was \(Int(anyIdleDuration)) seconds ago.
                """,
                auditFields: sharedIdleFields,
                deferForUnrecognizedTraffic: hasUnrecognizedTrafficInWindow,
                now: now,
                gracefulStop: gracefulStop,
                awaitGracefulExit: awaitGracefulExit,
                terminate: terminate
            ) {
                return true
            }
        }

        if !hasActiveRuntimeWork && hasProviderLivenessOnlyActivity && idleDuration >= noSemanticProgressTimeoutSeconds {
            if escalateOrStopForSilence(
                reason: "provider_no_actionable_progress",
                message: """
                ASTRA stopped the provider because it streamed provider-side liveness such as partial thinking or accounting, but never produced visible text, tool use, tool output, a result, or enough raw stream output to count as progress.
                Liveness-only activity continued for \(Int(idleDuration)) seconds; the last provider event was \(Int(anyIdleDuration)) seconds ago.
                """,
                auditFields: sharedIdleFields.merging([
                    "actionable_idle_seconds": String(Int(idleDuration))
                ]) { _, new in new },
                deferForUnrecognizedTraffic: hasUnrecognizedTrafficInWindow,
                now: now,
                gracefulStop: gracefulStop,
                awaitGracefulExit: awaitGracefulExit,
                terminate: terminate
            ) {
                return true
            }
        }

        if hasStalledAfterProgress {
            if escalateOrStopForSilence(
                reason: "provider_semantic_progress_stalled",
                message: """
                ASTRA stopped the provider because it had produced semantic progress earlier but stopped advancing the task.
                No visible text, tool use, tool output, result, or meaningful stream output arrived for \(Int(idleDuration)) seconds; the last provider event was \(Int(anyIdleDuration)) seconds ago.
                """,
                auditFields: sharedIdleFields,
                deferForUnrecognizedTraffic: hasUnrecognizedTrafficInWindow,
                now: now,
                gracefulStop: gracefulStop,
                awaitGracefulExit: awaitGracefulExit,
                terminate: terminate
            ) {
                return true
            }
        }

        if !hasActiveRuntimeWork, anyIdleDuration >= idleTimeoutSeconds,
           !hasPendingArtifactWindow, !hasLiveSemanticExtension(now: now) {
            AppLogger.audit(.workerTimeout, category: "Worker", taskID: taskID, fields: [
                "idle_seconds": String(Int(anyIdleDuration)),
                "semantic_idle_seconds": String(Int(idleDuration)),
                "limit_seconds": String(Int(idleTimeoutSeconds)),
                // The deadline that actually applied. When the artifact window
                // is wider, a kill logged against `idleTimeoutSeconds` alone
                // reads as having fired minutes late.
                "semantic_limit_seconds": String(Int(noSemanticProgressTimeoutSeconds))
            ], level: .error)
            lock.lock()
            _timedOut = true
            lock.unlock()
            terminate()
            return true
        }

        return false
    }

    /// Decides what a breached silence window actually earns.
    ///
    /// Three outcomes, in order of how much the watchdog trusts itself:
    ///
    /// 1. Unrecognised frames arrived inside the window — the taxonomy is out of
    ///    date, so this branch has no standing to kill. Defer to the outer idle
    ///    timeout and leave a trace so the parser gap is findable.
    /// 2. First breach — extend once. A kill throws away the entire run, and the
    ///    common false positive is a provider that is seconds from emitting.
    /// 3. Breached again after the extension — stop the run.
    ///
    /// Returns true only when the run was stopped.
    private func escalateOrStopForSilence(
        reason: String,
        message: String,
        auditFields: [String: String],
        deferForUnrecognizedTraffic: Bool,
        now: Date,
        gracefulStop: () -> Void,
        awaitGracefulExit: () -> Bool,
        terminate: () -> Void
    ) -> Bool {
        if deferForUnrecognizedTraffic {
            guard claimUnrecognizedDeferralTrace(reason: reason) else { return false }
            AppLogger.audit(.workerTimeout, category: "Worker", taskID: taskID, fields: auditFields.merging([
                "reason": reason,
                "outcome": "deferred_unrecognized_stream"
            ]) { _, new in new }, level: .warning)
            return false
        }

        lock.lock()
        let extensionsUsed = semanticProgressExtensionsUsed
        if extensionsUsed < Self.maxSemanticProgressExtensions {
            semanticProgressExtensionsUsed = extensionsUsed + 1
            // Extend the window without rebasing the byte mark or
            // `lastAnyActivityTime`: no progress was observed, only forgiven,
            // and the audit trail should keep saying how long the provider has
            // really been quiet.
            lastActivityTime = now
            semanticProgressExtensionExpiresAt = now.addingTimeInterval(noSemanticProgressTimeoutSeconds)
            lock.unlock()
            AppLogger.audit(.workerTimeout, category: "Worker", taskID: taskID, fields: auditFields.merging([
                "reason": reason,
                "outcome": "window_extended",
                "extension": String(extensionsUsed + 1)
            ]) { _, new in new }, level: .warning)
            return false
        }
        lock.unlock()

        AppLogger.audit(.workerTimeout, category: "Worker", taskID: taskID, fields: auditFields.merging([
            "reason": reason,
            "outcome": "terminated",
            "extensions_used": String(extensionsUsed)
        ]) { _, new in new }, level: .error)

        lock.lock()
        if _runtimeStopReason == nil {
            _runtimeStopReason = reason
            _runtimeStopMessage = message
        }
        lock.unlock()
        Self.stopProvider(gracefulStop: gracefulStop, awaitGracefulExit: awaitGracefulExit, terminate: terminate)
        return true
    }

    /// Closes the provider's stdin, gives it a moment to act on the EOF, and
    /// only then starts signalling.
    ///
    /// `requestGracefulStop` exists so an interactive stream-JSON provider can
    /// notice the run is over and flush the result it is already holding.
    /// Sending SIGTERM in the very next statement takes that back: the default
    /// disposition for SIGTERM is to die, so a provider whose event loop has not
    /// yet come round to the EOF is killed before it can write anything, and the
    /// call was pure ceremony. The three-second delay inside `terminate()` does
    /// not help — it sits between SIGTERM and SIGKILL, by which point the
    /// process is already unwinding.
    private static func stopProvider(
        gracefulStop: () -> Void,
        awaitGracefulExit: () -> Bool,
        terminate: () -> Void
    ) {
        gracefulStop()
        guard !awaitGracefulExit() else { return }
        terminate()
    }

    /// True the first time `reason` defers inside the current silence window.
    ///
    /// See `tracedDeferralWindowStart` for why the deferral has to be rationed:
    /// it is the one branch of the watchdog that leaves the run exactly as it
    /// found it, so the poll after it looks identical to the poll before it.
    private func claimUnrecognizedDeferralTrace(reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let windowStart = lastActivityTime
        if tracedDeferralWindowStart != windowStart {
            tracedDeferralWindowStart = windowStart
            tracedDeferralReasons = []
        }
        guard tracedDeferralReasons.insert(reason).inserted else { return false }
        _unrecognizedDeferralTraceCount += 1
        return true
    }

    /// How many deferral traces have actually been written. The log line itself
    /// is the thing being rationed and a test cannot read the log, so the count
    /// stands in for it.
    var unrecognizedDeferralTraceCount: Int {
        lock.lock(); defer { lock.unlock() }; return _unrecognizedDeferralTraceCount
    }

    private func refreshManagedWorkspaceJobs(now: Date) -> ManagedWorkspaceJobContext? {
        var stalledJob: ManagedWorkspaceJobContext?
        for (jobID, var job) in activeManagedWorkspaceJobs {
            if let resultPath = job.resultPath,
               let result = Self.managedWorkspaceJobFileState(atPath: resultPath),
               let status = result.status {
                job.status = status
                if let timestamp = result.timestamp, timestamp > job.lastObservedAt {
                    job.lastObservedAt = timestamp
                }
                if job.isTerminal {
                    activeManagedWorkspaceJobs.removeValue(forKey: jobID)
                    continue
                }
            }

            if let heartbeatPath = job.heartbeatPath,
               let heartbeat = Self.managedWorkspaceJobFileState(atPath: heartbeatPath) {
                if let status = heartbeat.status {
                    job.status = status
                }
                if let timestamp = heartbeat.timestamp {
                    job.lastHeartbeatAt = timestamp
                    job.lastObservedAt = timestamp
                } else if let modificationDate = Self.fileModificationDate(atPath: heartbeatPath),
                          modificationDate > job.lastObservedAt {
                    job.lastObservedAt = modificationDate
                }
                if job.isTerminal {
                    activeManagedWorkspaceJobs.removeValue(forKey: jobID)
                    continue
                }
            }

            activeManagedWorkspaceJobs[jobID] = job
            if now.timeIntervalSince(job.lastObservedAt) >= managedWorkspaceJobIdleTimeoutSeconds {
                stalledJob = job
                break
            }
        }
        return stalledJob
    }

    static func progressKind(for parsed: ParsedEvent) -> RuntimeProgressKind {
        switch parsed {
        case .control(let type):
            // Streaming a tool call's arguments, or a running tool's partial
            // stdout, is generation work rather than idle chatter: it can hold
            // the stream for minutes emitting nothing else, and treating it as
            // liveness gets the run killed mid-write by the semantic-progress
            // watchdog. Every runtime that streams work this way registers its
            // control type in `RuntimeProgressSignals`.
            return RuntimeProgressSignals.isProgressBearingControl(type)
                ? .actionableProgress
                : .providerLiveness
        case .systemInit: return .lifecycleMetadata
        case .unknown:
            return .diagnostic
        case .usage:
            return .accounting
        case .result:
            return .terminal
        case .astraProtocol:
            return .terminal
        case .text(let text):
            return nonEmpty(text) == nil ? .diagnostic : .visibleProgress
        case .thinking(let text):
            return nonEmpty(text) == nil ? .diagnostic : .providerLiveness
        case .toolResult(_, let content, _):
            return nonEmpty(content) == nil ? .diagnostic : .actionableProgress
        case .toolUse, .teammateStarted, .teammateCompleted, .teamCreated, .teamDeleted, .teamMessage, .permissionDenied:
            return .actionableProgress
        }
    }

    private static func isSuccessfulTerminalProgress(_ parsed: ParsedEvent) -> Bool {
        switch parsed {
        case .astraProtocol(.valid(.complete)):
            return true
        case .result(_, _, _, _, _, _, let isError):
            return !isError
        default:
            return false
        }
    }

    static func repetitionSignature(_ parsed: ParsedEvent) -> String? {
        switch parsed {
        case .text(let text):
            return nonEmpty(text).map { textSignature(prefix: "text", text: $0) }
        case .thinking(let text):
            return nonEmpty(text).map { textSignature(prefix: "think", text: $0) }
        case .toolUse(let name, _, let input):
            return "tool:\(name):\(inputSignature(input))"
        case .toolResult(_, let content, _):
            return nonEmpty(content).map { textSignature(prefix: "tool.result", text: $0) }
        case .teammateStarted(_, let name, let prompt):
            return "teammate.start:\(name):\(textSignature(prefix: "prompt", text: prompt))"
        case .teammateCompleted(_, let name):
            return "teammate.done:\(name)"
        case .teamCreated(let name, let description):
            return "team.created:\(name):\(textSignature(prefix: "description", text: description))"
        case .teamDeleted(let name):
            return "team.deleted:\(name)"
        case .teamMessage(let from, let to, let content):
            return nonEmpty(content).map { textSignature(prefix: "team.msg:\(from)->\(to)", text: $0) }
        case .permissionDenied(let tool, let reason):
            return "perm.denied:\(tool):\(textSignature(prefix: "reason", text: reason))"
        case .control, .usage, .result, .systemInit, .astraProtocol, .unknown:
            return nil
        }
    }

    private static func refreshesRuntimeActivity(_ parsed: ParsedEvent) -> Bool {
        refreshesRuntimeActivity(progressKind(for: parsed))
    }

    private static func refreshesRuntimeActivity(_ progressKind: RuntimeProgressKind) -> Bool {
        switch progressKind {
        case .visibleProgress, .actionableProgress, .terminal:
            return true
        case .lifecycleMetadata, .providerLiveness, .accounting, .diagnostic:
            return false
        }
    }

    static func eventSignature(_ parsed: ParsedEvent) -> String {
        switch parsed {
        case .control(let type): return "control:\(type)"
        case .text(let t): return textSignature(prefix: "text", text: t)
        case .thinking(let t): return textSignature(prefix: "think", text: t)
        case .toolUse(let name, let id, let input):
            return "tool:\(name):\(id):\(inputSignature(input))"
        case .toolResult(let id, let content, let isError):
            return "\(textSignature(prefix: "tool.result:\(id):\(isError)", text: content))"
        case .usage(let input, let output): return "usage:\(input):\(output)"
        case .result(let t, _, _, _, _, _, _): return textSignature(prefix: "result", text: t ?? "")
        case .systemInit: return "init"
        case .teammateStarted(_, let name, _): return "teammate.start:\(name)"
        case .teammateCompleted(_, let name): return "teammate.done:\(name)"
        case .teamCreated(let name, _): return "team.created:\(name)"
        case .teamDeleted(let name): return "team.deleted:\(name)"
        case .teamMessage(let from, let to, let content): return textSignature(prefix: "team.msg:\(from)->\(to)", text: content)
        case .permissionDenied(let tool, _): return "perm.denied:\(tool)"
        case .astraProtocol: return "astra.protocol"
        case .unknown(let type): return "unknown:\(type)"
        }
    }

    private static func textSignature(prefix: String, text: String) -> String {
        "\(prefix):\(text.count):\(text.prefix(80))"
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func inputSignature(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        return valueSignature(input)
    }

    private static func valueSignature(_ value: Any?) -> String {
        if let string = value as? String {
            return "s:\(string.count):\(string.prefix(80))"
        }
        if let dictionary = value as? [String: Any] {
            let joined = dictionary.keys.sorted().map { key in
                "\(key)=\(valueSignature(dictionary[key]))"
            }.joined(separator: ";")
            return "d:\(joined.count):\(joined.prefix(120))"
        }
        if let array = value as? [Any] {
            let joined = array.map(valueSignature).joined(separator: ",")
            return "a:\(joined.count):\(joined.prefix(120))"
        }
        let description = String(describing: value ?? "")
        return "v:\(description.count):\(description.prefix(80))"
    }
}
