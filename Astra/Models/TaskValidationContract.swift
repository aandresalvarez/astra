import Foundation

public enum TaskValidationAssertionScope: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case plan
    case step

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "step":
            self = .step
        case "plan":
            self = .plan
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported validation assertion scope: \(raw)"
            )
        }
    }
}

public enum TaskValidationAssertionMethod: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case command
    case artifact
    case manual
    case textEvidence = "text_evidence"
    case textContains = "text_contains"
    case verifier
    case browserBehavior = "browser_behavior"

    public var displayName: String {
        switch self {
        case .command:
            return "Command"
        case .artifact:
            return "Artifact"
        case .manual:
            return "Manual"
        case .textEvidence:
            return "Text evidence"
        case .textContains:
            return "Text contains"
        case .verifier:
            return "Verifier"
        case .browserBehavior:
            return "Browser behavior"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "command", "shell", "bash":
            self = .command
        case "artifact", "file", "path":
            self = .artifact
        case "manual", "manual_review", "human":
            self = .manual
        case "text_evidence", "textevidence", "evidence", "structured_evidence":
            self = .textEvidence
        case "text_contains", "textcontains", "contains_text", "file_contains", "file_text", "artifact_contains", "artifact_text":
            self = .textContains
        case "verifier", "independent_verifier", "reviewer", "ai_verifier":
            self = .verifier
        case "browser", "browser_behavior", "browser_check", "behavior", "behavioral", "ui", "ui_behavior":
            self = .browserBehavior
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported validation assertion method: \(raw)"
            )
        }
    }
}

public struct TaskValidationAssertion: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var scope: TaskValidationAssertionScope
    public var stepID: String?
    public var description: String
    public var method: TaskValidationAssertionMethod
    public var required: Bool
    public var command: String?
    public var path: String?
    public var expectedArtifactType: String?
    public var manualReviewLabel: String?
    public var evidenceQuery: String?

    public init(
        id: String,
        scope: TaskValidationAssertionScope = .plan,
        stepID: String? = nil,
        description: String,
        method: TaskValidationAssertionMethod,
        required: Bool = true,
        command: String? = nil,
        path: String? = nil,
        expectedArtifactType: String? = nil,
        manualReviewLabel: String? = nil,
        evidenceQuery: String? = nil
    ) {
        self.id = id
        self.scope = scope
        self.stepID = stepID
        self.description = description
        self.method = method
        self.required = required
        self.command = command
        self.path = path
        self.expectedArtifactType = expectedArtifactType
        self.manualReviewLabel = manualReviewLabel
        self.evidenceQuery = evidenceQuery
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case scope
        case stepID
        case description
        case method
        case required
        case command
        case path
        case expectedArtifactType
        case manualReviewLabel
        case evidenceQuery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        scope = try container.decodeIfPresent(TaskValidationAssertionScope.self, forKey: .scope) ?? .plan
        stepID = try container.decodeIfPresent(String.self, forKey: .stepID)
        description = try container.decode(String.self, forKey: .description)
        method = try container.decode(TaskValidationAssertionMethod.self, forKey: .method)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        command = try container.decodeIfPresent(String.self, forKey: .command)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        expectedArtifactType = try container.decodeIfPresent(String.self, forKey: .expectedArtifactType)
        manualReviewLabel = try container.decodeIfPresent(String.self, forKey: .manualReviewLabel)
        evidenceQuery = try container.decodeIfPresent(String.self, forKey: .evidenceQuery)
    }
}

public struct TaskValidationContract: Codable, Sendable, Equatable, Hashable {
    public var version: Int
    public var assertions: [TaskValidationAssertion]

    public init(version: Int = 1, assertions: [TaskValidationAssertion]) {
        self.version = version
        self.assertions = assertions
    }
}

public enum TaskValidationAssertionOutcome: String, Codable, Sendable, Equatable, Hashable {
    case defined
    case started
    case passed
    case failed
    case skipped
    case reviewed
    case unknown

    public init(status: String) {
        self = TaskValidationAssertionOutcome(rawValue: status) ?? .unknown
    }

    public var didPass: Bool {
        self == .passed
    }
}

public enum TaskValidationContractOutcome: String, Codable, Sendable, Equatable, Hashable {
    case notRequired = "not_required"
    case defined
    case passed
    case failed
    case overridden
    case unknown

    public init(status: String) {
        self = TaskValidationContractOutcome(rawValue: status) ?? .unknown
    }

    public var canComplete: Bool {
        switch self {
        case .notRequired, .passed, .overridden:
            true
        case .defined, .failed, .unknown:
            false
        }
    }
}

public enum TaskValidationEventTypes {
    public static let contractCreated = TaskEventTypes.Validation.contractCreated.rawValue
    public static let contractUpdated = TaskEventTypes.Validation.contractUpdated.rawValue
    public static let assertionDefined = TaskEventTypes.Validation.assertionDefined.rawValue
    public static let assertionStarted = TaskEventTypes.Validation.assertionStarted.rawValue
    public static let assertionPassed = TaskEventTypes.Validation.assertionPassed.rawValue
    public static let assertionFailed = TaskEventTypes.Validation.assertionFailed.rawValue
    public static let assertionSkipped = TaskEventTypes.Validation.assertionSkipped.rawValue
    public static let assertionReviewed = TaskEventTypes.Validation.assertionReviewed.rawValue
    public static let contractPassed = TaskEventTypes.Validation.contractPassed.rawValue
    public static let contractFailed = TaskEventTypes.Validation.contractFailed.rawValue
    public static let contractOverridden = TaskEventTypes.Validation.contractOverridden.rawValue
    public static let evidence = TaskEventTypes.Validation.evidence.rawValue
}

