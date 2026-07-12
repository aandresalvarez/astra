import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum FeedbackReportRequiredField: String, Equatable, Sendable {
    case intendedOutcome
    case actualResult
    case expectedResult
}

struct FeedbackReportFormState: Equatable, Sendable {
    static let consentVersion = "feedback-consent-v1"
    static let defaultEvidenceWindow: TimeInterval = 15 * 60

    var intendedOutcome: String
    var actualResult: String
    var expectedResult: String
    var workBlocked: Bool
    var evidenceWindowStart: Date
    var evidenceWindowEnd: Date
    var selections: FeedbackEvidenceSelections

    init(launch: FeedbackReportLaunch, now: Date = Date()) {
        intendedOutcome = launch.prefill.intendedOutcome
        actualResult = launch.prefill.actualResult
        expectedResult = launch.prefill.expectedResult
        workBlocked = launch.prefill.workBlocked
        let defaultStart = now.addingTimeInterval(-Self.defaultEvidenceWindow)
        let crashDates = launch.crashReports.map { min($0.modifiedAt, now) }
        if let oldestCrashDate = crashDates.min(),
           let newestCrashDate = crashDates.max() {
            // Crash offers can survive across launches. Anchor the bounded window
            // to the crash cohort instead of to the current launch so an older
            // offered diagnostic cannot be filtered out of its own report.
            evidenceWindowEnd = min(now, newestCrashDate.addingTimeInterval(1))
            evidenceWindowStart = max(
                evidenceWindowEnd.addingTimeInterval(-FeedbackContractLimitsV1.maximumEvidenceWindow),
                min(
                    evidenceWindowEnd.addingTimeInterval(-Self.defaultEvidenceWindow),
                    oldestCrashDate.addingTimeInterval(-1)
                )
            )
        } else if launch.entryPoint == .taskFailure,
                  let taskFailureOccurredAt = launch.taskFailureOccurredAt {
            // A report action can be opened well after the failed run. Anchor
            // the default selected logs to the failure rather than sheet-open
            // time so the run being reported remains inside its own evidence.
            evidenceWindowEnd = min(now, taskFailureOccurredAt)
            evidenceWindowStart = max(
                evidenceWindowEnd.addingTimeInterval(-FeedbackContractLimitsV1.maximumEvidenceWindow),
                evidenceWindowEnd.addingTimeInterval(-Self.defaultEvidenceWindow)
            )
        } else {
            evidenceWindowEnd = now
            evidenceWindowStart = defaultStart
        }
        selections = FeedbackEvidenceSelections()
        // A task-log selection is meaningful only when the report is bound to
        // one exact task. General Help/Logs reports must not claim an evidence
        // class that the source reader cannot identify without broadening the
        // disclosure to unrelated tasks.
        if launch.taskID == nil {
            selections.includeTaskLogs = false
        }
    }

    var hasRequiredStatement: Bool { missingRequiredField == nil }

    var missingRequiredField: FeedbackReportRequiredField? {
        if intendedOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .intendedOutcome
        }
        if actualResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .actualResult
        }
        if expectedResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .expectedResult
        }
        return nil
    }

    var evidenceWindow: FeedbackEvidenceWindowV1 {
        FeedbackEvidenceWindowV1(start: evidenceWindowStart, end: evidenceWindowEnd)
    }
}

struct FeedbackReportEvidenceSource: Sendable {
    var applicationLogEntries: [LogEntry]
    var taskLogEntries: [LogEntry]
    var browserRecords: [FeedbackBrowserEvidenceRecord]
    var screenshots: [FeedbackScreenshotCandidate]
    var crashReports: [CrashReportSummary]

    static let empty = FeedbackReportEvidenceSource(
        applicationLogEntries: [],
        taskLogEntries: [],
        browserRecords: [],
        screenshots: [],
        crashReports: []
    )
}

/// An exact, reviewable package still owned by trusted same-volume staging.
/// Confirmation succeeds only for the same form and durable reporting context.
struct FeedbackReportPreparedPreview: Equatable, Sendable {
    enum Ownership: Equatable, Sendable {
        case trustedStaging
        case adoptedOutbox
    }

    let reportID: UUID
    let contextIdentity: FeedbackReportContextIdentity
    let form: FeedbackReportFormState
    let reviewedAt: Date
    let package: FeedbackPreparedEvidencePackage
    let ownership: Ownership

    var manifest: FeedbackEvidenceManifestV1 { package.manifest }
}

enum FeedbackReportPreparationError: Error, Equatable {
    case missingRequiredField(FeedbackReportRequiredField)
    case reportMissingAfterDraftSave
    case reportIsNotDraft
    case stalePreparedPreview
    case stagedPackageChangedAfterReview
    case unsafeStagingPath
    case stagingCleanupFailed(String)
    case cancelledPreviewCleanupFailed(FeedbackReportPreparedPreview, String)
    case crashEvidenceChanged
}

enum FeedbackReportStoragePaths {
    static var root: URL {
        WorkspaceRecoveryService.applicationSupportDirectory
            .appendingPathComponent("Feedback", isDirectory: true)
    }

