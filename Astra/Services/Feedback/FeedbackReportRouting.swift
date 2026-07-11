import Combine
import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
import ASTRACore

enum FeedbackReportEntryPoint: String, CaseIterable, Equatable, Sendable {
    case help
    case logs
    case taskFailure = "task_failure"
    case crashRecovery = "crash_recovery"
}

struct FeedbackReportPrefill: Equatable, Sendable {
    var intendedOutcome: String
    var actualResult: String
    var expectedResult: String
    var workBlocked: Bool

    static let empty = FeedbackReportPrefill(
        intendedOutcome: "",
        actualResult: "",
        expectedResult: "",
        workBlocked: false
    )
}

struct FeedbackReportLaunch: Identifiable, Equatable, Sendable {
    let id: UUID
    var hostID: UUID
    var entryPoint: FeedbackReportEntryPoint
    var prefill: FeedbackReportPrefill
    var taskID: UUID?
    var runID: UUID?
    var taskFailureOccurredAt: Date?
    var runtimeEvidence: RuntimeFeedbackPersistedEvidence?
    var crashReports: [CrashReportSummary]
    var crashFingerprint: String?

    var contextIdentity: FeedbackReportContextIdentity {
        if let taskID {
            return .task(taskID: taskID, runID: runID)
        }
        if let crashFingerprint {
            return .crashRecovery(crashFingerprint)
        }
        return .general
    }

    init(
        reportID: UUID = UUID(),
        hostID: UUID,
        entryPoint: FeedbackReportEntryPoint,
        prefill: FeedbackReportPrefill = .empty,
        taskID: UUID? = nil,
        runID: UUID? = nil,
        taskFailureOccurredAt: Date? = nil,
        runtimeEvidence: RuntimeFeedbackPersistedEvidence? = nil,
        crashReports: [CrashReportSummary] = [],
        crashFingerprint: String? = nil
    ) {
        self.id = reportID
        self.hostID = hostID
        self.entryPoint = entryPoint
        self.prefill = prefill
        self.taskID = taskID
        self.runID = runID
        self.taskFailureOccurredAt = taskFailureOccurredAt
        self.runtimeEvidence = runtimeEvidence
        self.crashReports = crashReports
        self.crashFingerprint = crashFingerprint
    }
}

enum FeedbackReportContextIdentity: Equatable, Hashable, Sendable {
    case general
    case task(taskID: UUID, runID: UUID?)
    case crashRecovery(String)
}

enum FeedbackReportResumeError: Error, Equatable {
    case reportNotFound
    case reportIsNotDraft
    case contextMismatch
}

enum FeedbackReportCoordinatorError: Error, Equatable {
    case activeReportConflict
    case alreadyPresented
    case hostUnavailable
    case hostSettlementFailed
    case hostSettlementWaiterLimitReached
    case invalidEntryPointContext
    case crashOfferNotVerified
}

/// Resolves a preserved draft from SwiftData after relaunch. No report ID is
/// accepted until its durable status and task/run context match the launch.
@MainActor
struct FeedbackReportResumeService {
    let modelContainer: ModelContainer
    let storageRoot: URL
    let crashLedger: any FeedbackCrashOfferLedgerReading

    init(
        modelContainer: ModelContainer,
        storageRoot: URL = FeedbackReportStoragePaths.root
    ) {
        self.init(
            modelContainer: modelContainer,
            storageRoot: storageRoot,
            crashLedger: FeedbackCrashOfferService()
        )
    }

    init(
        modelContainer: ModelContainer,
        storageRoot: URL,
        crashLedger: any FeedbackCrashOfferLedgerReading
    ) {
        self.modelContainer = modelContainer
        self.storageRoot = storageRoot
        self.crashLedger = crashLedger
    }

