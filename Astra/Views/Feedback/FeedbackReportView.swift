import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels

struct FeedbackReportView: View {
    let launch: FeedbackReportLaunch
    let hostLeaseID: UUID
    let onDismiss: () -> Void
    let onHostDeactivationSettled: (Bool) -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var crashOfferService: FeedbackCrashOfferService
    @Query private var reports: [FeedbackReport]
    @State private var form: FeedbackReportFormState
    @State private var initialForm: FeedbackReportFormState
    @State private var preview: FeedbackReportPreparedPreview?
    @State private var invalidatingPreview: FeedbackReportPreparedPreview?
    @State private var isPreparing = false
    @State private var formRevision = 0
    @State private var preparationWork: FeedbackReportOwnedWork?
    @State private var invalidationWork: FeedbackReportOwnedWork?
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showDismissChoices = false
    @State private var isRestoring = false
    @State private var explicitDismissalCompleted = false

    init(
        launch: FeedbackReportLaunch,
        hostLeaseID: UUID,
        onDismiss: @escaping () -> Void,
        onHostDeactivationSettled: @escaping (Bool) -> Void
    ) {
        self.launch = launch
        self.hostLeaseID = hostLeaseID
        self.onDismiss = onDismiss
        self.onHostDeactivationSettled = onHostDeactivationSettled
        let initial = FeedbackReportFormState(launch: launch)
        _form = State(initialValue: initial)
        _initialForm = State(initialValue: initial)
        let reportID = launch.id
        _reports = Query(filter: #Predicate<FeedbackReport> { $0.id == reportID })
    }

    private var report: FeedbackReport? { reports.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let report { statusCard(report) }
                    statementCard.disabled(!interactionPolicy.canEdit)
                    evidenceCard.disabled(!interactionPolicy.canEdit)
                    if let preview { disclosureCard(preview) }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.failed)
                            .accessibilityLabel("Report error: \(errorMessage)")
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 720)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier(FeedbackReportAccessibilityID.sheet)
        .interactiveDismissDisabled(
            hasMeaningfulProgress || isPreparing || report != nil || preview != nil || invalidatingPreview != nil
        )
        .confirmationDialog("Keep this report as a draft?", isPresented: $showDismissChoices) {
            Button("Keep Draft") { finishDismiss(keepingDraft: true) }
                .accessibilityIdentifier(FeedbackReportAccessibilityID.keepDraft)
            Button("Discard Report", role: .destructive) { finishDismiss(keepingDraft: false) }
                .accessibilityIdentifier(FeedbackReportAccessibilityID.discard)
            Button("Continue Editing", role: .cancel) {}
        } message: {
            Text("Keeping the draft preserves your description. Discarding is permanent.")
        }
        .onChange(of: form) { _, _ in
            guard !isRestoring else { return }
            formRevision += 1
            if let preview {
                self.preview = nil
                invalidatingPreview = preview
                let invalidationRevision = formRevision
                invalidationWork = FeedbackReportOwnedWork.start {
                    try service.invalidatePreparedPreview(preview)
                    if invalidatingPreview == preview {
                        invalidatingPreview = nil
                        if invalidationRevision <= formRevision {
                            scheduleProgressSave()
                        }
                    }
                } onFailure: { error in
                    errorMessage = safeMessage(error)
                    return .generic
                }
            }
            scheduleProgressSave()
        }
        .task {
            guard report != nil else { return }
            do {
                isRestoring = true
                defer { isRestoring = false }
                let restored = try service.restoredForm(reportID: launch.id, launch: launch)
                form = restored
                initialForm = restored
                if try report?.requireLocalStatus() == .prepared {
                    preview = try service.restoredPreparedPreview(
                        reportID: launch.id,
                        launch: launch,
                        form: restored
                    )
                }
            } catch { errorMessage = safeMessage(error) }
        }
        .onDisappear {
            progressSaveTask?.cancel()
            let ownedWork = [preparationWork, invalidationWork].compactMap { $0 }
            Task { @MainActor in
                var resolvedCleanupKeys: Set<FeedbackPreparedPreviewCleanupKey> = []
                let settled = await FeedbackReportTaskSettlement.cancelAndFinalize(
                    ownedWork,
                    isResolvedRetainedCleanup: { resolvedCleanupKeys.contains($0) }
                ) {
                    // Read staged ownership only after work reaches a terminal
                    // receipt. A late invalidation failure therefore remains
                    // visible to the trusted cleanup boundary.
                    let stagedPreview = preview ?? invalidatingPreview
                    if let stagedPreview,
                       let cleanupKey = try invalidateForLiveClose(stagedPreview) {
                        resolvedCleanupKeys.insert(cleanupKey)
                    }
                    try service.settleForHostDeactivation(
                        launch: launch,
                        form: form,
                        preview: nil,
                        shouldPersist: FeedbackReportHostDeactivationPersistencePolicy.shouldPersist(
                            explicitDismissalCompleted: explicitDismissalCompleted,
                            hasStoredReport: report != nil,
                            hasMeaningfulProgress: hasMeaningfulProgress
                        )
                    )
                    preview = nil
                    invalidatingPreview = nil
                }
                guard settled else {
                    AppLogger.error(
                        "Feedback host deactivation could not settle owned work",
                        category: "Diagnostics"
                    )
                    switch FeedbackReportTaskSettlement.recoverAfterLateSuccess(
                        ownedWork,
                        onSuccess: {
                            onHostDeactivationSettled(true)
                            onDismiss()
                        }
                    ) {
                    case .alreadySucceeded:
                        onHostDeactivationSettled(true)
                        onDismiss()
                    case .observing:
                        onHostDeactivationSettled(false)
                    case .unrecoverable:
                        onHostDeactivationSettled(false)
                    }
                    return
                }
                onHostDeactivationSettled(true)
                onDismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.bubble")
                .font(Stanford.ui(18, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 36, height: 36)
                .background(Stanford.lagunita.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Report a Problem").font(Stanford.heading(22))
                Text("Review exactly what will be queued from this Mac.")
                    .font(Stanford.caption(12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { requestDismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(FeedbackReportAccessibilityID.close)
        }
        .padding(18)
    }

    private func statusCard(_ report: FeedbackReport) -> some View {
        Group {
            if let status = try? report.requireLocalStatus() {
                let presentation = FeedbackReportStatusPresentation.make(status: status)
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.title).font(Stanford.body(14).weight(.semibold))
                        Text(presentation.detail).font(Stanford.caption(12)).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: presentation.symbol)
                }
            } else {
                Label("Stored report status is invalid. No action was taken.", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Stanford.failed)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.lagunita.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier(FeedbackReportAccessibilityID.status)
    }

    private var statementCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What happened").font(Stanford.heading(16))
            field("What were you trying to do?", text: $form.intendedOutcome, id: FeedbackReportAccessibilityID.intendedOutcome)
            field("What actually happened?", text: $form.actualResult, id: FeedbackReportAccessibilityID.actualResult)
            field("What did you expect?", text: $form.expectedResult, id: FeedbackReportAccessibilityID.expectedResult)
            Toggle("This blocked my work", isOn: $form.workBlocked)
                .accessibilityIdentifier(FeedbackReportAccessibilityID.workBlocked)
        }
    }

    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Stanford.caption(12).weight(.semibold))
            TextEditor(text: text)
                .font(Stanford.body(13))
                .frame(minHeight: 58)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityIdentifier(id)
        }
    }

    private var evidenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Evidence from \(evidenceWindowLabel)").font(Stanford.heading(16))
            Text("Logs are sanitized before preview. Browser details, screenshots, and macOS diagnostics require explicit opt-in.")
                .font(Stanford.caption(12)).foregroundStyle(.secondary)
            Toggle("Application logs", isOn: $form.selections.includeApplicationLogs)
                .accessibilityIdentifier(FeedbackReportAccessibilityID.applicationLogs)
            Toggle("Task logs", isOn: $form.selections.includeTaskLogs)
                .disabled(launch.taskID == nil)
                .accessibilityIdentifier(FeedbackReportAccessibilityID.taskLogs)
            Toggle("Browser interaction details", isOn: $form.selections.includeBrowserEvidence)
                .accessibilityIdentifier(FeedbackReportAccessibilityID.browserEvidence)
            Toggle("Browser screenshots", isOn: $form.selections.includeScreenshots)
                .accessibilityIdentifier(FeedbackReportAccessibilityID.screenshots)
            Toggle("macOS crash diagnostics", isOn: $form.selections.includeMacOSDiagnostics)
                .accessibilityIdentifier(FeedbackReportAccessibilityID.macOSDiagnostics)
        }
    }

    private func disclosureCard(_ preview: FeedbackReportPreparedPreview) -> some View {
        let presentation = FeedbackEvidencePreviewPresentation(preview: preview)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Exact disclosure preview").font(Stanford.heading(16))
            Text("Manifest \(presentation.manifestSHA256) · \(presentation.totalByteCount) bytes")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            ForEach(presentation.rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.included ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(row.included ? Stanford.paloAltoGreen : Stanford.coolGrey)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(Stanford.body(13).weight(.semibold))
                        Text(row.detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            ForEach(presentation.warnings) {
                Label($0.message, systemImage: "exclamationmark.triangle").font(Stanford.caption(12))
            }
        }
        .padding(14)
        .background(Stanford.paloAltoGreen.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier(FeedbackReportAccessibilityID.disclosurePreview)
    }

    private var footer: some View {
        HStack {
            Text("Follow-up defaults to in-app status.")
                .font(Stanford.caption(11)).foregroundStyle(.secondary)
            Spacer()
            if preview == nil {
                Button(isPreparing ? "Preparing…" : "Review Evidence") { prepare() }
                    .disabled(isPreparing || invalidatingPreview != nil || !form.hasRequiredStatement || !interactionPolicy.canPrepare)
                    .accessibilityIdentifier(FeedbackReportAccessibilityID.reviewEvidence)
            } else {
                Button("Queue Report") { queue() }
                    .disabled(isPreparing || invalidatingPreview != nil || !interactionPolicy.canQueue)
                    .buttonStyle(StanfordButtonStyle(isPrimary: true, color: Stanford.lagunita))
                    .accessibilityIdentifier(FeedbackReportAccessibilityID.queue)
            }
        }
        .padding(18)
    }

    private var interactionPolicy: FeedbackReportInteractionPolicy {
        FeedbackReportInteractionPolicy.make(
            hasStoredReport: report != nil,
            storedStatus: report.flatMap { try? $0.requireLocalStatus() },
            hasExactPreview: preview != nil,
            hasMeaningfulProgress: hasMeaningfulProgress
        )
    }

    private var hasMeaningfulProgress: Bool {
        !form.intendedOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !form.actualResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !form.expectedResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || form.workBlocked
            || form.selections != initialForm.selections
    }

    private var evidenceWindowLabel: String {
        FeedbackEvidenceWindowPresentation.label(
            start: form.evidenceWindowStart,
            end: form.evidenceWindowEnd
        )
    }

    private var service: FeedbackReportPreparationService {
        FeedbackReportPreparationService(
            modelContainer: modelContext.container,
            crashOfferService: crashOfferService
        )
    }

    private func prepare() {
        progressSaveTask?.cancel()
        progressSaveTask = nil
        preparationWork?.cancel()
        isPreparing = true
        errorMessage = nil
        let revision = formRevision
        let preparedForm = form
        preparationWork = FeedbackReportOwnedWork.start {
            defer { isPreparing = false }
            let result = try await service.preparePreview(launch: launch, form: preparedForm)
            if Task.isCancelled || revision != formRevision || preparedForm != form {
                invalidatingPreview = result
                try service.invalidatePreparedPreview(result)
                if invalidatingPreview == result {
                    invalidatingPreview = nil
                }
            } else {
                preview = result
            }
        } onFailure: { error in
            isPreparing = false
            if case FeedbackReportPreparationError.cancelledPreviewCleanupFailed(
                let retainedPreview, _
            ) = error {
                invalidatingPreview = retainedPreview
                let key = FeedbackPreparedPreviewCleanupKey(
                    reportID: retainedPreview.reportID,
                    contextIdentity: retainedPreview.contextIdentity,
                    sourceHostID: launch.hostID,
                    sourceLeaseID: hostLeaseID,
                    directoryURL: retainedPreview.package.directoryURL
                )
                do {
                    try FeedbackPreparedPreviewCleanupOwner.shared.retain(key: key) {
                        try service.invalidatePreparedPreview(retainedPreview)
                    }
                    errorMessage = safeMessage(error)
                    return .retainedCleanup(key)
                } catch {
                    AppLogger.error(
                        "Feedback cleanup capability could not transfer to its lifecycle owner",
                        category: "Diagnostics"
                    )
                }
            }
            errorMessage = safeMessage(error)
            return .generic
        }
    }

    private func queue() {
        guard let preview else { return }
        progressSaveTask?.cancel()
        progressSaveTask = nil
        do {
            try service.confirmAndQueue(preview, launch: launch, form: form)
            self.preview = nil
        } catch {
            errorMessage = safeMessage(error)
        }
    }

    private func requestDismiss() {
        FeedbackReportClosePolicy.perform(
            hasStoredReport: report != nil,
            storedStatus: report.flatMap { try? $0.requireLocalStatus() },
            hasMeaningfulProgress: hasMeaningfulProgress,
            isPreparing: isPreparing,
            hasPreview: preview != nil,
            isInvalidatingPreview: invalidatingPreview != nil,
            offerDraftChoices: { showDismissChoices = true },
            closePresentation: onDismiss
        )
    }

    private func finishDismiss(keepingDraft: Bool) {
        progressSaveTask?.cancel()
        let ownedWork = [preparationWork, invalidationWork].compactMap { $0 }
        Task { @MainActor in
            var resolvedCleanupKeys: Set<FeedbackPreparedPreviewCleanupKey> = []
            let settled = await FeedbackReportTaskSettlement.cancelAndFinalize(
                ownedWork,
                isResolvedRetainedCleanup: { resolvedCleanupKeys.contains($0) }
            ) {
                if let preview {
                    if let cleanupKey = try invalidateForLiveClose(preview) {
                        resolvedCleanupKeys.insert(cleanupKey)
                    }
                    self.preview = nil
                }
                if let invalidatingPreview {
                    if let cleanupKey = try invalidateForLiveClose(invalidatingPreview) {
                        resolvedCleanupKeys.insert(cleanupKey)
                    }
                    self.invalidatingPreview = nil
                }
            }
            clearTerminalOwnedWork()
            guard settled else {
                errorMessage = "Private evidence cleanup is still in progress. Try closing again."
                return
            }
            do {
                switch FeedbackReportDismissPersistencePolicy.action(
                    keepingDraft: keepingDraft,
                    hasStoredReport: report != nil,
                    hasMeaningfulProgress: hasMeaningfulProgress
                ) {
                case .saveDraft:
                    try service.saveProgress(launch: launch, form: form)
                case .discardStoredReport:
                    try service.discard(reportID: launch.id)
                case .closeWithoutPersistence:
                    break
                }
                // The explicit action above is the sole persistence owner for
                // this dismissal. onDisappear still settles cleanup/host
                // ownership, but must not recreate a report that was discarded.
                explicitDismissalCompleted = true
                onDismiss()
            } catch { errorMessage = safeMessage(error) }
        }
    }

    private func clearTerminalOwnedWork() {
        if preparationWork?.isTerminal == true { preparationWork = nil }
        if invalidationWork?.isTerminal == true { invalidationWork = nil }
    }

    private func invalidateForLiveClose(
        _ stagedPreview: FeedbackReportPreparedPreview
    ) throws -> FeedbackPreparedPreviewCleanupKey? {
        try FeedbackReportLiveCleanupFinalizer.invalidateIfOwned(
            stagedPreview,
            sourceHostID: launch.hostID,
            sourceLeaseID: hostLeaseID,
            cleanupOwner: .shared
        ) {
            try service.invalidatePreparedPreview(stagedPreview)
        }
    }

    private func scheduleProgressSave() {
        progressSaveTask?.cancel()
        guard interactionPolicy.shouldAutosave,
              preview == nil,
              invalidatingPreview == nil
        else { return }
        let snapshot = form
        progressSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, snapshot == form else { return }
            do { try service.saveProgress(launch: launch, form: snapshot) }
            catch { errorMessage = safeMessage(error) }
        }
    }

    private func safeMessage(_ error: Error) -> String {
        FeedbackEvidenceSanitizer.sanitize(error.localizedDescription, maximumBytes: 240).text
    }
}

