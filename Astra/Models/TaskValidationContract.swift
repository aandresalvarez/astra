import Foundation

enum TaskValidationAssertionScope: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case plan
    case step

    init(from decoder: Decoder) throws {
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

enum TaskValidationAssertionMethod: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case command
    case artifact
    case manual
    case textEvidence = "text_evidence"
    case textContains = "text_contains"
    case verifier
    case browserBehavior = "browser_behavior"

    var displayName: String {
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

    init(from decoder: Decoder) throws {
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

struct TaskValidationAssertion: Codable, Identifiable, Sendable, Equatable, Hashable {
    var id: String
    var scope: TaskValidationAssertionScope
    var stepID: String?
    var description: String
    var method: TaskValidationAssertionMethod
    var required: Bool
    var command: String?
    var path: String?
    var expectedArtifactType: String?
    var manualReviewLabel: String?
    var evidenceQuery: String?

    init(
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

    init(from decoder: Decoder) throws {
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

struct TaskValidationContract: Codable, Sendable, Equatable, Hashable {
    var version: Int
    var assertions: [TaskValidationAssertion]

    init(version: Int = 1, assertions: [TaskValidationAssertion]) {
        self.version = version
        self.assertions = assertions
    }
}

enum TaskValidationAssertionOutcome: String, Codable, Sendable, Equatable, Hashable {
    case defined
    case started
    case passed
    case failed
    case skipped
    case reviewed
    case unknown

    init(status: String) {
        self = TaskValidationAssertionOutcome(rawValue: status) ?? .unknown
    }

    var didPass: Bool {
        self == .passed
    }
}

enum TaskValidationContractOutcome: String, Codable, Sendable, Equatable, Hashable {
    case notRequired = "not_required"
    case defined
    case passed
    case failed
    case overridden
    case unknown

    init(status: String) {
        self = TaskValidationContractOutcome(rawValue: status) ?? .unknown
    }

    var canComplete: Bool {
        switch self {
        case .notRequired, .passed, .overridden:
            true
        case .defined, .failed, .unknown:
            false
        }
    }
}

enum TaskValidationEventTypes {
    static let contractCreated = TaskEventTypes.Validation.contractCreated.rawValue
    static let contractUpdated = TaskEventTypes.Validation.contractUpdated.rawValue
    static let assertionDefined = TaskEventTypes.Validation.assertionDefined.rawValue
    static let assertionStarted = TaskEventTypes.Validation.assertionStarted.rawValue
    static let assertionPassed = TaskEventTypes.Validation.assertionPassed.rawValue
    static let assertionFailed = TaskEventTypes.Validation.assertionFailed.rawValue
    static let assertionSkipped = TaskEventTypes.Validation.assertionSkipped.rawValue
    static let assertionReviewed = TaskEventTypes.Validation.assertionReviewed.rawValue
    static let contractPassed = TaskEventTypes.Validation.contractPassed.rawValue
    static let contractFailed = TaskEventTypes.Validation.contractFailed.rawValue
    static let contractOverridden = TaskEventTypes.Validation.contractOverridden.rawValue
    static let evidence = TaskEventTypes.Validation.evidence.rawValue
}

enum TaskVerifierEventTypes {
    static let started = TaskEventTypes.Verifier.started.rawValue
    static let completed = TaskEventTypes.Verifier.completed.rawValue
    static let failed = TaskEventTypes.Verifier.failed.rawValue
}

enum TaskValidationBehaviorEventTypes {
    static let started = TaskEventTypes.Validation.behaviorStarted.rawValue
    static let passed = TaskEventTypes.Validation.behaviorPassed.rawValue
    static let failed = TaskEventTypes.Validation.behaviorFailed.rawValue
    static let evidenceAttached = TaskEventTypes.Validation.behaviorEvidenceAttached.rawValue
}

struct TaskValidationBehaviorEventPayload: Codable, Sendable, Equatable {
    var version: Int
    var planID: UUID
    var assertionID: String
    var path: String?
    var url: String?
    var actionCount: Int
    var screenshotPath: String?
    var evidencePath: String?
    var summary: String
    var reason: String?

    enum CodingKeys: String, CodingKey {
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

struct TaskVerifierEventPayload: Codable, Sendable, Equatable {
    var version: Int
    var planID: UUID
    var assertionID: String
    var runtime: String
    var model: String
    var result: String
    var summary: String
    var evidence: String?

    enum CodingKeys: String, CodingKey {
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

struct TaskValidationAssertionEventPayload: Codable, Sendable, Equatable {
    var version: Int
    var planID: UUID
    var assertionID: String
    var scope: TaskValidationAssertionScope
    var stepID: String?
    var method: TaskValidationAssertionMethod
    var required: Bool
    var status: String
    var summary: String
    var command: String?
    var exitCode: Int?
    var path: String?
    var evidence: String?
    var reason: String?

    enum CodingKeys: String, CodingKey {
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

    var outcome: TaskValidationAssertionOutcome {
        TaskValidationAssertionOutcome(status: status)
    }
}

struct TaskValidationContractEventPayload: Codable, Sendable, Equatable {
    var version: Int
    var planID: UUID
    var status: String
    var requiredPassed: Int
    var requiredTotal: Int
    var failedRequiredAssertionIDs: [String]
    var summary: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case planID
        case status
        case requiredPassed
        case requiredTotal
        case failedRequiredAssertionIDs
        case summary
    }

    var outcome: TaskValidationContractOutcome {
        TaskValidationContractOutcome(status: status)
    }
}