    func resolve(
        reportID: UUID,
        for proposed: FeedbackReportLaunch
    ) throws -> FeedbackReportLaunch {
        let snapshot: FeedbackDraftSnapshot
        do { snapshot = try outbox().recoverableSnapshot(reportID: reportID) }
        catch FeedbackOutboxError.reportNotFound { throw FeedbackReportResumeError.reportNotFound }
        catch let FeedbackOutboxError.illegalTransition(from, _) where from != FeedbackLocalStatusV1.draft.rawValue {
            throw FeedbackReportResumeError.reportIsNotDraft
        }
        let progress = snapshot.progress
        guard progress.taskID == proposed.taskID?.uuidString.lowercased(),
              progress.runID == proposed.runID?.uuidString.lowercased()
        else { throw FeedbackReportResumeError.contextMismatch }
        if proposed.entryPoint == .crashRecovery {
            guard let fingerprint = proposed.crashFingerprint,
                  let link = try crashLedger.verifiedLink(
                      fingerprint: fingerprint,
                      consentVersion: FeedbackReportFormState.consentVersion
                  ), link.reportID == reportID, link.outcome == .reportCreated
            else { throw FeedbackReportResumeError.contextMismatch }
        }
        return resumedLaunch(reportID: reportID, proposed: proposed, progress: progress)
    }

    func latest(for proposed: FeedbackReportLaunch) throws -> FeedbackReportLaunch? {
        guard proposed.entryPoint != .crashRecovery else { return nil }
        guard let snapshot = try outbox().latestRecoverable(
            taskID: proposed.taskID?.uuidString.lowercased(),
            runID: proposed.runID?.uuidString.lowercased()
        ) else { return nil }
        return resumedLaunch(reportID: snapshot.reportID, proposed: proposed, progress: snapshot.progress)
    }

    private func resumedLaunch(
        reportID: UUID,
        proposed: FeedbackReportLaunch,
        progress: FeedbackDraftProgress
    ) -> FeedbackReportLaunch {
        return FeedbackReportLaunch(
            reportID: reportID,
            hostID: proposed.hostID,
            entryPoint: proposed.entryPoint,
            prefill: FeedbackReportPrefill(
                intendedOutcome: progress.intendedOutcome,
                actualResult: progress.actualResult,
                expectedResult: progress.expectedResult,
                workBlocked: progress.workBlocked
            ),
            taskID: proposed.taskID,
            runID: proposed.runID,
            taskFailureOccurredAt: proposed.taskFailureOccurredAt,
            runtimeEvidence: proposed.runtimeEvidence,
            crashReports: proposed.crashReports,
            crashFingerprint: proposed.crashFingerprint
        )
    }

    private func outbox() throws -> FeedbackOutboxService {
        try FeedbackOutboxService(modelContainer: modelContainer, storageRoot: storageRoot)
    }
}

/// Resolves durable identity before presenting any entry point. The router owns
/// only the active sheet; SwiftData and the crash ledger own relaunch recovery.
@MainActor
struct FeedbackReportCoordinator {
    let router: FeedbackReportRouter
    let modelContainer: ModelContainer
    let storageRoot: URL
    let crashLedger: any FeedbackCrashOfferLedgerReading
    let cleanupOwner: FeedbackPreparedPreviewCleanupOwner

    init(
        router: FeedbackReportRouter,
        modelContainer: ModelContainer,
        storageRoot: URL = FeedbackReportStoragePaths.root,
        cleanupOwner: FeedbackPreparedPreviewCleanupOwner? = nil
    ) {
        self.init(
            router: router,
            modelContainer: modelContainer,
            crashLedger: FeedbackCrashOfferService(),
            storageRoot: storageRoot,
            cleanupOwner: cleanupOwner
        )
    }

    init(
        router: FeedbackReportRouter,
        modelContainer: ModelContainer,
        crashLedger: any FeedbackCrashOfferLedgerReading,
        storageRoot: URL = FeedbackReportStoragePaths.root,
        cleanupOwner: FeedbackPreparedPreviewCleanupOwner? = nil
    ) {
        self.router = router
        self.modelContainer = modelContainer
        self.storageRoot = storageRoot
        self.crashLedger = crashLedger
        self.cleanupOwner = cleanupOwner ?? .shared
    }

