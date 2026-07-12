import Foundation
import Dispatch
import SwiftData
import Testing
import ASTRACore
import ASTRALogging
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

extension FeedbackReportPresentationTests {
    @Test("General reports default to a fifteen-minute window without unbound task logs")
    func formDefaults() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let form = FeedbackReportFormState(
            launch: FeedbackReportLaunch(hostID: UUID(), entryPoint: .help),
            now: now
        )
        #expect(form.evidenceWindowEnd == now)
        #expect(form.evidenceWindowStart == now.addingTimeInterval(-15 * 60))
        #expect(form.selections.includeApplicationLogs)
        #expect(!form.selections.includeTaskLogs)
        #expect(!form.selections.includeBrowserEvidence)
        #expect(!form.selections.includeScreenshots)
        #expect(!form.selections.includeMacOSDiagnostics)
    }

    @Test("Task-bound reports default to their exact task logs")
    func taskReportsDefaultToExactTaskLogs() {
        let form = FeedbackReportFormState(
            launch: FeedbackReportLaunch(
                hostID: UUID(), entryPoint: .taskFailure, taskID: UUID()
            )
        )
        #expect(form.selections.includeTaskLogs)
    }

    @Test("Unbound task-log selections fail instead of silently disclosing nothing")
    func unboundTaskLogsFailClosed() {
        #expect(throws: FeedbackReportEvidenceSourceReader.SourceError.unavailable(.taskLogs)) {
            _ = try FeedbackReportEvidenceSourceReader.collect(
                launch: FeedbackReportLaunch(hostID: UUID(), entryPoint: .logs),
                selections: FeedbackEvidenceSelections(),
                interval: DateInterval(start: .distantPast, end: .distantFuture),
                entriesProvider: { [] },
                browserProvider: { _, _, _, _ in (records: [], screenshots: []) },
                crashProvider: { _, _ in [] }
            )
        }
    }

    @Test("Feedback evidence reads retained app and exact task log files")
    func retainedLogsRemainAvailableForFeedback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-retained-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let taskID = try #require(UUID(uuidString: "0c48773f-1111-4111-8111-111111111111"))
        let appURL = directory.appendingPathComponent("astra.log")
        let taskURL = directory.appendingPathComponent("task-0C48773F.log")
        try "[13:20:00.000] [INFO] [App] retained-app-entry\n"
            .write(to: appURL, atomically: true, encoding: .utf8)
        try "[13:20:01.000] [WARNING] [Worker task:0C48773F] retained-task-entry\n"
            .write(to: taskURL, atomically: true, encoding: .utf8)
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: anchor], ofItemAtPath: appURL.path)
        try FileManager.default.setAttributes([.modificationDate: anchor], ofItemAtPath: taskURL.path)
        let retained = FeedbackReportEvidenceSourceReader.retainedLogEntries(
            inMemoryEntries: [LogEntry(
                level: .info, category: "App", message: "current-ring-entry", timestamp: anchor
            )],
            logDirectory: directory
        )
        let source = try FeedbackReportEvidenceSourceReader.collect(
            launch: FeedbackReportLaunch(
                hostID: UUID(), entryPoint: .taskFailure, taskID: taskID
            ),
            selections: FeedbackEvidenceSelections(),
            interval: DateInterval(start: .distantPast, end: .distantFuture),
            entriesProvider: { retained },
            browserProvider: { _, _, _, _ in (records: [], screenshots: []) },
            crashProvider: { _, _ in [] }
        )
        #expect(source.applicationLogEntries.contains { $0.message == "retained-app-entry" })
        #expect(source.taskLogEntries.contains { $0.message.contains("retained-task-entry") })
    }

    @Test("Prefilled unsaved reports offer Keep or Discard even before an edit")
    func prefilledUnsavedCloseOffersDraftChoices() {
        #expect(FeedbackReportClosePolicy.action(
            hasStoredReport: false,
            storedStatus: nil,
            hasMeaningfulProgress: true,
            isPreparing: false,
            hasPreview: false,
            isInvalidatingPreview: false
        ) == .offerDraftChoices)
    }

    @Test("Evidence window labels distinguish current and historical intervals")
    func evidenceWindowLabelsAreAccurate() {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let start = end.addingTimeInterval(-15 * 60)
        #expect(FeedbackEvidenceWindowPresentation.label(
            start: start, end: end, now: end
        ) == "the last 15 minutes")

        let historical = FeedbackEvidenceWindowPresentation.label(
            start: start,
            end: end,
            now: end.addingTimeInterval(60 * 60),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        #expect(historical.contains("Nov 14, 2023"))
        let normalizedHistorical = historical.replacingOccurrences(of: "\u{202f}", with: " ")
        #expect(normalizedHistorical.contains("9:58 PM"))
        #expect(normalizedHistorical.contains("10:13 PM"))
        #expect(!historical.contains("last"))
    }

    @Test("Manual reporting can resume a saved crash-linked draft")
    @MainActor
    func generalEntryPointRecoversCrashLinkedDraft() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-crash-linked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeFeedbackOutboxContainer()
        let outbox = try FeedbackOutboxService(modelContainer: container, storageRoot: root)
        let reportID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let progress = FeedbackDraftProgress(
            intendedOutcome: "Recover after the crash",
            actualResult: "ASTRA closed unexpectedly",
            expectedResult: "ASTRA should remain open",
            workBlocked: true,
            evidenceWindow: FeedbackEvidenceWindowV1(
                start: now.addingTimeInterval(-900), end: now
            ),
            consent: FeedbackConsentV1(
                version: FeedbackReportFormState.consentVersion,
                evidenceSelections: []
            )
        )
        _ = try outbox.createDraftProgress(
            reportID: reportID,
            installationID: FeedbackInstallationIDV1(rawValue: "installation-v1"),
            progress: progress
        )
        let proposed = FeedbackReportLaunch(hostID: UUID(), entryPoint: .help)
        let resolver = FeedbackReportResumeService(
            modelContainer: container,
            storageRoot: root,
            crashLedger: LifecycleLinkedCrashLedger(reportIDs: [reportID])
        )

        let resumed = try #require(try resolver.latest(for: proposed))

        #expect(resumed.id == reportID)
        #expect(resumed.entryPoint == .help)
        #expect(resumed.prefill.intendedOutcome == progress.intendedOutcome)
        #expect(resumed.prefill.actualResult == progress.actualResult)
        #expect(resumed.prefill.expectedResult == progress.expectedResult)
    }

    @Test("Unsaved discard closes without creating a durable draft")
    func unsavedDiscardDoesNotPersist() {
        #expect(FeedbackReportDismissPersistencePolicy.action(
            keepingDraft: false, hasStoredReport: false, hasMeaningfulProgress: true
        ) == .closeWithoutPersistence)
        #expect(FeedbackReportDismissPersistencePolicy.action(
            keepingDraft: false, hasStoredReport: true, hasMeaningfulProgress: true
        ) == .discardStoredReport)
        #expect(FeedbackReportDismissPersistencePolicy.action(
            keepingDraft: true, hasStoredReport: false, hasMeaningfulProgress: true
        ) == .saveDraft)
        #expect(FeedbackReportDismissPersistencePolicy.action(
            keepingDraft: true, hasStoredReport: false, hasMeaningfulProgress: false
        ) == .closeWithoutPersistence)
        #expect(!FeedbackReportHostDeactivationPersistencePolicy.shouldPersist(
            explicitDismissalCompleted: true,
            hasStoredReport: false,
            hasMeaningfulProgress: true
        ))
        #expect(!FeedbackReportHostDeactivationPersistencePolicy.shouldPersist(
            explicitDismissalCompleted: true,
            hasStoredReport: true,
            hasMeaningfulProgress: true
        ))
        #expect(FeedbackReportHostDeactivationPersistencePolicy.shouldPersist(
            explicitDismissalCompleted: false,
            hasStoredReport: false,
            hasMeaningfulProgress: true
        ))
    }

    @Test("Delayed task-failure reports anchor evidence to the failed run")
    func delayedTaskFailureAnchorsEvidenceWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failureDate = now.addingTimeInterval(-3 * 60 * 60)
        let launch = FeedbackReportLaunch(
            hostID: UUID(),
            entryPoint: .taskFailure,
            taskID: UUID(),
            runID: UUID(),
            taskFailureOccurredAt: failureDate
        )

        let form = FeedbackReportFormState(launch: launch, now: now)

        #expect(form.evidenceWindowEnd == failureDate)
        #expect(form.evidenceWindowStart == failureDate.addingTimeInterval(
            -FeedbackReportFormState.defaultEvidenceWindow
        ))
        #expect(form.evidenceWindowEnd < now.addingTimeInterval(
            -FeedbackReportFormState.defaultEvidenceWindow
        ))
    }

    @Test("Task failure routing retains the failed-run evidence anchor")
    @MainActor
    func taskFailureRoutingRetainsEvidenceAnchor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-task-anchor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = FeedbackReportRouter()
        let hostID = UUID()
        router.register(hostID: hostID, leaseID: UUID())
        let failureDate = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = FeedbackReportCoordinator(
            router: router,
            modelContainer: try makeFeedbackOutboxContainer(),
            crashLedger: LifecycleLinkedCrashLedger(reportIDs: []),
            storageRoot: root
        )

        try await coordinator.present(
            from: .taskFailure,
            hostID: hostID,
            taskID: UUID(),
            runID: UUID(),
            taskFailureOccurredAt: failureDate
        )

        #expect(router.launch?.taskFailureOccurredAt == failureDate)
    }

    @Test("Adopted outbox previews bypass live staging cleanup")
    @MainActor
    func adoptedPreviewIsNotInvalidatedOnClose() throws {
        let reportID = UUID()
        let launch = FeedbackReportLaunch(reportID: reportID, hostID: UUID(), entryPoint: .help)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("owned-feedback-\(reportID.uuidString)", isDirectory: true)
        let manifest = FeedbackEvidenceManifestV1(
            artifacts: [], redactionPolicyVersion: "feedback-redaction-v1",
            totalByteCount: 0, archiveSHA256: nil
        )
        let package = FeedbackPreparedEvidencePackage(
            reportID: reportID, reportCreatedAt: Date(), directoryURL: directory,
            reportURL: directory.appendingPathComponent("feedback-report.json"),
            archiveURL: directory.appendingPathComponent("evidence.zip"),
            manifestURL: directory.appendingPathComponent("manifest.json"),
            manifest: manifest, manifestSHA256: String(repeating: "a", count: 64),
            reportSHA256: String(repeating: "b", count: 64),
            archiveSHA256: String(repeating: "c", count: 64)
        )
        let preview = FeedbackReportPreparedPreview(
            reportID: reportID, contextIdentity: launch.contextIdentity,
            form: FeedbackReportFormState(launch: launch), reviewedAt: Date(),
            package: package, ownership: .adoptedOutbox
        )
        var fallbackCleanupCalled = false

        let cleanupKey = try FeedbackReportLiveCleanupFinalizer.invalidateIfOwned(
            preview, sourceHostID: launch.hostID, sourceLeaseID: UUID(),
            cleanupOwner: FeedbackPreparedPreviewCleanupOwner()
        ) { fallbackCleanupCalled = true }

        #expect(cleanupKey == nil)
        #expect(!fallbackCleanupCalled)
    }

    @Test("Preview cleanup reopens nested read-only artifact directories")
    @MainActor
    func previewCleanupReopensArtifactDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-read-only-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportID = UUID()
        let packageDirectory = FeedbackReportStoragePaths.preparationRoot(storageRoot: root)
            .appendingPathComponent("feedback-\(reportID.uuidString.lowercased())", isDirectory: true)
        let logsDirectory = packageDirectory.appendingPathComponent("logs", isDirectory: true)
        let artifactURL = logsDirectory.appendingPathComponent("application-log.jsonl")
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try Data("sanitized log".utf8).write(to: artifactURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: artifactURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: logsDirectory.path)
        let launch = FeedbackReportLaunch(reportID: reportID, hostID: UUID(), entryPoint: .help)
        let manifest = FeedbackEvidenceManifestV1(
            artifacts: [], redactionPolicyVersion: "feedback-redaction-v1", totalByteCount: 0
        )
        let preview = FeedbackReportPreparedPreview(
            reportID: reportID,
            contextIdentity: launch.contextIdentity,
            form: FeedbackReportFormState(launch: launch),
            reviewedAt: Date(),
            package: FeedbackPreparedEvidencePackage(
                reportID: reportID,
                reportCreatedAt: Date(),
                directoryURL: packageDirectory,
                reportURL: packageDirectory.appendingPathComponent("feedback-report.json"),
                archiveURL: packageDirectory.appendingPathComponent("evidence.zip"),
                manifestURL: packageDirectory.appendingPathComponent("manifest.json"),
                manifest: manifest,
                manifestSHA256: String(repeating: "a", count: 64),
                reportSHA256: String(repeating: "b", count: 64),
                archiveSHA256: String(repeating: "c", count: 64)
            ),
            ownership: .trustedStaging
        )
        let service = FeedbackReportPreparationService(
            modelContainer: try makeFeedbackOutboxContainer(),
            crashOfferService: FeedbackCrashOfferService(),
            storageRoot: root
        )

        try service.invalidatePreparedPreview(preview)

        #expect(!FileManager.default.fileExists(atPath: packageDirectory.path))
    }

    @Test("Old crash offers anchor the evidence window to the crash")
    func oldCrashOfferAnchorsEvidenceWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let crashDate = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let crash = CrashReportSummary(
            url: URL(fileURLWithPath: "/tmp/old-feedback.crash"),
            appName: "ASTRA Dev",
            modifiedAt: crashDate,
            sizeBytes: 42
        )
        let crashLaunch = FeedbackReportLaunch(
            hostID: UUID(),
            entryPoint: .crashRecovery,
            crashReports: [crash]
        )

        let form = FeedbackReportFormState(launch: crashLaunch, now: now)

        #expect(form.evidenceWindowStart <= crashDate)
        #expect(form.evidenceWindowEnd >= crashDate)
        #expect(
            form.evidenceWindowEnd.timeIntervalSince(form.evidenceWindowStart) <=
            FeedbackContractLimitsV1.maximumEvidenceWindow
        )
        #expect(form.evidenceWindowEnd < now)
    }

    @Test("Early successful settlement preserves payload across host teardown")
    @MainActor
    func earlySuccessBeforeUnregisterPreservesLaunch() throws {
        let router = FeedbackReportRouter()
        let firstHost = UUID(), firstLease = UUID()
        let original = lifecycleLaunch(hostID: firstHost)
        try mountLifecycleLaunch(original, on: router, hostID: firstHost, leaseID: firstLease)
        router.completeHostDeactivation(
            hostID: firstHost, reportID: original.id, leaseID: firstLease, succeeded: true
        )
        router.unregister(hostID: firstHost, leaseID: firstLease)
        let nextHost = UUID(), nextLease = UUID()
        router.register(hostID: nextHost, leaseID: nextLease)
        #expect(try router.reactivatePendingLaunch(
            matching: original.contextIdentity, explicitReportID: original.id,
            hostID: nextHost, hostLeaseID: nextLease
        ))
        expectLifecyclePayload(router.launch, equals: original, hostID: nextHost)
    }

    @Test("Early successful settlement preserves payload across same-host lease replacement")
    @MainActor
    func earlySuccessBeforeLeaseReplacementPreservesLaunch() throws {
        let router = FeedbackReportRouter()
        let hostID = UUID(), firstLease = UUID(), replacementLease = UUID()
        let original = lifecycleLaunch(hostID: hostID)
        try mountLifecycleLaunch(original, on: router, hostID: hostID, leaseID: firstLease)
        router.completeHostDeactivation(
            hostID: hostID, reportID: original.id, leaseID: firstLease, succeeded: true
        )
        router.register(hostID: hostID, leaseID: replacementLease)
        #expect(try router.reactivatePendingLaunch(
            matching: original.contextIdentity, explicitReportID: original.id,
            hostID: hostID, hostLeaseID: replacementLease
        ))
        expectLifecyclePayload(router.launch, equals: original, hostID: hostID)
    }

    @Test("Owned work timeouts leave no monitor waiters while the worker stays blocked")
    @MainActor
    func ownedWorkSettlementHasNoMonitorSurvivors() async {
        let blocker = LifecycleAsyncBlocker()
        let work = FeedbackReportOwnedWork.start { await blocker.wait() }
        for _ in 0..<5 {
            #expect(!(await FeedbackReportTaskSettlement.wait(
                for: [work], timeout: .milliseconds(10)
            )))
            #expect(work.settlementWaiterCount == 0)
        }
        let join = Task { @MainActor in
            await FeedbackReportTaskSettlement.wait(for: [work], timeout: .seconds(10))
        }
        join.cancel()
        #expect(!(await join.value))
        #expect(work.settlementWaiterCount == 0)
        await blocker.release()
        #expect(await FeedbackReportTaskSettlement.wait(for: [work], timeout: .seconds(1)))
    }

    @Test("Late successful cleanup repairs the exact failed host settlement")
    @MainActor
    func lateSuccessRepairsHostSettlementWithoutMonitorTask() async throws {
        let blocker = LifecycleAsyncBlocker()
        let work = FeedbackReportOwnedWork.start { await blocker.wait() }
        let router = FeedbackReportRouter()
        let hostID = UUID(), leaseID = UUID()
        let launch = lifecycleLaunch(hostID: hostID)
        try mountLifecycleLaunch(launch, on: router, hostID: hostID, leaseID: leaseID)
        router.unregister(hostID: hostID, leaseID: leaseID)
        let settled = await FeedbackReportTaskSettlement.cancelAndFinalize(
            [work], timeout: .milliseconds(10)
        ) {}
        #expect(!settled)

        var recovered = false
        let recovery = FeedbackReportTaskSettlement.recoverAfterLateSuccess([work]) {
            router.completeHostDeactivation(
                hostID: hostID,
                reportID: launch.id,
                leaseID: leaseID,
                succeeded: true
            )
            recovered = true
        }
        #expect(recovery == .observing)
        #expect(work.lateSettlementObserverCount == 1)
        router.completeHostDeactivation(
            hostID: hostID,
            reportID: launch.id,
            leaseID: leaseID,
            succeeded: false
        )

        await blocker.release()
        for _ in 0..<100 where !recovered { await Task.yield() }
        #expect(recovered)
        #expect(work.lateSettlementObserverCount == 0)
        #expect(!router.isSettlingHostDeactivation)

        let nextHost = UUID(), nextLease = UUID()
        router.register(hostID: nextHost, leaseID: nextLease)
        #expect(try router.reactivatePendingLaunch(
            matching: launch.contextIdentity,
            explicitReportID: launch.id,
            hostID: nextHost,
            hostLeaseID: nextLease
        ))
        expectLifecyclePayload(router.launch, equals: launch, hostID: nextHost)
    }

    @Test("Failed owned cleanup remains fail-closed and finalization removes staging")
    @MainActor
    func failedOwnedWorkDoesNotTransferRouterOwnership() async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-owned-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let work = FeedbackReportOwnedWork.start { throw LifecycleTestError.cleanupFailed }
        let router = FeedbackReportRouter()
        let hostID = UUID(), leaseID = UUID()
        let launch = lifecycleLaunch(hostID: hostID)
        try mountLifecycleLaunch(launch, on: router, hostID: hostID, leaseID: leaseID)
        router.unregister(hostID: hostID, leaseID: leaseID)
        let settled = await FeedbackReportTaskSettlement.cancelAndFinalize(
            [work],
            isResolvedRetainedCleanup: { _ in true }
        ) {
            try FileManager.default.removeItem(at: staging)
        }
        #expect(!settled)
        router.completeHostDeactivation(
            hostID: hostID, reportID: launch.id, leaseID: leaseID, succeeded: settled
        )
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(router.isSettlingHostDeactivation)
        let nextHost = UUID(), nextLease = UUID()
        router.register(hostID: nextHost, leaseID: nextLease)
        #expect(throws: FeedbackReportCoordinatorError.activeReportConflict) {
            _ = try router.reactivatePendingLaunch(
                matching: launch.contextIdentity, explicitReportID: launch.id,
                hostID: nextHost, hostLeaseID: nextLease
            )
        }
    }

    @Test("Persistent cleanup failure transfers exact capability to a later owner")
    @MainActor
    func lateCleanupFailureRetainsCapabilityAndLeavesNoOrphan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-cleanup-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "feedback-cleanup-receipt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let launch = FeedbackReportLaunch(
            hostID: UUID(), entryPoint: .taskFailure,
            prefill: FeedbackReportPrefill(
                intendedOutcome: "Finish the provider task",
                actualResult: "The provider stopped",
                expectedResult: "The provider should finish",
                workBlocked: true
            ),
            taskID: UUID(), runID: UUID(),
            runtimeEvidence: RuntimeFeedbackPersistedEvidence(
                runtimeID: "codex", providerVersion: "1.2.3",
                failureCategory: "provider_failed",
                sanitizedSummary: "The persisted provider run stopped.",
                exitCode: 1, stopReason: "provider_failed"
            ),
            crashReports: [CrashReportSummary(
                url: root.appendingPathComponent("retained.crash"), appName: "ASTRA Dev",
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000), sizeBytes: 512
            )]
        )
        let sourceLeaseID = UUID()
        var form = FeedbackReportFormState(launch: launch)
        form.intendedOutcome = "Finish the task"
        form.actualResult = "The provider stopped"
        form.expectedResult = "The task should finish"
        let ready = LifecycleCounter(), release = DispatchSemaphore(value: 0)
        let fileManager = ControlledRemovalFailureFileManager(failureLimit: 3)
        let cleanupOwner = FeedbackPreparedPreviewCleanupOwner()
        let sentinel = root.deletingLastPathComponent()
            .appendingPathComponent("feedback-cleanup-sentinel-\(UUID().uuidString)")
        let sentinelBytes = Data("outside cleanup root".utf8)
        try sentinelBytes.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let container = try makeFeedbackOutboxContainer()
        let crashOfferService = FeedbackCrashOfferService(defaults: defaults)
        let service = FeedbackReportPreparationService(
            modelContainer: container,
            crashOfferService: crashOfferService,
            storageRoot: root,
            defaults: defaults,
            evidenceSourceProvider: { _, _, _ in .empty },
            packageBuilder: { input, selections, directory in
                let package = try FeedbackEvidenceBuilder().prepare(
                    input: input, selections: selections, directory: directory
                )
                ready.increment()
                release.wait()
                return package
            },
            fileManager: fileManager
        )
        var retained: FeedbackReportPreparedPreview?
        var retainedKey: FeedbackPreparedPreviewCleanupKey?
        let work = FeedbackReportOwnedWork.start {
            _ = try await service.preparePreview(launch: launch, form: form)
        } onFailure: { error in
            if case FeedbackReportPreparationError.cancelledPreviewCleanupFailed(
                let preview, _
            ) = error {
                retained = preview
                let key = FeedbackPreparedPreviewCleanupKey(
                    reportID: preview.reportID,
                    contextIdentity: preview.contextIdentity,
                    sourceHostID: launch.hostID,
                    sourceLeaseID: sourceLeaseID,
                    directoryURL: preview.package.directoryURL
                )
                try? cleanupOwner.retain(key: key) {
                    try service.invalidatePreparedPreview(preview)
                }
                retainedKey = key
                return .retainedCleanup(key)
            }
            return .generic
        }
        while ready.value == 0 { await Task.yield() }
        work.cancel()
        let expected = FeedbackReportStoragePaths.preparationRoot(storageRoot: root)
            .appendingPathComponent("feedback-\(launch.id.uuidString.lowercased())", isDirectory: true)
        let settled = await FeedbackReportTaskSettlement.cancelAndFinalize(
            [work], timeout: .milliseconds(10)
        ) {
            #expect(retained == nil)
        }
        #expect(!settled)
        #expect(FileManager.default.fileExists(atPath: expected.path))

        // The replacement host has already appeared while the capability does
        // not exist yet. This is the production ordering that made an
        // onAppear-only recovery hook insufficient.
        let router = FeedbackReportRouter()
        try mountLifecycleLaunch(
            launch, on: router, hostID: launch.hostID, leaseID: sourceLeaseID
        )
        router.unregister(hostID: launch.hostID, leaseID: sourceLeaseID)
        router.completeHostDeactivation(
            hostID: launch.hostID, reportID: launch.id,
            leaseID: sourceLeaseID, succeeded: false
        )
        let nextHost = UUID(), nextLease = UUID()
        router.register(hostID: nextHost, leaseID: nextLease)
        #expect(try cleanupOwner.retryPendingCleanup(
            willClean: { key in
                try router.validateFailedHostSettlement(forCleanup: key)
            },
            didClean: { key in
                try router.resolveFailedHostSettlement(afterCleanup: key)
            }
        ) == false)

        release.signal()
        #expect(!(await FeedbackReportTaskSettlement.wait(
            for: [work], timeout: .seconds(1)
        )))
        let key = try #require(retainedKey)
        #expect(fileManager.injectedFailureCount == 2)
        #expect(cleanupOwner.pendingKey == key)
        #expect(work.terminalResult == .failed(.retainedCleanup(key)))
        #expect(FileManager.default.fileExists(atPath: expected.path))
        try cleanupOwner.retain(key: key) {
            try FileManager.default.removeItem(at: sentinel)
        }
        let wrongKey = FeedbackPreparedPreviewCleanupKey(
            reportID: key.reportID, contextIdentity: key.contextIdentity,
            sourceHostID: key.sourceHostID, sourceLeaseID: key.sourceLeaseID,
            directoryURL: sentinel
        )
        #expect(throws: FeedbackPreparedPreviewCleanupOwnerError.capabilityMismatch) {
            try cleanupOwner.retryPendingCleanup(matching: wrongKey)
        }
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(FileManager.default.fileExists(atPath: expected.path))
        for mismatched in cleanupKeyMismatches(from: key) {
            #expect(throws: FeedbackReportCoordinatorError.hostSettlementFailed) {
                try router.resolveFailedHostSettlement(afterCleanup: mismatched)
            }
        }
        let liveRouter = FeedbackReportRouter()
        let liveHost = UUID(), liveLease = UUID()
        let liveLaunch = lifecycleLaunch(hostID: liveHost)
        try mountLifecycleLaunch(
            liveLaunch, on: liveRouter, hostID: liveHost, leaseID: liveLease
        )
        #expect(throws: FeedbackReportCoordinatorError.hostSettlementFailed) {
            try liveRouter.resolveFailedHostSettlement(afterCleanup: key)
        }
        #expect(liveRouter.launch == liveLaunch)

        let coordinator = FeedbackReportCoordinator(
            router: router,
            modelContainer: container,
            crashLedger: crashOfferService,
            storageRoot: root,
            cleanupOwner: cleanupOwner
        )
        let differentPrefill = FeedbackReportPrefill(
            intendedOutcome: "Different caller data",
            actualResult: "Different caller data",
            expectedResult: "Different caller data",
            workBlocked: false
        )
        await #expect(throws: FeedbackReportCoordinatorError.hostSettlementFailed) {
            try await coordinator.present(
                from: .taskFailure,
                hostID: nextHost,
                prefill: differentPrefill,
                taskID: launch.taskID,
                runID: launch.runID,
                runtimeEvidence: nil
            )
        }
        #expect(cleanupOwner.pendingKey == key)
        #expect(fileManager.injectedFailureCount == 3)
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(router.isSettlingHostDeactivation)
        fileManager.allowRemovals()
        try await coordinator.present(
            from: .taskFailure,
            hostID: nextHost,
            prefill: differentPrefill,
            taskID: launch.taskID,
            runID: launch.runID,
            runtimeEvidence: nil
        )
        #expect(cleanupOwner.pendingKey == nil)
        #expect(!FileManager.default.fileExists(atPath: expected.path))
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(!router.isSettlingHostDeactivation)
        expectLifecyclePayload(router.launch, equals: launch, hostID: nextHost)
    }

    @Test("Live Close consumes exact late cleanup authority before dismissal")
    @MainActor
    func liveCloseConsumesLateCleanupCapability() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-live-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "feedback-live-close-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let launch = FeedbackReportLaunch(
            hostID: UUID(), entryPoint: .taskFailure,
            prefill: FeedbackReportPrefill(
                intendedOutcome: "Finish the task",
                actualResult: "The provider stopped",
                expectedResult: "The task should finish",
                workBlocked: true
            ),
            taskID: UUID(), runID: UUID(),
            runtimeEvidence: RuntimeFeedbackPersistedEvidence(
                runtimeID: "codex", providerVersion: "1.2.3",
                failureCategory: "provider_failed",
                sanitizedSummary: "The persisted provider run stopped.",
                exitCode: 1, stopReason: "provider_failed"
            )
        )
        var form = FeedbackReportFormState(launch: launch)
        form.intendedOutcome = "Finish the task"
        form.actualResult = "The provider stopped"
        form.expectedResult = "The task should finish"
        let container = try makeFeedbackOutboxContainer()
        let crashOfferService = FeedbackCrashOfferService(defaults: defaults)
        let fileManager = ControlledRemovalFailureFileManager(failureLimit: 1)
        let service = FeedbackReportPreparationService(
            modelContainer: container,
            crashOfferService: crashOfferService,
            storageRoot: root,
            defaults: defaults,
            evidenceSourceProvider: { _, _, _ in .empty },
            packageBuilder: { input, selections, directory in
                try FeedbackEvidenceBuilder().prepare(
                    input: input, selections: selections, directory: directory
                )
            },
            fileManager: fileManager
        )
        let preview = try await service.preparePreview(launch: launch, form: form)
        let cleanupOwner = FeedbackPreparedPreviewCleanupOwner()
        let sourceLeaseID = UUID()
        let router = FeedbackReportRouter()
        try mountLifecycleLaunch(
            launch, on: router, hostID: launch.hostID, leaseID: sourceLeaseID
        )
        let blocker = LifecycleAsyncBlocker()
        var retainedKey: FeedbackPreparedPreviewCleanupKey?
        let work = FeedbackReportOwnedWork.start {
            await blocker.wait()
            throw FeedbackReportPreparationError.cancelledPreviewCleanupFailed(
                preview, "injected late cleanup transfer"
            )
        } onFailure: { error in
            guard case FeedbackReportPreparationError.cancelledPreviewCleanupFailed(
                let retainedPreview, _
            ) = error else { return .generic }
            let key = FeedbackPreparedPreviewCleanupKey(
                reportID: retainedPreview.reportID,
                contextIdentity: retainedPreview.contextIdentity,
                sourceHostID: launch.hostID,
                sourceLeaseID: sourceLeaseID,
                directoryURL: retainedPreview.package.directoryURL
            )
            try? cleanupOwner.retain(key: key) {
                try service.invalidatePreparedPreview(retainedPreview)
            }
            retainedKey = key
            return .retainedCleanup(key)
        }

        work.cancel()
        #expect(!(await FeedbackReportTaskSettlement.cancelAndFinalize(
            [work], timeout: .milliseconds(10)
        ) {}))
        #expect(cleanupOwner.pendingKey == nil)
        #expect(router.launch == launch)
        await blocker.release()
        #expect(!(await FeedbackReportTaskSettlement.wait(
            for: [work], timeout: .seconds(1)
        )))
        let key = try #require(retainedKey)
        #expect(cleanupOwner.pendingKey == key)

        let sentinel = root.deletingLastPathComponent()
            .appendingPathComponent("feedback-live-close-sentinel-\(UUID().uuidString)")
        let sentinelBytes = Data("outside cleanup root".utf8)
        try sentinelBytes.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        #expect(throws: FeedbackPreparedPreviewCleanupOwnerError.capabilityMismatch) {
            _ = try FeedbackReportLiveCleanupFinalizer.invalidate(
                preview,
                sourceHostID: UUID(),
                sourceLeaseID: sourceLeaseID,
                cleanupOwner: cleanupOwner
            ) {
                try FileManager.default.removeItem(at: sentinel)
            }
        }
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(cleanupOwner.pendingKey == key)

        #expect(!(await FeedbackReportTaskSettlement.cancelAndFinalize([work]) {
            _ = try FeedbackReportLiveCleanupFinalizer.invalidate(
                preview,
                sourceHostID: launch.hostID,
                sourceLeaseID: sourceLeaseID,
                cleanupOwner: cleanupOwner
            ) {
                try service.invalidatePreparedPreview(preview)
            }
        }))
        #expect(fileManager.injectedFailureCount == 1)
        #expect(cleanupOwner.pendingKey == key)
        #expect(router.launch == launch)
        #expect(FileManager.default.fileExists(atPath: preview.package.directoryURL.path))

        fileManager.allowRemovals()
        router.unregister(hostID: launch.hostID, leaseID: sourceLeaseID)
        #expect(router.launch == nil)
        #expect(router.isSettlingHostDeactivation)
        var resolvedCleanupKeys: Set<FeedbackPreparedPreviewCleanupKey> = []
        let teardownSettled = await FeedbackReportTaskSettlement.cancelAndFinalize(
            [work],
            isResolvedRetainedCleanup: { resolvedCleanupKeys.contains($0) }
        ) {
            resolvedCleanupKeys.insert(try FeedbackReportLiveCleanupFinalizer.invalidate(
                preview,
                sourceHostID: launch.hostID,
                sourceLeaseID: sourceLeaseID,
                cleanupOwner: cleanupOwner
            ) {
                try service.invalidatePreparedPreview(preview)
            })
        }
        #expect(teardownSettled)
        router.completeHostDeactivation(
            hostID: launch.hostID,
            reportID: launch.id,
            leaseID: sourceLeaseID,
            succeeded: teardownSettled
        )
        #expect(cleanupOwner.pendingKey == nil)
        #expect(!FileManager.default.fileExists(atPath: preview.package.directoryURL.path))
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(router.launch == nil)
        #expect(!router.isSettlingHostDeactivation)
        let nextHost = UUID(), nextLease = UUID()
        router.register(hostID: nextHost, leaseID: nextLease)
        let coordinator = FeedbackReportCoordinator(
            router: router,
            modelContainer: container,
            crashLedger: crashOfferService,
            storageRoot: root,
            cleanupOwner: cleanupOwner
        )
        try await coordinator.present(
            from: .taskFailure,
            hostID: nextHost,
            taskID: launch.taskID,
            runID: launch.runID,
            runtimeEvidence: launch.runtimeEvidence
        )
        expectLifecyclePayload(router.launch, equals: launch, hostID: nextHost)
    }
}

