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
    /// memory: older SwiftData versions reject predicates that capture `TaskStatus`
    /// with `unsupportedPredicate`, and the old `try?` turned
    /// that into a permanent 0 — so this backstop never blocked an update. A
    /// running task always has `completedAt == nil` (only finalization sets it).
    ///
    /// This is the count that decides whether an install may proceed, so it
    /// always asks the store: the fetch also brings rows this context holds up
    /// to date with what another context has saved.
    ///
    /// If the store cannot be read the count is unknown, and an unknown count
    /// blocks the install rather than waving it through.
    static func runningTaskCount(in modelContext: ModelContext) -> Int {
        count(in: modelContext) { try fetchedRunningTaskCount(in: $0) }
    }

    /// The same count from rows the context already holds, for the window's
    /// own bookkeeping after a run, cancel, delete or mark-done click.
    ///
    /// Drafts never get a `completedAt`, so in a real store the open set is
    /// most of the table: 1,605 of 2,208 tasks in the production store this
    /// was measured on, 1,578 of them drafts. Fetching those rows on each of
    /// those clicks cost a median 144 ms on the main thread (278 calls, 54 s
    /// over eight days of production logs). The window's context holds every
    /// task for the sidebar, so the status is read off the instance it has
    /// registered: 4 ms against 100 ms on a copy of that store. A context
    /// registers a row only while something holds it, so one that is missing
    /// any of them fetches the open set instead.
    ///
    /// **Not for the install decision.** A held row keeps its old status
    /// after another context saves a new one, until the row is next fetched.
    /// `runningTaskCount(in:)` is the one that gates an install.
    static func heldRunningTaskCount(in modelContext: ModelContext) -> Int {
        PerformanceTelemetry.measure("update_safety_held_count", thresholdMilliseconds: 8) {
            count(in: modelContext) {
                try registeredRunningTaskCount(in: $0) ?? fetchedRunningTaskCount(in: $0)
            }
        }
    }

    private static func count(in modelContext: ModelContext, _ read: (ModelContext) throws -> Int) -> Int {
        do {
            return try read(modelContext)
        } catch {
            AppLogger.audit(.appUpdateBlocked, category: "Updater", fields: [
                "reason": "running_task_count_unavailable",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
            return 1
        }
    }

    private static var openTasks: FetchDescriptor<AgentTask> {
        FetchDescriptor<AgentTask>(predicate: #Predicate<AgentTask> { $0.completedAt == nil })
    }

    /// The count from rows the context already holds, or nil when it does not
    /// hold all of them. Not `private`: a test has to tell this path from the
    /// fetch it replaces, and both return the same number.
    static func registeredRunningTaskCount(in modelContext: ModelContext) throws -> Int? {
        var running = Set<PersistentIdentifier>()
        for identifier in try modelContext.fetchIdentifiers(openTasks) {
            guard let task: AgentTask = modelContext.registeredModel(for: identifier) else { return nil }
            if isRunning(task) { running.insert(identifier) }
        }
        // Unsaved work belongs to the context, not the store: a task inserted
        // or reopened since the last save may have no row for the identifier
        // read to find, and it blocks an install all the same.
        for model in modelContext.insertedModelsArray + modelContext.changedModelsArray {
            guard let task = model as? AgentTask, isRunning(task) else { continue }
            running.insert(task.persistentModelID)
        }
        return running.count
    }

    static func fetchedRunningTaskCount(in modelContext: ModelContext) throws -> Int {
        try modelContext.fetch(openTasks).filter { $0.status == .running }.count
    }

    private static func isRunning(_ task: AgentTask) -> Bool {
        !task.isDeleted && task.completedAt == nil && task.status == .running
    }
}
