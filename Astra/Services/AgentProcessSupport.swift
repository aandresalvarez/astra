import Darwin
import Foundation
import ASTRACore

protocol AgentRuntimeProcessControl: AnyObject {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    func terminate()
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
}

struct AgentExecutionScopedProcessError: LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

/// Launches a provider in its own process group so cancellation can clean up
/// tool subprocesses that the provider starts or backgrounds.
final class AgentExecutionScopedProcess: @unchecked Sendable, AgentRuntimeProcessControl {
    private let executablePath: String
    private let arguments: [String]
    private let currentDirectory: String
    private let environment: [String: String]
    private let lock = NSLock()

    private var processID: pid_t = 0
    private var processGroupID: pid_t = 0
    private var running = false
    private var status: Int32 = 0

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    var terminationHandler: ((AgentExecutionScopedProcess) -> Void)?

    var stdoutFileHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrFileHandle: FileHandle { stderrPipe.fileHandleForReading }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    init(
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String]
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
    }

    func run() throws {
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        var childPID = pid_t(0)

        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw AgentExecutionScopedProcessError(operation: "posix_spawn_file_actions_init", code: errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        guard posix_spawnattr_init(&attr) == 0 else {
            throw AgentExecutionScopedProcessError(operation: "posix_spawnattr_init", code: errno)
        }
        defer { posix_spawnattr_destroy(&attr) }

        try check(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                  operation: "posix_spawn_file_actions_adddup2(stdout)")
        try check(posix_spawn_file_actions_adddup2(&actions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO),
                  operation: "posix_spawn_file_actions_adddup2(stderr)")
        try check(posix_spawn_file_actions_addclose(&actions, stdoutPipe.fileHandleForReading.fileDescriptor),
                  operation: "posix_spawn_file_actions_addclose(stdout_read)")
        try check(posix_spawn_file_actions_addclose(&actions, stderrPipe.fileHandleForReading.fileDescriptor),
                  operation: "posix_spawn_file_actions_addclose(stderr_read)")
        try addWorkingDirectory(to: &actions)

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        try check(posix_spawnattr_setflags(&attr, flags), operation: "posix_spawnattr_setflags")
        try check(posix_spawnattr_setpgroup(&attr, 0), operation: "posix_spawnattr_setpgroup")

        var argv = makeCStringArray([executablePath] + arguments)
        var envp = makeCStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            freeCStringArray(argv)
            freeCStringArray(envp)
        }

        let spawnResult = executablePath.withCString { executable in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(
                        &childPID,
                        executable,
                        &actions,
                        &attr,
                        argvBuffer.baseAddress,
                        envBuffer.baseAddress
                    )
                }
            }
        }
        try check(spawnResult, operation: "posix_spawn")

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        lock.lock()
        processID = childPID
        processGroupID = childPID
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.reapProcess(pid: childPID)
        }
    }

    func terminate() {
        let ids = currentIDs()
        guard ids.isRunning else { return }

        if ids.processGroupID > 0 && ids.processGroupID != getpgrp() {
            kill(-ids.processGroupID, SIGTERM)
        } else if ids.processID > 0 {
            kill(ids.processID, SIGTERM)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard let self else { return }
            let latest = self.currentIDs()
            guard latest.isRunning else { return }
            if latest.processGroupID > 0 && latest.processGroupID != getpgrp() {
                kill(-latest.processGroupID, SIGKILL)
            } else if latest.processID > 0 {
                kill(latest.processID, SIGKILL)
            }
        }
    }

    private func addWorkingDirectory(to actions: inout posix_spawn_file_actions_t?) throws {
        let result = currentDirectory.withCString { path in
            if #available(macOS 26.0, *) {
                return posix_spawn_file_actions_addchdir(&actions, path)
            } else {
                return posix_spawn_file_actions_addchdir_np(&actions, path)
            }
        }
        try check(result, operation: "posix_spawn_file_actions_addchdir")
    }

    private func reapProcess(pid: pid_t) {
        var waitStatus: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &waitStatus, 0)
        } while result == -1 && errno == EINTR

        let exitStatus: Int32
        if result == pid {
            exitStatus = Self.exitCode(from: waitStatus)
        } else {
            exitStatus = -1
        }

        cleanupResidualProcessGroup()

        lock.lock()
        status = exitStatus
        running = false
        lock.unlock()

        terminationHandler?(self)
    }

    private func cleanupResidualProcessGroup() {
        let ids = currentIDs()
        guard ids.processGroupID > 0,
              ids.processGroupID != getpgrp() else {
            return
        }

        if kill(-ids.processGroupID, SIGTERM) == 0 {
            usleep(200_000)
        }
        kill(-ids.processGroupID, SIGKILL)
    }

    private func currentIDs() -> (processID: pid_t, processGroupID: pid_t, isRunning: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (processID, processGroupID, running)
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw AgentExecutionScopedProcessError(operation: operation, code: result)
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + signal
    }

    private func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for pointer in array {
            if let pointer {
                free(pointer)
            }
        }
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

    func appendAndDrainLines(_ string: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        _value += string
        var lines: [String] = []
        while let newlineIndex = _value.firstIndex(of: "\n") {
            let line = String(_value[_value.startIndex..<newlineIndex])
            lines.append(line)
            _value = String(_value[_value.index(after: newlineIndex)...])
        }
        return lines
    }

    func drainRemaining() -> String {
        lock.lock()
        defer { lock.unlock() }

        let remaining = _value
        _value = ""
        return remaining
    }
}