    func present(
        from entryPoint: FeedbackReportEntryPoint,
        hostID: UUID,
        prefill: FeedbackReportPrefill = .empty,
        taskID: UUID? = nil,
        runID: UUID? = nil,
        taskFailureOccurredAt: Date? = nil,
        runtimeEvidence: RuntimeFeedbackPersistedEvidence? = nil,
        crashOffer: FeedbackCrashOffer? = nil
    ) async throws {
        try validate(
            entryPoint: entryPoint,
            taskID: taskID,
            runID: runID,
            crashOffer: crashOffer
        )
        guard let hostLeaseID = router.hostLeaseID(for: hostID) else {
            throw FeedbackReportCoordinatorError.hostUnavailable
        }
        do {
            _ = try cleanupOwner.retryPendingCleanup(
                willClean: { key in
                    try router.validateFailedHostSettlement(forCleanup: key)
                },
                didClean: { key in
                    try router.resolveFailedHostSettlement(afterCleanup: key)
                }
            )
        } catch {
            // One bounded attempt is made for each explicit report action.
            // Failure retains the first cleanup authority and the failed
            // settlement, so another action can safely retry later.
            throw FeedbackReportCoordinatorError.hostSettlementFailed
        }
        try await router.waitForHostSettlement()
        guard router.hostLeaseID(for: hostID) == hostLeaseID else {
            throw FeedbackReportCoordinatorError.hostUnavailable
        }
        let explicitReportID = crashOffer?.reportID
        let incomingIdentity: FeedbackReportContextIdentity = if let taskID {
            .task(taskID: taskID, runID: runID)
        } else if let crashOffer {
            .crashRecovery(crashOffer.fingerprint)
        } else {
            .general
        }
        if let active = router.launch {
            guard active.contextIdentity == incomingIdentity,
                  explicitReportID == nil || explicitReportID == active.id
            else { throw FeedbackReportCoordinatorError.activeReportConflict }
            guard active.hostID == hostID else {
                throw FeedbackReportCoordinatorError.alreadyPresented
            }
            return
        }
        if try router.reactivatePendingLaunch(
            matching: incomingIdentity,
            explicitReportID: explicitReportID,
            hostID: hostID,
            hostLeaseID: hostLeaseID
        ) {
            return
        }
        let proposed = FeedbackReportLaunch(
            reportID: crashOffer?.reportID ?? UUID(),
            hostID: hostID,
            entryPoint: entryPoint,
            prefill: prefill,
            taskID: taskID,
            runID: runID,
            taskFailureOccurredAt: taskFailureOccurredAt,
            runtimeEvidence: runtimeEvidence,
            crashReports: crashOffer.map { [$0.report] } ?? [],
            crashFingerprint: crashOffer?.fingerprint
        )
        let resolver = FeedbackReportResumeService(
            modelContainer: modelContainer,
            storageRoot: storageRoot,
            crashLedger: crashLedger
        )
        if let crashOffer {
            guard try await crashLedger.validateOffer(crashOffer) else {
                throw FeedbackReportCoordinatorError.crashOfferNotVerified
            }
            guard let link = try crashLedger.verifiedLink(
                fingerprint: crashOffer.fingerprint,
                consentVersion: crashOffer.consentVersion
            ), link.reportID == crashOffer.reportID,
                  link.outcome == .offered || link.outcome == .reportCreated
            else { throw FeedbackReportCoordinatorError.crashOfferNotVerified }
            if link.outcome == .reportCreated {
                let resumed = try resolver.resolve(reportID: link.reportID, for: proposed)
                try router.activate(resumed, hostLeaseID: hostLeaseID)
            } else {
                let crashOutbox = try FeedbackOutboxService(
                    modelContainer: modelContainer,
                    storageRoot: storageRoot
                )
                let hasRecoverableReport: Bool
                do {
                    _ = try crashOutbox.recoverableSnapshot(reportID: link.reportID)
                    hasRecoverableReport = true
                } catch FeedbackOutboxError.reportNotFound {
                    hasRecoverableReport = false
                }
                if hasRecoverableReport {
                    _ = try crashLedger.reconcileOfferedReport(
                        fingerprint: crashOffer.fingerprint,
                        consentVersion: crashOffer.consentVersion,
                        reportID: crashOffer.reportID
                    )
                    let resumed = try resolver.resolve(reportID: link.reportID, for: proposed)
                    try router.activate(resumed, hostLeaseID: hostLeaseID)
                } else {
                    try router.activate(proposed, hostLeaseID: hostLeaseID)
                }
            }
        } else if let resumed = try resolver.latest(for: proposed) {
            try router.activate(resumed, hostLeaseID: hostLeaseID)
        } else {
            try router.activate(proposed, hostLeaseID: hostLeaseID)
        }
    }

