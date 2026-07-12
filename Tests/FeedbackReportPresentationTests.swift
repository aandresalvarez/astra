import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRALogging
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Feedback Report Presentation")
struct FeedbackReportPresentationTests {
    @Test("Startup removes only canonical abandoned feedback staging packages")
    @MainActor
    func abandonedStagingReconciliationIsContained() throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let fileManager = FileManager.default
        let root = FeedbackReportStoragePaths.preparationRoot(storageRoot: fixture.root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let preview = root.appendingPathComponent(
            "feedback-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let construction = root.appendingPathComponent(
            ".feedback-staging-\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: preview, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: construction, withIntermediateDirectories: false)
        try Data("preview".utf8).write(to: preview.appendingPathComponent("feedback-report.json"))
        try Data("construction".utf8).write(to: construction.appendingPathComponent("partial.json"))

        let unknown = root.appendingPathComponent("operator-notes", isDirectory: true)
        try fileManager.createDirectory(at: unknown, withIntermediateDirectories: false)
        let external = fixture.root.appendingPathComponent("external-sentinel", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: false)
        let sentinel = external.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let symlink = root.appendingPathComponent("feedback-\(UUID().uuidString.lowercased())")
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: external)
        let matchingFile = root.appendingPathComponent("feedback-\(UUID().uuidString.lowercased())")
        try Data("not a package directory".utf8).write(to: matchingFile)

        let result = try FeedbackPreparationStagingReconciler(
            storageRoot: fixture.root,
            fileManager: fileManager
        ).reconcileAbandonedPackages()

        #expect(result.removedPackageCount == 2)
        #expect(result.unsafePackageCount == 2)
        #expect(result.failedPackageCount == 0)
        #expect(!fileManager.fileExists(atPath: preview.path))
        #expect(!fileManager.fileExists(atPath: construction.path))
        #expect(fileManager.fileExists(atPath: unknown.path))
        #expect(fileManager.fileExists(atPath: symlink.path))
        #expect(fileManager.fileExists(atPath: matchingFile.path))
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))

        let redirectedTarget = fixture.root.appendingPathComponent("redirect-target", isDirectory: true)
        let redirectedStorage = redirectedTarget.appendingPathComponent("Feedback", isDirectory: true)
        let redirectedPreparation = FeedbackReportStoragePaths.preparationRoot(storageRoot: redirectedStorage)
        let redirectedPackage = redirectedPreparation.appendingPathComponent(
            "feedback-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: redirectedPackage, withIntermediateDirectories: true)
        let redirectedSentinel = redirectedPackage.appendingPathComponent("keep.json")
        try Data("keep redirected".utf8).write(to: redirectedSentinel)
        let redirectedAncestor = fixture.root.appendingPathComponent("redirected-ancestor")
        try fileManager.createSymbolicLink(at: redirectedAncestor, withDestinationURL: redirectedTarget)
        let storageThroughSymlink = redirectedAncestor.appendingPathComponent("Feedback", isDirectory: true)

        #expect(throws: FeedbackPreparationStagingReconciliationError.unsafePreparationRoot) {
            _ = try FeedbackPreparationStagingReconciler(
                storageRoot: storageThroughSymlink,
                fileManager: fileManager
            ).reconcileAbandonedPackages()
        }
        #expect(try Data(contentsOf: redirectedSentinel) == Data("keep redirected".utf8))
    }

    @Test("Every required statement field fails before evidence collection or persistence")
    @MainActor
    func requiredFieldsFailWithoutSideEffects() async throws {
        for missing in FeedbackReportRequiredField.allTestCases {
            let fixture = try makePresentationFixture()
            defer { fixture.cleanup() }
            let counter = LockedInt()
            let service = FeedbackReportPreparationService(
                modelContainer: fixture.container,
                crashOfferService: fixture.crashService,
                storageRoot: fixture.root,
                defaults: fixture.defaults,
                evidenceSourceProvider: { _, _, _ in counter.increment(); return .empty }
            )
            var form = validPresentationForm()
            switch missing {
            case .intendedOutcome: form.intendedOutcome = "  \n"
            case .actualResult: form.actualResult = "\t"
            case .expectedResult: form.expectedResult = ""
            }
            await #expect(throws: FeedbackReportPreparationError.missingRequiredField(missing)) {
                _ = try await service.preparePreview(launch: presentationLaunch(), form: form)
            }
            #expect(counter.value == 0)
            #expect(try fetchReports(fixture.container).isEmpty)
        }
    }

    @Test("Explicit opt-outs perform zero browser screenshot and crash I/O")
    func optOutsPerformNoIO() throws {
        let browser = LockedInt()
        let crashes = LockedInt()
        var selections = FeedbackEvidenceSelections()
        selections.includeTaskLogs = false
        selections.includeBrowserEvidence = false
        selections.includeScreenshots = false
        selections.includeMacOSDiagnostics = false
        let result = try FeedbackReportEvidenceSourceReader.collect(
            launch: presentationLaunch(),
            selections: selections,
            interval: DateInterval(start: .distantPast, end: .distantFuture),
            entriesProvider: { [] },
            browserProvider: { _, _, _, _ in
                browser.increment(); return (records: [], screenshots: [])
            },
            crashProvider: { _, _ in crashes.increment(); return [] }
        )
        #expect(result.browserRecords.isEmpty)
        #expect(result.screenshots.isEmpty)
        #expect(result.crashReports.isEmpty)
        #expect(browser.value == 0)
        #expect(crashes.value == 0)
    }

    @Test("Unavailable screenshots do not discard available browser records")
    func unavailableScreenshotKeepsBrowserRecords() throws {
        var selections = FeedbackEvidenceSelections()
        selections.includeTaskLogs = false
        selections.includeBrowserEvidence = true
        selections.includeScreenshots = true
        selections.includeMacOSDiagnostics = false
        let result = try FeedbackReportEvidenceSourceReader.collect(
            launch: presentationLaunch(),
            selections: selections,
            interval: DateInterval(start: .distantPast, end: .distantFuture),
            entriesProvider: { [] },
            browserProvider: { _, _, _, _ in
                (records: [browserRecord()], screenshots: [])
            },
            crashProvider: { _, _ in [] }
        )
        #expect(result.browserRecords.map(\.sequence) == [1])
        #expect(result.omissions.contains {
            $0.artifactID == "browser-screenshot" && $0.reason == .unavailable
        })
        #expect(!result.omissions.contains { $0.artifactID == "browser-evidence" })
        #expect(FeedbackReportEvidenceSourceReader.browserReadFailureSource(includeRecords: false) == .browserScreenshot)
    }

    @Test("Unavailable macOS diagnostics become a typed omission")
    func unavailableCrashDiagnosticsAreOmitted() throws {
        var selections = FeedbackEvidenceSelections()
        selections.includeTaskLogs = false
        selections.includeMacOSDiagnostics = true
        selections.includeBrowserEvidence = false
        selections.includeScreenshots = false
        let result = try FeedbackReportEvidenceSourceReader.collect(
            launch: presentationLaunch(),
            selections: selections,
            interval: DateInterval(start: .distantPast, end: .distantFuture),
            entriesProvider: { [] },
            browserProvider: { _, _, _, _ in (records: [], screenshots: []) },
            crashProvider: { _, _ in [] }
        )
        #expect(result.crashReports.isEmpty)
        #expect(result.omissions.contains {
            $0.artifactID == "macos-diagnostics" && $0.reason == .unavailable
        })
    }

    @Test("Selected browser read failures are omitted while corrupt parser bytes stay typed")
    func selectedSourceFailuresStaySafe() throws {
        var browserSelection = FeedbackEvidenceSelections()
        browserSelection.includeTaskLogs = false
        browserSelection.includeBrowserEvidence = true
        browserSelection.includeScreenshots = false
        browserSelection.includeMacOSDiagnostics = false
        let source = try FeedbackReportEvidenceSourceReader.collect(
            launch: presentationLaunch(),
            selections: browserSelection,
            interval: DateInterval(start: .distantPast, end: .distantFuture),
            entriesProvider: { [] },
            browserProvider: { _, _, _, _ in
                throw FeedbackReportEvidenceSourceReader.SourceError.unavailable(.browserEvidence)
            },
            crashProvider: { _, _ in [] }
        )
        #expect(source.omissions.contains {
            $0.artifactID == "browser-evidence" && $0.reason == .unavailable
        })

        let timestamp = "2027-01-15T08:00:00.000Z"
        let corruptScreenshot = try JSONSerialization.data(withJSONObject: [
            "createdAt": timestamp,
            "debugCapture": ["screenshot": ["base64": "%%%", "source": "browser"]]
        ])
        #expect(throws: FeedbackReportEvidenceSourceReader.SourceError.corrupt(.browserScreenshot)) {
            _ = try FeedbackReportEvidenceSourceReader.parseBrowserEvidence(
                data: corruptScreenshot,
                isCappedSuffix: false,
                interval: DateInterval(start: .distantPast, end: .distantFuture),
                includeRecords: false,
                includeScreenshots: true
            )
        }
    }

    @Test("Capped browser suffix ignores only its first truncated fragment")
    func cappedBrowserSuffixParsing() throws {
        let object: [String: Any] = [
            "createdAt": "2027-01-15T08:00:00.000Z",
            "sequence": 7,
            "method": "GET",
            "path": "/safe",
            "statusCode": 200,
            "durationMs": 12,
            "urlChanged": false,
            "ok": true
        ]
        var bytes = Data("partial-json-fragment\n".utf8)
        bytes.append(try JSONSerialization.data(withJSONObject: object))
        bytes.append(0x0a)
        let parsed = try FeedbackReportEvidenceSourceReader.parseBrowserEvidence(
            data: bytes,
            isCappedSuffix: true,
            interval: DateInterval(start: .distantPast, end: .distantFuture),
            includeRecords: true,
            includeScreenshots: false
        )
        #expect(parsed.records.map(\.sequence) == [7])

        #expect(throws: FeedbackReportEvidenceSourceReader.SourceError.corrupt(.browserEvidence)) {
            _ = try FeedbackReportEvidenceSourceReader.parseBrowserEvidence(
                data: Data("partial\nmalformed-complete-line\n".utf8),
                isCappedSuffix: true,
                interval: DateInterval(start: .distantPast, end: .distantFuture),
                includeRecords: true,
                includeScreenshots: false
            )
        }
    }

    @Test("Installation identity reuses canonical UUID and regenerates corrupt values")
    func installationIdentityHardening() {
        let defaults = ephemeralDefaults()
        let key = "installation"
        let valid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        defaults.set(valid, forKey: key)
        let reused = FeedbackInstallationIdentityStore(
            defaults: defaults,
            key: key,
            makeUUID: { UUID(uuidString: "11111111-2222-4333-8444-555555555555")! }
        ).value()
        #expect(reused.rawValue == valid)

        defaults.set("SECRET-OVERLONG-\(String(repeating: "x", count: 400))", forKey: key)
        let regenerated = FeedbackInstallationIdentityStore(
            defaults: defaults,
            key: key,
            makeUUID: { UUID(uuidString: "11111111-2222-4333-8444-555555555555")! }
        ).value()
        #expect(regenerated.rawValue == "11111111-2222-4333-8444-555555555555")
    }

    @Test("Incomplete progress restores its complete window selections and exact context")
    @MainActor
    func progressRoundTripAndContextIsolation() throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let outbox = try FeedbackOutboxService(modelContainer: fixture.container, storageRoot: fixture.root)
        let taskID = UUID()
        let runID = UUID()
        let progress = draftProgress(taskID: taskID, runID: runID)
        _ = try outbox.createDraftProgress(
            reportID: UUID(),
            installationID: FeedbackInstallationIDV1(rawValue: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            progress: progress
        )
        let restored = try #require(try outbox.latestDraft(
            taskID: taskID.uuidString.lowercased(),
            runID: runID.uuidString.lowercased()
        ))
        #expect(restored.progress == progress)
        #expect(try outbox.latestDraft(taskID: nil, runID: nil) == nil)

        let changed = FeedbackDraftProgress(
            intendedOutcome: "different",
            actualResult: "",
            expectedResult: "",
            workBlocked: false,
            taskID: UUID().uuidString.lowercased(),
            runID: nil,
            evidenceWindow: progress.evidenceWindow,
            consent: progress.consent
        )
        #expect(throws: FeedbackOutboxError.preparedPackageDoesNotMatchDraft) {
            try outbox.updateDraftProgress(reportID: restored.reportID, progress: changed)
        }
        #expect(try outbox.draftSnapshot(reportID: restored.reportID).progress == progress)
    }

    @Test("Preserved draft reopens after relaunch and clearing all fields remains durable")
    @MainActor
    func preserveRelaunchAndClearAll() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let reportID = UUID()
        let original = FeedbackReportLaunch(
            reportID: reportID,
            hostID: UUID(),
            entryPoint: .help
        )
        let first = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults
        )
        var form = validPresentationForm()
        form.selections.includeBrowserEvidence = true
        try first.saveProgress(launch: original, form: form)

        let freshRouter = FeedbackReportRouter()
        let freshCoordinator = FeedbackReportCoordinator(
            router: freshRouter,
            modelContainer: fixture.container,
            crashLedger: EmptyCrashLedger(),
            storageRoot: fixture.root
        )
        let freshHostID = UUID()
        freshRouter.register(hostID: freshHostID, leaseID: UUID())
        try await freshCoordinator.present(from: .logs, hostID: freshHostID)
        let resumed = try #require(freshRouter.launch)
        #expect(resumed.id == reportID)
        let fresh = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults
        )
        #expect(try fresh.restoredForm(reportID: reportID, launch: resumed) == form)

        var cleared = form
        cleared.intendedOutcome = ""
        cleared.actualResult = ""
        cleared.expectedResult = ""
        cleared.workBlocked = false
        cleared.selections = FeedbackEvidenceSelections(
            includeApplicationLogs: false,
            includeTaskLogs: false,
            includeBrowserEvidence: false,
            includeScreenshots: false,
            includeMacOSDiagnostics: false
        )
        try fresh.saveProgress(launch: resumed, form: cleared)
        let relaunched = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults
        )
        #expect(try relaunched.restoredForm(reportID: reportID, launch: resumed) == cleared)
    }

    @Test("Stored draft normalization corruption fails closed")
    @MainActor
    func storedProgressCorruptionFailsClosed() throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let reportID = UUID()
        let outbox = try FeedbackOutboxService(modelContainer: fixture.container, storageRoot: fixture.root)
        _ = try outbox.createDraftProgress(
            reportID: reportID,
            installationID: FeedbackInstallationIDV1(rawValue: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            progress: draftProgress(taskID: nil, runID: nil)
        )
        let context = ModelContext(fixture.container)
        let report = try #require(try context.fetch(FetchDescriptor<FeedbackReport>(
            predicate: #Predicate { $0.id == reportID }
        )).first)
        report.actualResult = "line one\r\nline two"
        try context.save()
        #expect(throws: (any Error).self) {
            _ = try outbox.draftSnapshot(reportID: reportID)
        }
    }

    @Test("Unrelated corrupt status does not block exact-context recovery")
    @MainActor
    func unrelatedCorruptStatusIsIsolated() throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let outbox = try FeedbackOutboxService(modelContainer: fixture.container, storageRoot: fixture.root)
        let goodID = UUID()
        _ = try outbox.createDraftProgress(
            reportID: goodID,
            installationID: FeedbackInstallationIDV1(rawValue: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            progress: draftProgress(taskID: nil, runID: nil)
        )
        let badID = UUID()
        _ = try outbox.createDraftProgress(
            reportID: badID,
            installationID: FeedbackInstallationIDV1(rawValue: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"),
            progress: draftProgress(taskID: UUID(), runID: nil)
        )
        let context = ModelContext(fixture.container)
        let bad = try #require(try context.fetch(FetchDescriptor<FeedbackReport>(
            predicate: #Predicate { $0.id == badID }
        )).first)
        bad.localStatusRaw = "future_status"
        try context.save()
        #expect(try outbox.latestDraft(taskID: nil, runID: nil)?.reportID == goodID)
        #expect(throws: FeedbackOutboxError.invalidStoredState(field: "localStatusRaw", value: "future_status")) {
            _ = try outbox.latestDraft(taskID: bad.taskID, runID: nil)
        }
    }

    @Test("Preview bytes equal adopted manifest and queue never claims upload")
    @MainActor
    func previewMatchesQueuedPackage() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        let form = validPresentationForm()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty }
        )
        let preview = try await service.preparePreview(launch: launch, form: form)
        let reviewedManifestBytes = try Data(contentsOf: preview.package.manifestURL)
        try service.confirmAndQueue(preview, launch: launch, form: form)

        let report = try #require(try fetchPresentationReport(fixture.container, id: launch.id))
        #expect(report.localStatus == .queued)
        #expect(report.uploadAttemptCount == 0)
        let envelope = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportEnvelopeV1.self,
            from: try #require(report.canonicalEnvelopeData)
        )
        #expect(envelope.payload.evidence == preview.manifest)
        #expect(try FeedbackCanonicalJSONV1.encodeValidated(envelope.payload.evidence) == reviewedManifestBytes)
    }

    @Test("Sub-millisecond evidence windows remain identical through adoption")
    @MainActor
    func submillisecondEvidenceWindowQueues() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        var form = validPresentationForm()
        form.evidenceWindowStart = Date(timeIntervalSince1970: 1_800_000_000.908325)
        form.evidenceWindowEnd = Date(timeIntervalSince1970: 1_800_000_900.908325)
        let collectedInterval = LockedDateInterval()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, interval in
                collectedInterval.set(interval)
                return .empty
            }
        )

        let preview = try await service.preparePreview(launch: launch, form: form)
        try service.confirmAndQueue(preview, launch: launch, form: form)

        let report = try #require(try fetchPresentationReport(fixture.container, id: launch.id))
        let canonicalStart = Date(timeIntervalSince1970: 1_800_000_000.908)
        let canonicalEnd = Date(timeIntervalSince1970: 1_800_000_900.908)
        #expect(report.localStatus == .queued)
        #expect(report.evidenceWindowStart == canonicalStart)
        #expect(report.evidenceWindowEnd == canonicalEnd)
        #expect(collectedInterval.value == DateInterval(start: canonicalStart, end: canonicalEnd))
        let envelope = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportEnvelopeV1.self,
            from: try #require(report.canonicalEnvelopeData)
        )
        #expect(envelope.payload.evidenceWindow.start == canonicalStart)
        #expect(envelope.payload.evidenceWindow.end == canonicalEnd)
    }

    @Test("Edited form cannot confirm stale preview and existing preview survives second preparation")
    @MainActor
    func staleAndDuplicatePreviewFailClosed() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        let form = validPresentationForm()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty }
        )
        let preview = try await service.preparePreview(launch: launch, form: form)
        let originalBytes = try Data(contentsOf: preview.package.manifestURL)
        await #expect(throws: (any Error).self) {
            _ = try await service.preparePreview(launch: launch, form: form)
        }
        #expect(try Data(contentsOf: preview.package.manifestURL) == originalBytes)

        var edited = form
        edited.expectedResult = "A changed expectation"
        #expect(throws: FeedbackReportPreparationError.stalePreparedPreview) {
            try service.confirmAndQueue(preview, launch: launch, form: edited)
        }
        #expect(try fetchPresentationReport(fixture.container, id: launch.id)?.localStatus == .draft)
        try service.invalidatePreparedPreview(preview)
    }

    @Test("Invalid replacement form preserves the previously reviewed staging package")
    @MainActor
    func invalidReplacementPreservesReviewedPackage() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        let originalForm = validPresentationForm()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty }
        )
        let preview = try await service.preparePreview(launch: launch, form: originalForm)
        let manifestBytes = try Data(contentsOf: preview.package.manifestURL)
        var invalid = originalForm
        invalid.actualResult = String(repeating: "x", count: FeedbackContractLimitsV1.userStatementLength + 1)

        await #expect(throws: FeedbackContractError.exceedsMaximumLength(
            path: "payload.statement.actualResult",
            maximum: FeedbackContractLimitsV1.userStatementLength,
            actual: FeedbackContractLimitsV1.userStatementLength + 1
        )) {
            _ = try await service.preparePreview(
                launch: launch,
                form: invalid,
                replacing: preview
            )
        }
        #expect(FileManager.default.fileExists(atPath: preview.package.directoryURL.path))
        #expect(try Data(contentsOf: preview.package.manifestURL) == manifestBytes)
        #expect(try fetchPresentationReport(fixture.container, id: launch.id)?.actualResult == originalForm.actualResult)
        try service.invalidatePreparedPreview(preview)
    }

    @Test("Late cancellation removes only the package returned by its worker")
    @MainActor
    func lateCancellationCleansReturnedPackage() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        let form = validPresentationForm()
        let ready = LockedInt()
        let release = DispatchSemaphore(value: 0)
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty },
            packageBuilder: { input, selections, root in
                let package = try FeedbackEvidenceBuilder().prepare(
                    input: input,
                    selections: selections,
                    directory: root
                )
                ready.increment()
                release.wait()
                return package
            }
        )
        let task = Task { try await service.preparePreview(launch: launch, form: form) }
        while ready.value == 0 { await Task.yield() }
        let expected = FeedbackReportStoragePaths.preparationRoot(storageRoot: fixture.root)
            .appendingPathComponent("feedback-\(launch.id.uuidString.lowercased())", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: expected.path))
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: expected.path))
        #expect(try fetchPresentationReport(fixture.container, id: launch.id)?.localStatus == .draft)
    }

    @Test("Prepared retry queues idempotently without claiming upload")
    @MainActor
    func preparedRetryQueuesWithoutClaim() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        let form = validPresentationForm()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty }
        )
        let preview = try await service.preparePreview(launch: launch, form: form)
        try service.confirmPreparedPreview(preview, launch: launch, form: form)
        #expect(try fetchPresentationReport(fixture.container, id: launch.id)?.localStatus == .prepared)
        try service.confirmAndQueue(preview, launch: launch, form: form)
        try service.confirmAndQueue(preview, launch: launch, form: form)
        let report = try #require(try fetchPresentationReport(fixture.container, id: launch.id))
        #expect(report.localStatus == .queued)
        #expect(report.uploadAttemptCount == 0)
        #expect(report.activeClaimToken == nil)
    }

    @Test("Draft confirmation rejects a self-consistent package that replaced reviewed bytes")
    @MainActor
    func draftConfirmationRejectsReplacedReviewedPackage() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        let form = validPresentationForm()
        let original = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let reviewed = try await original.preparePreview(launch: launch, form: form)
        let displaced = fixture.root.appendingPathComponent("reviewed-package", isDirectory: true)
        try FileManager.default.moveItem(at: reviewed.package.directoryURL, to: displaced)
        let replacementLaunch = FeedbackReportLaunch(
            reportID: launch.id,
            hostID: UUID(),
            entryPoint: .help,
            runtimeEvidence: RuntimeFeedbackPersistedEvidence(
                runtimeID: "codex",
                executableFound: true,
                failureCategory: "provider_process_failed",
                sanitizedSummary: "A different persisted runtime snapshot."
            )
        )
        let replacementService = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty },
            now: { Date(timeIntervalSince1970: 1_800_000_001) }
        )
        let replacement = try await replacementService.preparePreview(
            launch: replacementLaunch,
            form: form
        )
        #expect(replacement.package.reportSHA256 != reviewed.package.reportSHA256)
        #expect(throws: FeedbackReportPreparationError.stagedPackageChangedAfterReview) {
            try original.confirmPreparedPreview(reviewed, launch: launch, form: form)
        }
        #expect(try fetchPresentationReport(fixture.container, id: launch.id)?.localStatus == .draft)
        #expect(FileManager.default.fileExists(atPath: replacement.package.directoryURL.path))
        try replacementService.invalidatePreparedPreview(replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: displaced.path)
        try? FileManager.default.removeItem(at: displaced)
    }

    @Test("Prepared retry revalidates every adopted artifact before queueing")
    @MainActor
    func preparedRetryRejectsChangedOrMissingArtifact() async throws {
        for deleteArtifact in [false, true] {
            let fixture = try makePresentationFixture()
            defer { fixture.cleanup() }
            let launch = presentationLaunch()
            let form = validPresentationForm()
            let service = FeedbackReportPreparationService(
                modelContainer: fixture.container,
                crashOfferService: fixture.crashService,
                storageRoot: fixture.root,
                defaults: fixture.defaults,
                evidenceSourceProvider: { _, _, _ in
                    FeedbackReportEvidenceSource(
                        applicationLogEntries: [
                            LogEntry(
                                level: .info,
                                category: "FeedbackTest",
                                message: "A deterministic safe log line",
                                timestamp: Date(timeIntervalSince1970: 1_800_000_000)
                            )
                        ],
                        taskLogEntries: [],
                        browserRecords: [],
                        screenshots: [],
                        crashReports: []
                    )
                }
            )
            let preview = try await service.preparePreview(launch: launch, form: form)
            let artifact = try #require(preview.manifest.artifacts.first)
            try service.confirmPreparedPreview(preview, launch: launch, form: form)
            let artifactURL = fixture.root
                .appendingPathComponent("packages", isDirectory: true)
                .appendingPathComponent(launch.id.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(artifact.relativePath)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: artifactURL.deletingLastPathComponent().path
            )
            if deleteArtifact {
                try FileManager.default.removeItem(at: artifactURL)
            } else {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: artifactURL.path
                )
                try Data("changed after review".utf8).write(to: artifactURL)
            }

            #expect(throws: (any Error).self) {
                try service.confirmAndQueue(preview, launch: launch, form: form)
            }
            let report = try #require(try fetchPresentationReport(fixture.container, id: launch.id))
            #expect(report.localStatus == .prepared)
            #expect(report.uploadAttemptCount == 0)
            #expect(report.activeClaimToken == nil)
        }
    }

    @Test("Invalid complete form fails before crash fingerprint or evidence I/O")
    @MainActor
    func invalidCompleteFormFailsBeforeCrashIO() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let crashURL = fixture.root.appendingPathComponent("invalid-form.crash")
        try Data("Incident Identifier: INVALID-FORM\nException Type: EXC_BAD_ACCESS\n".utf8)
            .write(to: crashURL)
        let crash = crashFileSummary(crashURL)
        let fingerprint = try #require(FeedbackCrashFingerprint.make(crash))
        try FileManager.default.removeItem(at: crashURL)
        let crashLaunch = FeedbackReportLaunch(
            hostID: UUID(),
            entryPoint: .crashRecovery,
            crashReports: [crash],
            crashFingerprint: fingerprint
        )
        var form = validPresentationForm()
        form.evidenceWindowStart = Date(timeIntervalSince1970: 1_800_000_001)
        form.evidenceWindowEnd = Date(timeIntervalSince1970: 1_800_000_000)
        let providerCalls = LockedInt()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in providerCalls.increment(); return .empty }
        )

        await #expect(throws: FeedbackContractError.valueOutOfRange(
            path: "payload.evidenceWindow",
            description: "end must not precede start"
        )) {
            _ = try await service.preparePreview(launch: crashLaunch, form: form)
        }
        #expect(providerCalls.value == 0)
        #expect(try fetchReports(fixture.container).isEmpty)
    }

    @Test("Prepared package recovers after relaunch and remains queue-only")
    @MainActor
    func preparedRelaunchRecovery() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = FeedbackReportLaunch(
            reportID: UUID(),
            hostID: UUID(),
            entryPoint: .help
        )
        let form = validPresentationForm()
        let first = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty }
        )
        let originalPreview = try await first.preparePreview(launch: launch, form: form)
        try first.confirmPreparedPreview(originalPreview, launch: launch, form: form)

        let relaunchedRouter = FeedbackReportRouter()
        let coordinator = FeedbackReportCoordinator(
            router: relaunchedRouter,
            modelContainer: fixture.container,
            crashLedger: EmptyCrashLedger(),
            storageRoot: fixture.root
        )
        let relaunchedHostID = UUID()
        relaunchedRouter.register(hostID: relaunchedHostID, leaseID: UUID())
        try await coordinator.present(from: .help, hostID: relaunchedHostID)
        let resumedLaunch = try #require(relaunchedRouter.launch)
        #expect(resumedLaunch.id == launch.id)
        let relaunchedService = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults
        )
        let restoredForm = try relaunchedService.restoredForm(
            reportID: launch.id,
            launch: resumedLaunch
        )
        let restoredPreview = try relaunchedService.restoredPreparedPreview(
            reportID: launch.id,
            launch: resumedLaunch,
            form: restoredForm
        )
        #expect(restoredPreview.ownership == .adoptedOutbox)
        #expect(restoredPreview.package.reportSHA256 == originalPreview.package.reportSHA256)
        #expect(restoredPreview.manifest == originalPreview.manifest)
        #expect(throws: FeedbackReportPreparationError.unsafeStagingPath) {
            try relaunchedService.invalidatePreparedPreview(restoredPreview)
        }
        try relaunchedService.settleForHostDeactivation(
            launch: resumedLaunch,
            form: restoredForm,
            preview: restoredPreview,
            shouldPersist: true
        )
        #expect(FileManager.default.fileExists(atPath: restoredPreview.package.directoryURL.path))
        #expect(try fetchPresentationReport(fixture.container, id: launch.id)?.localStatus == .prepared)
        let stillRecoverable = try FeedbackOutboxService(
            modelContainer: fixture.container,
            storageRoot: fixture.root
        ).recoverablePreparedPackage(reportID: launch.id)
        #expect(stillRecoverable.reportSHA256 == restoredPreview.package.reportSHA256)
        try relaunchedService.confirmAndQueue(
            restoredPreview,
            launch: resumedLaunch,
            form: restoredForm
        )
        let report = try #require(try fetchPresentationReport(fixture.container, id: launch.id))
        #expect(report.localStatus == .queued)
        #expect(report.uploadAttemptCount == 0)
        #expect(report.activeClaimToken == nil)
    }

    @Test("Crash draft reconciles an interrupted ledger transition on relaunch")
    @MainActor
    func crashDraftLedgerReconciliation() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let crashURL = fixture.root.appendingPathComponent("recovery.crash")
        try Data("Incident Identifier: RECOVERY\nException Type: EXC_BAD_ACCESS\n".utf8).write(to: crashURL)
        let reportSummary = crashFileSummary(crashURL)
        let writes = LockedInt()
        let interruptedLedger = FeedbackCrashOfferService(
            defaults: fixture.defaults,
            writeData: { data in
                let attempt = writes.incrementAndGet()
                guard attempt == 1 else { return false }
                fixture.defaults.set(data, forKey: AppStorageKeys.feedbackCrashOfferLedger)
                return fixture.defaults.data(forKey: AppStorageKeys.feedbackCrashOfferLedger) == data
            }
        )
        let offer = try #require(try await interruptedLedger.claimOffer(from: [reportSummary]))
        let crashLaunch = FeedbackReportLaunch(
            reportID: offer.reportID,
            hostID: UUID(),
            entryPoint: .crashRecovery,
            prefill: .empty,
            crashReports: [reportSummary],
            crashFingerprint: offer.fingerprint
        )
        let preparation = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: interruptedLedger,
            storageRoot: fixture.root,
            defaults: fixture.defaults
        )
        #expect(throws: FeedbackCrashOfferError.persistenceFailed) {
            try preparation.saveProgress(launch: crashLaunch, form: validPresentationForm())
        }
        #expect(try fetchPresentationReport(fixture.container, id: offer.reportID)?.localStatus == .draft)

        let recoveredLedger = FeedbackCrashOfferService(defaults: fixture.defaults)
        let recoveredOffer = try #require(try await recoveredLedger.claimOffer(
            from: [reportSummary],
            recoverableReportIDs: Set([offer.reportID])
        ))
        let router = FeedbackReportRouter()
        let coordinator = FeedbackReportCoordinator(
            router: router,
            modelContainer: fixture.container,
            crashLedger: recoveredLedger,
            storageRoot: fixture.root
        )
        let recoveredHostID = UUID()
        router.register(hostID: recoveredHostID, leaseID: UUID())
        try await coordinator.present(
            from: .crashRecovery,
            hostID: recoveredHostID,
            crashOffer: recoveredOffer
        )
        #expect(router.launch?.id == offer.reportID)
        #expect(try recoveredLedger.verifiedLink(
            fingerprint: offer.fingerprint,
            consentVersion: offer.consentVersion
        )?.outcome == .reportCreated)
    }

    @Test("Crash routing never treats a corrupt recoverable report as absent")
    @MainActor
    func crashRoutingFailsClosedOnCorruptOutbox() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let crashURL = fixture.root.appendingPathComponent("corrupt-outbox.crash")
        try Data("Incident Identifier: CORRUPT-OUTBOX\nException Type: EXC_BAD_ACCESS\n".utf8)
            .write(to: crashURL)
        let ledger = FeedbackCrashOfferService(defaults: fixture.defaults)
        let offer = try #require(try await ledger.claimOffer(from: [crashFileSummary(crashURL)]))
        let outbox = try FeedbackOutboxService(
            modelContainer: fixture.container,
            storageRoot: fixture.root
        )
        _ = try outbox.createDraftProgress(
            reportID: offer.reportID,
            installationID: FeedbackInstallationIDV1(rawValue: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            progress: draftProgress(taskID: nil, runID: nil)
        )
        let context = ModelContext(fixture.container)
        let reportID = offer.reportID
        let report = try #require(try context.fetch(FetchDescriptor<FeedbackReport>(
            predicate: #Predicate { $0.id == reportID }
        )).first)
        report.localStatusRaw = "future_status"
        try context.save()

        let router = FeedbackReportRouter()
        let hostID = UUID()
        router.register(hostID: hostID, leaseID: UUID())
        let coordinator = FeedbackReportCoordinator(
            router: router,
            modelContainer: fixture.container,
            crashLedger: ledger,
            storageRoot: fixture.root
        )
        await #expect(throws: FeedbackOutboxError.invalidStoredState(
            field: "localStatusRaw",
            value: "future_status"
        )) {
            try await coordinator.present(
                from: .crashRecovery,
                hostID: hostID,
                crashOffer: offer
            )
        }
        #expect(router.launch == nil)
        #expect(try ledger.verifiedLink(
            fingerprint: offer.fingerprint,
            consentVersion: offer.consentVersion
        )?.outcome == .offered)
    }

    @Test("Crash replacement fails before draft or evidence side effects")
    @MainActor
    func changedCrashFailsBeforePreparation() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let crashURL = fixture.root.appendingPathComponent("changed.crash")
        try Data("Incident Identifier: FIRST\nException Type: EXC_BAD_ACCESS\n".utf8).write(to: crashURL)
        let original = crashFileSummary(crashURL)
        let offer = try #require(try await fixture.crashService.claimOffer(from: [original]))
        try Data("Incident Identifier: SECOND\nException Type: EXC_BAD_ACCESS\n".utf8).write(to: crashURL)
        let reads = LockedInt()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in reads.increment(); return .empty }
        )
        let launch = FeedbackReportLaunch(
            reportID: offer.reportID,
            hostID: UUID(),
            entryPoint: .crashRecovery,
            crashReports: [original],
            crashFingerprint: offer.fingerprint
        )
        await #expect(throws: FeedbackReportPreparationError.crashEvidenceChanged) {
            _ = try await service.preparePreview(launch: launch, form: validPresentationForm())
        }
        #expect(reads.value == 0)
        #expect(try fetchPresentationReport(fixture.container, id: offer.reportID) == nil)
    }

    @Test("Evidence collection and package building execute off the main thread")
    @MainActor
    func preparationWorkerRunsOffMain() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let observations = ThreadObservations()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in
                observations.recordProvider(isMain: Thread.isMainThread)
                return .empty
            },
            packageBuilder: { input, selections, root in
                observations.recordBuilder(isMain: Thread.isMainThread)
                return try FeedbackEvidenceBuilder().prepare(
                    input: input,
                    selections: selections,
                    directory: root
                )
            }
        )
        let preview = try await service.preparePreview(launch: presentationLaunch(), form: validPresentationForm())
        #expect(observations.providerWasMain == false)
        #expect(observations.builderWasMain == false)
        try service.invalidatePreparedPreview(preview)
    }

    @Test("Facade operations reject corrupt status without mutation")
    @MainActor
    func corruptStatusFailsAcrossFacade() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        let form = validPresentationForm()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty }
        )
        let preview = try await service.preparePreview(launch: launch, form: form)
        let context = ModelContext(fixture.container)
        let reportID = launch.id
        let report = try #require(try context.fetch(FetchDescriptor<FeedbackReport>(
            predicate: #Predicate { $0.id == reportID }
        )).first)
        report.localStatusRaw = "future_status"
        try context.save()

        #expect(throws: (any Error).self) { try service.saveProgress(launch: launch, form: form) }
        #expect(throws: (any Error).self) { _ = try service.restoredForm(reportID: launch.id, launch: launch) }
        await #expect(throws: (any Error).self) { _ = try await service.preparePreview(launch: launch, form: form) }
        #expect(throws: (any Error).self) { try service.confirmPreparedPreview(preview, launch: launch, form: form) }
        #expect(throws: (any Error).self) { try service.confirmAndQueue(preview, launch: launch, form: form) }
        #expect(throws: (any Error).self) { try service.discard(reportID: launch.id) }
        #expect(try fetchPresentationReport(fixture.container, id: launch.id)?.localStatusRaw == "future_status")
        try service.invalidatePreparedPreview(preview)
    }

    @Test("Router preserves identity only for the same active context and host")
    @MainActor
    func routerAndCoordinatorIdentity() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let router = FeedbackReportRouter()
        let ledger = EmptyCrashLedger()
        let coordinator = FeedbackReportCoordinator(
            router: router,
            modelContainer: fixture.container,
            crashLedger: ledger,
            storageRoot: fixture.root
        )
        let firstHost = UUID()
        let firstLease = UUID()
        router.register(hostID: firstHost, leaseID: firstLease)
        try await coordinator.present(from: .help, hostID: firstHost)
        let reportID = try #require(router.launch?.id)
        let secondHost = UUID()
        router.register(hostID: secondHost, leaseID: UUID())
        await #expect(throws: FeedbackReportCoordinatorError.alreadyPresented) {
            try await coordinator.present(from: .logs, hostID: secondHost)
        }
        #expect(router.launch?.id == reportID)
        #expect(router.launch?.hostID == firstHost)
        await #expect(throws: FeedbackReportCoordinatorError.activeReportConflict) {
            try await coordinator.present(from: .taskFailure, hostID: firstHost, taskID: UUID())
        }
        #expect(router.launch?.id == reportID)
    }

    @Test("Host leases prevent stale views from owning or dismissing a report")
    @MainActor
    func hostLeasePreventsABARaces() throws {
        let router = FeedbackReportRouter()
        let hostID = UUID()
        let firstLease = UUID()
        let secondLease = UUID()
        let fingerprint = String(repeating: "a", count: 64)
        let crash = CrashReportSummary(
            url: URL(fileURLWithPath: "/tmp/astra-retained.crash"), appName: "ASTRA Dev",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000), sizeBytes: 512
        )
        let firstLaunch = FeedbackReportLaunch(
            hostID: hostID, entryPoint: .crashRecovery,
            prefill: FeedbackReportPrefill(
                intendedOutcome: "Recover after the crash",
                actualResult: "ASTRA closed",
                expectedResult: "The report should remain available",
                workBlocked: true
            ),
            crashReports: [crash], crashFingerprint: fingerprint
        )
        router.register(hostID: hostID, leaseID: firstLease)
        try router.activate(firstLaunch, hostLeaseID: firstLease)
        #expect(router.launch(for: hostID, leaseID: firstLease)?.id == firstLaunch.id)
        router.register(hostID: hostID, leaseID: secondLease)
        #expect(router.launch == nil)
        #expect(router.launch(for: hostID, leaseID: firstLease) == nil)
        router.unregister(hostID: hostID, leaseID: firstLease)
        #expect(router.hostLeaseID(for: hostID) == secondLease)
        let secondLaunch = FeedbackReportLaunch(hostID: hostID, entryPoint: .logs)
        #expect(throws: FeedbackReportCoordinatorError.activeReportConflict) {
            try router.activate(secondLaunch, hostLeaseID: secondLease)
        }
        #expect(throws: FeedbackReportCoordinatorError.activeReportConflict) {
            _ = try router.reactivatePendingLaunch(
                matching: .general, explicitReportID: nil,
                hostID: hostID, hostLeaseID: secondLease
            )
        }
        #expect(throws: FeedbackReportCoordinatorError.activeReportConflict) {
            _ = try router.reactivatePendingLaunch(
                matching: .crashRecovery(fingerprint), explicitReportID: UUID(),
                hostID: hostID, hostLeaseID: secondLease
            )
        }
        #expect(try router.reactivatePendingLaunch(
            matching: .crashRecovery(fingerprint), explicitReportID: firstLaunch.id,
            hostID: hostID, hostLeaseID: secondLease
        ))
        let retained = try #require(router.launch(for: hostID, leaseID: secondLease))
        #expect(retained.id == firstLaunch.id)
        #expect(retained.prefill == firstLaunch.prefill)
        #expect(retained.crashReports == firstLaunch.crashReports)
        #expect(retained.crashFingerprint == firstLaunch.crashFingerprint)
        router.dismiss(hostID: hostID, reportID: firstLaunch.id, leaseID: firstLease)
        #expect(router.launch(for: hostID, leaseID: secondLease)?.id == firstLaunch.id)
        router.dismiss(hostID: hostID, reportID: UUID(), leaseID: secondLease)
        #expect(router.launch(for: hostID, leaseID: secondLease)?.id == firstLaunch.id)
        router.dismiss(hostID: hostID, reportID: firstLaunch.id, leaseID: secondLease)
        #expect(router.launch == nil)
    }

    @Test("Host teardown before sheet mount releases the router for another window")
    @MainActor
    func deadHostReleaseAllowsAnotherWindow() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let router = FeedbackReportRouter()
        let coordinator = FeedbackReportCoordinator(
            router: router, modelContainer: fixture.container,
            crashLedger: EmptyCrashLedger(), storageRoot: fixture.root
        )
        let firstHost = UUID()
        let firstLease = UUID()
        let taskID = UUID()
        let runID = UUID()
        let runtimeEvidence = RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex",
            providerVersion: "1.2.3",
            executableFound: true,
            readiness: "ready",
            failureCategory: "provider_failed",
            sanitizedSummary: "The provider stopped before completion.",
            exitCode: 1,
            stopReason: "provider_failed"
        )
        let prefill = FeedbackReportPrefill(
            intendedOutcome: "Publish the reviewed workspace",
            actualResult: "The report sheet did not mount",
            expectedResult: "The same report should remain available",
            workBlocked: true
        )
        router.register(hostID: firstHost, leaseID: firstLease)
        try await coordinator.present(
            from: .taskFailure, hostID: firstHost, prefill: prefill,
            taskID: taskID, runID: runID,
            runtimeEvidence: runtimeEvidence
        )
        let original = try #require(router.launch)
        #expect(original.hostID == firstHost)
        router.unregister(hostID: firstHost, leaseID: firstLease)
        #expect(router.launch == nil)
        #expect(router.hostLeaseID(for: firstHost) == nil)
        let secondHost = UUID()
        let secondLease = UUID()
        router.register(hostID: secondHost, leaseID: secondLease)
        try await coordinator.present(
            from: .taskFailure, hostID: secondHost, taskID: taskID, runID: runID
        )
        let handedOff = try #require(router.launch(for: secondHost, leaseID: secondLease))
        #expect(handedOff.id == original.id)
        #expect(handedOff.hostID == secondHost)
        #expect(handedOff.entryPoint == original.entryPoint)
        #expect(handedOff.prefill == original.prefill)
        #expect(handedOff.contextIdentity == original.contextIdentity)
        #expect(handedOff.taskID == original.taskID)
        #expect(handedOff.runID == original.runID)
        #expect(handedOff.runtimeEvidence == original.runtimeEvidence)
        #expect(handedOff.crashReports == original.crashReports)
        #expect(handedOff.crashFingerprint == original.crashFingerprint)
    }

    @Test("Mounted host teardown blocks a second presentation until durable settlement completes")
    @MainActor
    func mountedHostSettlementBarrier() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let router = FeedbackReportRouter()
        let coordinator = FeedbackReportCoordinator(
            router: router, modelContainer: fixture.container,
            crashLedger: EmptyCrashLedger(), storageRoot: fixture.root
        )
        let firstHost = UUID()
        let firstLease = UUID()
        let taskID = UUID()
        let runID = UUID()
        let originalPrefill = FeedbackReportPrefill(
            intendedOutcome: "Finish the provider task",
            actualResult: "The provider stopped",
            expectedResult: "The provider should finish",
            workBlocked: true
        )
        let originalRuntime = RuntimeFeedbackPersistedEvidence(
            runtimeID: "claude",
            providerVersion: "9.9.9",
            failureCategory: "provider_failed",
            sanitizedSummary: "The persisted provider run stopped.",
            exitCode: 2,
            stopReason: "provider_failed"
        )
        let firstLaunch = FeedbackReportLaunch(
            hostID: firstHost, entryPoint: .taskFailure, prefill: originalPrefill,
            taskID: taskID, runID: runID,
            runtimeEvidence: originalRuntime
        )
        try mountLaunch(firstLaunch, on: router, hostID: firstHost, leaseID: firstLease)
        router.unregister(hostID: firstHost, leaseID: firstLease)
        #expect(router.launch == nil)
        #expect(router.isSettlingHostDeactivation)
        let secondHost = UUID()
        let secondLease = UUID()
        router.register(hostID: secondHost, leaseID: secondLease)
        let presentation = Task { @MainActor in
            try await coordinator.present(
                from: .taskFailure,
                hostID: secondHost,
                prefill: FeedbackReportPrefill(
                    intendedOutcome: "Different caller data",
                    actualResult: "Different caller data",
                    expectedResult: "Different caller data",
                    workBlocked: false
                ),
                taskID: taskID, runID: runID,
                runtimeEvidence: nil
            )
        }
        await waitForSettlementWaiters(on: router)
        #expect(router.hasHostSettlementWaiters)
        #expect(router.launch == nil)
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults
        )
        try service.saveProgress(launch: firstLaunch, form: validPresentationForm())
        router.completeHostDeactivation(
            hostID: firstHost, reportID: firstLaunch.id,
            leaseID: firstLease, succeeded: true
        )
        try await presentation.value
        #expect(!router.isSettlingHostDeactivation)
        #expect(router.launch?.id == firstLaunch.id)
        #expect(router.launch?.hostID == secondHost)
        #expect(router.launch?.prefill == originalPrefill)
        #expect(router.launch?.runtimeEvidence == originalRuntime)
        #expect(router.launch?.taskID == taskID)
        #expect(router.launch?.runID == runID)
        #expect(try fetchReports(fixture.container).map(\.id) == [firstLaunch.id])
    }

    @Test("Mounted crash settlement preserves the exact claimed launch payload")
    @MainActor
    func mountedCrashSettlementPreservesPayload() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let crashURL = fixture.root.appendingPathComponent("mounted.crash")
        try Data("Incident Identifier: MOUNTED\nException Type: EXC_BAD_ACCESS\n".utf8)
            .write(to: crashURL)
        let ledger = FeedbackCrashOfferService(defaults: fixture.defaults)
        let offer = try #require(try await ledger.claimOffer(from: [crashFileSummary(crashURL)]))
        let router = FeedbackReportRouter()
        let coordinator = FeedbackReportCoordinator(
            router: router, modelContainer: fixture.container,
            crashLedger: ledger, storageRoot: fixture.root
        )
        let firstHost = UUID()
        let firstLease = UUID()
        let originalPrefill = FeedbackReportPrefill(
            intendedOutcome: "Recover the interrupted work",
            actualResult: "ASTRA closed unexpectedly",
            expectedResult: "ASTRA should remain open",
            workBlocked: true
        )
        router.register(hostID: firstHost, leaseID: firstLease)
        try await coordinator.present(
            from: .crashRecovery, hostID: firstHost, prefill: originalPrefill,
            crashOffer: offer
        )
        let firstLaunch = try #require(router.launch)
        router.markPresentationMounted(
            hostID: firstHost, reportID: firstLaunch.id, leaseID: firstLease
        )
        router.unregister(hostID: firstHost, leaseID: firstLease)
        let secondHost = UUID()
        router.register(hostID: secondHost, leaseID: UUID())
        let presentation = Task { @MainActor in
            try await coordinator.present(
                from: .crashRecovery, hostID: secondHost, prefill: .empty,
                runtimeEvidence: nil,
                crashOffer: offer
            )
        }
        await waitForSettlementWaiters(on: router)
        #expect(router.hasHostSettlementWaiters)
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: ledger,
            storageRoot: fixture.root,
            defaults: fixture.defaults
        )
        try service.saveProgress(launch: firstLaunch, form: validPresentationForm())
        router.completeHostDeactivation(
            hostID: firstHost, reportID: firstLaunch.id,
            leaseID: firstLease, succeeded: true
        )
        try await presentation.value
        let retained = try #require(router.launch)
        #expect(retained.id == firstLaunch.id)
        #expect(retained.hostID == secondHost)
        #expect(retained.prefill == originalPrefill)
        #expect(retained.crashReports == firstLaunch.crashReports)
        #expect(retained.crashFingerprint == firstLaunch.crashFingerprint)
        #expect(try fetchReports(fixture.container).map(\.id) == [firstLaunch.id])
    }

    @Test("Failed mounted settlement blocks duplicate report ownership")
    @MainActor
    func failedMountedSettlementBlocksPresentation() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let router = FeedbackReportRouter()
        let coordinator = FeedbackReportCoordinator(
            router: router, modelContainer: fixture.container,
            crashLedger: EmptyCrashLedger(), storageRoot: fixture.root
        )
        let firstHost = UUID()
        let firstLease = UUID()
        let firstLaunch = FeedbackReportLaunch(hostID: firstHost, entryPoint: .help)
        try mountLaunch(firstLaunch, on: router, hostID: firstHost, leaseID: firstLease)
        router.unregister(hostID: firstHost, leaseID: firstLease)
        let secondHost = UUID()
        router.register(hostID: secondHost, leaseID: UUID())
        let presentation = Task { @MainActor in
            try await coordinator.present(from: .logs, hostID: secondHost)
        }
        await waitForSettlementWaiters(on: router)
        #expect(router.hasHostSettlementWaiters)
        router.completeHostDeactivation(
            hostID: firstHost, reportID: firstLaunch.id,
            leaseID: firstLease, succeeded: false
        )
        await #expect(throws: FeedbackReportCoordinatorError.hostSettlementFailed) {
            try await presentation.value
        }
        #expect(router.isSettlingHostDeactivation)
        #expect(router.launch == nil)
        #expect(try fetchReports(fixture.container).isEmpty)
    }

    @Test("Cancelled settlement waiter cannot activate after completion")
    @MainActor
    func cancelledMountedSettlementWaiter() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let router = FeedbackReportRouter()
        let coordinator = FeedbackReportCoordinator(
            router: router, modelContainer: fixture.container,
            crashLedger: EmptyCrashLedger(), storageRoot: fixture.root
        )
        let firstHost = UUID()
        let firstLease = UUID()
        let firstLaunch = FeedbackReportLaunch(hostID: firstHost, entryPoint: .help)
        try mountLaunch(firstLaunch, on: router, hostID: firstHost, leaseID: firstLease)
        router.unregister(hostID: firstHost, leaseID: firstLease)
        let secondHost = UUID()
        router.register(hostID: secondHost, leaseID: UUID())
        let presentation = Task { @MainActor in
            try await coordinator.present(from: .logs, hostID: secondHost)
        }
        await waitForSettlementWaiters(on: router)
        #expect(router.hasHostSettlementWaiters)
        presentation.cancel()
        await #expect(throws: CancellationError.self) {
            try await presentation.value
        }
        #expect(router.hostSettlementWaiterCount == 0)
        #expect(router.isSettlingHostDeactivation)
        #expect(router.launch == nil)
        #expect(try fetchReports(fixture.container).isEmpty)
        router.completeHostDeactivation(
            hostID: firstHost, reportID: firstLaunch.id,
            leaseID: firstLease, succeeded: true
        )
    }

    @Test("Settlement waiters are bounded and individually removed on cancellation")
    @MainActor
    func settlementWaitersStayBounded() async throws {
        let router = FeedbackReportRouter()
        let hostID = UUID()
        let leaseID = UUID()
        let launch = FeedbackReportLaunch(hostID: hostID, entryPoint: .help)
        try mountLaunch(launch, on: router, hostID: hostID, leaseID: leaseID)
        router.unregister(hostID: hostID, leaseID: leaseID)
        var waiters: [Task<Void, Error>] = []
        for _ in 0..<FeedbackReportRouter.maximumHostSettlementWaiters {
            waiters.append(Task { @MainActor in
                try await router.waitForHostSettlement()
            })
        }
        await waitForSettlementWaiters(
            on: router, count: FeedbackReportRouter.maximumHostSettlementWaiters
        )
        #expect(router.hostSettlementWaiterCount == FeedbackReportRouter.maximumHostSettlementWaiters)
        await #expect(throws: FeedbackReportCoordinatorError.hostSettlementWaiterLimitReached) {
            try await router.waitForHostSettlement()
        }
        waiters.forEach { $0.cancel() }
        var cancelled = 0
        for waiter in waiters {
            do { try await waiter.value }
            catch is CancellationError { cancelled += 1 }
        }
        #expect(cancelled == FeedbackReportRouter.maximumHostSettlementWaiters)
        #expect(router.hostSettlementWaiterCount == 0)
        #expect(router.isSettlingHostDeactivation)
        router.completeHostDeactivation(
            hostID: hostID, reportID: launch.id, leaseID: leaseID, succeeded: true
        )
    }

    @Test("Close policy covers unsaved, draft, prepared, and queued reports")
    func closePolicyMatrix() {
        func action(_ stored: Bool, _ status: FeedbackLocalStatusV1?, _ meaningful: Bool) -> FeedbackReportCloseAction {
            FeedbackReportClosePolicy.action(
                hasStoredReport: stored, storedStatus: status, hasMeaningfulProgress: meaningful,
                isPreparing: meaningful, hasPreview: meaningful, isInvalidatingPreview: meaningful
            )
        }
        #expect(action(false, nil, true) == .offerDraftChoices)
        #expect(action(true, .draft, false) == .offerDraftChoices)
        #expect(action(true, .prepared, true) == .offerPreparedDiscard)
        #expect(action(true, .queued, true) == .closePresentation)
    }

    @Test("Prepared Close offers discard while queued Close is presentation-only")
    @MainActor
    func closeAfterPreparationDoesNotMutate() async throws {
        let fixture = try makePresentationFixture()
        defer { fixture.cleanup() }
        let launch = presentationLaunch()
        let form = validPresentationForm()
        let service = FeedbackReportPreparationService(
            modelContainer: fixture.container,
            crashOfferService: fixture.crashService,
            storageRoot: fixture.root,
            defaults: fixture.defaults,
            evidenceSourceProvider: { _, _, _ in .empty }
        )
        let preview = try await service.preparePreview(launch: launch, form: form)
        try service.confirmPreparedPreview(preview, launch: launch, form: form)
        let preparedPackage = try FeedbackOutboxService(
            modelContainer: fixture.container,
            storageRoot: fixture.root
        ).recoverablePreparedPackage(reportID: launch.id)
        let adoptedReportURL = preparedPackage.directoryURL
            .appendingPathComponent(FeedbackEvidencePolicy.reportFileName)
        let packageBytes = try Data(contentsOf: adoptedReportURL)
        #expect(FeedbackReportClosePolicy.action(
            hasStoredReport: true,
            storedStatus: .prepared,
            hasMeaningfulProgress: true,
            isPreparing: false,
            hasPreview: true,
            isInvalidatingPreview: false
        ) == .offerPreparedDiscard)
        #expect(try fetchPresentationReport(fixture.container, id: launch.id)?.localStatus == .prepared)
        #expect(try Data(contentsOf: adoptedReportURL) == packageBytes)

        let recovered = try service.restoredPreparedPreview(
            reportID: launch.id,
            launch: launch,
            form: form
        )
        try service.confirmAndQueue(recovered, launch: launch, form: form)
        let router = FeedbackReportRouter()
        let leaseID = UUID()
        router.register(hostID: launch.hostID, leaseID: leaseID)
        try router.activate(launch, hostLeaseID: leaseID)
        var offeredDraftChoices = false
        FeedbackReportClosePolicy.perform(
            hasStoredReport: true,
            storedStatus: .queued,
            hasMeaningfulProgress: true,
            isPreparing: false,
            hasPreview: false,
            isInvalidatingPreview: false,
            offerDraftChoices: { offeredDraftChoices = true },
            offerPreparedDiscard: { Issue.record("Queued report must not offer discard") },
            closePresentation: {
                router.dismiss(hostID: launch.hostID, reportID: launch.id, leaseID: leaseID)
            }
        )
        #expect(!offeredDraftChoices)
        #expect(router.launch == nil)
        let queued = try #require(try fetchPresentationReport(fixture.container, id: launch.id))
        #expect(queued.localStatus == .queued)
        #expect(queued.uploadAttemptCount == 0)
        #expect(try Data(contentsOf: adoptedReportURL) == packageBytes)
    }

    @Test("Crash alert policy declines only an explicit Not Now action")
    func crashAlertDismissalDoesNotDecline() {
        #expect(!FeedbackCrashAlertPolicy.shouldDecline(for: .reportProblem))
        #expect(!FeedbackCrashAlertPolicy.shouldDecline(for: .presentationDismissed))
        #expect(FeedbackCrashAlertPolicy.shouldDecline(for: .decline))
    }

    @Test("Crash readiness never invokes the monitor when outbox recovery fails")
    func crashReadinessFailsClosed() async {
        let monitorCalls = LockedInt()
        await #expect(throws: FeedbackReadinessTestError.outboxCorrupt) {
            _ = try await FeedbackCrashOfferReadiness.claimNext(
                recoverableReportIDs: { throw FeedbackReadinessTestError.outboxCorrupt },
                claim: { _ in monitorCalls.increment(); return nil }
            )
        }
        #expect(monitorCalls.value == 0)
    }

    @Test("Task failure prefill never contains hostile event or provider output")
    func taskFailurePrefillUsesOnlyAllowlist() {
        let hostile = "Bearer ghp_super_secret provider@example.com"
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let context = FeedbackTaskFailureReportContextBuilder.make(
            runtimeID: "codex_cli", providerVersion: "1.2.3",
            status: .failed, exitCode: 1,
            stopReason: "provider_process_failed", startedAt: completedAt.addingTimeInterval(-1_000),
            completedAt: completedAt
        )
        #expect(!context.prefill.actualResult.contains(hostile))
        #expect(context.runtimeEvidence?.sanitizedSummary.orEmpty.contains(hostile) == false)
        #expect(context.prefill.actualResult == "The provider run stopped before completing."); #expect(context.taskFailureOccurredAt == completedAt)
    }

    @Test("Task failure mapping preserves root-cause ownership")
    func taskFailureMappingPreservesRootCause() {
        let cases: [(RunStatus, String, String, String)] = [
            (.timeout, TaskRunStopReason.timeout.rawValue, "runtime_timed_out", "The provider run timed out before completing."),
            (.budgetExceeded, TaskRunStopReason.maxBudgetReached.rawValue, "budget_exceeded", "ASTRA stopped the run at its configured budget limit."),
            (.failed, TaskRunStopReason.policyBlocked.rawValue, "astra_policy_blocked", "ASTRA stopped the run because a safety or permission policy blocked it."),
            (.failed, TaskRunStopReason.validationContractFailed.rawValue, "astra_validation_failed", "ASTRA stopped the run because required validation did not pass."),
            (.failed, TaskRunStopReason.deliverableVerificationFailed.rawValue, "astra_deliverable_verification_failed", "ASTRA stopped the run because the required deliverable could not be verified."),
            (.failed, TaskRunStopReason.connectorPreflightFailed.rawValue, "connector_preflight_failed", "ASTRA could not prepare a required connector before launch."),
            (.failed, TaskRunStopReason.capabilityRuntimeResourcesMissing.rawValue, "capability_resources_missing", "ASTRA could not find runtime resources required by the selected capability."),
            (.failed, "mcp_server_executable_missing", "missing", "ASTRA could not find a required runtime executable or workspace."),
            (.failed, "runtime_readiness_failed", "misconfigured", "ASTRA stopped before launch because runtime readiness was blocked."),
            (.failed, TaskRunStopReason.dockerDaemonUnavailable.rawValue, "runtime_environment_unavailable", "ASTRA could not prepare the configured execution environment."),
            (.failed, TaskRunStopReason.credentialProjectionRequired.rawValue, "unauthenticated", "The run could not authenticate with the selected provider or connector."),
            (.failed, "rate_limited", "rate_limited", "The provider rate-limited the run."),
            (.failed, "quota_exhausted", "quota_limited", "The provider stopped the run because its quota was unavailable."),
            (.failed, "model_unavailable", "misconfigured", "The selected runtime or provider configuration was unavailable."),
            (.failed, "unsupported_output_format", "misconfigured", "The selected runtime or provider configuration was unavailable."),
            (.failed, TaskRunStopReason.providerPermissionUnresumable.rawValue, "permission_denied", "The provider could not continue with the approved permissions."),
            (.failed, "sandbox_credential_access_blocked", "permission_denied", "The provider could not continue with the approved permissions."),
            (.failed, "network_failed", "provider_process_failed", "The provider run stopped after a network failure."),
            (.failed, "no_visible_output", "provider_process_failed", "The provider exited without returning a visible result."),
            (.failed, TaskRunStopReason.failed.rawValue, "provider_process_failed", "The provider run stopped before completing."),
        ]

        for (status, reason, category, summary) in cases {
            let context = FeedbackTaskFailureReportContextBuilder.make(
                runtimeID: "codex_cli",
                providerVersion: "1.2.3",
                status: status,
                exitCode: 1,
                stopReason: reason
            )
            #expect(context.runtimeEvidence?.failureCategory == category)
            #expect(context.runtimeEvidence?.sanitizedSummary == summary)
            #expect(context.prefill.actualResult == summary)
            #expect(!context.prefill.expectedResult.isEmpty)
        }
    }

    @Test("Runtime worker durably retains every classified failure category")
    func runtimeWorkerRetainsClassifiedFailureCategory() {
        for category in AgentRuntimeFailureCategory.allCases {
            let reason = AgentRuntimeWorker.durableFailureStopReason(category: category)
            let expected = category == .providerProcessFailed
                ? TaskRunStopReason.failed.rawValue
                : category.rawValue
            #expect(reason.rawValue == expected)
        }
        #expect(
            AgentRuntimeWorker.durableFailureStopReason(category: nil)
                == TaskRunStopReason.failed
        )
    }

    @Test("Every native runtime missing reason reaches the provider-neutral snapshot")
    func nativeRuntimeMissingReasonsMapToSnapshot() throws {
        let cases = [
            ("claude_code", "missing_claude"),
            ("copilot_cli", "missing_copilot"),
            ("antigravity_cli", "missing_antigravity"),
            ("codex_cli", "missing_codex"),
            ("cursor_cli", "missing_cursor"),
            ("opencode_cli", "missing_opencode"),
        ]
        for (runtimeID, stopReason) in cases {
            let context = FeedbackTaskFailureReportContextBuilder.make(
                runtimeID: runtimeID,
                providerVersion: nil,
                status: .failed,
                exitCode: nil,
                stopReason: stopReason
            )
            let snapshot = try #require(
                RuntimeFeedbackSnapshotBuilder().build(from: context.runtimeEvidence)
            )
            #expect(snapshot.failureCategory == .missing)
            #expect(snapshot.executableFound == false)
            #expect(snapshot.unavailableReason == .unavailable)
        }
    }

    @Test("Missing workspace or MCP resource never claims the provider executable is absent")
    func nonRuntimeMissingReasonsDoNotMislabelExecutable() throws {
        for stopReason in [TaskRunStopReason.workspaceNotFound.rawValue, "mcp_server_executable_missing"] {
            let context = FeedbackTaskFailureReportContextBuilder.make(
                runtimeID: "codex_cli",
                providerVersion: nil,
                status: .failed,
                exitCode: nil,
                stopReason: stopReason
            )
            #expect(context.runtimeEvidence?.executableFound == nil)
            let snapshot = try #require(
                RuntimeFeedbackSnapshotBuilder().build(from: context.runtimeEvidence)
            )
            #expect(snapshot.failureCategory == .missing)
            #expect(snapshot.executableFound == nil)
            #expect(snapshot.unavailableReason == nil)
        }
    }

    @Test("Every local state has deterministic status presentation and accessibility IDs")
    func statusesAndAccessibility() {
        for status in FeedbackLocalStatusV1.allCases {
            let value = FeedbackReportStatusPresentation.make(status: status)
            #expect(!value.title.isEmpty)
            #expect(!value.detail.isEmpty)
            #expect(!value.symbol.isEmpty)
        }
        #expect(!FeedbackReportAccessibilityID.queue.isEmpty)
        #expect(!FeedbackReportAccessibilityID.macOSDiagnostics.isEmpty)
        #expect(FeedbackReportRuntimeAvailability.canReport(runtimeEvidence: nil))
        #expect(Set(FeedbackReportDismissChoice.allCases) == [.keepDraft, .discard])
    }

    @Test("Help Logs and task failures route through the shared report boundary")
    func productionEntryPointsStayWired() throws {
        let root = try TestRepositoryRoot.resolve()
        let app = try String(
            contentsOf: root.appendingPathComponent("Astra/ASTRAApp.swift"),
            encoding: .utf8
        )
        let content = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )
        let logs = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/LogViewerView.swift"),
            encoding: .utf8
        )
        let task = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/TaskMainView.swift"),
            encoding: .utf8
        )
        let preparation = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Feedback/FeedbackReportPreparationService.swift"),
            encoding: .utf8
        )
        let integration = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/Feedback/FeedbackContentViewIntegration.swift"),
            encoding: .utf8
        )

        #expect(app.contains("Report a Problem…"))
        #expect(app.contains("ReportProblemMenuItem()"))
        #expect(app.contains("FeedbackPreparationStagingReconciler().reconcileAbandonedPackages()"))
        #expect(app.contains(".recoverInterruptedAdoptions()"))
        #expect(content.contains("presentGeneralFeedback(from: .help)"))
        #expect(content.contains(".feedbackReportSheetHost(feedbackHostID)"))
        #expect(logs.contains("presentFeedback()"))
        #expect(logs.contains("from: .logs"))
        #expect(task.contains("case .reportProblem:"))
        #expect(task.contains("reportCurrentFailure()"))
        #expect(!preparation.contains("func queue(reportID:"))
        let crashAlertStart = try #require(integration.range(of: ".alert(\"ASTRA closed unexpectedly\""))
        let nextAlert = try #require(integration.range(
            of: ".alert(\"Feedback unavailable\"",
            range: crashAlertStart.upperBound..<integration.endIndex
        ))
        let crashAlert = String(integration[crashAlertStart.lowerBound..<nextAlert.lowerBound])
        #expect(crashAlert.contains("set: { _ in }"))
        #expect(crashAlert.contains("Button(\"Report a Problem\") { presentOffer() }"))
        #expect(crashAlert.contains("Button(\"Not Now\", role: .cancel) { declineOffer() }"))
        #expect(crashAlert.components(separatedBy: "declineOffer()").count - 1 == 1)
    }

    @Test("Interaction policy autosaves cleared drafts and keeps prepared queue retry reachable")
    func interactionPolicyClosesPersistenceGaps() {
        let emptyNew = FeedbackReportInteractionPolicy.make(
            hasStoredReport: false,
            storedStatus: nil,
            hasExactPreview: false,
            hasMeaningfulProgress: false
        )
        #expect(!emptyNew.shouldAutosave)

        let clearedDraft = FeedbackReportInteractionPolicy.make(
            hasStoredReport: true,
            storedStatus: .draft,
            hasExactPreview: false,
            hasMeaningfulProgress: false
        )
        #expect(clearedDraft.shouldAutosave)
        #expect(clearedDraft.canEdit)
        #expect(clearedDraft.canPrepare)
        #expect(!clearedDraft.canQueue)

        let reviewedDraft = FeedbackReportInteractionPolicy.make(
            hasStoredReport: true,
            storedStatus: .draft,
            hasExactPreview: true,
            hasMeaningfulProgress: true
        )
        #expect(reviewedDraft.canQueue)
        #expect(reviewedDraft.canEdit)
        #expect(reviewedDraft.canPrepare)

        let preparedRetry = FeedbackReportInteractionPolicy.make(
            hasStoredReport: true,
            storedStatus: .prepared,
            hasExactPreview: true,
            hasMeaningfulProgress: true
        )
        #expect(preparedRetry.canQueue)
        #expect(!preparedRetry.canEdit)
        #expect(!preparedRetry.canPrepare)
        #expect(!preparedRetry.shouldAutosave)

        let corrupt = FeedbackReportInteractionPolicy.make(
            hasStoredReport: true,
            storedStatus: nil,
            hasExactPreview: true,
            hasMeaningfulProgress: true
        )
        #expect(!corrupt.canQueue)
        #expect(!corrupt.canEdit)
        #expect(!corrupt.canPrepare)
    }
}