struct AgentRuntimeStreamDebugSnapshot: Sendable {
    let rawLineCount: Int
    let jsonLineCount: Int
    let plainTextLineCount: Int
    let parsedEventCount: Int
    let emittedEventCount: Int
    let stdoutBytes: Int
    let stderrBytes: Int
    let durationMs: Int
    let firstLineLatencyMs: Int?
    let lastLineOffsetMs: Int?
    let eventTypeCounts: [String: Int]
    let rawSamples: [String]
    let unknownJSONShapes: [String]
    let stderrTail: String?

    var fields: [String: String] {
        var fields: [String: String] = [
            "raw_lines": String(rawLineCount),
            "json_lines": String(jsonLineCount),
            "plain_text_lines": String(plainTextLineCount),
            "parsed_events": String(parsedEventCount),
            "emitted_events": String(emittedEventCount),
            "stdout_bytes": String(stdoutBytes),
            "stderr_bytes": String(stderrBytes),
            "duration_ms": String(durationMs),
            "raw_samples": String(rawSamples.count),
            "unknown_json_shapes": String(unknownJSONShapes.count),
            "stderr_tail_chars": String(stderrTail?.count ?? 0),
            "event_types": eventTypeCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        ]
        if let firstLineLatencyMs {
            fields["first_line_latency_ms"] = String(firstLineLatencyMs)
        }
        if let lastLineOffsetMs {
            fields["last_line_offset_ms"] = String(lastLineOffsetMs)
        }
        return fields
    }
}

final class AgentRuntimeStreamDebugCapture: @unchecked Sendable {
    static let environmentKey = "ASTRA_STREAM_DEBUG"

    private let lock = NSLock()
    private let startedAt = Date()
    private let maxRawSamples: Int
    private let maxUnknownJSONShapes: Int
    private let maxSampleLength: Int
    private let maxStderrTailLength: Int

    private var rawLineCount = 0
    private var jsonLineCount = 0
    private var plainTextLineCount = 0
    private var parsedEventCount = 0
    private var emittedEventCount = 0
    private var stdoutBytes = 0
    private var stderrBytes = 0
    private var firstLineAt: Date?
    private var lastLineAt: Date?
    private var eventTypeCounts: [String: Int] = [:]
    private var rawSamples: [String] = []
    private var unknownJSONShapes: [String] = []
    private var stderrTail = ""

    init(
        maxRawSamples: Int = 4,
        maxUnknownJSONShapes: Int = 4,
        maxSampleLength: Int = 500,
        maxStderrTailLength: Int = 2_000
    ) {
        self.maxRawSamples = maxRawSamples
        self.maxUnknownJSONShapes = maxUnknownJSONShapes
        self.maxSampleLength = maxSampleLength
        self.maxStderrTailLength = maxStderrTailLength
    }

    static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return false
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    static func makeIfEnabled() -> AgentRuntimeStreamDebugCapture? {
        isEnabled ? AgentRuntimeStreamDebugCapture() : nil
    }

