import Foundation
import SwiftUI
import ASTRAModels
import ASTRAPersistence

enum FeedbackCrashAlertAction: Equatable, Sendable {
    case reportProblem
    case decline
    case presentationDismissed
}

enum FeedbackCrashAlertPolicy {
    static func shouldDecline(for action: FeedbackCrashAlertAction) -> Bool {
        action == .decline
    }
}

enum FeedbackCrashOfferReadiness {
    static func claimNext(
        recoverableReportIDs: () throws -> Set<UUID>,
        claim: (Set<UUID>) async -> FeedbackCrashOffer?
    ) async throws -> FeedbackCrashOffer? {
        let recoverable = try recoverableReportIDs()
        return await claim(recoverable)
    }
}

extension ContentView {
    func presentGeneralFeedback(from entryPoint: FeedbackReportEntryPoint) {
        Task { @MainActor in
            do {
                try await makeFeedbackCoordinator().present(
                    from: entryPoint,
                    hostID: feedbackHostID
                )
            } catch {
                feedbackErrorMessage = safeFeedbackError(error)
            }
        }
    }

    func presentTaskFeedback(
        task: AgentTask,
        prefill: FeedbackReportPrefill,
        runID: UUID?,
        runtimeEvidence: RuntimeFeedbackPersistedEvidence?,
        taskFailureOccurredAt: Date?
    ) {
        Task { @MainActor in
            do {
                try await makeFeedbackCoordinator().present(
                    from: .taskFailure,
                    hostID: feedbackHostID,
                    prefill: prefill,
                    taskID: task.id,
                    runID: runID,
                    taskFailureOccurredAt: taskFailureOccurredAt,
                    runtimeEvidence: runtimeEvidence
                )
            } catch {
                feedbackErrorMessage = safeFeedbackError(error)
            }
        }
    }

    func checkForCrashFeedbackOffer() async {
        guard !didCheckCrashFeedback else { return }
        didCheckCrashFeedback = true
        guard feedbackRouter.launch == nil else { return }

        do {
            pendingCrashFeedbackOffer = try await FeedbackCrashOfferReadiness.claimNext(
                recoverableReportIDs: {
                    try FeedbackOutboxService(
                        modelContainer: modelContext.container,
                        storageRoot: FeedbackReportStoragePaths.root
                    ).recoverableReportIDs()
                },
                claim: { recoverableReportIDs in
                    await FeedbackCrashLaunchMonitor.shared.claimNextOffer(
                        using: crashOfferService,
                        recoverableReportIDs: recoverableReportIDs
                    )
                }
            )
        } catch {
            feedbackErrorMessage = safeFeedbackError(error)
        }
    }

    func presentCrashFeedback() {
        guard let offer = pendingCrashFeedbackOffer else { return }
        Task { @MainActor in
            do {
                try await makeFeedbackCoordinator().present(
                    from: .crashRecovery,
                    hostID: feedbackHostID,
                    prefill: FeedbackReportPrefill(
                        intendedOutcome: "Continue using ASTRA",
                        actualResult: "ASTRA closed unexpectedly",
                        expectedResult: "ASTRA stays open",
                        workBlocked: true
                    ),
                    crashOffer: offer
                )
                pendingCrashFeedbackOffer = nil
            } catch {
                feedbackErrorMessage = safeFeedbackError(error)
            }
        }
    }

    func declineCrashFeedback() {
        guard let offer = pendingCrashFeedbackOffer,
              FeedbackCrashAlertPolicy.shouldDecline(for: .decline)
        else { return }
        do {
            try crashOfferService.decline(offer)
            pendingCrashFeedbackOffer = nil
        } catch {
            feedbackErrorMessage = safeFeedbackError(error)
        }
    }

    private func makeFeedbackCoordinator() -> FeedbackReportCoordinator {
        FeedbackReportCoordinator(
            router: feedbackRouter,
            modelContainer: modelContext.container,
            crashLedger: crashOfferService
        )
    }

    private func safeFeedbackError(_ error: Error) -> String {
        FeedbackEvidenceSanitizer.sanitize(
            error.localizedDescription,
            maximumBytes: 240
        ).text
    }
}

struct ContentFeedbackAlertsModifier: ViewModifier {
    let hasCompletedOnboarding: Bool
    @Binding var offer: FeedbackCrashOffer?
    @Binding var errorMessage: String?
    let checkForOffer: () async -> Void
    let presentOffer: () -> Void
    let declineOffer: () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: hasCompletedOnboarding) {
                guard hasCompletedOnboarding else { return }
                await checkForOffer()
            }
            .alert("ASTRA closed unexpectedly", isPresented: Binding(
                get: { offer != nil },
                set: { _ in }
            )) {
                Button("Report a Problem") { presentOffer() }
                Button("Not Now", role: .cancel) { declineOffer() }
            } message: {
                Text("Would you like to review a privacy-safe crash report? Diagnostics remain excluded until you opt in.")
            }
            .alert("Feedback unavailable", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }
}
