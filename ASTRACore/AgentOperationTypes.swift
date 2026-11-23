import Foundation

/// How one operation ended, as the provider reported it. `unknown` is a
/// status this build could not read; it is never presented as success.
public enum AgentOperationOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case failed
    case cancelled
    case unknown

    /// A stored value this build does not know decodes as `unknown` rather
    /// than failing the whole record.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }

    /// The outcome a provider's terminal status and exit code describe. An
    /// exit code decides when there is one; otherwise the status word does,
    /// and a word this build does not know stays `unknown`.
    public init(providerStatus: String?, exitCode: Int?) {
        let status = (providerStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.cancelledStatuses.contains(status) {
            self = .cancelled
        } else if let exitCode {
            self = exitCode == 0 && !Self.failedStatuses.contains(status) ? .succeeded : .failed
        } else if Self.failedStatuses.contains(status) {
            self = .failed
        } else if Self.succeededStatuses.contains(status) {
            self = .succeeded
        } else {
            self = .unknown
        }
    }

    private static let succeededStatuses: Set<String> = ["completed", "complete", "success", "succeeded", "done", "ok"]
    private static let failedStatuses: Set<String> = ["failed", "failure", "error", "errored", "timed_out", "timeout", "denied", "rejected"]
    private static let cancelledStatuses: Set<String> = ["cancelled", "canceled", "aborted", "interrupted", "stopped", "killed"]
}

/// Something a provider said about one operation apart from its output text.
/// The parsers emit these beside the tool events they already produce, so a
/// status, exit code or job identity is never recovered from prose.
public enum AgentOperationSignal: Sendable, Equatable {
    /// Nonterminal activity for one operation: partial output, a progress
    /// note. It refreshes liveness and is never recorded as a result.
    case progress(operationID: String)
    /// The provider's own terminal status for the operation whose result
    /// follows. Emitted immediately before that `toolResult`.
    case finished(operationID: String, outcome: AgentOperationOutcome, exitCode: Int?, providerStatus: String?)
    /// A background job the provider ran on the agent's behalf ended. This is
    /// the job's outcome, not the outcome of the call that launched it.
    case backgroundJobFinished(AgentBackgroundJobEvent)

    /// Registered in `RuntimeProgressSignals.progressBearingControlTypes`: a
    /// background job ending is evidence of work, as the assistant text this
    /// notice used to be mistaken for was.
    public static let backgroundJobFinishedControlType = "operation.background_job_finished"

    /// What the process monitor sees of this signal. Progress and terminal
    /// status ride beside a control or result frame the monitor already
    /// receives, so only a job ending needs a frame of its own.
    public var monitorControlType: String? {
        if case .backgroundJobFinished = self { return Self.backgroundJobFinishedControlType }
        return nil
    }
}

public struct AgentBackgroundJobEvent: Sendable, Equatable {
    public let jobID: String
    /// The provider's word for the notification, such as `shell_completed`.
    public let kind: String
    public let outcome: AgentOperationOutcome
    public let exitCode: Int?
    /// What the provider said, without its wrapper tags, bounded.
    public let summary: String?

    public init(jobID: String, kind: String, outcome: AgentOperationOutcome, exitCode: Int?, summary: String?) {
        self.jobID = jobID
        self.kind = kind
        self.outcome = outcome
        self.exitCode = exitCode
        self.summary = summary
    }
}

/// One finished tool operation, as kept in a `tool.operation` event. It is
/// written when the result arrives — including a result with no output, which
/// leaves no `tool.result` row of its own.
///
/// It is what ties a result to its call after a task is reopened: the
/// `tool.use` and `tool.result` rows keep their text payloads, and this
/// record names both by row id together with the provider's call id.
public struct ToolOperationRecord: Codable, Sendable, Equatable {
    public static let eventType = "tool.operation"
    /// The status of a call that ended because permission for it was denied.
    public static let deniedStatus = "permission_denied"

