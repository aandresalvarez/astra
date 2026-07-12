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
    static let manualExport = "feedback.report.manualExport"
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

enum FeedbackReportHostDeactivationPersistencePolicy {
    static func shouldPersist(
        explicitDismissalCompleted: Bool,
        hasStoredReport: Bool,
        hasMeaningfulProgress: Bool
    ) -> Bool {
        !explicitDismissalCompleted && (hasStoredReport || hasMeaningfulProgress)
    }
}

enum FeedbackReportClosePolicy {
    static func action(
        hasStoredReport: Bool,
        storedStatus: FeedbackLocalStatusV1?,
        hasMeaningfulProgress: Bool,
        isPreparing: Bool,
        hasPreview: Bool,
        isInvalidatingPreview: Bool
    ) -> FeedbackReportCloseAction {
        if hasStoredReport {
            guard storedStatus == .draft else { return .closePresentation }
            return .offerDraftChoices
        }
        return hasMeaningfulProgress || isPreparing || hasPreview || isInvalidatingPreview
            ? .offerDraftChoices
            : .closePresentation
    }

    static func perform(
        hasStoredReport: Bool,
        storedStatus: FeedbackLocalStatusV1?,
        hasMeaningfulProgress: Bool,
        isPreparing: Bool,
        hasPreview: Bool,
        isInvalidatingPreview: Bool,
        offerDraftChoices: () -> Void,
        closePresentation: () -> Void
    ) {
        switch action(
            hasStoredReport: hasStoredReport,
            storedStatus: storedStatus,
            hasMeaningfulProgress: hasMeaningfulProgress,
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

enum FeedbackEvidenceWindowPresentation {
    private static let recentTolerance: TimeInterval = 60

    static func label(
        start: Date,
        end: Date,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let durationMinutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        if abs(now.timeIntervalSince(end)) <= recentTolerance {
            return durationMinutes == 1 ? "the last minute" : "the last \(durationMinutes) minutes"
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: start)) to \(formatter.string(from: end))"
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
    private var completionObservers: [UUID: @Sendable (FeedbackReportOwnedWorkResult) -> Void] = [:]

    var waiterCount: Int { lock.withLock { waiters.count } }
    var completionObserverCount: Int { lock.withLock { completionObservers.count } }
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
        let callbacks: (
            continuations: [CheckedContinuation<FeedbackReportOwnedWorkResult, Never>],
            observers: [@Sendable (FeedbackReportOwnedWorkResult) -> Void]
        ) = lock.withLock {
            guard self.result == nil else { return ([], []) }
            self.result = result
            let continuations = Array(waiters.values)
            let observers = Array(completionObservers.values)
            waiters.removeAll()
            completionObservers.removeAll()
            return (continuations, observers)
        }
        callbacks.continuations.forEach { $0.resume(returning: result) }
        callbacks.observers.forEach { $0(result) }
    }

    func observeCompletion(
        _ observer: @escaping @Sendable (FeedbackReportOwnedWorkResult) -> Void
    ) -> Bool {
        let state = lock.withLock { () -> (accepted: Bool, completed: FeedbackReportOwnedWorkResult?) in
            if let result { return (true, result) }
            guard completionObservers.isEmpty else { return (false, nil) }
            completionObservers[UUID()] = observer
            return (true, nil)
        }
        if let completed = state.completed { observer(completed) }
        return state.accepted
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
    var lateSettlementObserverCount: Int { receipt.completionObserverCount }
    var isTerminal: Bool { receipt.isComplete }
    var terminalResult: FeedbackReportOwnedWorkResult? { receipt.terminalResult }

    func observeCompletion(
        _ observer: @escaping @MainActor (FeedbackReportOwnedWorkResult) -> Void
    ) -> Bool {
        receipt.observeCompletion { result in
            // This task is created only after terminal completion. It never
            // waits for owned work, so a cancellation-ignoring worker cannot
            // leave a monitor task alive.
            Task { @MainActor in observer(result) }
        }
    }
}

enum FeedbackReportLateSettlementRecovery: Equatable {
    case alreadySucceeded
    case observing
    case unrecoverable
}

@MainActor
private final class FeedbackReportLateSettlementBarrier {
    private var remaining: Int
    private var failed = false
    private let onSuccess: @MainActor () -> Void

    init(remaining: Int, onSuccess: @escaping @MainActor () -> Void) {
        self.remaining = remaining
        self.onSuccess = onSuccess
    }

    func record(_ result: FeedbackReportOwnedWorkResult) {
        guard remaining > 0 else { return }
        if result != .succeeded { failed = true }
        remaining -= 1
        if remaining == 0, !failed { onSuccess() }
    }
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

    /// Installs completion callbacks rather than a waiting task. A timed-out
    /// sheet owns at most two operations, so cancellation-ignoring work retains
    /// a bounded callback and can repair the exact router settlement when every
    /// operation eventually completes successfully.
    static func recoverAfterLateSuccess(
        _ work: [FeedbackReportOwnedWork],
        onSuccess: @escaping @MainActor () -> Void
    ) -> FeedbackReportLateSettlementRecovery {
        guard !work.isEmpty, work.count <= maximumOwnedTasks else { return .unrecoverable }
        let terminal = work.compactMap(\.terminalResult)
        guard terminal.allSatisfy({ $0 == .succeeded }) else { return .unrecoverable }
        let pending = work.filter { !$0.isTerminal }
        guard !pending.isEmpty else { return .alreadySucceeded }
        guard pending.allSatisfy({ $0.lateSettlementObserverCount == 0 }) else {
            return .unrecoverable
        }
        let barrier = FeedbackReportLateSettlementBarrier(
            remaining: pending.count,
            onSuccess: onSuccess
        )
        for item in pending {
            guard item.observeCompletion({ barrier.record($0) }) else {
                return .unrecoverable
            }
        }
        return .observing
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