    private func validate(
        entryPoint: FeedbackReportEntryPoint,
        taskID: UUID?,
        runID: UUID?,
        crashOffer: FeedbackCrashOffer?
    ) throws {
        switch entryPoint {
        case .taskFailure:
            guard taskID != nil, crashOffer == nil else {
                throw FeedbackReportCoordinatorError.invalidEntryPointContext
            }
        case .crashRecovery:
            guard crashOffer != nil, taskID == nil, runID == nil else {
                throw FeedbackReportCoordinatorError.invalidEntryPointContext
            }
        case .help:
            guard taskID == nil, runID == nil, crashOffer == nil else {
                throw FeedbackReportCoordinatorError.invalidEntryPointContext
            }
        case .logs:
            guard taskID == nil, runID == nil, crashOffer == nil else {
                throw FeedbackReportCoordinatorError.invalidEntryPointContext
            }
        }
    }
}

@MainActor
final class FeedbackReportRouter: ObservableObject {
    static let maximumHostSettlementWaiters = 8

    private struct PresentationKey: Equatable {
        let hostID: UUID
        let reportID: UUID
        let leaseID: UUID
    }

    private struct HostSettlement {
        let key: PresentationKey
        let launch: FeedbackReportLaunch
        var failed: Bool
    }

    private struct PendingLaunchCapability {
        let sourceKey: PresentationKey
        let launch: FeedbackReportLaunch
    }

    private enum SettlementWaitOutcome {
        case succeeded
        case failed
        case cancelled
        case capacityExceeded
    }

    @Published private(set) var launch: FeedbackReportLaunch?
    private var hostLeases: [UUID: UUID] = [:]
    private var launchLeaseID: UUID?
    private var launchDidMount = false
    private var pendingLaunch: PendingLaunchCapability?
    private var hostSettlement: HostSettlement?
    private var earlySettlement: (key: PresentationKey, succeeded: Bool)?
    private var settlementWaiters: [UUID: CheckedContinuation<SettlementWaitOutcome, Never>] = [:]

    var isSettlingHostDeactivation: Bool { hostSettlement != nil }
    var hasHostSettlementWaiters: Bool { !settlementWaiters.isEmpty }
    var hostSettlementWaiterCount: Int { settlementWaiters.count }

    func register(hostID: UUID, leaseID: UUID) {
        if let previousLease = hostLeases[hostID],
           previousLease != leaseID,
           launch?.hostID == hostID,
           launchLeaseID == previousLease {
            releaseActivePresentation(hostID: hostID, leaseID: previousLease)
        }
        hostLeases[hostID] = leaseID
    }

    func unregister(hostID: UUID, leaseID: UUID) {
        guard hostLeases[hostID] == leaseID else { return }
        hostLeases.removeValue(forKey: hostID)
        releaseActivePresentation(hostID: hostID, leaseID: leaseID)
    }

    func hostLeaseID(for hostID: UUID) -> UUID? {
        hostLeases[hostID]
    }

    func activate(_ incoming: FeedbackReportLaunch, hostLeaseID: UUID) throws {
        if hostLeases[incoming.hostID] != hostLeaseID {
            throw FeedbackReportCoordinatorError.hostUnavailable
        }
        if let active = launch {
            guard active == incoming, launchLeaseID == hostLeaseID else {
                throw FeedbackReportCoordinatorError.activeReportConflict
            }
            return
        }
        guard pendingLaunch == nil, hostSettlement == nil else {
            throw FeedbackReportCoordinatorError.activeReportConflict
        }
        launch = incoming
        launchLeaseID = hostLeaseID
        launchDidMount = false
    }