private enum LifecycleTestError: Error { case cleanupFailed }

private func cleanupKeyMismatches(
    from key: FeedbackPreparedPreviewCleanupKey
) -> [FeedbackPreparedPreviewCleanupKey] {
    [
        FeedbackPreparedPreviewCleanupKey(
            reportID: UUID(), contextIdentity: key.contextIdentity,
            sourceHostID: key.sourceHostID, sourceLeaseID: key.sourceLeaseID,
            directoryURL: key.directoryURL
        ),
        FeedbackPreparedPreviewCleanupKey(
            reportID: key.reportID, contextIdentity: .general,
            sourceHostID: key.sourceHostID, sourceLeaseID: key.sourceLeaseID,
            directoryURL: key.directoryURL
        ),
        FeedbackPreparedPreviewCleanupKey(
            reportID: key.reportID, contextIdentity: key.contextIdentity,
            sourceHostID: UUID(), sourceLeaseID: key.sourceLeaseID,
            directoryURL: key.directoryURL
        ),
        FeedbackPreparedPreviewCleanupKey(
            reportID: key.reportID, contextIdentity: key.contextIdentity,
            sourceHostID: key.sourceHostID, sourceLeaseID: UUID(),
            directoryURL: key.directoryURL
        )
    ]
}

private final class LifecycleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class ControlledRemovalFailureFileManager: FileManager {
    private let stateLock = NSLock()
    private var remainingFailures: Int
    private var failureCount = 0
    var injectedFailureCount: Int { stateLock.withLock { failureCount } }

