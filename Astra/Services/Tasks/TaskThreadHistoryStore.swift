import Foundation
import SwiftData
import ASTRAModels

/// Runs `TaskThreadHistoryReader` off the main actor.
///
/// `ModelContext` declares its `Sendable` conformance unavailable ("contexts
/// cannot be shared across concurrency contexts"), so the caller hands over the
/// `ModelContainer` and every read builds its own context here. Nothing but
/// `Sendable` value snapshots crosses back out; a `TaskRun` or `TaskEvent` must
/// never be returned from these methods.
///
/// A fresh context per read is deliberate rather than wasteful. A long-lived
/// context keeps the row it first materialized for a `TaskEvent`, which would
/// freeze a coalesced streaming payload at whatever text it held on the first
/// read. That is also why this is a plain `actor` rather than `@ModelActor`:
/// the macro pins one context for the actor's whole lifetime.
///
/// Callers must flush the main context before reading. This reads the
/// persistent store, and the streaming path mutates `TaskEvent.payload` in the
/// main context without saving (`AgentEventRecorder`).
actor TaskThreadHistoryStore {
    private let container: ModelContainer
    private lazy var publicationCache = TaskPublicationDecisionEvidenceReader.Cache(container: container)

    #if DEBUG
    func publicationWorkForTesting() -> TaskPublicationDecisionEvidenceReader.Work { publicationCache.work }
    #endif

    init(container: ModelContainer) {
        self.container = container
    }

    /// The newest bounded page. An invalidation must use this same limit,
    /// rather than widening it to the count accumulated during streaming.
    /// Browsing an older window uses `retainedPage` instead.
    func initialPage(
        taskID: UUID,
        ownerID: PersistentIdentifier? = nil,
        runPageSize: Int = TaskThreadHistoryReader.defaultRunPageSize,
        eventPageSize: Int = TaskThreadHistoryReader.defaultEventPageSize,
        historyInvalidation: Int = 0
    ) throws -> TaskThreadHistoryPage {
        // No `await` between the context and the return: the context must never
        // be alive across a suspension point.
        let context = makeContext()
        return try TaskThreadHistoryReader.initialPage(
            taskID: taskID,
            ownerID: ownerID,
            modelContext: context,
            runPageSize: runPageSize,
            eventPageSize: eventPageSize,
            publicationCache: publicationCache,
            historyInvalidation: historyInvalidation
        )
    }

    /// Re-read exactly the browsed rows, including deletions and replacements,
    /// plus current live runs and state anchors. New conversation rows wait for
    /// Jump to latest, so streaming never evicts the reader's scroll anchor.
    func retainedPage(
        taskID: UUID,
        ownerID: PersistentIdentifier,
        eventIDs: [UUID],
        runIDs: [UUID],
        cursor: TaskThreadHistoryCursor,
        historyInvalidation: Int = 0
    ) throws -> TaskThreadHistoryPage {
        try TaskThreadHistoryReader.retainedPage(
            taskID: taskID, ownerID: ownerID, eventIDs: eventIDs,
            runIDs: runIDs, cursor: cursor, modelContext: makeContext(),
            publicationCache: publicationCache, historyInvalidation: historyInvalidation
        )
    }

    func tailPage(
        taskID: UUID,
        ownerID: PersistentIdentifier? = nil,
        since cursor: TaskThreadEventCursor,
        runPageSize: Int = TaskThreadHistoryReader.defaultRunPageSize,
        eventPageSize: Int = TaskThreadHistoryReader.defaultEventPageSize,
        historyInvalidation: Int = 0
    ) throws -> TaskThreadHistoryTailPage {
        try TaskThreadHistoryReader.tailPage(
            taskID: taskID,
            ownerID: ownerID,
            since: cursor,
            modelContext: makeContext(),
            runPageSize: runPageSize,
            eventPageSize: eventPageSize,
            publicationCache: publicationCache,
            historyInvalidation: historyInvalidation
        )
    }

    func previousPage(
        taskID: UUID,
        ownerID: PersistentIdentifier? = nil,
        before cursor: TaskThreadHistoryCursor,
        runPageSize: Int = TaskThreadHistoryReader.defaultRunPageSize,
        eventPageSize: Int = TaskThreadHistoryReader.defaultEventPageSize
    ) throws -> TaskThreadHistoryPage {
        try TaskThreadHistoryReader.previousPage(
            taskID: taskID,
            ownerID: ownerID,
            before: cursor,
            modelContext: makeContext(),
            runPageSize: runPageSize,
            eventPageSize: eventPageSize
        )
    }

    /// The task's turns that changed files, newest first. Unlike the pages
    /// above, this reads every run: turn numbers count the whole task.
    func fileTurns(
        taskID: UUID,
        ownerID: PersistentIdentifier? = nil,
        taskFolder: String,
        workspacePath: String,
        executionPath: String? = nil,
        additionalRoots: [String] = [],
        pendingRuns: [TaskFileTurnsReader.PendingRun] = []
    ) throws -> [TaskFileTurn] {
        guard let input = try TaskFileTurnsReader.input(
            taskID: taskID,
            ownerID: ownerID,
            taskFolder: taskFolder,
            workspacePath: workspacePath,
            executionPath: executionPath,
            additionalRoots: additionalRoots,
            pendingRuns: pendingRuns,
            modelContext: makeContext()
        ) else { return [] }
        return TaskFileTurns.build(input)
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        // These contexts only ever read. Autosave would let SwiftData write
        // back from a background isolation the app does not own.
        context.autosaveEnabled = false
        return context
    }
}
