import Foundation
import ASTRACore

struct FeedbackEvidenceSelections: Equatable, Sendable {
    var includeApplicationLogs = true
    var includeTaskLogs = true
    var includeBrowserEvidence = false
    var includeScreenshots = false
    var includeMacOSDiagnostics = false
}

struct FeedbackBrowserEvidenceRecord: Codable, Equatable, Sendable {
    let sequence: Int
    let createdAt: Date
    let method: String
    let path: String
    let statusCode: Int
    let durationMilliseconds: Int
    let beforeHost: String
    let afterHost: String
    let urlChanged: Bool
    let succeeded: Bool
    let errorCode: String?
    let observedOutcome: String?
}

struct FeedbackScreenshotCandidate: Equatable, Sendable {
    let jpegData: Data
    let source: String
    let width: Int
    let height: Int
}

struct FeedbackEvidenceInput: Sendable {
    let reportID: UUID
    let reportCreatedAt: Date
    let applicationLogEntries: [LogEntry]
    let taskLogEntries: [LogEntry]
    let browserRecords: [FeedbackBrowserEvidenceRecord]
    let screenshots: [FeedbackScreenshotCandidate]
    let crashReports: [CrashReportSummary]
    let makeReportEnvelopeData: @Sendable (FeedbackEvidenceManifestV1) throws -> Data

    init(
        reportID: UUID,
        reportCreatedAt: Date,
        applicationLogEntries: [LogEntry],
        taskLogEntries: [LogEntry],
        browserRecords: [FeedbackBrowserEvidenceRecord],
        screenshots: [FeedbackScreenshotCandidate],
        crashReports: [CrashReportSummary],
        makeReportEnvelopeData: @escaping @Sendable (FeedbackEvidenceManifestV1) throws -> Data
    ) {
        self.reportID = reportID
        self.reportCreatedAt = reportCreatedAt
        self.applicationLogEntries = applicationLogEntries
        self.taskLogEntries = taskLogEntries
        self.browserRecords = browserRecords
        self.screenshots = screenshots
        self.crashReports = crashReports
        self.makeReportEnvelopeData = makeReportEnvelopeData
    }
}

struct FeedbackPreparedEvidencePackage: Equatable, Sendable {
    let reportID: UUID
    let reportCreatedAt: Date
    let directoryURL: URL
    let reportURL: URL
    let archiveURL: URL
    let manifestURL: URL
    let manifest: FeedbackEvidenceManifestV1
    let manifestSHA256: String
    let reportSHA256: String
    let archiveSHA256: String
}

enum FeedbackEvidencePolicy {
    static let redactionPolicyVersion = "feedback-redaction-v1"
    static let reportFileName = "feedback-report.json"
    static let archiveFileName = "evidence.zip"
    static let manifestFileName = "manifest.json"
    static let maximumTextArtifactBytes = 2 * 1_024 * 1_024
    static let maximumBrowserRecords = 200
    static let maximumScreenshots = 8
    static let maximumCrashReports = 20
    static let maximumCrashInspectionBytes = 128 * 1_024

    struct Rule: Equatable, Sendable {
        let kind: FeedbackEvidenceArtifactKindV1
        let disclosureClass: FeedbackEvidenceDisclosureClassV1
        let relativePath: String
        let mediaType: String
        let maximumBytes: Int
    }

    static let applicationLog = Rule(
        kind: .applicationLog,
        disclosureClass: .standard,
        relativePath: "logs/application-log.jsonl",
        mediaType: "application/x-ndjson",
        maximumBytes: maximumTextArtifactBytes
    )

    static let taskLog = Rule(
        kind: .taskLog,
        disclosureClass: .standard,
        relativePath: "logs/task-log.jsonl",
        mediaType: "application/x-ndjson",
        maximumBytes: maximumTextArtifactBytes
    )

    static let browserEvidence = Rule(
        kind: .browserEvidence,
        disclosureClass: .explicitOptIn,
        relativePath: "browser/browser-evidence.json",
        mediaType: "application/json",
        maximumBytes: maximumTextArtifactBytes
    )

    static let macOSDiagnostic = Rule(
        kind: .macOSDiagnostic,
        disclosureClass: .explicitOptIn,
        relativePath: "diagnostics/macos-diagnostics.json",
        mediaType: "application/json",
        maximumBytes: maximumTextArtifactBytes
    )

    static func screenshotRule(index: Int) -> Rule {
        Rule(
            kind: .screenshot,
            disclosureClass: .explicitOptIn,
            relativePath: String(format: "screenshots/browser-%03d.jpg", index + 1),
            mediaType: "image/jpeg",
            maximumBytes: Int(FeedbackContractLimitsV1.maximumArtifactBytes)
        )
    }

    static func isSelected(_ rule: Rule, selections: FeedbackEvidenceSelections) -> Bool {
        switch rule.kind {
        case .applicationLog:
            selections.includeApplicationLogs
        case .taskLog:
            selections.includeTaskLogs
        case .browserEvidence:
            selections.includeBrowserEvidence
        case .screenshot:
            selections.includeScreenshots
        case .macOSDiagnostic:
            selections.includeMacOSDiagnostics
        default:
            false
        }
    }
}

enum FeedbackEvidenceBuildError: LocalizedError, Equatable {
    case packageAlreadyExists(String)
    case unsafeDestination(String)
    case archiveCreationFailed(String)
    case noArchiveTool
    case invalidReportEnvelope(String)

    var errorDescription: String? {
        switch self {
        case .packageAlreadyExists(let path):
            "A prepared feedback package already exists at \(path)."
        case .unsafeDestination(let path):
            "Feedback evidence resolved outside its staging directory: \(path)."
        case .archiveCreationFailed(let message):
            "Could not create the feedback evidence archive: \(message)"
        case .noArchiveTool:
            "The system zip tool is unavailable."
        case .invalidReportEnvelope(let detail):
            "The feedback report envelope does not match its prepared evidence: \(detail)"
        }
    }
}
