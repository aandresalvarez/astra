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

    init(container: ModelContainer) {
        self.container = container
    }

    /// The newest page. `covering*` widen it to at least the window the caller
    /// already holds — the page size is the floor, never the cap — because a
    /// caller that has to *replace* what it accumulated (an announced mutation
    /// invalidated it) would otherwise collapse a transcript the user paged
    /// open back to a single page and lose their place. The widening is bounded
    /// by rows the caller is already holding in memory.
    func initialPage(
        taskID: UUID,
        coveringEventCount: Int = 0,
        coveringRunCount: Int = 0,
        runPageSize: Int = TaskThreadHistoryReader.defaultRunPageSize,
        eventPageSize: Int = TaskThreadHistoryReader.defaultEventPageSize
    ) throws -> TaskThreadHistoryPage {
        // No `await` between the context and the return: the context must never
        // be alive across a suspension point.
        try TaskThreadHistoryReader.initialPage(
            taskID: taskID,
            modelContext: makeContext(),
            runPageSize: max(runPageSize, coveringRunCount),
            eventPageSize: max(eventPageSize, coveringEventCount)
        )
    }

    func tailPage(
        taskID: UUID,
        since cursor: TaskThreadEventCursor,
        runPageSize: Int = TaskThreadHistoryReader.defaultRunPageSize,
        eventPageSize: Int = TaskThreadHistoryReader.defaultEventPageSize
    ) throws -> TaskThreadHistoryTailPage {
        try TaskThreadHistoryReader.tailPage(
            taskID: taskID,
            since: cursor,
            modelContext: makeContext(),
            runPageSize: runPageSize,
            eventPageSize: eventPageSize
        )
    }

    func previousPage(
        taskID: UUID,
        before cursor: TaskThreadHistoryCursor,
        runPageSize: Int = TaskThreadHistoryReader.defaultRunPageSize,
        eventPageSize: Int = TaskThreadHistoryReader.defaultEventPageSize
    ) throws -> TaskThreadHistoryPage {
        try TaskThreadHistoryReader.previousPage(
            taskID: taskID,
            before: cursor,
            modelContext: makeContext(),
            runPageSize: runPageSize,
            eventPageSize: eventPageSize
        )
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        // These contexts only ever read. Autosave would let SwiftData write
        // back from a background isolation the app does not own.
        context.autosaveEnabled = false
        return context
    }
}
