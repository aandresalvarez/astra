import Foundation

enum TaskPlanPayloadStepStatus: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case pending
    case running
    case blocked
    case done
    case skipped

    var isHistoricalTerminalStatus: Bool {
        switch self {
        case .done, .skipped:
            true
        case .pending, .running, .blocked:
            false
        }
    }
}

enum TaskPlanPayloadRisk: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case low
    case medium
    case high
}

struct TaskPlanPayloadStep: Codable, Identifiable, Sendable, Equatable, Hashable {
    var id: String
    var title: String
    var detail: String
    var status: TaskPlanPayloadStepStatus
    var risk: TaskPlanPayloadRisk
    var likelyTools: [String]
    var doneSignal: String

    init(
        id: String,
        title: String,
        detail: String = "",
        status: TaskPlanPayloadStepStatus = .pending,
        risk: TaskPlanPayloadRisk = .low,
        likelyTools: [String] = [],
        doneSignal: String = ""
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.risk = risk
        self.likelyTools = likelyTools
        self.doneSignal = doneSignal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        status = try container.decodeIfPresent(TaskPlanPayloadStepStatus.self, forKey: .status) ?? .pending
        risk = try container.decodeIfPresent(TaskPlanPayloadRisk.self, forKey: .risk) ?? .low
        likelyTools = try container.decodeIfPresent([String].self, forKey: .likelyTools) ?? []
        doneSignal = try container.decodeIfPresent(String.self, forKey: .doneSignal) ?? ""
    }
}

struct TaskPlanPayload: Codable, Identifiable, Sendable, Equatable, Hashable {
    var version: Int
    var planID: UUID
    var title: String
    var goal: String
    var steps: [TaskPlanPayloadStep]
    var validationContract: TaskValidationContract?

    var id: UUID { planID }

    init(
        version: Int = 1,
        planID: UUID = UUID(),
        title: String,
        goal: String,
        steps: [TaskPlanPayloadStep],
        validationContract: TaskValidationContract? = nil
    ) {
        self.version = version
        self.planID = planID
        self.title = title
        self.goal = goal
        self.steps = steps
        self.validationContract = validationContract
    }
}

enum TaskPlanLifecycleStatus: String, Sendable, Equatable {
    case none
    case draft
    case approved
    case executing
    case completed
    case failed
    case cancelled
}

enum TaskPlanExecutionMode: String, Sendable, Equatable {
    case fullPlan = "full_plan"
    case nextStep = "next_step"
}

struct TaskPlanState: Sendable, Equatable {
    var plan: TaskPlanPayload?
    var lifecycleStatus: TaskPlanLifecycleStatus
    var approvedAt: Date?
    var cancelledAt: Date?
    var cancellationReason: String?
    var executionStartedAt: Date?
    var executionCompletedAt: Date?
    var executionFailedAt: Date?
    var latestEventAt: Date?

    static let empty = TaskPlanState(
        plan: nil,
        lifecycleStatus: .none,
        approvedAt: nil,
        cancelledAt: nil,
        cancellationReason: nil,
        executionStartedAt: nil,
        executionCompletedAt: nil,
        executionFailedAt: nil,
        latestEventAt: nil
    )
}

struct TaskPlanProgressPayload: Codable, Sendable, Equatable {
    var version: Int
    var type: String
    var planID: UUID?
    var stepID: String
    var status: TaskPlanPayloadStepStatus
    var title: String?
    var detail: String?
    var summary: String?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case planID
        case stepID
        case status
        case title
        case detail
        case summary
        case reason
    }
}

struct TaskPlanLifecyclePayload: Codable, Sendable, Equatable {
    var version: Int
    var planID: UUID
    var reason: String?

    init(version: Int = 1, planID: UUID, reason: String? = nil) {
        self.version = version
        self.planID = planID
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case planID
        case reason
    }
}

typealias TaskPlan = TaskPlanPayload
typealias TaskPlanStep = TaskPlanPayloadStep
typealias TaskPlanStepStatus = TaskPlanPayloadStepStatus
typealias TaskPlanRisk = TaskPlanPayloadRisk