    /// Transfers an unmounted presentation to a live host without changing the
    /// report identity or its prefill/evidence payload. Once a sheet mounts,
    /// durable draft settlement owns recovery instead of this transient handoff.
    func reactivatePendingLaunch(
        matching contextIdentity: FeedbackReportContextIdentity,
        explicitReportID: UUID?,
        hostID: UUID,
        hostLeaseID: UUID
    ) throws -> Bool {
        guard hostLeases[hostID] == hostLeaseID else {
            throw FeedbackReportCoordinatorError.hostUnavailable
        }
        guard launch == nil else {
            throw FeedbackReportCoordinatorError.activeReportConflict
        }
        guard hostSettlement == nil else {
            throw FeedbackReportCoordinatorError.activeReportConflict
        }
        guard let capability = pendingLaunch else { return false }
        guard capability.sourceKey.reportID == capability.launch.id,
              capability.launch.contextIdentity == contextIdentity,
              explicitReportID == nil || explicitReportID == capability.launch.id
        else { throw FeedbackReportCoordinatorError.activeReportConflict }
        var pending = capability.launch
        pending.hostID = hostID
        pendingLaunch = nil
        launch = pending
        launchLeaseID = hostLeaseID
        launchDidMount = false
        return true
    }

    func markPresentationMounted(hostID: UUID, reportID: UUID, leaseID: UUID) {
        guard hostLeases[hostID] == leaseID,
              launch?.hostID == hostID,
              launch?.id == reportID,
              launchLeaseID == leaseID
        else { return }
        launchDidMount = true
    }

    func waitForHostSettlement() async throws {
        try Task.checkCancellation()
        guard let hostSettlement else { return }
        guard !hostSettlement.failed else {
            throw FeedbackReportCoordinatorError.hostSettlementFailed
        }
        let waiterID = UUID()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SettlementWaitOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if settlementWaiters.count >= Self.maximumHostSettlementWaiters {
                    continuation.resume(returning: .capacityExceeded)
                } else {
                    settlementWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSettlementWaiter(waiterID)
            }
        }
        switch outcome {
        case .succeeded:
            try Task.checkCancellation()
        case .failed:
            throw FeedbackReportCoordinatorError.hostSettlementFailed
        case .capacityExceeded:
            throw FeedbackReportCoordinatorError.hostSettlementWaiterLimitReached
        case .cancelled:
            throw CancellationError()
        }
    }

    func completeHostDeactivation(
        hostID: UUID,
        reportID: UUID,
        leaseID: UUID,
        succeeded: Bool
    ) {
        let key = PresentationKey(hostID: hostID, reportID: reportID, leaseID: leaseID)
        if var settlement = hostSettlement, settlement.key == key {
            settlement.failed = !succeeded
            if succeeded {
                pendingLaunch = PendingLaunchCapability(
                    sourceKey: settlement.key,
                    launch: settlement.launch
                )
                hostSettlement = nil
            } else {
                hostSettlement = settlement
            }
            let waiters = Array(settlementWaiters.values)
            settlementWaiters.removeAll()
            let outcome: SettlementWaitOutcome = succeeded ? .succeeded : .failed
            waiters.forEach { $0.resume(returning: outcome) }
            return
        }
        guard launch?.hostID == hostID,
              launch?.id == reportID,
              launchLeaseID == leaseID,
              launchDidMount
        else { return }
        earlySettlement = (key, succeeded)
    }

    func validateFailedHostSettlement(
        forCleanup key: FeedbackPreparedPreviewCleanupKey
    ) throws {
        guard let settlement = hostSettlement,
              settlement.failed,
              settlement.key.hostID == key.sourceHostID,
              settlement.key.reportID == key.reportID,
              settlement.key.leaseID == key.sourceLeaseID,
              settlement.launch.contextIdentity == key.contextIdentity
        else { throw FeedbackReportCoordinatorError.hostSettlementFailed }
    }

    func resolveFailedHostSettlement(afterCleanup key: FeedbackPreparedPreviewCleanupKey) throws {
        try validateFailedHostSettlement(forCleanup: key)
        completeHostDeactivation(
            hostID: key.sourceHostID,
            reportID: key.reportID,
            leaseID: key.sourceLeaseID,
            succeeded: true
        )
    }

    func dismiss(hostID: UUID, reportID: UUID, leaseID: UUID) {
        guard hostLeases[hostID] == leaseID,
              launch?.hostID == hostID,
              launch?.id == reportID,
              launchLeaseID == leaseID
        else { return }
        if let earlySettlement,
           earlySettlement.key == PresentationKey(hostID: hostID, reportID: reportID, leaseID: leaseID),
           earlySettlement.succeeded {
            if let launch {
                pendingLaunch = PendingLaunchCapability(
                    sourceKey: earlySettlement.key,
                    launch: launch
                )
            }
        }
        launch = nil
        launchLeaseID = nil
        launchDidMount = false
        earlySettlement = nil
    }

    func launch(for hostID: UUID, leaseID: UUID) -> FeedbackReportLaunch? {
        guard hostLeases[hostID] == leaseID,
              launch?.hostID == hostID,
              launchLeaseID == leaseID
        else { return nil }
        return launch
    }

    private func releaseActivePresentation(hostID: UUID, leaseID: UUID) {
        guard let active = launch,
              active.hostID == hostID,
              launchLeaseID == leaseID
        else { return }
        if launchDidMount {
            let key = PresentationKey(hostID: hostID, reportID: active.id, leaseID: leaseID)
            if let earlySettlement, earlySettlement.key == key {
                if earlySettlement.succeeded {
                    pendingLaunch = PendingLaunchCapability(
                        sourceKey: key,
                        launch: active
                    )
                } else {
                    hostSettlement = HostSettlement(key: key, launch: active, failed: true)
                }
                self.earlySettlement = nil
            } else {
                hostSettlement = HostSettlement(key: key, launch: active, failed: false)
            }
        } else {
            pendingLaunch = PendingLaunchCapability(
                sourceKey: PresentationKey(hostID: hostID, reportID: active.id, leaseID: leaseID),
                launch: active
            )
        }
        launch = nil
        launchLeaseID = nil
        launchDidMount = false
    }

    private func cancelSettlementWaiter(_ waiterID: UUID) {
        settlementWaiters.removeValue(forKey: waiterID)?.resume(returning: .cancelled)
    }
}