public enum TaskVerifierEventTypes {
    public static let started = TaskEventTypes.Verifier.started.rawValue
    public static let completed = TaskEventTypes.Verifier.completed.rawValue
    public static let failed = TaskEventTypes.Verifier.failed.rawValue
}

public enum TaskValidationBehaviorEventTypes {
    public static let started = TaskEventTypes.Validation.behaviorStarted.rawValue
    public static let passed = TaskEventTypes.Validation.behaviorPassed.rawValue
    public static let failed = TaskEventTypes.Validation.behaviorFailed.rawValue
    public static let evidenceAttached = TaskEventTypes.Validation.behaviorEvidenceAttached.rawValue
}

public struct TaskValidationBehaviorEventPayload: Codable, Sendable, Equatable {
    public init(version: Int, planID: UUID, assertionID: String, path: String? = nil, url: String? = nil, actionCount: Int, screenshotPath: String? = nil, evidencePath: String? = nil, summary: String, reason: String? = nil) {
        self.version = version
        self.planID = planID
        self.assertionID = assertionID
        self.path = path
        self.url = url
        self.actionCount = actionCount
        self.screenshotPath = screenshotPath
        self.evidencePath = evidencePath
        self.summary = summary
        self.reason = reason
    }

    public var version: Int
    public var planID: UUID
    public var assertionID: String
    public var path: String?
    public var url: String?
    public var actionCount: Int
    public var screenshotPath: String?
    public var evidencePath: String?
    public var summary: String
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case planID
        case assertionID
        case path
        case url
        case actionCount
        case screenshotPath
        case evidencePath
        case summary
        case reason
    }
}

public struct TaskVerifierEventPayload: Codable, Sendable, Equatable {
    public init(version: Int, planID: UUID, assertionID: String, runtime: String, model: String, result: String, summary: String, evidence: String? = nil) {
        self.version = version
        self.planID = planID
        self.assertionID = assertionID
        self.runtime = runtime
        self.model = model
        self.result = result
        self.summary = summary
        self.evidence = evidence
    }

    public var version: Int
    public var planID: UUID
    public var assertionID: String
    public var runtime: String
    public var model: String
    public var result: String
    public var summary: String
    public var evidence: String?

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case planID
        case assertionID
        case runtime
        case model
        case result
        case summary
        case evidence
    }
}

public struct TaskValidationAssertionEventPayload: Codable, Sendable, Equatable {
    public init(version: Int, planID: UUID, assertionID: String, scope: TaskValidationAssertionScope, stepID: String? = nil, method: TaskValidationAssertionMethod, required: Bool, status: String, summary: String, command: String? = nil, exitCode: Int? = nil, path: String? = nil, evidence: String? = nil, reason: String? = nil) {
        self.version = version
        self.planID = planID
        self.assertionID = assertionID
        self.scope = scope
        self.stepID = stepID
        self.method = method
        self.required = required
        self.status = status
        self.summary = summary
        self.command = command
        self.exitCode = exitCode
        self.path = path
        self.evidence = evidence
        self.reason = reason
    }

    public var version: Int
    public var planID: UUID
    public var assertionID: String
    public var scope: TaskValidationAssertionScope
    public var stepID: String?
    public var method: TaskValidationAssertionMethod
    public var required: Bool
    public var status: String
    public var summary: String
    public var command: String?
    public var exitCode: Int?
    public var path: String?
    public var evidence: String?
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case planID
        case assertionID
        case scope
        case stepID
        case method
        case required
        case status
        case summary
        case command
        case exitCode
        case path
        case evidence
        case reason
    }

    public var outcome: TaskValidationAssertionOutcome {
        TaskValidationAssertionOutcome(status: status)
    }
}

public struct TaskValidationContractEventPayload: Codable, Sendable, Equatable {
    public init(version: Int, planID: UUID, status: String, requiredPassed: Int, requiredTotal: Int, failedRequiredAssertionIDs: [String], summary: String) {
        self.version = version
        self.planID = planID
        self.status = status
        self.requiredPassed = requiredPassed
        self.requiredTotal = requiredTotal
        self.failedRequiredAssertionIDs = failedRequiredAssertionIDs
        self.summary = summary
    }

    public var version: Int
    public var planID: UUID
    public var status: String
    public var requiredPassed: Int
    public var requiredTotal: Int
    public var failedRequiredAssertionIDs: [String]
    public var summary: String

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case planID
        case status
        case requiredPassed
        case requiredTotal
        case failedRequiredAssertionIDs
        case summary
    }

    public var outcome: TaskValidationContractOutcome {
        TaskValidationContractOutcome(status: status)
    }
}
