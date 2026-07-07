import Foundation

/// Pure value-type + decode slice of
/// `Astra/Services/Validation/TaskDeliverableVerificationService.swift`,
/// extracted for Track A4 (`ASTRAPersistence`) so `TaskContextStateManager.swift`
/// can read a deliverable-verification event's payload without depending on
/// the rest of that app-side service (which shells out to `node` via
/// `AsyncProcessRunner`/`RuntimePathResolver` to check JavaScript syntax -
/// real process-execution logic that must stay app-side).
/// `TaskDeliverableVerificationService.decode`/`.decodeResult` delegate here
/// so its existing callers are unaffected.
public enum TaskDeliverableProfile: String, Codable, Sendable, Equatable {
    case notRequired = "not_required"
    case standaloneWebArtifact = "standalone_web_artifact"
    case documentArtifact = "document_artifact"
    case codeArtifact = "code_artifact"
    case dataArtifact = "data_artifact"
    case genericArtifact = "generic_artifact"
}

public enum TaskDeliverableQualityLevel: String, Codable, Sendable, Equatable {
    case notApplicable = "not_applicable"
    case noArtifact = "no_artifact"
    case artifactOnly = "artifact_only"
    case syntaxVerified = "syntax_verified"
    case runtimeVerified = "runtime_verified"
    case behaviorVerified = "behavior_verified"
    case needsHumanReview = "needs_human_review"
    case failed
}

public enum TaskDeliverableCheckStatus: String, Codable, Sendable, Equatable {
    case passed
    case failed
    case skipped
    case warning
}

public struct TaskDeliverableCheck: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var status: TaskDeliverableCheckStatus
    public var summary: String
    public var path: String?

    public init(id: String, title: String, status: TaskDeliverableCheckStatus, summary: String, path: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.path = path
    }
}

public struct TaskDeliverableVerificationResult: Codable, Sendable, Equatable {
    public var version: Int
    public var profile: TaskDeliverableProfile
    public var level: TaskDeliverableQualityLevel
    public var status: String
    public var canComplete: Bool
    public var requiresHumanReview: Bool
    public var summary: String
    public var checks: [TaskDeliverableCheck]
    public var evidencePaths: [String]
    public var runID: UUID?
    public var verifiedAt: Date

    public init(
        version: Int,
        profile: TaskDeliverableProfile,
        level: TaskDeliverableQualityLevel,
        status: String,
        canComplete: Bool,
        requiresHumanReview: Bool,
        summary: String,
        checks: [TaskDeliverableCheck],
        evidencePaths: [String],
        runID: UUID? = nil,
        verifiedAt: Date
    ) {
        self.version = version
        self.profile = profile
        self.level = level
        self.status = status
        self.canComplete = canComplete
        self.requiresHumanReview = requiresHumanReview
        self.summary = summary
        self.checks = checks
        self.evidencePaths = evidencePaths
        self.runID = runID
        self.verifiedAt = verifiedAt
    }

    public var shouldBlockCompletion: Bool {
        !canComplete
    }

    public var userVisibleFailureMessage: String {
        switch level {
        case .noArtifact:
            return summary
        case .failed:
            let failedChecks = checks
                .filter { $0.status == .failed }
                .map { "\($0.title): \($0.summary)" }
                .prefix(4)
                .joined(separator: "\n")
            return """
            ASTRA did not mark this task complete because the requested deliverable was present but failed deterministic verification.
            \(failedChecks.isEmpty ? summary : failedChecks)
            Fix the artifact and retry, or explicitly continue if you want the provider to repair it.
            """
        default:
            return summary
        }
    }
}

public struct TaskDeliverableVerificationEventPayload: Codable, Sendable, Equatable {
    public var version: Int
    public var profile: TaskDeliverableProfile
    public var level: TaskDeliverableQualityLevel
    public var status: String
    public var canComplete: Bool
    public var requiresHumanReview: Bool
    public var summary: String
    public var checks: [TaskDeliverableCheck]
    public var evidencePaths: [String]
    public var runID: UUID?
    public var verifiedAt: Date

    public init(
        version: Int,
        profile: TaskDeliverableProfile,
        level: TaskDeliverableQualityLevel,
        status: String,
        canComplete: Bool,
        requiresHumanReview: Bool,
        summary: String,
        checks: [TaskDeliverableCheck],
        evidencePaths: [String],
        runID: UUID? = nil,
        verifiedAt: Date
    ) {
        self.version = version
        self.profile = profile
        self.level = level
        self.status = status
        self.canComplete = canComplete
        self.requiresHumanReview = requiresHumanReview
        self.summary = summary
        self.checks = checks
        self.evidencePaths = evidencePaths
        self.runID = runID
        self.verifiedAt = verifiedAt
    }
}

public enum TaskDeliverableVerificationEventTypes {
    public static let passed = TaskEventTypes.Deliverable.verificationPassed.rawValue
    public static let reviewNeeded = TaskEventTypes.Deliverable.verificationReviewNeeded.rawValue
    public static let failed = TaskEventTypes.Deliverable.verificationFailed.rawValue
}

public enum TaskDeliverableVerificationCodec {
    public static func decode(_ payload: String) -> TaskDeliverableVerificationEventPayload? {
        switch decodeResult(payload) {
        case .success(let decoded):
            decoded
        case .failure:
            nil
        }
    }

    public static func decodeResult(
        _ payload: String
    ) -> Result<TaskDeliverableVerificationEventPayload, TaskEventPayloadDecodeError> {
        guard let data = payload.data(using: .utf8) else {
            return .failure(.invalidUTF8)
        }
        do {
            return .success(try TaskEventPayloadCodec.makeISO8601Decoder().decode(
                TaskDeliverableVerificationEventPayload.self,
                from: data
            ))
        } catch {
            return .failure(.decodingFailed(error.localizedDescription))
        }
    }
}
