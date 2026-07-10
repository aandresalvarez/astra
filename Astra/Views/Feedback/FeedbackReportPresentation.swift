import Foundation
import ASTRACore
import ASTRAModels

struct FeedbackReportStatusPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let symbol: String
    let isTerminal: Bool

    static func make(status: FeedbackLocalStatusV1) -> Self {
        switch status {
        case .draft:
            Self(title: "Draft", detail: "Your report is saved on this Mac.", symbol: "square.and.pencil", isTerminal: false)
        case .prepared:
            Self(title: "Ready to queue", detail: "The reviewed evidence package is stored locally.", symbol: "checkmark.shield", isTerminal: false)
        case .queued:
            Self(title: "Queued", detail: "ASTRA will make this available to the feedback sender in a later update.", symbol: "tray.full", isTerminal: false)
        case .uploading:
            Self(title: "Uploading", detail: "The report is being submitted.", symbol: "arrow.up.circle", isTerminal: false)
        case .submitted:
            Self(title: "Submitted", detail: "Follow-up is available in in-app status.", symbol: "checkmark.circle.fill", isTerminal: true)
        case .retryableFailure:
            Self(title: "Waiting to retry", detail: "The report remains safely stored on this Mac.", symbol: "arrow.clockwise.circle", isTerminal: false)
        case .cancelled:
            Self(title: "Discarded", detail: "This report will not be submitted.", symbol: "xmark.circle", isTerminal: true)
        case .permanentFailure:
            Self(title: "Could not submit", detail: "Review the in-app status before creating another report.", symbol: "exclamationmark.triangle", isTerminal: true)
        }
    }
}

enum FeedbackReportAccessibilityID {
    static let sheet = "feedback.report.sheet"
    static let intendedOutcome = "feedback.report.intendedOutcome"
    static let actualResult = "feedback.report.actualResult"
    static let expectedResult = "feedback.report.expectedResult"
    static let workBlocked = "feedback.report.workBlocked"
    static let reviewEvidence = "feedback.report.reviewEvidence"
    static let disclosurePreview = "feedback.report.disclosurePreview"
    static let queue = "feedback.report.queue"
    static let reportProblem = "feedback.report.action"
    static let close = "feedback.report.close"
    static let keepDraft = "feedback.report.keepDraft"
    static let discard = "feedback.report.discard"
    static let status = "feedback.report.status"
    static let applicationLogs = "feedback.report.evidence.applicationLogs"
    static let taskLogs = "feedback.report.evidence.taskLogs"
    static let browserEvidence = "feedback.report.evidence.browser"
    static let screenshots = "feedback.report.evidence.screenshots"
    static let macOSDiagnostics = "feedback.report.evidence.macosDiagnostics"
}

enum FeedbackReportRuntimeAvailability {
    static func canReport(runtimeEvidence: RuntimeFeedbackPersistedEvidence?) -> Bool { true }
}

enum FeedbackReportDismissChoice: String, CaseIterable, Equatable, Sendable {
    case keepDraft
    case discard
}

struct FeedbackReportInteractionPolicy: Equatable, Sendable {
    let canEdit: Bool
    let canPrepare: Bool
    let canQueue: Bool
    let shouldAutosave: Bool

    static func make(
        hasStoredReport: Bool,
        storedStatus: FeedbackLocalStatusV1?,
        hasExactPreview: Bool,
        hasMeaningfulProgress: Bool
    ) -> Self {
        guard hasStoredReport else {
            return Self(
                canEdit: true,
                canPrepare: true,
                canQueue: false,
                shouldAutosave: hasMeaningfulProgress
            )
        }
        guard let storedStatus else {
            return Self(canEdit: false, canPrepare: false, canQueue: false, shouldAutosave: false)
        }
        switch storedStatus {
        case .draft:
            return Self(
                canEdit: true,
                canPrepare: true,
                canQueue: hasExactPreview,
                shouldAutosave: true
            )
        case .prepared:
            return Self(
                canEdit: false,
                canPrepare: false,
                canQueue: hasExactPreview,
                shouldAutosave: false
            )
        case .queued, .uploading, .submitted, .retryableFailure, .cancelled, .permanentFailure:
            return Self(canEdit: false, canPrepare: false, canQueue: false, shouldAutosave: false)
        }
    }
}

struct FeedbackEvidencePreviewPresentation: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        let included: Bool
    }
    struct Warning: Identifiable, Equatable, Sendable {
        let id: String
        let message: String
    }

    let rows: [Row]
    let warnings: [Warning]
    let totalByteCount: Int64
    let manifestSHA256: String

    init(preview: FeedbackReportPreparedPreview) {
        var rows = preview.manifest.artifacts.map {
            Row(
                id: $0.artifactID,
                title: $0.artifactID,
                detail: "\($0.kind.rawValue) · \($0.disclosureClass.rawValue) · \($0.byteCount) bytes · \($0.sha256)",
                included: true
            )
        }
        rows += preview.manifest.omissions.map {
            Row(
                id: "omitted-\($0.artifactID)",
                title: $0.artifactID,
                detail: "Not included · \($0.reason.rawValue)\($0.detail.map { " · \($0)" } ?? "")",
                included: false
            )
        }
        self.rows = rows.sorted { $0.id < $1.id }
        warnings = preview.manifest.warnings.enumerated().map { index, warning in
            Warning(
                id: "\(index)-\(warning.code)-\(warning.artifactID ?? "none")",
                message: warning.message
            )
        }
        totalByteCount = preview.manifest.totalByteCount
        manifestSHA256 = preview.package.manifestSHA256
    }
}
