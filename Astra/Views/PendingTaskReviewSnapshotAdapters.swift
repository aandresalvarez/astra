import Foundation
import ASTRAModels

extension PendingTaskReviewRunSnapshot {
    init(_ snapshot: TaskRunSnapshot) {
        self.init(
            id: snapshot.id,
            status: snapshot.status,
            startedAt: snapshot.startedAt,
            completedAt: snapshot.completedAt,
            stopReason: snapshot.stopReason
        )
    }
}

extension PendingTaskReviewEventSnapshot {
    init(_ snapshot: TaskEventSnapshot) {
        self.init(runID: snapshot.runID, type: snapshot.type, timestamp: snapshot.timestamp)
    }
}

extension PendingTaskReviewSnapshotInput {
    /// `latestRunScope` is read from the latest run's turn request off the body
    /// pass (`recomputeDecisionOutcomes`). Until it is, or once a newer run
    /// replaces it, the run is graded against the task's own request.
    init(task: AgentTask, snapshot: TaskThreadSnapshot, latestRunScope: TaskDeliverableExpectation.RunScope?) {
        let latestRun = snapshot.latestRun
        let latestRunSnapshot = latestRun.map(PendingTaskReviewRunSnapshot.init)
        let runSnapshots = snapshot.sortedRuns.map(PendingTaskReviewRunSnapshot.init)
        let eventSnapshots = snapshot.sortedEvents.map(PendingTaskReviewEventSnapshot.init)
        let scope = latestRunScope.flatMap { $0.runID == latestRun?.id ? $0.scope : nil } ?? .task
        let requiresDeliverableArtifact = TaskDeliverableExpectation.requiresDeliverableArtifact(task, scope: scope)
        let requiresScopedArtifactEvidence = PendingTaskReviewPolicy.requiresScopedArtifactEvidence(
            taskStatus: task.status,
            isTaskDone: task.isDone,
            requiresDeliverableArtifact: requiresDeliverableArtifact,
            latestRun: latestRunSnapshot,
            runs: runSnapshots,
            events: eventSnapshots
        )
        let latestRunHasScopedArtifact = requiresScopedArtifactEvidence && latestRun.map { latestRun in
            TaskDeliverableExpectation.hasRunScopedArtifact(
                for: task,
                fileChanges: latestRun.fileChanges,
                runStartedAt: latestRun.startedAt,
                runCompletedAt: latestRun.completedAt
            )
        } == true

        self.init(
            taskStatus: task.status,
            isTaskDone: task.isDone,
            requiresDeliverableArtifact: requiresDeliverableArtifact,
            latestRun: latestRunSnapshot,
            runs: runSnapshots,
            events: eventSnapshots,
            latestRunHasScopedArtifact: latestRunHasScopedArtifact
        )
    }
}
