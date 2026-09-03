import Foundation
import SwiftData
import ASTRACore

public enum RunStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case timeout
    case budgetExceeded = "budget_exceeded"
}

@Model
public final class TaskRun {
    public var id: UUID
    public var task: AgentTask?
    public var status: RunStatus
    public var startedAt: Date
    public var completedAt: Date?
    public var tokensUsed: Int
    public var inputTokens: Int         // Input tokens for this run (context window usage)
    public var outputTokens: Int        // Output tokens for this run
    public var runtimeID: String?
    public var providerSessionId: String?
    public var providerVersion: String?
    public var executionEnvironmentSnapshotJSON: String?
    /// JSON-encoded provider launch signature used to decide whether native
    /// continuation is safe for a follow-up run.
    public var providerLaunchSignatureJSON: String?
    public var exitCode: Int?
    public private(set) var output: String
    /// Whether `output` contains at least one run-protocol marker.
    /// `nil` means "never scanned" (a row written before schema V17); readers
    /// must treat that as "might contain markers" and fall back to the text.
    public private(set) var hasProtocolEvents: Bool?
    public var costUSD: Double
    public var fileChangesJSON: String  // JSON array of file changes
    public var stopReason: String       // "completed", "failed", "max_turns_reached", "max_budget_reached", "timeout", "cancelled", "repetition_detected"

    public init(task: AgentTask) {
        self.id = UUID()
        self.task = task
        self.status = .running
        self.startedAt = Date()
        self.tokensUsed = 0
        self.inputTokens = 0
        self.outputTokens = 0
        self.runtimeID = task.runtimeID
        self.providerSessionId = task.sessionId
        self.providerVersion = nil
        let snapshot = task.executionEnvironmentSnapshotJSON
            ?? ExecutionEnvironmentStore.encodeSnapshot(
                ExecutionEnvironmentStore.decode(task.workspace?.activeExecutionEnvironmentJSON)
            )
        self.executionEnvironmentSnapshotJSON = snapshot
        if task.executionEnvironmentSnapshotJSON == nil {
            task.executionEnvironmentSnapshotJSON = snapshot
        }
        self.providerLaunchSignatureJSON = nil
        self.output = ""
        self.hasProtocolEvents = false
        self.costUSD = 0
        self.fileChangesJSON = "[]"
        self.stopReason = ""
    }

    /// Replaces the stored output and recomputes the protocol-marker flag.
    /// Recomputation (rather than a monotonic OR) is required because several
    /// writers shrink the text: the completed-summary rewrite strips markers,
    /// output capping elides the middle, and the workspace-JSON mirror
    /// truncates.
    ///
    /// The marker flag is derived from the text as the caller supplied it:
    /// credential redaction runs afterwards, and a protocol marker that a
    /// redaction happened to straddle is still a marker the parser must be
    /// told about.
    public func setOutput(_ newValue: String) {
        hasProtocolEvents = newValue.contains(AstraRunProtocolParser.markerToken)
        output = RunSecretRedactionScope.redact(newValue, taskID: task?.id)
    }

    /// Appends streamed text and keeps the marker flag exact.
    /// Provider deltas can split the marker across two chunks, so the tail of
    /// the already-stored output is re-scanned together with the new text. A
    /// never-scanned (`nil`) row stays `nil` on a miss: the appended text alone
    /// cannot prove the older output is marker-free.
    /// A credential can straddle a chunk boundary the same way a marker can, so
    /// the append is redacted across the seam too, which may rewrite the tail of
    /// the text already stored.
    public func appendOutput(_ text: String) {
        if hasProtocolEvents != true {
            let token = AstraRunProtocolParser.markerToken
            let overlap = String(output.suffix(token.count - 1))
            if (overlap + text).contains(token) {
                hasProtocolEvents = true
            }
        }
        let redacted = RunSecretRedactionScope.redactedAppend(
            existing: output,
            addition: text,
            taskID: task?.id
        )
        if redacted.dropFromExisting > 0 {
            output.removeLast(redacted.dropFromExisting)
        }
        output += redacted.append
    }

