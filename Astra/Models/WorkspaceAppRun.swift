import Foundation
import SwiftData

public enum WorkspaceAppRunStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case running
    case completed
    case failed
    case blocked
    case cancelled
    // B2: a pipeline/loop run suspended while an async agent task it launched runs.
    case waiting
}

public enum WorkspaceAppRunTrigger: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case automation
    case importReview
    case test
}

@Model
public final class WorkspaceAppRun: Identifiable {
    public var id: UUID
    public var workspaceID: UUID
    public var appID: UUID
    public var appLogicalID: String
    public var actionID: String
    public var triggerRaw: String
    public var statusRaw: String
    public var startedAt: Date
    public var completedAt: Date?
    public var inputSummary: String
    public var outputSummary: String
    public var errorMessage: String?
    public var linkedTaskID: UUID?
    public var linkedArtifactPath: String?
    // B2 resumable runs: when a pipeline/loop suspends on an async agent task,
    // `pendingActionID` is the suspended pipeline/loop action and
    // `pendingStepIndex` the next step to execute on resume. `linkedTaskID` holds
    // the awaited task. Defaulted so it is absorbed into schema V8's fresh tables
    // (the V7 -> V8 stage), no new schema version.
    public var pendingActionID: String?
    public var pendingStepIndex: Int = 0
    // B3: tokens consumed by the run's awaited agent tasks so far, accumulated on
    // each resume to enforce a whole-run token budget. Defaulted (lightweight).
    public var consumedTokens: Int = 0
    // C1 parallel fan-out barrier: the SET of agent tasks a fanned-out run awaits,
    // stored as a JSON [UUID] string (SwiftData has no [UUID] attribute; defaulted,
    // absorbed into V8). The single-task B2 case is the degenerate one-element
    // barrier; linkedTaskID is retained for the single-await fast path + back-compat.
    public var awaitedTaskIDsJSON: String = "[]"
    // Human-in-the-loop approval: when a pipeline suspends on an un-approved gate.humanApproval
    // step, this holds that gate action's id (pendingStepIndex points at the gate step). The run is
    // `.waiting` pending a HUMAN decision — distinct from awaiting an agent task, where this is nil.
    // Defaulted/optional → lightweight, absorbed into V8 like the B2/C1 fields above.
    public var pendingApprovalActionID: String?

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        appID: UUID,
        appLogicalID: String,
        actionID: String,
        trigger: WorkspaceAppRunTrigger = .user,
        status: WorkspaceAppRunStatus = .running,
        startedAt: Date = Date(),
        inputSummary: String = "",
        outputSummary: String = "",
        errorMessage: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.appID = appID
        self.appLogicalID = appLogicalID
        self.actionID = actionID
        self.triggerRaw = trigger.rawValue
        self.statusRaw = status.rawValue
        self.startedAt = startedAt
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.errorMessage = errorMessage
    }

    public var status: WorkspaceAppRunStatus {
        get { WorkspaceAppRunStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    public var trigger: WorkspaceAppRunTrigger {
        get { WorkspaceAppRunTrigger(rawValue: triggerRaw) ?? .user }
        set { triggerRaw = newValue.rawValue }
    }

    public var awaitedTaskIDs: [UUID] {
        get { (try? JSONDecoder().decode([UUID].self, from: Data(awaitedTaskIDsJSON.utf8))) ?? [] }
        set {
            if let data = try? JSONEncoder().encode(newValue), let json = String(data: data, encoding: .utf8) {
                awaitedTaskIDsJSON = json
            }
        }
    }
}

@Model
public final class WorkspaceAppRunEvent: Identifiable {
    public var id: UUID
    public var runID: UUID
    public var workspaceID: UUID
    public var appID: UUID
    public var actionID: String
    public var type: String
    public var payload: String
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        workspaceID: UUID,
        appID: UUID,
        actionID: String,
        type: String,
        payload: String = "{}",
        timestamp: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.workspaceID = workspaceID
        self.appID = appID
        self.actionID = actionID
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }
}