    func recordLine(_ line: String, parsesJSONLines: Bool) {
        let now = Date()
        lock.lock()
        rawLineCount += 1
        if parsesJSONLines {
            jsonLineCount += 1
        } else {
            plainTextLineCount += 1
        }
        stdoutBytes += line.utf8.count
        if firstLineAt == nil {
            firstLineAt = now
        }
        lastLineAt = now
        if rawSamples.count < maxRawSamples {
            rawSamples.append(Self.truncated(line, limit: maxSampleLength))
        }
        lock.unlock()
    }

    func recordParsed(_ events: [ParsedEvent], rawLine: String) {
        lock.lock()
        parsedEventCount += events.count
        for event in events {
            let type = Self.eventType(event)
            eventTypeCounts[type, default: 0] += 1
            if case .unknown(let unknownType) = event {
                appendUnknownJSONShape(raw: rawLine, eventType: unknownType)
            }
        }
        if events.isEmpty {
            appendUnknownJSONShape(raw: rawLine, eventType: nil)
        }
        lock.unlock()
    }

    func recordParsed(_ events: [AgentEvent], rawLine: String) {
        lock.lock()
        parsedEventCount += events.count
        for event in events {
            let type = Self.eventType(event)
            eventTypeCounts[type, default: 0] += 1
            if case .unknown(_, let unknownType, let raw) = event {
                appendUnknownJSONShape(raw: raw.isEmpty ? rawLine : raw, eventType: unknownType)
            }
        }
        if events.isEmpty {
            appendUnknownJSONShape(raw: rawLine, eventType: nil)
        }
        lock.unlock()
    }

    func recordEmitted(_ events: [ParsedEvent]) {
        lock.lock()
        emittedEventCount += events.count
        lock.unlock()
    }

    func recordEmitted(_ events: [AgentEvent]) {
        lock.lock()
        emittedEventCount += events.count
        lock.unlock()
    }

    func recordStderr(_ stderr: String?) {
        guard let stderr, !stderr.isEmpty else { return }
        lock.lock()
        stderrBytes += stderr.utf8.count
        stderrTail += stderr
        if stderrTail.count > maxStderrTailLength {
            stderrTail = String(stderrTail.suffix(maxStderrTailLength))
        }
        lock.unlock()
    }

    func snapshot() -> AgentRuntimeStreamDebugSnapshot {
        let finishedAt = Date()
        lock.lock()
        defer { lock.unlock() }
        return AgentRuntimeStreamDebugSnapshot(
            rawLineCount: rawLineCount,
            jsonLineCount: jsonLineCount,
            plainTextLineCount: plainTextLineCount,
            parsedEventCount: parsedEventCount,
            emittedEventCount: emittedEventCount,
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            durationMs: Self.milliseconds(from: startedAt, to: finishedAt),
            firstLineLatencyMs: firstLineAt.map { Self.milliseconds(from: startedAt, to: $0) },
            lastLineOffsetMs: lastLineAt.map { Self.milliseconds(from: startedAt, to: $0) },
            eventTypeCounts: eventTypeCounts,
            rawSamples: rawSamples,
            unknownJSONShapes: unknownJSONShapes,
            stderrTail: stderrTail.isEmpty ? nil : stderrTail
        )
    }

    private func appendUnknownJSONShape(raw: String, eventType: String?) {
        guard unknownJSONShapes.count < maxUnknownJSONShapes,
              let shape = Self.jsonShape(raw: raw, eventType: eventType),
              !unknownJSONShapes.contains(shape) else {
            return
        }
        unknownJSONShapes.append(shape)
    }

