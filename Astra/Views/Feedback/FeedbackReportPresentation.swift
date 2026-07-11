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

enum FeedbackReportCloseAction: Equatable, Sendable {
    case closePresentation
    case offerDraftChoices
}

enum FeedbackReportDismissPersistenceAction: Equatable, Sendable {
    case closeWithoutPersistence
    case saveDraft
    case discardStoredReport
}

enum FeedbackReportDismissPersistencePolicy {
    static func action(
        keepingDraft: Bool,
        hasStoredReport: Bool,
        hasMeaningfulProgress: Bool
    ) -> FeedbackReportDismissPersistenceAction {
        if keepingDraft {
            return hasStoredReport || hasMeaningfulProgress ? .saveDraft : .closeWithoutPersistence
        }
        return hasStoredReport ? .discardStoredReport : .closeWithoutPersistence
    }
}

enum FeedbackReportClosePolicy {
    static func action(
        hasStoredReport: Bool,
        storedStatus: FeedbackLocalStatusV1?,
        isDirty: Bool,
        isPreparing: Bool,
        hasPreview: Bool,
        isInvalidatingPreview: Bool
    ) -> FeedbackReportCloseAction {
        if hasStoredReport {
            guard storedStatus == .draft else { return .closePresentation }
            return .offerDraftChoices
        }
        return isDirty || isPreparing || hasPreview || isInvalidatingPreview
            ? .offerDraftChoices
            : .closePresentation
    }

    static func perform(
        hasStoredReport: Bool,
        storedStatus: FeedbackLocalStatusV1?,
        isDirty: Bool,
        isPreparing: Bool,
        hasPreview: Bool,
        isInvalidatingPreview: Bool,
        offerDraftChoices: () -> Void,
        closePresentation: () -> Void
    ) {
        switch action(
            hasStoredReport: hasStoredReport,
            storedStatus: storedStatus,
            isDirty: isDirty,
            isPreparing: isPreparing,
            hasPreview: hasPreview,
            isInvalidatingPreview: isInvalidatingPreview
        ) {
        case .offerDraftChoices:
            offerDraftChoices()
        case .closePresentation:
            closePresentation()
        }
    }
}

enum FeedbackReportOwnedWorkFailure: Equatable, Sendable {
    case generic
    case retainedCleanup(FeedbackPreparedPreviewCleanupKey)
}

enum FeedbackReportOwnedWorkResult: Equatable, Sendable {
    case succeeded
    case failed(FeedbackReportOwnedWorkFailure)
    case cancelled
}

/// The live sheet remains the presentation owner while Keep Draft or Discard
/// settles its staged preview. If bounded cancellation previously transferred
/// cleanup to the process owner, Close must consume that first exact authority
/// instead of deleting independently and leaving a stale capability behind.
@MainActor
enum FeedbackReportLiveCleanupFinalizer {
    static func invalidateIfOwned(
        _ preview: FeedbackReportPreparedPreview,
        sourceHostID: UUID,
        sourceLeaseID: UUID,
        cleanupOwner: FeedbackPreparedPreviewCleanupOwner,
        fallbackCleanup: @MainActor () throws -> Void
    ) throws -> FeedbackPreparedPreviewCleanupKey? {
        guard preview.ownership == .trustedStaging else { return nil }
        return try invalidate(
            preview,
            sourceHostID: sourceHostID,
            sourceLeaseID: sourceLeaseID,
            cleanupOwner: cleanupOwner,
            fallbackCleanup: fallbackCleanup
        )
    }

    static func invalidate(
        _ preview: FeedbackReportPreparedPreview,
        sourceHostID: UUID,
        sourceLeaseID: UUID,
        cleanupOwner: FeedbackPreparedPreviewCleanupOwner,
        fallbackCleanup: @MainActor () throws -> Void
    ) throws -> FeedbackPreparedPreviewCleanupKey {
        let expectedKey = FeedbackPreparedPreviewCleanupKey(
            reportID: preview.reportID,
            contextIdentity: preview.contextIdentity,
            sourceHostID: sourceHostID,
            sourceLeaseID: sourceLeaseID,
            directoryURL: preview.package.directoryURL
        )
        if cleanupOwner.pendingKey != nil {
            guard try cleanupOwner.retryPendingCleanup(matching: expectedKey) else {
                throw FeedbackPreparedPreviewCleanupOwnerError.capabilityMismatch
            }
        } else {
            try fallbackCleanup()
        }
        return expectedKey
    }
}

private final class FeedbackReportOwnedWorkReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var result: FeedbackReportOwnedWorkResult?
    private var waiters: [UUID: CheckedContinuation<FeedbackReportOwnedWorkResult, Never>] = [:]

    var waiterCount: Int { lock.withLock { waiters.count } }
    var isComplete: Bool { lock.withLock { result != nil } }
    var terminalResult: FeedbackReportOwnedWorkResult? { lock.withLock { result } }

    func wait() async -> FeedbackReportOwnedWorkResult {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                } else {
                    waiters[waiterID] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel(waiterID)
        }
    }

    func complete(_ result: FeedbackReportOwnedWorkResult) {
        let continuations: [CheckedContinuation<FeedbackReportOwnedWorkResult, Never>] = lock.withLock {
            guard self.result == nil else { return [] }
            self.result = result
            let continuations = Array(waiters.values)
            waiters.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume(returning: result) }
    }

    private func cancel(_ waiterID: UUID) {
        let continuation = lock.withLock { waiters.removeValue(forKey: waiterID) }
        continuation?.resume(returning: .cancelled)
    }
}

@MainActor
final class FeedbackReportOwnedWork {
    private let receipt: FeedbackReportOwnedWorkReceipt
    private let task: Task<Void, Never>

    private init(receipt: FeedbackReportOwnedWorkReceipt, task: Task<Void, Never>) {
        self.receipt = receipt
        self.task = task
    }

    static func start(
        operation: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> FeedbackReportOwnedWorkFailure = { _ in .generic }
    ) -> FeedbackReportOwnedWork {
        let receipt = FeedbackReportOwnedWorkReceipt()
        let task = Task { @MainActor in
            do {
                try await operation()
                receipt.complete(.succeeded)
            } catch is CancellationError {
                // Preparation owns cancellation cleanup. Reaching this catch
                // means no staged capability escaped the operation.
                receipt.complete(.succeeded)
            } catch {
                receipt.complete(.failed(onFailure(error)))
            }
        }
        return FeedbackReportOwnedWork(receipt: receipt, task: task)
    }

    func cancel() { task.cancel() }
    func wait() async -> FeedbackReportOwnedWorkResult { await receipt.wait() }
    var settlementWaiterCount: Int { receipt.waiterCount }
    var isTerminal: Bool { receipt.isComplete }
    var terminalResult: FeedbackReportOwnedWorkResult? { receipt.terminalResult }
}

@MainActor
enum FeedbackReportTaskSettlement {
    static let maximumOwnedTasks = 2

    static func cancelAndFinalize(
        _ work: [FeedbackReportOwnedWork],
        timeout: Duration = .seconds(2),
        isResolvedRetainedCleanup: @MainActor (FeedbackPreparedPreviewCleanupKey) -> Bool = { _ in false },
        finalize: @MainActor () throws -> Void
    ) async -> Bool {
        work.forEach { $0.cancel() }
        let workSucceeded = await wait(for: work, timeout: timeout)
        do {
            try finalize()
        } catch {
            return false
        }
        if workSucceeded { return true }
        // A retained-cleanup receipt describes a failure only until the exact
        // live finalizer consumes that capability. Timeouts, generic errors,
        // unresolved keys, and nonterminal work remain fail-closed.
        return work.allSatisfy { item in
            switch item.terminalResult {
            case .succeeded:
                return true
            case .failed(.retainedCleanup(let key)):
                return isResolvedRetainedCleanup(key)
            case .failed(.generic):
                return false
            case .cancelled, .none:
                return false
            }
        }
    }

    static func wait(
        for work: [FeedbackReportOwnedWork],
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        guard !work.isEmpty else { return true }
        guard work.count <= maximumOwnedTasks else { return false }
        return await withTaskGroup(of: FeedbackReportOwnedWorkResult.self) { group in
            for item in work {
                group.addTask { await item.wait() }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) }
                catch { return .cancelled }
                return .cancelled
            }
            var completed = 0
            while let result = await group.next() {
                switch result {
                case .succeeded:
                    completed += 1
                    if completed == work.count {
                        group.cancelAll()
                        return true
                    }
                case .failed, .cancelled:
                    group.cancelAll()
                    return false
                }
            }
            return false
        }
    }
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