enum FeedbackTaskRuntimeEvidenceMapper {
    private struct Classification: Sendable {
        let category: String
        let actualResult: String
        let expectedResult: String
    }

    static func evidence(
        runtimeID: String?,
        providerVersion: String?,
        status: RunStatus,
        exitCode: Int?,
        stopReason: String,
        failureSummary: String
    ) -> RuntimeFeedbackPersistedEvidence? {
        guard let runtimeID, !runtimeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let classification = classification(status: status, stopReason: stopReason)
        let normalizedReason = stopReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return RuntimeFeedbackPersistedEvidence(
            runtimeID: runtimeID,
            providerVersion: providerVersion,
            executableFound: isRuntimeExecutableMissing(normalizedReason) ? false : nil,
            readiness: normalizedReason == "runtime_readiness_failed" ? "blocked" : nil,
            failureCategory: classification.category,
            sanitizedSummary: failureSummary,
            exitCode: exitCode,
            stopReason: stopReason.isEmpty ? nil : stopReason,
            policyState: classification.category == "astra_policy_blocked" ? "blocked" : nil
        )
    }

    fileprivate static func reportClassification(
        status: RunStatus,
        stopReason: String
    ) -> (category: String, actualResult: String, expectedResult: String) {
        let value = classification(status: status, stopReason: stopReason)
        return (value.category, value.actualResult, value.expectedResult)
    }

    private static func isRuntimeExecutableMissing(_ reason: String) -> Bool {
        [
            TaskRunStopReason.dockerProviderExecutableMissing.rawValue,
            "missing_claude", "missing_copilot", "missing_antigravity", "missing_codex",
            "missing_cursor", "missing_opencode", "missing_executable", "runtime_missing",
        ].contains(reason)
    }