private extension FeedbackReportRequiredField {
    static let allTestCases: [Self] = [.intendedOutcome, .actualResult, .expectedResult]
}

@MainActor
private func mountLaunch(
    _ launch: FeedbackReportLaunch, on router: FeedbackReportRouter,
    hostID: UUID, leaseID: UUID
) throws {
    router.register(hostID: hostID, leaseID: leaseID)
    try router.activate(launch, hostLeaseID: leaseID)
    router.markPresentationMounted(hostID: hostID, reportID: launch.id, leaseID: leaseID)
}

@MainActor
private func waitForSettlementWaiters(
    on router: FeedbackReportRouter, count: Int = 1
) async {
    for _ in 0..<100 {
        if router.hostSettlementWaiterCount == count { return }
        await Task.yield()
    }
}
private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
private enum FeedbackReadinessTestError: Error {
    case outboxCorrupt
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
    func incrementAndGet() -> Int { lock.withLock { storage += 1; return storage } }
}


private final class LockedDateInterval: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: DateInterval?
    var value: DateInterval? { lock.withLock { storage } }
    func set(_ value: DateInterval) { lock.withLock { storage = value } }
}

private final class ThreadObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var providerMain: Bool?
    private var builderMain: Bool?
    var providerWasMain: Bool? { lock.withLock { providerMain } }
    var builderWasMain: Bool? { lock.withLock { builderMain } }
    func recordProvider(isMain: Bool) { lock.withLock { providerMain = isMain } }
    func recordBuilder(isMain: Bool) { lock.withLock { builderMain = isMain } }
}

