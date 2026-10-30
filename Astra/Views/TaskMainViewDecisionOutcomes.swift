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
    var decisionOutcomeCache: TaskDecisionOutcomeCache { decisionOutcomeProjection.outcomes }
    /// Streamed output, successful tool results and updatedAt do not change
    /// decisions. The save revision covers relevant rows outside this window.
    var decisionOutcomeInputSignature: TaskDecisionOutcomeRefresh.Key {
        .init(task: task, snapshot: threadViewModel.snapshot,
              artifactPaths: decisionArtifactPathsCache, saveRevision: decisionOutcomeSaveRevision)
    }

    var shouldOfferGitPublishReview: Bool {
        TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: task.status,
            latestRunStopReason: threadViewModel.snapshot?.latestRun.flatMap { TaskRunStopReason(rawValue: $0.stopReason) },
            hasPendingPublication: decisionOutcomeCache.hasGitPublishRequest
        )
    }

    /// Refreshes only when semantic inputs change. Reads remain in this
    /// context, including pending changes and rollback, and never authorize
    /// actions: each action's service rechecks its durable evidence.
    func recomputeDecisionOutcomes() {
        let snapshot = threadViewModel.snapshot
        decisionOutcomeProjection.refresh(key: decisionOutcomeInputSignature) {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let outcomes = TaskDecisionOutcomeResolver.outcomes(
                task: task,
                latestRun: snapshot?.latestRun.map { .init(id: $0.id, startedAt: $0.startedAt) },
                windowEvents: (snapshot?.sortedEvents ?? []).map {
                    TaskOutcomeEventRecord(id: $0.id, runID: $0.runID, type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
                },
                decisionArtifactPaths: decisionArtifactPathsCache,
                modelContext: modelContext
            )
            PerformanceTelemetry.logIfNeeded("task_decision_outcomes_refresh", start: startedAt,
                thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
                fields: ["task_status": task.status.rawValue], taskID: task.id)
            return outcomes
        }
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
            let follows: Bool
            do {
                follows = try TaskDeliverableHistoryReader.followsUpDeliveredRequest(
                    ownerID: task.persistentModelID, runID: latestRun.id,
                    startedAt: latestRun.startedAt, in: modelContext
                )
            } catch {
                AppLogger.error("Decision delivery evidence could not be read", category: "UI")
                follows = false
            }
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
