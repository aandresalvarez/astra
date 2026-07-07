import Foundation

public enum TaskPlanPayloadStepStatus: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case pending
    case running
    case blocked
    case done
    case skipped

    public var isHistoricalTerminalStatus: Bool {
        switch self {
        case .done, .skipped:
            true
        case .pending, .running, .blocked:
            false
        }
    }
}

public enum TaskPlanPayloadRisk: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case low
    case medium
    case high
}

public enum TaskPlanArtifactKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case file
    case directory
    case url
    case text
    case evidence

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "file", "artifact", "document":
            self = .file
        case "directory", "folder", "dir":
            self = .directory
        case "url", "link":
            self = .url
        case "text", "chat", "answer":
            self = .text
        case "evidence", "proof", "validation_evidence":
            self = .evidence
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported task plan artifact kind: \(raw)"
            )
        }
    }
}

public enum TaskPlanArtifactScope: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case taskOutput = "task_output"
    case workspace
    case remote
    case chat

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "task_output", "taskoutput", "task", "output", "outputs", "artifact", "artifacts":
            self = .taskOutput
        case "workspace", "project", "repository", "repo":
            self = .workspace
        case "remote", "server", "external":
            self = .remote
        case "chat", "message", "response":
            self = .chat
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported task plan artifact scope: \(raw)"
            )
        }
    }
}

public struct TaskPlanStepOutput: Codable, Sendable, Equatable, Hashable {
    public var kind: TaskPlanArtifactKind
    public var scope: TaskPlanArtifactScope
    public var path: String?
    public var required: Bool
    public var prepareParentDirectories: Bool
    public var source: String?

    public init(
        kind: TaskPlanArtifactKind = .file,
        scope: TaskPlanArtifactScope = .taskOutput,
        path: String? = nil,
        required: Bool = true,
        prepareParentDirectories: Bool = true,
        source: String? = nil
    ) {
        self.kind = kind
        self.scope = scope
        self.path = path
        self.required = required
        self.prepareParentDirectories = prepareParentDirectories
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case scope
        case path
        case required
        case prepareParentDirectories
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(TaskPlanArtifactKind.self, forKey: .kind) ?? .file
        scope = try container.decodeIfPresent(TaskPlanArtifactScope.self, forKey: .scope) ?? .taskOutput
        path = try container.decodeIfPresent(String.self, forKey: .path)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        prepareParentDirectories = try container.decodeIfPresent(Bool.self, forKey: .prepareParentDirectories) ?? true
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}

public struct TaskPlanPayloadStep: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var status: TaskPlanPayloadStepStatus
    public var risk: TaskPlanPayloadRisk
    public var likelyTools: [String]
    public var doneSignal: String
    public var outputs: [TaskPlanStepOutput]

    public init(
        id: String,
        title: String,
        detail: String = "",
        status: TaskPlanPayloadStepStatus = .pending,
        risk: TaskPlanPayloadRisk = .low,
        likelyTools: [String] = [],
        doneSignal: String = "",
        outputs: [TaskPlanStepOutput] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.risk = risk
        self.likelyTools = likelyTools
        self.doneSignal = doneSignal
        self.outputs = outputs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        status = try container.decodeIfPresent(TaskPlanPayloadStepStatus.self, forKey: .status) ?? .pending
        risk = try container.decodeIfPresent(TaskPlanPayloadRisk.self, forKey: .risk) ?? .low
        likelyTools = try container.decodeIfPresent([String].self, forKey: .likelyTools) ?? []
        doneSignal = try container.decodeIfPresent(String.self, forKey: .doneSignal) ?? ""
        outputs = try container.decodeIfPresent([TaskPlanStepOutput].self, forKey: .outputs) ?? []
    }
}

public struct TaskPlanPayload: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var version: Int
    public var planID: UUID
    public var title: String
    public var goal: String
    public var steps: [TaskPlanPayloadStep]
    public var validationContract: TaskValidationContract?

    public var id: UUID { planID }

    public init(
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

public enum TaskPlanLifecycleStatus: String, Sendable, Equatable {
    case none
    case draft
    case approved
    case executing
    case completed
    case failed
    case cancelled
}

public enum TaskPlanExecutionMode: String, Sendable, Equatable {
    case fullPlan = "full_plan"
    case nextStep = "next_step"
}

public struct TaskPlanState: Sendable, Equatable {
    public init(plan: TaskPlanPayload? = nil, lifecycleStatus: TaskPlanLifecycleStatus, approvedAt: Date? = nil, cancelledAt: Date? = nil, cancellationReason: String? = nil, executionStartedAt: Date? = nil, executionCompletedAt: Date? = nil, executionFailedAt: Date? = nil, latestEventAt: Date? = nil) {
        self.plan = plan
        self.lifecycleStatus = lifecycleStatus
        self.approvedAt = approvedAt
        self.cancelledAt = cancelledAt
        self.cancellationReason = cancellationReason
        self.executionStartedAt = executionStartedAt
        self.executionCompletedAt = executionCompletedAt
        self.executionFailedAt = executionFailedAt
        self.latestEventAt = latestEventAt
    }

    public var plan: TaskPlanPayload?
    public var lifecycleStatus: TaskPlanLifecycleStatus
    public var approvedAt: Date?
    public var cancelledAt: Date?
    public var cancellationReason: String?
    public var executionStartedAt: Date?
    public var executionCompletedAt: Date?
    public var executionFailedAt: Date?
    public var latestEventAt: Date?

    public static let empty = TaskPlanState(
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

public struct TaskPlanProgressPayload: Codable, Sendable, Equatable {
    public init(version: Int, type: String, planID: UUID? = nil, stepID: String, status: TaskPlanPayloadStepStatus, title: String? = nil, detail: String? = nil, summary: String? = nil, reason: String? = nil) {
        self.version = version
        self.type = type
        self.planID = planID
        self.stepID = stepID
        self.status = status
        self.title = title
        self.detail = detail
        self.summary = summary
        self.reason = reason
    }

    public var version: Int
    public var type: String
    public var planID: UUID?
    public var stepID: String
    public var status: TaskPlanPayloadStepStatus
    public var title: String?
    public var detail: String?
    public var summary: String?
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
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

public struct TaskPlanLifecyclePayload: Codable, Sendable, Equatable {
    public var version: Int
    public var planID: UUID
    public var reason: String?

    public init(version: Int = 1, planID: UUID, reason: String? = nil) {
        self.version = version
        self.planID = planID
        self.reason = reason
    }

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case planID
        case reason
    }
}

public typealias TaskPlan = TaskPlanPayload
public typealias TaskPlanStep = TaskPlanPayloadStep
public typealias TaskPlanStepStatus = TaskPlanPayloadStepStatus
public typealias TaskPlanRisk = TaskPlanPayloadRisk