    private static func classification(status: RunStatus, stopReason: String) -> Classification {
        let reason = stopReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if status == .timeout || reason == TaskRunStopReason.timeout.rawValue
            || reason.contains("timed_out") || reason.contains("stalled")
        {
            return Classification(
                category: "runtime_timed_out",
                actualResult: "The provider run timed out before completing.",
                expectedResult: "The provider run completes without timing out"
            )
        }
        if status == .budgetExceeded
            || reason == TaskRunStopReason.maxBudgetReached.rawValue
            || reason == TaskRunStopReason.browserActionBudgetExceeded.rawValue
            || reason.contains("budget_exceeded")
        {
            return Classification(
                category: "budget_exceeded",
                actualResult: "ASTRA stopped the run at its configured budget limit.",
                expectedResult: "The task completes within its configured budget"
            )
        }
        if [
            TaskRunStopReason.policyBlocked.rawValue,
            TaskRunStopReason.policyViolation.rawValue,
            TaskRunStopReason.permissionApprovalRequired.rawValue,
        ].contains(reason) {
            return Classification(
                category: "astra_policy_blocked",
                actualResult: "ASTRA stopped the run because a safety or permission policy blocked it.",
                expectedResult: "ASTRA can safely authorize or explain the required action"
            )
        }
        if [
            TaskRunStopReason.validationContractFailed.rawValue,
            TaskRunStopReason.inferredValidationFailed.rawValue,
        ].contains(reason) {
            return Classification(
                category: "astra_validation_failed",
                actualResult: "ASTRA stopped the run because required validation did not pass.",
                expectedResult: "The task produces evidence that satisfies its validation contract"
            )
        }
        if [
            TaskRunStopReason.deliverableVerificationFailed.rawValue,
            TaskRunStopReason.noUsableResult.rawValue,
        ].contains(reason) {
            return Classification(
                category: "astra_deliverable_verification_failed",
                actualResult: "ASTRA stopped the run because the required deliverable could not be verified.",
                expectedResult: "The task produces a verifiable requested deliverable"
            )
        }
        if reason == TaskRunStopReason.connectorPreflightFailed.rawValue {
            return Classification(
                category: "connector_preflight_failed",
                actualResult: "ASTRA could not prepare a required connector before launch.",
                expectedResult: "ASTRA prepares the required connector before launching the provider"
            )
        }
        if reason == TaskRunStopReason.capabilityRuntimeResourcesMissing.rawValue {
            return Classification(
                category: "capability_resources_missing",
                actualResult: "ASTRA could not find runtime resources required by the selected capability.",
                expectedResult: "ASTRA resolves every required capability resource before launch"
            )
        }
        if [
            TaskRunStopReason.dockerDaemonUnavailable.rawValue,
            TaskRunStopReason.dockerImageUnavailable.rawValue,
            TaskRunStopReason.dockerContextUnapproved.rawValue,
            TaskRunStopReason.dockerMountFailed.rawValue,
            TaskRunStopReason.dockerLaunchFailed.rawValue,
            TaskRunStopReason.isolationFailed.rawValue,
        ].contains(reason) {
            return Classification(
                category: "runtime_environment_unavailable",
                actualResult: "ASTRA could not prepare the configured execution environment.",
                expectedResult: "ASTRA verifies the execution environment before launching the provider"
            )
        }
        if [
            TaskRunStopReason.dockerProviderExecutableMissing.rawValue,
            TaskRunStopReason.workspaceNotFound.rawValue,
            "missing_claude", "missing_copilot", "missing_antigravity", "missing_codex",
            "missing_cursor", "missing_opencode", "missing_executable", "runtime_missing",
            "mcp_server_executable_missing",
        ].contains(reason) {
            return Classification(
                category: "missing",
                actualResult: "ASTRA could not find a required runtime executable or workspace.",
                expectedResult: "ASTRA verifies required runtime files before launch"
            )
        }
        if [
            TaskRunStopReason.credentialProjectionRequired.rawValue,
            "authentication_failed", "auth_required", "unauthenticated",
        ].contains(reason) {
            return Classification(
                category: "unauthenticated",
                actualResult: "The run could not authenticate with the selected provider or connector.",
                expectedResult: "ASTRA verifies usable authentication before launch"
            )
        }
        if reason == "rate_limited" {
            return Classification(
                category: "rate_limited",
                actualResult: "The provider rate-limited the run.",
                expectedResult: "ASTRA handles provider rate limits without losing task progress"
            )
        }
        if ["quota_exceeded", "quota_exhausted", "quota_limited"].contains(reason) {
            return Classification(
                category: "quota_limited",
                actualResult: "The provider stopped the run because its quota was unavailable.",
                expectedResult: "ASTRA detects provider quota limits before or during launch"
            )
        }
        if [
            "model_unavailable", "provider_configuration_invalid", "malformed_mcp_config",
            "unsupported_output_format", "misconfigured",
        ].contains(reason) {
            return Classification(
                category: "misconfigured",
                actualResult: "The selected runtime or provider configuration was unavailable.",
                expectedResult: "ASTRA validates the selected runtime configuration before launch"
            )
        }
        if [
            TaskRunStopReason.providerPermissionDeniedAfterApproval.rawValue,
            TaskRunStopReason.providerPermissionDeniedBroadPermissions.rawValue,
            TaskRunStopReason.providerPermissionUnresumable.rawValue,
        ].contains(reason) || reason == "permission_denied"
            || reason == "sandbox_credential_access_blocked"
        {
            return Classification(
                category: "permission_denied",
                actualResult: "The provider could not continue with the approved permissions.",
                expectedResult: "The provider continues with only the permissions the user approved"
            )
        }
        if ["network_failed", "no_visible_output"].contains(reason) {
            return Classification(
                category: "provider_process_failed",
                actualResult: reason == "network_failed"
                    ? "The provider run stopped after a network failure."
                    : "The provider exited without returning a visible result.",
                expectedResult: reason == "network_failed"
                    ? "ASTRA preserves progress and explains provider network failures"
                    : "The provider returns a visible result or an actionable failure"
            )
        }
        if reason == "runtime_readiness_failed" {
            return Classification(
                category: "misconfigured",
                actualResult: "ASTRA stopped before launch because runtime readiness was blocked.",
                expectedResult: "ASTRA explains and resolves blocked runtime readiness before launch"
            )
        }
        return Classification(
            category: "provider_process_failed",
            actualResult: "The provider run stopped before completing.",
            expectedResult: "The provider run completes successfully"
        )
    }
}