    private static func jsonShape(raw: String, eventType: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = eventType
            ?? firstString(in: object, keys: ["type", "event", "kind", "sessionUpdate", "name"])
            ?? "unknown"
        var parts = [
            "type=\(type)",
            "keys=\(object.keys.sorted().joined(separator: ","))"
        ]
        for key in ["data", "payload", "message", "content", "delta"] {
            if let nested = object[key] as? [String: Any] {
                parts.append("\(key)_keys=\(nested.keys.sorted().joined(separator: ","))")
            }
        }
        return truncated(parts.joined(separator: " "), limit: 500)
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        for key in ["data", "payload", "message"] {
            if let nested = object[key] as? [String: Any],
               let value = firstString(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func eventType(_ event: ParsedEvent) -> String {
        switch event {
        case .systemInit: "system_init"
        case .thinking: "thinking"
        case .text: "text"
        case .toolUse: "tool_use"
        case .toolResult: "tool_result"
        case .usage: "usage"
        case .result: "result"
        case .teammateStarted: "teammate_started"
        case .teammateCompleted: "teammate_completed"
        case .teamCreated: "team_created"
        case .teamDeleted: "team_deleted"
        case .teamMessage: "team_message"
        case .permissionDenied: "permission_denied"
        case .astraProtocol: "astra_protocol"
        case .unknown(let type): "unknown:\(type)"
        }
    }

    private static func eventType(_ event: AgentEvent) -> String {
        switch event {
        case .started: "started"
        case .thinking: "thinking"
        case .text: "text"
        case .toolUse: "tool_use"
        case .toolResult: "tool_result"
        case .fileChange: "file_change"
        case .permissionRequested: "permission_requested"
        case .stats: "stats"
        case .astraProtocol: "astra_protocol"
        case .completed: "completed"
        case .failed: "failed"
        case .unknown(_, let type, _): "unknown:\(type)"
        }
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " [truncated]"
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

struct AgentProcessResult {
    let exitCode: Int
    let error: String?
    let providerVersion: String?
    let policyViolation: Bool
    let policyViolationMessage: String?
    let policyApprovalRequired: Bool
    let policyApprovalMessage: String?
    let budgetExceeded: Bool
    let budgetWarning: Bool
    let finalReportedBudgetExceededAfterCompletion: Bool
    let timedOut: Bool
    let repetitionKilled: Bool
    let maxTurnsExceeded: Bool

    init(
        exitCode: Int,
        error: String? = nil,
        providerVersion: String? = nil,
        policyViolation: Bool = false,
        policyViolationMessage: String? = nil,
        policyApprovalRequired: Bool = false,
        policyApprovalMessage: String? = nil,
        budgetExceeded: Bool = false,
        budgetWarning: Bool = false,
        finalReportedBudgetExceededAfterCompletion: Bool = false,
        timedOut: Bool = false,
        repetitionKilled: Bool = false,
        maxTurnsExceeded: Bool = false
    ) {
        self.exitCode = exitCode
        self.error = error
        self.providerVersion = providerVersion
        self.policyViolation = policyViolation
        self.policyViolationMessage = policyViolationMessage
        self.policyApprovalRequired = policyApprovalRequired
        self.policyApprovalMessage = policyApprovalMessage
        self.budgetExceeded = budgetExceeded
        self.budgetWarning = budgetWarning
        self.finalReportedBudgetExceededAfterCompletion = finalReportedBudgetExceededAfterCompletion
        self.timedOut = timedOut
        self.repetitionKilled = repetitionKilled
        self.maxTurnsExceeded = maxTurnsExceeded
    }
}

/// Encapsulates budget enforcement, repetition circuit breaker, and idle timeout
/// for agent runtime processes.
nonisolated final class AgentProcessMonitor: @unchecked Sendable {
    let tokenBudget: Int
    let budgetEnforcementMode: BudgetEnforcementMode
    let maxTurns: Int
    let maxRepetitions: Int
    let idleTimeoutSeconds: TimeInterval
    let taskID: UUID
    let policyGuard: AgentRuntimePolicyGuard?

    private let lock = NSLock()

    private var _estimatedTokens: Int = 0
    private var _turnCount: Int = 0
    private var _budgetExceeded: Bool = false
    private var _budgetWarning: Bool = false
    private var _finalReportedBudgetExceededAfterCompletion: Bool = false
    private var _maxTurnsExceeded: Bool = false
    private var _timedOut: Bool = false
    private var _repetitionKilled: Bool = false
    private var _policyViolation: Bool = false
    private var _policyViolationMessage: String?
    private var _policyApprovalRequired: Bool = false
    private var _policyApprovalMessage: String?
    private var _sawAstraComplete: Bool = false

    private var lastEventSignature: String = ""
    private var repetitionCount: Int = 0
    private var lastActivityTime = Date()
    private var watchdogRunning = false

    var estimatedTokens: Int { lock.lock(); defer { lock.unlock() }; return _estimatedTokens }
    var turnCount: Int { lock.lock(); defer { lock.unlock() }; return _turnCount }
    var budgetExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _budgetExceeded }
    var budgetWarning: Bool { lock.lock(); defer { lock.unlock() }; return _budgetWarning }
    var finalReportedBudgetExceededAfterCompletion: Bool { lock.lock(); defer { lock.unlock() }; return _finalReportedBudgetExceededAfterCompletion }
    var maxTurnsExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _maxTurnsExceeded }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
    var repetitionKilled: Bool { lock.lock(); defer { lock.unlock() }; return _repetitionKilled }
    var policyViolation: Bool { lock.lock(); defer { lock.unlock() }; return _policyViolation }
    var policyViolationMessage: String? { lock.lock(); defer { lock.unlock() }; return _policyViolationMessage }
    var policyApprovalRequired: Bool { lock.lock(); defer { lock.unlock() }; return _policyApprovalRequired }
    var policyApprovalMessage: String? { lock.lock(); defer { lock.unlock() }; return _policyApprovalMessage }

    init(
        tokenBudget: Int,
        budgetEnforcementMode: BudgetEnforcementMode = .hardStop,
        maxTurns: Int = 0,
        maxRepetitions: Int = 8,
        idleTimeoutSeconds: TimeInterval = 600,
        taskID: UUID = UUID(),
        policyGuard: AgentRuntimePolicyGuard? = nil
    ) {
        self.tokenBudget = tokenBudget
        self.budgetEnforcementMode = budgetEnforcementMode
        self.maxTurns = maxTurns
        self.maxRepetitions = maxRepetitions
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.taskID = taskID
        self.policyGuard = policyGuard
    }

    static func estimatedTokenCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, text.count / 4)
    }

    func processEvent(_ parsed: ParsedEvent, process: AgentRuntimeProcessControl?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        lastActivityTime = Date()

        if case .astraProtocol(.valid(.complete)) = parsed {
            _sawAstraComplete = true
            return false
        }

        if case .astraProtocol = parsed {
            return false
        }

        if let violation = policyGuard?.violation(for: parsed) {
            return recordPolicyViolation(violation, process: process)
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

        if case .usage(let totalInput, let totalOutput) = parsed {
            let totalTokens = totalInput + totalOutput
            if totalTokens > tokenBudget {
                if budgetEnforcementMode == .warning {
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
                if budgetEnforcementMode == .warning {
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
        case .astraProtocol:
            break
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
            if budgetEnforcementMode == .warning {
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

    private func recordPolicyViolation(_ violation: AgentRuntimePolicyViolation, process: AgentRuntimeProcessControl?) -> Bool {
        guard !_policyViolation, !_policyApprovalRequired else { return false }
        let redactedDetail = violation.detail.map { LogSanitizer.sanitize($0, maxLength: 240) }
        let reason = violation.requiresApproval ? "runtime_policy_approval_required" : "runtime_policy_violation"
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: taskID, fields: [
            "reason": reason,
            "tool": violation.toolName ?? "unknown",
            "message": violation.reason,
            "approval_grant": violation.approvalGrant ?? "none",
            "detail": redactedDetail ?? "none"
        ], level: violation.requiresApproval ? .warning : .error)
        let message = AgentRuntimePolicyViolation(
            reason: violation.reason,
            toolName: violation.toolName,
            detail: redactedDetail,
            requiresApproval: violation.requiresApproval,
            approvalGrant: violation.approvalGrant
        ).userMessage
        if violation.requiresApproval {
            _policyApprovalRequired = true
            _policyApprovalMessage = message
        } else {
            _policyViolation = true
            _policyViolationMessage = message
        }
        process?.terminate()
        return true
    }

    private func recordBudgetOverage(reason: String, fields: [String: String], process: AgentRuntimeProcessControl?) -> Bool {
        var auditFields = fields
        auditFields["reason"] = reason
        auditFields["enforcement"] = BudgetEnforcementMode.hardStop.rawValue
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
        lastActivityTime = Date()
        lock.unlock()
    }

    func startWatchdog(process: AgentRuntimeProcessControl) {
        lock.lock()
        guard !watchdogRunning else { lock.unlock(); return }
        watchdogRunning = true
        lock.unlock()

        let processBox = AgentRuntimeProcessControlBox(process)
        let checkInterval: TimeInterval = 30
        DispatchQueue.global().async { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: checkInterval)
                guard let self, processBox.isRunning else { return }

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
                    processBox.terminate()
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
        case .usage(let input, let output): return "usage:\(input):\(output)"
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
