import Foundation
import ASTRACore
import ASTRAModels

/// Structured evidence a stopped run left for the decision dock, scoped to that
/// run via `TaskEventSnapshot.runID` rather than the whole thread's history.
/// Kept out of `TaskMainView`, which is at its line budget.
enum TaskRunStopEvidence {
    static func launchBlock(events: [TaskEventSnapshot], runID: UUID?) -> TaskRunLaunchBlockPayload? {
        latestPayload(events: events, runID: runID, type: TaskEventTypes.System.runtimeLaunchBlocked)
            .flatMap(TaskRunLaunchBlockPayload.decode(from:))
    }

    /// The repair the run stopped for (a plugin sign-in expired mid-task).
    static func repair(events: [TaskEventSnapshot], runID: UUID?) -> RepairAction? {
        // The typed event owns both automatic and manual setup. A manual
        // repair deliberately has no legacy executable-action event.
        if let captured = latestPayload(events: events, runID: runID, type: TaskEventTypes.System.runtimeRepairContext) {
            return RuntimeRepairContext.decode(from: captured)?.repair
                ?? RuntimeRepairContext.manualReview(message: "The saved repair context could not be read.").repair
        }
        return latestPayload(events: events, runID: runID, type: TaskEventTypes.System.runtimeRepairRequired)
            .flatMap(RepairAction.decode(from:))
    }

    @MainActor
    static func presentationRepair(events: [TaskEventSnapshot], runID: UUID?, task: AgentTask) -> RepairAction? {
        guard var repair = repair(events: events, runID: runID) else { return nil }
        repair = repair.checking(in: TaskLifecycleCoordinator.projectedCheckEnvironment(for: task, binary: repair.checkBinary))
        repair.checkWorkingDirectory = TaskLifecycleCoordinator.checkWorkingDirectory(for: task)
        repair = CLISessionExpiryClassifier.checkingCredentialFile(CLISessionExpiryClassifier.checkingLaunchHost(repair))
        return repair.targetingCredentialStore(repair.checkEnvironment)
    }

    /// Resolves the stopped run's exact verification context on click,
    /// outside the render path. Task-selected directories and Enterprise
    /// hosts require manual setup; their read-only checks keep their target.
    /// An explicit ADC file is verified without replacing that file.
    @MainActor
    static func signInRepair(events: [TaskEventSnapshot], runID: UUID?, task: AgentTask) async -> RepairAction? {
        guard let repair = presentationRepair(events: events, runID: runID, task: task) else { return nil }
        let resolved = await CLISessionExpiryClassifier.checkingCheckoutHost(repair)
        return resolved.targetingCredentialStore(resolved.checkEnvironment)
    }

    private static func latestPayload(events: [TaskEventSnapshot], runID: UUID?, type: TaskEventType) -> String? {
        guard let runID else { return nil }
        return events.last { $0.runID == runID && $0.type == type.rawValue }?.payload
    }
}
