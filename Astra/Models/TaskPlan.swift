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

enum TaskPlanArtifactKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case file
    case directory
    case url
    case text
    case evidence

    init(from decoder: Decoder) throws {
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

enum TaskPlanArtifactScope: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case taskOutput = "task_output"
    case workspace
    case remote
    case chat

    init(from decoder: Decoder) throws {
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

struct TaskPlanStepOutput: Codable, Sendable, Equatable, Hashable {
    var kind: TaskPlanArtifactKind
    var scope: TaskPlanArtifactScope
    var path: String?
    var required: Bool
    var prepareParentDirectories: Bool
    var source: String?

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(TaskPlanArtifactKind.self, forKey: .kind) ?? .file
        scope = try container.decodeIfPresent(TaskPlanArtifactScope.self, forKey: .scope) ?? .taskOutput
        path = try container.decodeIfPresent(String.self, forKey: .path)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        prepareParentDirectories = try container.decodeIfPresent(Bool.self, forKey: .prepareParentDirectories) ?? true
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}

struct TaskPlanPayloadStep: Codable, Identifiable, Sendable, Equatable, Hashable {
    var id: String
    var title: String
    var detail: String
    var status: TaskPlanPayloadStepStatus
    var risk: TaskPlanPayloadRisk
    var likelyTools: [String]
    var doneSignal: String
    var outputs: [TaskPlanStepOutput]

    init(
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

    init(from decoder: Decoder) throws {
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