    static func preparationRoot(storageRoot: URL) -> URL {
        storageRoot.appendingPathComponent("Preparation", isDirectory: true)
    }
}

struct FeedbackInstallationIdentityStore {
    private let defaults: UserDefaults
    private let key: String
    private let makeUUID: () -> UUID

    init(
        defaults: UserDefaults = .standard,
        key: String = AppStorageKeys.feedbackInstallationID,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.defaults = defaults
        self.key = key
        self.makeUUID = makeUUID
    }

    func value() -> FeedbackInstallationIDV1 {
        if let existing = defaults.string(forKey: key),
           let parsed = UUID(uuidString: existing),
           parsed.uuidString.lowercased() == existing {
            return FeedbackInstallationIDV1(rawValue: existing)
        }
        let created = makeUUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return FeedbackInstallationIDV1(rawValue: created)
    }
}

@MainActor
struct FeedbackReportPreparationService {
    typealias EvidenceSourceProvider = @Sendable (
        _ launch: FeedbackReportLaunch,
        _ selections: FeedbackEvidenceSelections,
        _ interval: DateInterval
    ) throws -> FeedbackReportEvidenceSource
    typealias PackageBuilder = @Sendable (
        _ input: FeedbackEvidenceInput,
        _ selections: FeedbackEvidenceSelections,
        _ directory: URL
    ) throws -> FeedbackPreparedEvidencePackage

    private let modelContainer: ModelContainer
    private let storageRoot: URL
    private let identityStore: FeedbackInstallationIdentityStore
    private let crashOfferService: FeedbackCrashOfferService
    private let evidenceSourceProvider: EvidenceSourceProvider
    private let packageBuilder: PackageBuilder
    private let buildInfo: AppBuildInfo
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    init(
        modelContainer: ModelContainer,
        crashOfferService: FeedbackCrashOfferService,
        storageRoot: URL = FeedbackReportStoragePaths.root,
        defaults: UserDefaults = .standard,
        evidenceSourceProvider: @escaping EvidenceSourceProvider = {
            try FeedbackReportEvidenceSourceReader.collect(
                launch: $0,
                selections: $1,
                interval: $2
            )
        },
        packageBuilder: @escaping PackageBuilder = {
            try FeedbackEvidenceBuilder().prepare(input: $0, selections: $1, directory: $2)
        },
        buildInfo: AppBuildInfo = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.modelContainer = modelContainer
        self.storageRoot = storageRoot
        self.crashOfferService = crashOfferService
        identityStore = FeedbackInstallationIdentityStore(defaults: defaults)
        self.evidenceSourceProvider = evidenceSourceProvider
        self.packageBuilder = packageBuilder
        self.buildInfo = buildInfo
        self.now = now
        self.fileManager = fileManager
    }