/// Reads only the allowlisted projection already persisted on a run. It never
/// probes, launches, or asks a provider runtime for diagnostic state.
struct FeedbackTaskRunRuntimeEvidenceReader: RuntimeFeedbackPersistedEvidenceReading {
    let evidence: RuntimeFeedbackPersistedEvidence?

    init(
        runtimeID: String?,
        providerVersion: String?,
        status: RunStatus,
        exitCode: Int?,
        stopReason: String,
        failureSummary: String
    ) {
        evidence = FeedbackTaskRuntimeEvidenceMapper.evidence(
            runtimeID: runtimeID,
            providerVersion: providerVersion,
            status: status,
            exitCode: exitCode,
            stopReason: stopReason,
            failureSummary: failureSummary
        )
    }

    func readPersistedRuntimeEvidence() throws -> RuntimeFeedbackPersistedEvidence? {
        evidence
    }
}

struct FeedbackTaskFailureReportContext: Equatable, Sendable {
    let prefill: FeedbackReportPrefill
    let runtimeEvidence: RuntimeFeedbackPersistedEvidence?
    let taskFailureOccurredAt: Date?
}

enum FeedbackTaskFailureReportContextBuilder {
    static func make(
        runtimeID: String?,
        providerVersion: String?,
        status: RunStatus,
        exitCode: Int?,
        stopReason: String,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> FeedbackTaskFailureReportContext {
        let classification = FeedbackTaskRuntimeEvidenceMapper.reportClassification(
            status: status,
            stopReason: stopReason
        )
        let safeSummary = classification.actualResult
        let reader = FeedbackTaskRunRuntimeEvidenceReader(
            runtimeID: runtimeID,
            providerVersion: providerVersion,
            status: status,
            exitCode: exitCode,
            stopReason: stopReason,
            failureSummary: safeSummary
        )
        return FeedbackTaskFailureReportContext(
            prefill: FeedbackReportPrefill(
                intendedOutcome: "Complete the task",
                actualResult: safeSummary,
                expectedResult: classification.expectedResult,
                workBlocked: true
            ),
            runtimeEvidence: reader.evidence,
            taskFailureOccurredAt: completedAt ?? startedAt
        )
    }
}
