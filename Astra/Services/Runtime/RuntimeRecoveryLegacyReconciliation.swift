import Foundation
import ASTRACore
import ASTRAModels

/// History written before the execution journal existed carries no receipt.
/// An upgrade alone must neither strand every task that ever ran nor treat it
/// as fresh: this admits such a task only from what the older app durably
/// recorded, and only once, because the owner it admits writes the first receipt.
///
/// It accepts that version's own settlement. Older versions never recorded
/// whether detached tools or remote work stopped, so this does not claim it.
/// A task the journal ever tracked is not legacy; its missing receipt stays
/// blocked (`RuntimeExecutionOwner.requiresExistingReceipt`).
enum RuntimeRecoveryLegacyReconciliation {
    /// A run that ended before this moment belonged to an app instance that
    /// has since exited, together with the provider processes it supervised.
    static let appStartedAt: Date? = RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier).map {
        Date(timeIntervalSince1970: TimeInterval($0.startedSeconds) + TimeInterval($0.startedMicroseconds) / 1_000_000)
    }

    /// The latest run, when every run has a recorded completion, ran on the
    /// host and ended before this app started, and the latest one carries a
    /// stop reason other than an app restart or a lost connection (neither
    /// attests that its provider stopped). Otherwise nil: the task stays blocked.
    @MainActor static func settledRun(of task: AgentTask) -> TaskRun? {
        guard let appStartedAt, let latest = task.runs.max(by: { $0.startedAt < $1.startedAt }),
              let reason = latest.typedStopReason, reason != .appRestarted, reason != .runtimeConnectionLost else { return nil }
        var environments: Set<String> = []
        for run in task.runs {
            guard run.status != .running, let completedAt = run.completedAt, completedAt < appStartedAt else { return nil }
            if let snapshot = run.executionEnvironmentSnapshotJSON { environments.insert(snapshot) }
        }
        // Runs nearly always share one snapshot; decode each distinct one once.
        return environments.allSatisfy(ranOnHost) ? latest : nil
    }

    /// Runs from before environment snapshots existed ran on the host. An
    /// unreadable snapshot is not evidence of either, so it does not qualify.
    private static func ranOnHost(_ snapshot: String) -> Bool {
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let environment = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: Data(snapshot.utf8)) else { return false }
        return environment.isHost
    }
}