struct FeedbackReportSheetHost: ViewModifier {
    @EnvironmentObject private var router: FeedbackReportRouter
    let hostID: UUID
    @State private var leaseID = UUID()

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { router.launch(for: hostID, leaseID: leaseID) },
            set: { _ in }
        )) { launch in
            FeedbackReportView(
                launch: launch,
                hostLeaseID: leaseID,
                onDismiss: {
                    router.dismiss(hostID: hostID, reportID: launch.id, leaseID: leaseID)
                },
                onHostDeactivationSettled: { succeeded in
                    router.completeHostDeactivation(
                        hostID: hostID,
                        reportID: launch.id,
                        leaseID: leaseID,
                        succeeded: succeeded
                    )
                }
            )
            .onAppear {
                router.markPresentationMounted(
                    hostID: hostID,
                    reportID: launch.id,
                    leaseID: leaseID
                )
            }
        }
        .onAppear {
            do {
                _ = try FeedbackPreparedPreviewCleanupOwner.shared.retryPendingCleanup(
                    willClean: { key in
                        try router.validateFailedHostSettlement(forCleanup: key)
                    },
                    didClean: { key in
                        try router.resolveFailedHostSettlement(afterCleanup: key)
                    }
                )
            } catch {
                AppLogger.error(
                    "Feedback cleanup remains pending for a prior report",
                    category: "Diagnostics"
                )
            }
            router.register(hostID: hostID, leaseID: leaseID)
        }
        .onDisappear { router.unregister(hostID: hostID, leaseID: leaseID) }
    }
}

extension View {
    func feedbackReportSheetHost(_ hostID: UUID) -> some View {
        modifier(FeedbackReportSheetHost(hostID: hostID))
    }
}