    /// Saves the durable draft first, then collects and builds away from the
    /// main actor. The returned package remains staged for exact user review.
    func preparePreview(
        launch: FeedbackReportLaunch,
        form: FeedbackReportFormState,
        replacing previous: FeedbackReportPreparedPreview? = nil
    ) async throws -> FeedbackReportPreparedPreview {
        if let missing = form.missingRequiredField {
            throw FeedbackReportPreparationError.missingRequiredField(missing)
        }
        let reviewedAt = now()
        let requestedConsent = Self.requestedConsent(
            selections: form.selections,
            reviewedAt: reviewedAt
        )
        try Self.validateRequestedForm(form, consent: requestedConsent)
        let requestedContents = contents(
            form: form,
            launch: launch,
            consent: requestedConsent
        )
        try await validateCrashIdentity(launch)
        if let previous {
            try invalidatePreparedPreview(previous)
        }

        let outbox = try makeOutbox()
        if let existing = try report(id: launch.id) {
            guard try existing.requireLocalStatus() == .draft else {
                throw FeedbackReportPreparationError.reportIsNotDraft
            }
            guard existing.taskID == launch.taskID?.uuidString.lowercased(),
                  existing.runID == launch.runID?.uuidString.lowercased()
            else { throw FeedbackReportResumeError.contextMismatch }
            try outbox.updateDraft(reportID: launch.id, contents: requestedContents)
        } else {
            _ = try outbox.createDraft(
                reportID: launch.id,
                installationID: identityStore.value(),
                contents: requestedContents
            )
        }

        guard let durableDraft = try report(id: launch.id) else {
            throw FeedbackReportPreparationError.reportMissingAfterDraftSave
        }
        let canonicalWindow = Self.canonicalEvidenceWindow(form.evidenceWindow)
        let interval = DateInterval(start: canonicalWindow.start, end: canonicalWindow.end)
        let preparationRoot = FeedbackReportStoragePaths.preparationRoot(storageRoot: storageRoot)
        let provider = evidenceSourceProvider
        let builder = packageBuilder
        let buildInfo = buildInfo
        let reportID = launch.id
        // The V1 canonical encoder writes timestamps at millisecond precision.
        // Use that same stable representation for both the builder input and
        // envelope so an arbitrary SwiftData sub-millisecond remainder cannot
        // make the package reject its own report bytes.
        let createdAt = Self.canonicalTimestamp(durableDraft.createdAt)
        let installationID = FeedbackInstallationIDV1(rawValue: durableDraft.installationID)
        let idempotencyKey = durableDraft.idempotencyKey
        let worker = Task.detached(priority: .userInitiated) {
            let source = try provider(launch, form.selections, interval)
            try Task.checkCancellation()
            let runtimeSnapshot = RuntimeFeedbackSnapshotBuilder().build(from: launch.runtimeEvidence)
            let envelopeData: @Sendable (FeedbackEvidenceManifestV1) throws -> Data = { manifest in
                let consent = Self.exactConsent(
                    manifest: manifest,
                    version: FeedbackReportFormState.consentVersion,
                    reviewedAt: reviewedAt
                )
                return try FeedbackReportEnvelopeFactory.makeData(
                    reportID: reportID,
                    installationID: installationID,
                    idempotencyKey: idempotencyKey,
                    createdAt: createdAt,
                    form: form,
                    launch: launch,
                    consent: consent,
                    runtimeSnapshot: runtimeSnapshot,
                    manifest: manifest,
                    buildInfo: buildInfo
                )
            }
            let input = FeedbackEvidenceInput(
                reportID: reportID,
                reportCreatedAt: createdAt,
                applicationLogEntries: source.applicationLogEntries,
                taskLogEntries: source.taskLogEntries,
                browserRecords: source.browserRecords,
                screenshots: source.screenshots,
                crashReports: source.crashReports,
                makeReportEnvelopeData: envelopeData
            )
            return try builder(input, form.selections, preparationRoot)
        }

        let package: FeedbackPreparedEvidencePackage
        do {
            package = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            worker.cancel()
            throw error
        }
        let preview = FeedbackReportPreparedPreview(
            reportID: reportID,
            contextIdentity: launch.contextIdentity,
            form: form,
            reviewedAt: reviewedAt,
            package: package,
            ownership: .trustedStaging
        )
        do {
            try Task.checkCancellation()
        } catch {
            do {
                try removeTrustedStagingPackage(at: package.directoryURL, reportID: reportID)
            } catch FeedbackReportPreparationError.stagingCleanupFailed(let message) {
                // Retry inside the capability-owning boundary so cleanup that
                // finishes after a view timeout cannot strand private staging.
                // The first failure still propagates through the typed receipt.
                do {
                    try removeTrustedStagingPackage(at: package.directoryURL, reportID: reportID)
                } catch FeedbackReportPreparationError.stagingCleanupFailed(let retryMessage) {
                    throw FeedbackReportPreparationError.cancelledPreviewCleanupFailed(
                        preview, retryMessage
                    )
                }
                throw FeedbackReportPreparationError.cancelledPreviewCleanupFailed(preview, message)
            }
            throw error
        }
        return preview
    }