@MainActor
private final class EmptyCrashLedger: FeedbackCrashOfferLedgerReading {
    func validateOffer(_ offer: FeedbackCrashOffer) async throws -> Bool { false }
    func verifiedLink(fingerprint: String, consentVersion: String) throws -> FeedbackCrashVerifiedLink? { nil }
    func linkedReportIDs() throws -> Set<UUID> { [] }
    func reconcileOfferedReport(
        fingerprint: String,
        consentVersion: String,
        reportID: UUID
    ) throws -> FeedbackCrashVerifiedLink {
        throw FeedbackCrashOfferError.offerNotFound
    }
}

struct PresentationFixture {
    let container: ModelContainer
    let root: URL
    let defaults: UserDefaults
    let crashService: FeedbackCrashOfferService
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
    }
}

@MainActor
func makePresentationFixture() throws -> PresentationFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("feedback-presentation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = ephemeralDefaults()
    return PresentationFixture(
        container: try makeFeedbackOutboxContainer(),
        root: root,
        defaults: defaults,
        crashService: FeedbackCrashOfferService(defaults: defaults)
    )
}

private func ephemeralDefaults() -> UserDefaults {
    let name = "feedback-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.set(name, forKey: "_suiteName")
    return defaults
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "_suiteName") ?? ""
}