    /// The provider's tool-call or step id; empty when it gave none.
    public let callID: String
    /// The tool's name, when the call was seen in this recording session.
    public let tool: String?
    public let outcome: AgentOperationOutcome
    public let exitCode: Int?
    /// The provider's terminal status word, verbatim, when it gave one.
    public let providerStatus: String?
    public let hasOutput: Bool
    /// The `tool.use` row this finishes, when it was recorded in this session.
    public let useEventID: UUID?
    /// The `tool.result` or `tool.result.failed` row, when output was kept.
    public let resultEventID: UUID?
    /// When the result arrived. A call that printed nothing has no result
    /// row to take the time from.
    public let finishedAt: Date?

    public init(
        callID: String,
        tool: String?,
        outcome: AgentOperationOutcome,
        exitCode: Int? = nil,
        providerStatus: String? = nil,
        hasOutput: Bool,
        useEventID: UUID? = nil,
        resultEventID: UUID? = nil,
        finishedAt: Date? = nil
    ) {
        self.callID = callID
        self.tool = tool
        self.outcome = outcome
        self.exitCode = exitCode
        self.providerStatus = providerStatus
        self.hasOutput = hasOutput
        self.useEventID = useEventID
        self.resultEventID = resultEventID
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case callID = "id", tool, outcome, exitCode, providerStatus = "status"
        case hasOutput = "output", useEventID = "use", resultEventID = "result", finishedAt = "at"
    }

    /// What a failed operation is called where only a line is shown.
    public var failureSummary: String? {
        guard outcome == .failed || outcome == .cancelled else { return nil }
        let name = tool.map { "\($0) " } ?? "Tool "
        if providerStatus == Self.deniedStatus { return "\(name)was denied permission" }
        let verb = outcome == .cancelled ? "was cancelled" : "failed"
        return exitCode.map { "\(name)\(verb) · exit code \($0)" } ?? "\(name)\(verb)"
    }
}

/// The payload of a `tool.operation` event: the operations a run finished,
/// in the order they finished. A run's records are kept a batch to a row and
/// the open batch is extended in place, so a tool-heavy run does not spend a
/// third of the history a thread loads on bookkeeping rows.
public struct ToolOperationBatch: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Records per row. A full row is left as it is and a new one started.
    public static let capacity = 16
    /// A row is also full at this many characters, whatever its count: the
    /// task mirror truncates a payload past 4,000, and a truncated batch
    /// would not decode.
    public static let payloadCharacterLimit = 3_600

    public let version: Int
    public var operations: [ToolOperationRecord]

    public init(operations: [ToolOperationRecord]) {
        version = Self.currentVersion
        self.operations = operations
    }

    public static func decode(from payload: String) -> Self? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Every operation record among `events`, given as `(type, payload)`.
    public static func records<Events: Sequence>(in events: Events) -> [ToolOperationRecord]
    where Events.Element == (type: String, payload: String) {
        events.flatMap { event -> [ToolOperationRecord] in
            guard event.type == ToolOperationRecord.eventType else { return [] }
            return decode(from: event.payload)?.operations ?? []
        }
    }
}

/// The durable record of a provider background job ending, written as a
/// `tool.background_job` event. It is kept apart from assistant text so a
/// job notice never reads as the agent's own narration.
public struct BackgroundJobRecord: Codable, Sendable, Equatable {
    /// Not under `runtime.`: that prefix marks ASTRA's own recovery evidence,
    /// which the task mirror exports without its usual bounds.
    public static let eventType = "tool.background_job"
    public static let currentVersion = 1
    public static let summaryLimit = 500

    public let version: Int
    public let jobID: String
    public let kind: String
    public let outcome: AgentOperationOutcome
    public let exitCode: Int?
    public let summary: String?

    public init(_ event: AgentBackgroundJobEvent) {
        version = Self.currentVersion
        jobID = event.jobID
        kind = event.kind
        outcome = event.outcome
        exitCode = event.exitCode
        summary = event.summary.map { String($0.prefix(Self.summaryLimit)) }
    }

    public static func decode(from payload: String) -> Self? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