    private func validateCrashIdentity(_ launch: FeedbackReportLaunch) async throws {
        guard let expected = launch.crashFingerprint else { return }
        guard launch.crashReports.count == 1, let report = launch.crashReports.first else {
            throw FeedbackReportPreparationError.crashEvidenceChanged
        }
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return FeedbackCrashFingerprint.make(report)
        }
        do {
            let current = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard current == expected else {
                throw FeedbackReportPreparationError.crashEvidenceChanged
            }
        } catch {
            worker.cancel()
            throw error
        }
    }

    func saveProgress(launch: FeedbackReportLaunch, form: FeedbackReportFormState) throws {
        let outbox = try makeOutbox()
        let value = progress(form: form, launch: launch)
        if try report(id: launch.id) == nil {
            _ = try outbox.createDraftProgress(
                reportID: launch.id,
                installationID: identityStore.value(),
                progress: value
            )
        } else {
            try outbox.updateDraftProgress(reportID: launch.id, progress: value)
        }
        if let fingerprint = launch.crashFingerprint {
            try crashOfferService.confirmReportCreated(
                fingerprint: fingerprint,
                consentVersion: FeedbackReportFormState.consentVersion,
                reportID: launch.id
            )
        }
    }

    func restoredForm(reportID: UUID, launch: FeedbackReportLaunch) throws -> FeedbackReportFormState {
        let snapshot = try makeOutbox().recoverableSnapshot(reportID: reportID)
        guard snapshot.progress.taskID == launch.taskID?.uuidString.lowercased(),
              snapshot.progress.runID == launch.runID?.uuidString.lowercased()
        else { throw FeedbackReportResumeError.contextMismatch }
        var form = FeedbackReportFormState(launch: launch, now: snapshot.progress.evidenceWindow.end)
        form.intendedOutcome = snapshot.progress.intendedOutcome
        form.actualResult = snapshot.progress.actualResult
        form.expectedResult = snapshot.progress.expectedResult
        form.workBlocked = snapshot.progress.workBlocked
        form.evidenceWindowStart = snapshot.progress.evidenceWindow.start
        form.evidenceWindowEnd = snapshot.progress.evidenceWindow.end
        form.selections = Self.selections(from: snapshot.progress.consent)
        if launch.taskID == nil {
            form.selections.includeTaskLogs = false
        }
        return form
    }

    func restoredPreparedPreview(
        reportID: UUID,
        launch: FeedbackReportLaunch,
        form: FeedbackReportFormState
    ) throws -> FeedbackReportPreparedPreview {
        guard reportID == launch.id else {
            throw FeedbackReportPreparationError.stalePreparedPreview
        }
        let recovery = try makeOutbox().recoverablePreparedPackage(reportID: reportID)
        let package = FeedbackPreparedEvidencePackage(
            reportID: reportID,
            reportCreatedAt: recovery.reportCreatedAt,
            directoryURL: recovery.directoryURL,
            reportURL: recovery.directoryURL.appendingPathComponent(FeedbackEvidencePolicy.reportFileName),
            archiveURL: recovery.directoryURL.appendingPathComponent(FeedbackEvidencePolicy.archiveFileName),
            manifestURL: recovery.directoryURL.appendingPathComponent(FeedbackEvidencePolicy.manifestFileName),
            manifest: recovery.manifest,
            manifestSHA256: recovery.manifestSHA256,
            reportSHA256: recovery.reportSHA256,
            archiveSHA256: recovery.archiveSHA256
        )
        let envelope = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportEnvelopeV1.self,
            from: recovery.envelopeData
        )
        let reviewedAt = envelope.payload.consent.evidenceSelections
            .compactMap(\.reviewedAt)
            .max() ?? recovery.reportCreatedAt
        return FeedbackReportPreparedPreview(
            reportID: reportID,
            contextIdentity: launch.contextIdentity,
            form: form,
            reviewedAt: reviewedAt,
            package: package,
            ownership: .adoptedOutbox
        )
    }

    /// Commits exactly the package the user reviewed. It never rebuilds or
    /// accepts a changed form/context under the old preview.
    func confirmPreparedPreview(
        _ preview: FeedbackReportPreparedPreview,
        launch: FeedbackReportLaunch,
        form: FeedbackReportFormState
    ) throws {
        guard preview.reportID == launch.id,
              preview.contextIdentity == launch.contextIdentity,
              preview.form == form,
              preview.ownership == .trustedStaging
        else { throw FeedbackReportPreparationError.stalePreparedPreview }
        try validateStagingURL(preview.package.directoryURL, reportID: launch.id)
        guard let existing = try report(id: launch.id),
              try existing.requireLocalStatus() == .draft
        else { throw FeedbackReportPreparationError.reportIsNotDraft }

        let exactContents = contents(
            form: form,
            launch: launch,
            consent: Self.exactConsent(
                manifest: preview.manifest,
                version: FeedbackReportFormState.consentVersion,
                reviewedAt: preview.reviewedAt
            )
        )
        let outbox = try makeOutbox()
        try outbox.updateDraft(reportID: launch.id, contents: exactContents)
        do {
            try outbox.adoptPreparedPackage(
                reportID: launch.id,
                from: preview.package.directoryURL,
                matching: FeedbackPreparedPackageReview(
                    manifest: preview.package.manifest,
                    manifestSHA256: preview.package.manifestSHA256,
                    reportSHA256: preview.package.reportSHA256,
                    archiveSHA256: preview.package.archiveSHA256
                )
            )
        } catch FeedbackOutboxError.preparedPackageChangedAfterReview {
            throw FeedbackReportPreparationError.stagedPackageChangedAfterReview
        }
    }

    /// Idempotent UI boundary for the local-only PR5 transition. It never
    /// claims an upload. A retry after adoption but before queueing validates
    /// the exact adopted envelope and continues from `.prepared`.
    func confirmAndQueue(
        _ preview: FeedbackReportPreparedPreview,
        launch: FeedbackReportLaunch,
        form: FeedbackReportFormState
    ) throws {
        guard preview.reportID == launch.id,
              preview.contextIdentity == launch.contextIdentity,
              preview.form == form
        else { throw FeedbackReportPreparationError.stalePreparedPreview }
        guard let existing = try report(id: launch.id) else {
            throw FeedbackOutboxError.reportNotFound
        }
        let outbox = try makeOutbox()
        switch try existing.requireLocalStatus() {
        case .draft:
            try confirmPreparedPreview(preview, launch: launch, form: form)
            try outbox.queue(reportID: launch.id)
        case .prepared:
            let recovered = try outbox.recoverablePreparedPackage(reportID: launch.id)
            guard recovered.reportID == preview.reportID,
                  recovered.reportSHA256 == preview.package.reportSHA256,
                  recovered.manifestSHA256 == preview.package.manifestSHA256,
                  recovered.archiveSHA256 == preview.package.archiveSHA256,
                  recovered.manifest == preview.package.manifest,
                  FeedbackCanonicalJSONV1.sha256Hex(recovered.envelopeData) == preview.package.reportSHA256
            else { throw FeedbackReportPreparationError.stalePreparedPreview }
            try outbox.queue(reportID: launch.id)
        case .queued:
            return
        default:
            throw FeedbackOutboxError.illegalTransition(
                from: existing.localStatusRaw,
                to: FeedbackLocalStatusV1.queued.rawValue
            )
        }
    }

    func invalidatePreparedPreview(_ preview: FeedbackReportPreparedPreview) throws {
        guard preview.ownership == .trustedStaging else {
            throw FeedbackReportPreparationError.unsafeStagingPath
        }
        try removeTrustedStagingPackage(at: preview.package.directoryURL, reportID: preview.reportID)
    }

    func discard(reportID: UUID, deleteArtifacts: Bool = true) throws {
        try makeOutbox().cancel(reportID: reportID, deleteArtifacts: deleteArtifacts)
    }

    func settleForHostDeactivation(
        launch: FeedbackReportLaunch,
        form: FeedbackReportFormState,
        preview: FeedbackReportPreparedPreview?,
        shouldPersist: Bool
    ) throws {
        if let preview,
           preview.ownership == .trustedStaging,
           fileManager.fileExists(atPath: preview.package.directoryURL.path) {
            try invalidatePreparedPreview(preview)
        }
        guard shouldPersist else { return }
        if let existing = try report(id: launch.id) {
            guard try existing.requireLocalStatus() == .draft else { return }
        }
        try saveProgress(launch: launch, form: form)
    }

    private func makeOutbox() throws -> FeedbackOutboxService {
        try FeedbackOutboxService(
            modelContainer: modelContainer,
            storageRoot: storageRoot,
            fileManager: fileManager
        )
    }

    private func report(id: UUID) throws -> FeedbackReport? {
        let context = ModelContext(modelContainer)
        let reportID = id
        let descriptor = FetchDescriptor<FeedbackReport>(
            predicate: #Predicate<FeedbackReport> { $0.id == reportID }
        )
        return try context.fetch(descriptor).first
    }

    private func contents(
        form: FeedbackReportFormState,
        launch: FeedbackReportLaunch,
        consent: FeedbackConsentV1
    ) -> FeedbackDraftContents {
        FeedbackDraftContents(
            intendedOutcome: form.intendedOutcome,
            actualResult: form.actualResult,
            expectedResult: form.expectedResult,
            workBlocked: form.workBlocked,
            taskID: launch.taskID?.uuidString.lowercased(),
            runID: launch.runID?.uuidString.lowercased(),
            evidenceWindow: Self.canonicalEvidenceWindow(form.evidenceWindow),
            consent: consent
        )
    }

    nonisolated private static func validateRequestedForm(
        _ form: FeedbackReportFormState,
        consent: FeedbackConsentV1
    ) throws {
        try FeedbackUserStatementV1(
            intendedOutcome: form.intendedOutcome,
            actualResult: form.actualResult,
            expectedResult: form.expectedResult,
            workBlocked: form.workBlocked
        ).validate()
        try form.evidenceWindow.validate()
        try canonicalEvidenceWindow(form.evidenceWindow).validate()
        try consent.validate()
    }

    private func progress(
        form: FeedbackReportFormState,
        launch: FeedbackReportLaunch
    ) -> FeedbackDraftProgress {
        FeedbackDraftProgress(
            intendedOutcome: form.intendedOutcome,
            actualResult: form.actualResult,
            expectedResult: form.expectedResult,
            workBlocked: form.workBlocked,
            taskID: launch.taskID?.uuidString.lowercased(),
            runID: launch.runID?.uuidString.lowercased(),
            evidenceWindow: Self.canonicalEvidenceWindow(form.evidenceWindow),
            consent: Self.requestedConsent(selections: form.selections, reviewedAt: now())
        )
    }

    nonisolated private static func selections(
        from consent: FeedbackConsentV1
    ) -> FeedbackEvidenceSelections {
        let included = Set(consent.evidenceSelections.filter(\.included).map(\.artifactID))
        return FeedbackEvidenceSelections(
            includeApplicationLogs: included.contains("application-log"),
            includeTaskLogs: included.contains("task-log"),
            includeBrowserEvidence: included.contains("browser-evidence"),
            includeScreenshots: included.contains("browser-screenshot")
                || included.contains(where: { $0.hasPrefix("browser-screenshot-") }),
            includeMacOSDiagnostics: included.contains("macos-diagnostics")
        )
    }

    nonisolated private static func requestedConsent(
        selections: FeedbackEvidenceSelections,
        reviewedAt: Date
    ) -> FeedbackConsentV1 {
        let options: [(String, FeedbackEvidenceDisclosureClassV1, Bool)] = [
            ("application-log", .standard, selections.includeApplicationLogs),
            ("task-log", .standard, selections.includeTaskLogs),
            ("browser-evidence", .explicitOptIn, selections.includeBrowserEvidence),
            ("browser-screenshot", .explicitOptIn, selections.includeScreenshots),
            ("macos-diagnostics", .explicitOptIn, selections.includeMacOSDiagnostics)
        ]
        return FeedbackConsentV1(
            version: FeedbackReportFormState.consentVersion,
            evidenceSelections: options.map { artifactID, disclosure, included in
                FeedbackEvidenceSelectionV1(
                    artifactID: artifactID,
                    disclosureClass: disclosure,
                    included: included,
                    reviewedAt: included && disclosure != .standard ? reviewedAt : nil
                )
            }
        )
    }

    nonisolated static func exactConsent(
        manifest: FeedbackEvidenceManifestV1,
        version: String,
        reviewedAt: Date
    ) -> FeedbackConsentV1 {
        var selections: [FeedbackEvidenceSelectionV1] = []
        var seen = Set<String>()
        for artifact in manifest.artifacts where seen.insert(artifact.artifactID).inserted {
            selections.append(FeedbackEvidenceSelectionV1(
                artifactID: artifact.artifactID,
                disclosureClass: artifact.disclosureClass,
                included: true,
                reviewedAt: artifact.disclosureClass == .standard ? nil : reviewedAt
            ))
        }
        for omission in manifest.omissions where seen.insert(omission.artifactID).inserted {
            selections.append(FeedbackEvidenceSelectionV1(
                artifactID: omission.artifactID,
                disclosureClass: disclosureClass(for: omission.kind),
                included: false
            ))
        }
        selections.sort { $0.artifactID < $1.artifactID }
        return FeedbackConsentV1(version: version, evidenceSelections: selections)
    }

    nonisolated private static func disclosureClass(
        for kind: FeedbackEvidenceArtifactKindV1
    ) -> FeedbackEvidenceDisclosureClassV1 {
        if kind == .browserEvidence || kind == .screenshot || kind == .macOSDiagnostic {
            return .explicitOptIn
        }
        return .standard
    }

    nonisolated fileprivate static func canonicalTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1_000) / 1_000)
    }

    nonisolated fileprivate static func canonicalEvidenceWindow(
        _ window: FeedbackEvidenceWindowV1
    ) -> FeedbackEvidenceWindowV1 {
        FeedbackEvidenceWindowV1(
            start: canonicalTimestamp(window.start),
            end: canonicalTimestamp(window.end)
        )
    }

    private func removeTrustedStagingPackage(at url: URL, reportID: UUID) throws {
        try validateStagingURL(url, reportID: reportID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try FeedbackPackageRemoval.removeOwnedPackage(at: url, fileManager: fileManager)
        } catch {
            AppLogger.error("Feedback preview cleanup failed", category: "Diagnostics")
            throw FeedbackReportPreparationError.stagingCleanupFailed(
                FeedbackEvidenceSanitizer.sanitize(error.localizedDescription, maximumBytes: 240).text
            )
        }
    }

    private func validateStagingURL(_ url: URL, reportID: UUID) throws {
        let root = FeedbackReportStoragePaths.preparationRoot(storageRoot: storageRoot)
            .standardizedFileURL.resolvingSymlinksInPath()
        let expected = root
            .appendingPathComponent("feedback-\(reportID.uuidString.lowercased())", isDirectory: true)
            .standardizedFileURL
        let supplied = url.standardizedFileURL
        guard supplied == expected,
              supplied.deletingLastPathComponent() == root,
              !supplied.path.hasPrefix(root.path + "/../")
        else { throw FeedbackReportPreparationError.unsafeStagingPath }
        if fileManager.fileExists(atPath: supplied.path) {
            let resolved = supplied.resolvingSymlinksInPath()
            guard resolved == expected else {
                throw FeedbackReportPreparationError.unsafeStagingPath
            }
        }
    }
}