    init(failureLimit: Int) {
        remainingFailures = failureLimit
        super.init()
    }

    func allowRemovals() { stateLock.withLock { remainingFailures = 0 } }

    override func removeItem(at url: URL) throws {
        let shouldFail = stateLock.withLock {
            guard remainingFailures > 0,
                  url.path.contains("/Preparation/feedback-")
            else { return false }
            remainingFailures -= 1
            failureCount += 1
            return true
        }
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}

private actor LifecycleAsyncBlocker {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class LifecycleLinkedCrashLedger: FeedbackCrashOfferLedgerReading {
    private let reportIDs: Set<UUID>
    init(reportIDs: Set<UUID>) { self.reportIDs = reportIDs }
    func validateOffer(_ offer: FeedbackCrashOffer) async throws -> Bool { false }
    func verifiedLink(
        fingerprint: String,
        consentVersion: String
    ) throws -> FeedbackCrashVerifiedLink? { nil }
    func linkedReportIDs() throws -> Set<UUID> { reportIDs }
    func reconcileOfferedReport(
        fingerprint: String,
        consentVersion: String,
        reportID: UUID
    ) throws -> FeedbackCrashVerifiedLink {
        throw FeedbackCrashOfferError.offerNotFound
    }
}

@MainActor
private func mountLifecycleLaunch(
    _ launch: FeedbackReportLaunch, on router: FeedbackReportRouter,
    hostID: UUID, leaseID: UUID
) throws {
    router.register(hostID: hostID, leaseID: leaseID)
    try router.activate(launch, hostLeaseID: leaseID)
    router.markPresentationMounted(hostID: hostID, reportID: launch.id, leaseID: leaseID)
}

private func lifecycleLaunch(hostID: UUID) -> FeedbackReportLaunch {
    FeedbackReportLaunch(
        hostID: hostID, entryPoint: .taskFailure,
        prefill: FeedbackReportPrefill(
            intendedOutcome: "Finish the task", actualResult: "The provider stopped",
            expectedResult: "The task should finish", workBlocked: true
        ),
        taskID: UUID(), runID: UUID(),
        runtimeEvidence: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex", providerVersion: "1.2.3", failureCategory: "provider_failed",
            sanitizedSummary: "The persisted provider run stopped.", exitCode: 1,
            stopReason: "provider_failed"
        ),
        crashReports: [CrashReportSummary(
            url: URL(fileURLWithPath: "/tmp/retained-payload.crash"), appName: "ASTRA Dev",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000), sizeBytes: 512
        )],
        crashFingerprint: String(repeating: "a", count: 64)
    )
}

private func expectLifecyclePayload(
    _ actual: FeedbackReportLaunch?, equals expected: FeedbackReportLaunch, hostID: UUID
) {
    #expect(actual?.id == expected.id); #expect(actual?.hostID == hostID)
    #expect(actual?.prefill == expected.prefill); #expect(actual?.taskID == expected.taskID)
    #expect(actual?.runID == expected.runID); #expect(actual?.runtimeEvidence == expected.runtimeEvidence)
    #expect(actual?.taskFailureOccurredAt == expected.taskFailureOccurredAt)
    #expect(actual?.crashReports == expected.crashReports)
    #expect(actual?.crashFingerprint == expected.crashFingerprint)
}
