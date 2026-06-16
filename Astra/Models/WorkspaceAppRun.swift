import Foundation
import SwiftData

enum WorkspaceAppRunStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case running
    case completed
    case failed
    case blocked
    case cancelled
    // B2: a pipeline/loop run suspended while an async agent task it launched runs.
    case waiting
}

enum WorkspaceAppRunTrigger: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case automation
    case importReview
    case test
}

@Model
final class WorkspaceAppRun: Identifiable {
    var id: UUID
    var workspaceID: UUID
    var appID: UUID
    var appLogicalID: String
    var actionID: String
    var triggerRaw: String
    var statusRaw: String
    var startedAt: Date
    var completedAt: Date?
    var inputSummary: String
    var outputSummary: String
    var errorMessage: String?
    var linkedTaskID: UUID?
    var linkedArtifactPath: String?
    // B2 resumable runs: when a pipeline/loop suspends on an async agent task,
    // `pendingActionID` is the suspended pipeline/loop action and
    // `pendingStepIndex` the next step to execute on resume. `linkedTaskID` holds
    // the awaited task. Defaulted so it is absorbed into schema V7's fresh tables
    // (the V6 -> V7 stage), no new schema version.
    var pendingActionID: String?
    var pendingStepIndex: Int = 0
    // B3: tokens consumed by the run's awaited agent tasks so far, accumulated on
    // each resume to enforce a whole-run token budget. Defaulted (lightweight).
    var consumedTokens: Int = 0
    // C1 parallel fan-out barrier: the SET of agent tasks a fanned-out run awaits,
    // stored as a JSON [UUID] string (SwiftData has no [UUID] attribute; defaulted,
    // absorbed into V7). The single-task B2 case is the degenerate one-element
    // barrier; linkedTaskID is retained for the single-await fast path + back-compat.
    var awaitedTaskIDsJSON: String = "[]"

    init(
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

    var status: WorkspaceAppRunStatus {
        get { WorkspaceAppRunStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var trigger: WorkspaceAppRunTrigger {
        get { WorkspaceAppRunTrigger(rawValue: triggerRaw) ?? .user }
        set { triggerRaw = newValue.rawValue }
    }

    var awaitedTaskIDs: [UUID] {
        get { (try? JSONDecoder().decode([UUID].self, from: Data(awaitedTaskIDsJSON.utf8))) ?? [] }
        set {
            if let data = try? JSONEncoder().encode(newValue), let json = String(data: data, encoding: .utf8) {
                awaitedTaskIDsJSON = json
            }
        }
    }
}

@Model
final class WorkspaceAppRunEvent: Identifiable {
    var id: UUID
    var runID: UUID
    var workspaceID: UUID
    var appID: UUID
    var actionID: String
    var type: String
    var payload: String
    var timestamp: Date

    init(
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