private enum FeedbackReportEnvelopeFactory {
    static func makeData(
        reportID: UUID,
        installationID: FeedbackInstallationIDV1,
        idempotencyKey: String,
        createdAt: Date,
        form: FeedbackReportFormState,
        launch: FeedbackReportLaunch,
        consent: FeedbackConsentV1,
        runtimeSnapshot: FeedbackRuntimeSnapshotV1?,
        manifest: FeedbackEvidenceManifestV1,
        buildInfo: AppBuildInfo
    ) throws -> Data {
        let payload = FeedbackReportPayloadV1(
            reportID: FeedbackReportIDV1(reportID),
            createdAt: createdAt,
            statement: FeedbackUserStatementV1(
                intendedOutcome: FeedbackContractNormalizationV1.text(form.intendedOutcome),
                actualResult: FeedbackContractNormalizationV1.text(form.actualResult),
                expectedResult: FeedbackContractNormalizationV1.text(form.expectedResult),
                workBlocked: form.workBlocked
            ),
            build: FeedbackBuildProvenanceV1(
                version: buildInfo.version,
                build: buildInfo.build,
                channel: buildInfo.channelRawValue,
                gitCommit: buildInfo.gitCommit,
                buildDate: buildInfo.buildDate,
                source: "astra-feedback-ui"
            ),
            platform: FeedbackPlatformV1(
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architectureName
            ),
            evidenceWindow: FeedbackReportPreparationService.canonicalEvidenceWindow(form.evidenceWindow),
            consent: consent,
            taskID: launch.taskID?.uuidString.lowercased(),
            runID: launch.runID?.uuidString.lowercased(),
            runtimeSnapshot: runtimeSnapshot,
            evidence: manifest
        )
        let payloadHash = try payload.canonicalSHA256()
        let placeholder = FeedbackReportEnvelopeV1(
            installationID: installationID,
            idempotencyKey: idempotencyKey,
            payloadSHA256: payloadHash,
            evidenceArchiveSHA256: manifest.archiveSHA256,
            canonicalDigestSHA256: String(repeating: "0", count: 64),
            payload: payload
        )
        let envelope = FeedbackReportEnvelopeV1(
            installationID: installationID,
            idempotencyKey: idempotencyKey,
            payloadSHA256: payloadHash,
            evidenceArchiveSHA256: manifest.archiveSHA256,
            canonicalDigestSHA256: try placeholder.computedCanonicalDigestSHA256(),
            payload: payload
        )
        return try envelope.canonicalData()
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

enum FeedbackReportEvidenceSourceReader {
    private static let maximumBrowserFlightBytes = 4 * 1_024 * 1_024
    enum SelectedSource: String, Equatable, Sendable {
        case taskLogs
        case browserEvidence
        case browserScreenshot
        case macOSDiagnostics

        var displayName: String {
            switch self {
            case .taskLogs: "task logs"
            case .browserEvidence: "browser interaction details"
            case .browserScreenshot: "browser screenshots"
            case .macOSDiagnostics: "macOS diagnostics"
            }
        }
    }
    enum SourceError: Error, Equatable, LocalizedError {
        case unavailable(SelectedSource)
        case corrupt(SelectedSource)

        var errorDescription: String? {
            switch self {
            case .unavailable(let source):
                "The selected \(source.displayName) are unavailable. Retry or deselect that evidence."
            case .corrupt(let source):
                "The selected \(source.displayName) could not be read safely. Retry or deselect that evidence."
            }
        }
    }
    typealias EntriesProvider = @Sendable () -> [LogEntry]
    typealias BrowserProvider = @Sendable (UUID?, DateInterval, Bool, Bool) throws -> (
        records: [FeedbackBrowserEvidenceRecord], screenshots: [FeedbackScreenshotCandidate]
    )
    typealias CrashProvider = @Sendable (FeedbackReportLaunch, DateInterval) throws -> [CrashReportSummary]

    static func collect(
        launch: FeedbackReportLaunch,
        selections: FeedbackEvidenceSelections,
        interval: DateInterval,
        entriesProvider: EntriesProvider = { retainedLogEntries() },
        browserProvider: @escaping BrowserProvider = {
            try browserEvidence(
                taskID: $0,
                interval: $1,
                includeRecords: $2,
                includeScreenshots: $3
            )
        },
        crashProvider: @escaping CrashProvider = { try crashEvidence(launch: $0, interval: $1) }
    ) throws -> FeedbackReportEvidenceSource {
        try Task.checkCancellation()
        let needsLogs = selections.includeApplicationLogs || selections.includeTaskLogs
        let entries = needsLogs ? entriesProvider() : []
        let windowEntries = entries.filter { interval.contains($0.timestamp) }
        if selections.includeTaskLogs && launch.taskID == nil {
            throw SourceError.unavailable(.taskLogs)
        }
        let taskEntries = selections.includeTaskLogs
            ? launch.taskID.map { taskID in
                windowEntries.filter { entryBelongsToTask($0, taskID: taskID) }
            } ?? []
            : []
        let applicationEntries = selections.includeApplicationLogs
            ? windowEntries.filter { $0.taskID == nil }
            : []
        try Task.checkCancellation()
        let browser: (
            records: [FeedbackBrowserEvidenceRecord],
            screenshots: [FeedbackScreenshotCandidate]
        )
        if selections.includeBrowserEvidence || selections.includeScreenshots {
            browser = try browserProvider(
                launch.taskID,
                interval,
                selections.includeBrowserEvidence,
                selections.includeScreenshots
            )
            if selections.includeBrowserEvidence && browser.records.isEmpty {
                throw SourceError.unavailable(.browserEvidence)
            }
            if selections.includeScreenshots && browser.screenshots.isEmpty {
                throw SourceError.unavailable(.browserScreenshot)
            }
        } else {
            browser = (records: [], screenshots: [])
        }
        try Task.checkCancellation()
        let crashes = selections.includeMacOSDiagnostics ? try crashProvider(launch, interval) : []
        if selections.includeMacOSDiagnostics && crashes.isEmpty {
            throw SourceError.unavailable(.macOSDiagnostics)
        }
        return FeedbackReportEvidenceSource(
            applicationLogEntries: applicationEntries,
            taskLogEntries: taskEntries,
            browserRecords: browser.records,
            screenshots: browser.screenshots,
            crashReports: crashes
        )
    }

    static func retainedLogEntries(
        inMemoryEntries: [LogEntry] = AppLogger.entries,
        logDirectory: URL = AppLogger.mainLogFile.deletingLastPathComponent()
    ) -> [LogEntry] {
        LogDiagnosticsService.collectCurrentEntries(
            inMemoryEntries: inMemoryEntries,
            logDirectory: logDirectory,
            includeRetainedAppLogs: true
        )
    }

    private static func entryBelongsToTask(_ entry: LogEntry, taskID: UUID) -> Bool {
        if entry.taskID == taskID { return true }
        let prefix = String(taskID.uuidString.prefix(8)).uppercased()
        return entry.message.hasPrefix("task_short=\(prefix) ")
    }

    private static func crashEvidence(
        launch: FeedbackReportLaunch,
        interval: DateInterval
    ) throws -> [CrashReportSummary] {
        let reports = launch.crashReports.isEmpty
            ? CrashDiagnosticsService.reports(limit: 20, modifiedIn: interval)
            : launch.crashReports.filter { interval.contains($0.modifiedAt) }
        guard !reports.isEmpty else {
            throw SourceError.unavailable(.macOSDiagnostics)
        }
        return reports
    }

    private static func browserEvidence(
        taskID: UUID?,
        interval: DateInterval,
        includeRecords: Bool,
        includeScreenshots: Bool
    ) throws -> (records: [FeedbackBrowserEvidenceRecord], screenshots: [FeedbackScreenshotCandidate]) {
        let url = AppLogger.browserFlightLogFile(taskID: taskID)
        let root = url.deletingLastPathComponent()
        let broker = HostFileAccessBroker()
        let isCappedSuffix = (broker.fileSize(
            at: url,
            intent: .astraManagedStorage(root: root)
        ) ?? 0) > maximumBrowserFlightBytes
        let data: Data
        do {
            data = try broker.readData(
            at: url,
            maxBytes: maximumBrowserFlightBytes,
            keeping: .suffix,
            intent: .astraManagedStorage(root: root)
            )
        } catch {
            throw SourceError.unavailable(browserReadFailureSource(includeRecords: includeRecords))
        }

        return try parseBrowserEvidence(
            data: data,
            isCappedSuffix: isCappedSuffix,
            interval: interval,
            includeRecords: includeRecords,
            includeScreenshots: includeScreenshots
        )
    }

    static func parseBrowserEvidence(
        data: Data,
        isCappedSuffix: Bool,
        interval: DateInterval,
        includeRecords: Bool,
        includeScreenshots: Bool
    ) throws -> (records: [FeedbackBrowserEvidenceRecord], screenshots: [FeedbackScreenshotCandidate]) {
        var records: [FeedbackBrowserEvidenceRecord] = []
        var screenshots: [FeedbackScreenshotCandidate] = []
        let lines = data.split(separator: 0x0a)
        for (index, line) in lines.enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let createdAt = date(object["createdAt"])
            else {
                if isCappedSuffix && index == 0 { continue }
                throw SourceError.corrupt(includeRecords ? .browserEvidence : .browserScreenshot)
            }
            guard interval.contains(createdAt) else { continue }
            if includeRecords {
                let before = object["before"] as? [String: Any]
                let after = object["after"] as? [String: Any]
                records.append(FeedbackBrowserEvidenceRecord(
                    sequence: int(object["sequence"]),
                    createdAt: createdAt,
                    method: string(object["method"]),
                    path: string(object["path"]),
                    statusCode: int(object["statusCode"]),
                    durationMilliseconds: int(object["durationMs"]),
                    beforeHost: string(before?["host"]),
                    afterHost: string(after?["host"]),
                    urlChanged: bool(object["urlChanged"]),
                    succeeded: bool(object["ok"]),
                    errorCode: optionalString(object["error"]),
                    observedOutcome: optionalString(object["observedOutcome"])
                ))
            }
            if includeScreenshots,
               let capture = object["debugCapture"] as? [String: Any],
               let screenshot = capture["screenshot"] as? [String: Any] {
                guard let base64 = screenshot["base64"] as? String,
                      let jpegData = Data(base64Encoded: base64), !jpegData.isEmpty
                else { throw SourceError.corrupt(.browserScreenshot) }
                screenshots.append(FeedbackScreenshotCandidate(
                    jpegData: jpegData,
                    source: string(screenshot["source"]),
                    width: int(screenshot["width"]),
                    height: int(screenshot["height"])
                ))
            }
        }
        if includeRecords && records.isEmpty {
            throw SourceError.unavailable(.browserEvidence)
        }
        if includeScreenshots && screenshots.isEmpty {
            throw SourceError.unavailable(.browserScreenshot)
        }
        return (records, screenshots)
    }

    static func browserReadFailureSource(includeRecords: Bool) -> SelectedSource {
        includeRecords ? .browserEvidence : .browserScreenshot
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func string(_ value: Any?) -> String { value as? String ?? "" }
    private static func optionalString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private static func bool(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue ?? false }
}
