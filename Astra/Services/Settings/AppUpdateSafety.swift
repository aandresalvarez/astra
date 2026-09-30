import Foundation
import SwiftData
import ASTRAModels

enum AppUpdateSafety {
    static func isInstallBlocked(
        queueIsProcessing: Bool,
        activeWorkerCount: Int,
        activeTaskCount: Int,
        runningTaskCount: Int
    ) -> Bool {
        queueIsProcessing
            || activeWorkerCount > 0
            || activeTaskCount > 0
            || runningTaskCount > 0
    }

    /// Tasks the store records as `.running`.
    ///
    /// The fetch narrows on `completedAt == nil` and refines the status in
    /// memory: a `#Predicate` that captures a `TaskStatus` throws
    /// `unsupportedPredicate` on every store backend, and the old `try?` turned
    /// that into a permanent 0 — so this backstop never blocked an update. A
    /// running task always has `completedAt == nil` (only finalization sets it).
    ///
    /// If the store cannot be read the count is unknown, and an unknown count
    /// blocks the install rather than waving it through.
    static func runningTaskCount(in modelContext: ModelContext) -> Int {
        let descriptor = FetchDescriptor<AgentTask>(
            predicate: #Predicate<AgentTask> { $0.completedAt == nil }
        )
        do {
            return try modelContext.fetch(descriptor).filter { $0.status == .running }.count
        } catch {
            AppLogger.audit(.appUpdateBlocked, category: "Updater", fields: [
                "reason": "running_task_count_unavailable",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
            return 1
        }
    }
}