func presentationLaunch() -> FeedbackReportLaunch {
    FeedbackReportLaunch(hostID: UUID(), entryPoint: .help)
}

func validPresentationForm() -> FeedbackReportFormState {
    var form = FeedbackReportFormState(
        launch: presentationLaunch(),
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    form.intendedOutcome = "Complete a report"
    form.actualResult = "The operation stopped"
    form.expectedResult = "The operation completes"
    return form
}

private func draftProgress(taskID: UUID?, runID: UUID?) -> FeedbackDraftProgress {
    FeedbackDraftProgress(
        intendedOutcome: "",
        actualResult: "Partial observation",
        expectedResult: "",
        workBlocked: true,
        taskID: taskID?.uuidString.lowercased(),
        runID: runID?.uuidString.lowercased(),
        evidenceWindow: FeedbackEvidenceWindowV1(
            start: Date(timeIntervalSince1970: 1_799_999_100),
            end: Date(timeIntervalSince1970: 1_800_000_000)
        ),
        consent: FeedbackConsentV1(
            version: FeedbackReportFormState.consentVersion,
            evidenceSelections: [
                FeedbackEvidenceSelectionV1(
                    artifactID: "browser-evidence",
                    disclosureClass: .explicitOptIn,
                    included: true,
                    reviewedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            ]
        )
    )
}

private func browserRecord() -> FeedbackBrowserEvidenceRecord {
    FeedbackBrowserEvidenceRecord(
        sequence: 1,
        createdAt: Date(),
        method: "GET",
        path: "/safe",
        statusCode: 200,
        durationMilliseconds: 10,
        beforeHost: "example.com",
        afterHost: "example.com",
        urlChanged: false,
        succeeded: true,
        errorCode: nil,
        observedOutcome: nil
    )
}

private func crashFileSummary(_ url: URL) -> CrashReportSummary {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return CrashReportSummary(
        url: url,
        appName: "ASTRA Dev",
        modifiedAt: values?.contentModificationDate ?? Date(),
        sizeBytes: Int64(values?.fileSize ?? 0),
        kind: .crash
    )
}

@MainActor
private func fetchReports(_ container: ModelContainer) throws -> [FeedbackReport] {
    try ModelContext(container).fetch(FetchDescriptor<FeedbackReport>())
}

@MainActor
func fetchPresentationReport(_ container: ModelContainer, id: UUID) throws -> FeedbackReport? {
    let value = id
    return try ModelContext(container).fetch(FetchDescriptor<FeedbackReport>(
        predicate: #Predicate { $0.id == value }
    )).first
}