    /// Re-derives the marker flag from the stored text without rewriting it.
    /// Used by the one-time backfill of pre-V17 rows.
    public func refreshProtocolMarkerFlag() {
        hasProtocolEvents = output.contains(AstraRunProtocolParser.markerToken)
    }

    /// Decoded file changes from JSON storage
    public var fileChanges: [StoredFileChange] {
        switch fileChangesDecodeResult {
        case .success(let changes):
            return changes
        case .failure:
            return []
        }
    }

    public var fileChangesDecodeResult: Result<[StoredFileChange], TaskRunFileChangesDecodeError> {
        if fileChangesJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success([])
        }
        guard let data = fileChangesJSON.data(using: .utf8) else {
            return .failure(.invalidUTF8)
        }
        do {
            return .success(try TaskEventPayloadCodec.makeDecoder().decode([StoredFileChange].self, from: data))
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
    }

    public func appendFileChange(_ change: StoredFileChange) {
        var changes = fileChanges
        changes.append(change.translated(using: ExecutionEnvironmentStore.decode(executionEnvironmentSnapshotJSON)))
        fileChangesJSON = TaskEvent.payloadString(changes, fallback: fileChangesJSON)
        task?.updatedAt = Date()
    }

    public func recordPermissionApprovalRequired() {
        status = .failed
        typedStopReason = .permissionApprovalRequired
    }

    public func recordCompletionBlocked(stopReason: TaskRunStopReason?) {
        status = .failed
        typedStopReason = stopReason
    }

    public func recordExternalOutcomePending() {
        status = .completed
        typedStopReason = .externalOutcomePending
    }

    public func recordExternalOutcomeCompleted(at date: Date = Date()) {
        status = .completed
        completedAt = completedAt ?? date
        typedStopReason = .completed
    }
}

public extension TaskRun {
    static func isChronologicallyOrdered(_ lhs: TaskRun, _ rhs: TaskRun) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public enum TaskRunFileChangesDecodeError: Error, Equatable, CustomStringConvertible {
    case invalidUTF8
    case decodingFailed(String)

    public var description: String {
        switch self {
        case .invalidUTF8:
            "Run file changes payload is not valid UTF-8."
        case .decodingFailed(let message):
            "Could not decode run file changes: \(message)"
        }
    }
}

/// Codable file change for JSON storage in TaskRun
public struct StoredFileChange: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let changeType: String  // "Write" or "Edit"
    public let content: String?
    public let oldString: String?
    public let newString: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        path: String,
        changeType: String,
        content: String? = nil,
        oldString: String? = nil,
        newString: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.changeType = changeType
        self.content = content
        self.oldString = oldString
        self.newString = newString
        self.timestamp = timestamp
    }

    public init(from fileChange: FileChange) {
        self.id = fileChange.id
        self.path = fileChange.path
        self.changeType = StoredFileChangeKind(changeType: fileChange.changeType.rawValue).rawValue
        self.content = fileChange.content
        self.oldString = fileChange.oldString
        self.newString = fileChange.newString
        self.timestamp = fileChange.timestamp
    }

    public var kind: StoredFileChangeKind {
        StoredFileChangeKind(changeType: changeType)
    }

    public func translated(using environment: WorkspaceExecutionEnvironment) -> StoredFileChange {
        guard environment.isContainerized else { return self }
        let mapper = ExecutionEnvironmentPathMapper(mounts: environment.mounts)
        guard let hostPath = mapper.hostPath(forContainerPath: path),
              hostPath != path else {
            return self
        }
        return StoredFileChange(
            id: id,
            path: hostPath,
            changeType: changeType,
            content: content,
            oldString: oldString,
            newString: newString,
            timestamp: timestamp
        )
    }
}

public enum StoredFileChangeKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case write = "Write"
    case edit = "Edit"
    case discovered = "discovered"
    case unknown = "unknown"

    public init(changeType: String) {
        switch changeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "write":
            self = .write
        case "edit":
            self = .edit
        case "discovered":
            self = .discovered
        default:
            self = .unknown
        }
    }

    public var sourceLabel: String {
        switch self {
        case .write:
            "created"
        case .edit:
            "edited"
        case .discovered:
            "output"
        case .unknown:
            "changed"
        }
    }
}
