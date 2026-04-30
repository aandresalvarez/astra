import Foundation
import ASTRACore

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

struct AgentProcessResult {
    let exitCode: Int
    let error: String?
    let budgetExceeded: Bool
    let timedOut: Bool
    let repetitionKilled: Bool
    let maxTurnsExceeded: Bool

    init(
        exitCode: Int,
        error: String? = nil,
        budgetExceeded: Bool = false,
        timedOut: Bool = false,
        repetitionKilled: Bool = false,
        maxTurnsExceeded: Bool = false
    ) {
        self.exitCode = exitCode
        self.error = error
        self.budgetExceeded = budgetExceeded
        self.timedOut = timedOut
        self.repetitionKilled = repetitionKilled
        self.maxTurnsExceeded = maxTurnsExceeded
    }
}

/// Encapsulates budget enforcement, repetition circuit breaker, and idle timeout
/// for agent runtime processes.
nonisolated final class AgentProcessMonitor: @unchecked Sendable {
    let tokenBudget: Int
    let maxTurns: Int
    let maxRepetitions: Int
    let idleTimeoutSeconds: TimeInterval
    let taskID: UUID

    private let lock = NSLock()

    private var _estimatedTokens: Int = 0
    private var _turnCount: Int = 0
    private var _budgetExceeded: Bool = false
    private var _maxTurnsExceeded: Bool = false
    private var _timedOut: Bool = false
    private var _repetitionKilled: Bool = false

    private var lastEventSignature: String = ""
    private var repetitionCount: Int = 0
    private var lastActivityTime = Date()
    private var watchdogRunning = false

    var estimatedTokens: Int { lock.lock(); defer { lock.unlock() }; return _estimatedTokens }
    var turnCount: Int { lock.lock(); defer { lock.unlock() }; return _turnCount }
    var budgetExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _budgetExceeded }
    var maxTurnsExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _maxTurnsExceeded }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
    var repetitionKilled: Bool { lock.lock(); defer { lock.unlock() }; return _repetitionKilled }

    init(
        tokenBudget: Int,
        maxTurns: Int = 0,
        maxRepetitions: Int = 8,
        idleTimeoutSeconds: TimeInterval = 600,
        taskID: UUID = UUID()
    ) {
        self.tokenBudget = tokenBudget
        self.maxTurns = maxTurns
        self.maxRepetitions = maxRepetitions
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.taskID = taskID
    }

    func processEvent(_ parsed: ParsedEvent, process: Process?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        lastActivityTime = Date()

        if case .astraProtocol = parsed {
            return false
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

        let signature = Self.eventSignature(parsed)
        if signature == lastEventSignature {
            repetitionCount += 1
            if repetitionCount >= maxRepetitions {
                AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: [
                    "reason": "repetition_detected",
                    "repetition_count": String(repetitionCount)
                ], level: .error)
                _repetitionKilled = true
                _budgetExceeded = true
                process?.terminate()
                return true
            }
        } else {
            lastEventSignature = signature
            repetitionCount = 1
        }

        if case .result(_, _, let totalInput, let totalOutput, _, _, _) = parsed {
            let totalTokens = totalInput + totalOutput
            if totalTokens > tokenBudget {
                _budgetExceeded = true
                process?.terminate()
                return true
            }
        }

        switch parsed {
        case .text(let text):
            _estimatedTokens += max(1, text.count / 4)
        case .thinking(let text):
            _estimatedTokens += max(1, text.count / 4)
        case .toolUse:
            _estimatedTokens += 100
        case .toolResult:
            _estimatedTokens += 200
        case .teamMessage(_, _, let content):
            _estimatedTokens += max(50, content.count / 4)
        case .teammateStarted, .teammateCompleted, .teamCreated, .teamDeleted:
            _estimatedTokens += 50
        case .permissionDenied:
            _estimatedTokens += 50
        case .astraProtocol:
            break
        case .systemInit, .unknown:
            _estimatedTokens += 20
        case .result:
            break
        }

        if _estimatedTokens > tokenBudget {
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: taskID, fields: [
                "reason": "estimated_budget_exceeded",
                "estimated_tokens": String(_estimatedTokens),
                "token_budget": String(tokenBudget)
            ], level: .error)
            _budgetExceeded = true
            process?.terminate()
            return true
        }

        return false
    }

    func recordActivity() {
        lock.lock()
        lastActivityTime = Date()
        lock.unlock()
    }

    func startWatchdog(process: Process) {
        lock.lock()
        guard !watchdogRunning else { lock.unlock(); return }
        watchdogRunning = true
        lock.unlock()

        let checkInterval: TimeInterval = 30
        DispatchQueue.global().async { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: checkInterval)
                guard let self, process.isRunning else { return }

                self.lock.lock()
                let idleDuration = Date().timeIntervalSince(self.lastActivityTime)
                self.lock.unlock()

                if idleDuration >= self.idleTimeoutSeconds {
                    AppLogger.audit(.workerTimeout, category: "Worker", taskID: self.taskID, fields: [
                        "idle_seconds": String(Int(idleDuration)),
                        "limit_seconds": String(Int(self.idleTimeoutSeconds))
                    ], level: .error)
                    self.lock.lock()
                    self._timedOut = true
                    self.lock.unlock()
                    process.terminate()
                    return
                }
            }
        }
    }

    static func eventSignature(_ parsed: ParsedEvent) -> String {
        switch parsed {
        case .text(let t): return "text:\(t.prefix(80))"
        case .thinking(let t): return "think:\(t.prefix(80))"
        case .toolUse(let name, _, _): return "tool:\(name)"
        case .toolResult(let id, _): return "result:\(id)"
        case .result(let t, _, _, _, _, _, _): return "result:\(String((t ?? "").prefix(80)))"
        case .systemInit: return "init"
        case .teammateStarted(_, let name, _): return "teammate.start:\(name)"
        case .teammateCompleted(_, let name): return "teammate.done:\(name)"
        case .teamCreated(let name, _): return "team.created:\(name)"
        case .teamDeleted(let name): return "team.deleted:\(name)"
        case .teamMessage(let from, let to, _): return "team.msg:\(from)->\(to)"
        case .permissionDenied(let tool, _): return "perm.denied:\(tool)"
        case .astraProtocol: return "astra.protocol"
        case .unknown(let type): return "unknown:\(type)"
        }
    }
}
