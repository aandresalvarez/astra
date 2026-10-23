import Foundation
import SwiftUI
import SwiftData
import ASTRAModels

/// Decision-dock inputs that are answered from the task's event history.
///
/// `hasGitPublishRequest` and `pendingConnectorMutationTargets` used to be
/// resolved straight off the task's event and run relationships inside
/// `taskDecisionDockPresentation`, which `body` evaluates on every pass — every
/// keystroke in the composer, every streamed snapshot, every sidebar tick. On
/// the 2026-09-15 production profile that one getter faulted each row of a
/// 362-event thread through `performAndWait` per pass and owned 80–95% of
/// `TaskMainView.body`'s main-thread samples.
struct TaskDecisionOutcomeCache: Equatable {
    var hasGitPublishRequest = false
    var pendingConnectorMutationTargets: [String] = []
    var githubReviewPath: String?
    /// The latest run, when it follows up a request already met and so does
    /// not owe the original deliverable.
    var deliveredRequestFollowUpRunID: UUID?
}

extension TaskMainView {
    /// Signature for the cached outcomes; all scalars, nothing faulted.
    ///
    /// `appliedSnapshotRevision` moves whenever the transcript picks up new
    /// events, `updatedAt` whenever the task persists anything at all (a
    /// mutation decline lands there before the next snapshot), and the latest
    /// run's identity and status bound the publication rule's target run.
    var decisionOutcomeInputSignature: String {
        let latestRun = threadViewModel.snapshot?.latestRun
        return [
            task.id.uuidString,
            task.status.rawValue,
            String(task.updatedAt.timeIntervalSince1970),
            "\(threadViewModel.appliedSnapshotRevision)",
            latestRun?.id.uuidString ?? "none",
            latestRun?.status.rawValue ?? "none",
            decisionArtifactPathsCache.joined(separator: ",")
        ].joined(separator: "|")
    }

    var shouldOfferGitPublishReview: Bool {
        TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: task.status,
            latestRunStopReason: threadViewModel.snapshot?.latestRun.flatMap { TaskRunStopReason(rawValue: $0.stopReason) },
            hasPendingPublication: decisionOutcomeCache.hasGitPublishRequest
        )
    }

    /// Runs under `.task(id: decisionOutcomeInputSignature)`. Synchronous on
    /// purpose: the publication rule reads the snapshot the view already holds
    /// (the window always carries the latest run, and the capped successful
    /// tool results are the one kind it never reads), and the mutation rule is
    /// a single typed fetch that faults only mutation rows.
    func recomputeDecisionOutcomes() {
        let snapshot = threadViewModel.snapshot
        decisionOutcomeCache = TaskDecisionOutcomeResolver.outcomes(
            task: task,
            latestRun: snapshot?.latestRun.map { .init(id: $0.id, startedAt: $0.startedAt) },
            windowEvents: (snapshot?.sortedEvents ?? []).map {
                TaskOutcomeEventRecord(id: $0.id, runID: $0.runID, type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
            },
            decisionArtifactPaths: decisionArtifactPathsCache,
            modelContext: modelContext
        )
    }
}

/// The decision dock's history-backed answers, as one function of the task,
/// its latest run, the transcript window the view already holds, and the
/// artifact paths it already cached. Kept apart from the view so
/// `TaskMainActorScalingGateTests` can bound the complete read cost
/// on disk-backed long histories.
@MainActor
enum TaskDecisionOutcomeResolver {
    struct LatestRun: Equatable {
        let id: UUID
        let startedAt: Date
    }

    static func outcomes(
        task: AgentTask,
        latestRun: LatestRun?,
        windowEvents: [TaskOutcomeEventRecord],
        decisionArtifactPaths: [String],
        modelContext: ModelContext
    ) -> TaskDecisionOutcomeCache {
        var outcomes = TaskDecisionOutcomeCache()
        if let latestRun {
            let follows = (try? TaskDeliverableExpectation.followsUpDeliveredRequest(
                taskID: task.id, runID: latestRun.id, startedAt: latestRun.startedAt, in: modelContext
            )) == true
            if follows { outcomes.deliveredRequestFollowUpRunID = latestRun.id }
        }
        if let latestRunID = latestRun?.id {
            outcomes.hasGitPublishRequest = TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
                task: task,
                targetRunID: latestRunID,
                events: windowEvents
            ) != nil
        }
        let pendingMutations = ConnectorMutationRequirementResolver.pendingMutations(task: task)
        outcomes.pendingConnectorMutationTargets = ConnectorMutationCoordinator
            .reviewable(pendingMutations).map(\.target)
        if task.status != .running, task.status != .queued,
           let reviewPath = GitHubReviewPublicationService.pendingCandidatePath(
            task: task, filePaths: decisionArtifactPaths
           ) {
            outcomes.githubReviewPath = reviewPath
        }
        return outcomes
    }
}
