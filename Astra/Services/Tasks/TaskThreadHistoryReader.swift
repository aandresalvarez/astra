import Foundation
import SwiftData
import ASTRAModels

struct TaskThreadRunCursor: Equatable, Sendable {
    let startedAt: Date
    let id: UUID
}

struct TaskThreadEventCursor: Equatable, Sendable {
    let timestamp: Date
    let id: UUID
}

struct TaskThreadHistoryCursor: Equatable, Sendable {
    let run: TaskThreadRunCursor?
    let event: TaskThreadEventCursor?
    let hasEarlierRuns: Bool
    let hasEarlierEvents: Bool

    var hasEarlierHistory: Bool {
        hasEarlierRuns || hasEarlierEvents
    }
}

struct TaskThreadHistoryPage: Sendable {
    let runs: [TaskRunSnapshotInput]
    let events: [TaskEventSnapshot]
    let stateAnchors: [TaskEventSnapshot]
    let cursor: TaskThreadHistoryCursor
    let totalRunCount: Int
    let totalEventCount: Int
}

/// The newest slice of a transcript, read from a caller-held cursor instead of
/// from the top. It carries no state anchors: those are a whole-task scan, and
/// the caller keeps the ones its last full page produced.
struct TaskThreadHistoryTailPage: Sendable {
    /// Newest first, exactly like `TaskThreadHistoryPage.events`.
    let events: [TaskEventSnapshot]
    let runs: [TaskRunSnapshotInput]
    let totalRunCount: Int
    let totalEventCount: Int
    let hasEarlierRuns: Bool
    let overflowed: Bool
}

/// Reads bounded pages directly from SwiftData. The durable `TaskRun` and
/// `TaskEvent` rows remain the only owners of thread history; this service
/// returns immutable presentation inputs and never persists a second copy.
///
/// Deliberately not isolated: production drives it from `TaskThreadHistoryStore`
/// on a background context, and it needs nothing from the main actor. Every
/// entry point takes the caller's `ModelContext` and returns only `Sendable`
/// snapshots, so a managed model can never escape the isolation that fetched it.
enum TaskThreadHistoryReader {
    static let defaultRunPageSize = 50
    static let defaultEventPageSize = 1_200

    static func initialPage(
        taskID: UUID,
        modelContext: ModelContext,
        runPageSize: Int = defaultRunPageSize,
        eventPageSize: Int = defaultEventPageSize
    ) throws -> TaskThreadHistoryPage {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let runResult = try latestRuns(
            taskID: taskID,
            limit: max(1, runPageSize),
            modelContext: modelContext
        )
        let eventResult = try latestEvents(
            taskID: taskID,
            limit: max(1, eventPageSize),
            modelContext: modelContext
        )
        let page = try makePage(
            taskID: taskID,
            runs: runResult.items,
            events: eventResult.items,
            hasEarlierRuns: runResult.hasEarlier,
            hasEarlierEvents: eventResult.hasEarlier,
            modelContext: modelContext,
            includeRunlessStateAnchors: true
        )
        logRead(operation: "latest", page: page, startedAt: startedAt, taskID: taskID)
        return page
    }

    /// Reads only the rows at or after `cursor`, which is what a streaming
    /// append actually changes. Backdated inserts and deletions are invisible
    /// here by construction, so callers must reconcile `totalEventCount`
    /// against their own accumulated count and fall back to `initialPage`
    /// whenever it does not match.
    static func tailPage(
        taskID: UUID,
        since cursor: TaskThreadEventCursor,
        modelContext: ModelContext,
        runPageSize: Int = defaultRunPageSize,
        eventPageSize: Int = defaultEventPageSize
    ) throws -> TaskThreadHistoryTailPage {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let eventResult = try eventsSince(
            taskID: taskID,
            cursor: cursor,
            limit: max(1, eventPageSize),
            modelContext: modelContext
        )
        // `TaskRun.output`, `status` and `completedAt` mutate in place with no
        // ordering key, so the newest run page must still be re-read or a live
        // run's streamed output stops updating.
        let runResult = try latestRuns(
            taskID: taskID,
            limit: max(1, runPageSize),
            modelContext: modelContext
        )
        let counts = try totals(taskID: taskID, modelContext: modelContext)
        let page = TaskThreadHistoryTailPage(
            events: eventResult.items.map(TaskEventSnapshot.init),
            runs: runResult.items.map(TaskRunSnapshotInput.init),
            totalRunCount: counts.runs,
            totalEventCount: counts.events,
            hasEarlierRuns: runResult.hasEarlier,
            overflowed: eventResult.hasEarlier
        )
        logRead(tail: page, startedAt: startedAt, taskID: taskID)
        return page
    }

    static func previousPage(
        taskID: UUID,
        before cursor: TaskThreadHistoryCursor,
        modelContext: ModelContext,
        runPageSize: Int = defaultRunPageSize,
        eventPageSize: Int = defaultEventPageSize
    ) throws -> TaskThreadHistoryPage {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let runResult: PageResult<TaskRun>
        if cursor.hasEarlierRuns, let runCursor = cursor.run {
            runResult = try runs(
                taskID: taskID,
                before: runCursor,
                limit: max(1, runPageSize),
                modelContext: modelContext
            )
        } else {
            runResult = PageResult(items: [], hasEarlier: false)
        }

        let eventResult: PageResult<TaskEvent>
        if cursor.hasEarlierEvents, let eventCursor = cursor.event {
            eventResult = try events(
                taskID: taskID,
                before: eventCursor,
                limit: max(1, eventPageSize),
                modelContext: modelContext
            )
        } else {
            eventResult = PageResult(items: [], hasEarlier: false)
        }

        let page = try makePage(
            taskID: taskID,
            runs: runResult.items,
            events: eventResult.items,
            hasEarlierRuns: runResult.hasEarlier,
            hasEarlierEvents: eventResult.hasEarlier,
            modelContext: modelContext,
            includeRunlessStateAnchors: false
        )
        logRead(operation: "previous", page: page, startedAt: startedAt, taskID: taskID)
        return page
    }

    private struct PageResult<Model> {
        let items: [Model]
        let hasEarlier: Bool
    }

    private static func makePage(
        taskID: UUID,
        runs: [TaskRun],
        events: [TaskEvent],
        hasEarlierRuns: Bool,
        hasEarlierEvents: Bool,
        modelContext: ModelContext,
        includeRunlessStateAnchors: Bool
    ) throws -> TaskThreadHistoryPage {
        let counts = try totals(taskID: taskID, modelContext: modelContext)
        let totalRunCount = counts.runs
        let totalEventCount = counts.events
        let runSnapshots = runs.map(TaskRunSnapshotInput.init)
        let eventSnapshots = events.map(TaskEventSnapshot.init)
        let stateAnchors = try latestStateAnchors(
            taskID: taskID,
            runs: runs,
            includeRunless: includeRunlessStateAnchors,
            modelContext: modelContext
        )

        return TaskThreadHistoryPage(
            runs: runSnapshots,
            events: eventSnapshots,
            stateAnchors: stateAnchors,
            cursor: TaskThreadHistoryCursor(
                run: runs.last.map { TaskThreadRunCursor(startedAt: $0.startedAt, id: $0.id) },
                event: events.last.map { TaskThreadEventCursor(timestamp: $0.timestamp, id: $0.id) },
                hasEarlierRuns: hasEarlierRuns,
                hasEarlierEvents: hasEarlierEvents
            ),
            totalRunCount: totalRunCount,
            totalEventCount: totalEventCount
        )
    }

    /// The authoritative row counts for the task. Tail reads reconcile against
    /// these, so both callers must derive them from the same predicates.
    private static func totals(
        taskID: UUID,
        modelContext: ModelContext
    ) throws -> (runs: Int, events: Int) {
        let runCount = try modelContext.fetchCount(FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.task?.id == taskID }
        ))
        let eventCount = try modelContext.fetchCount(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.task?.id == taskID }
        ))
        return (runCount, eventCount)
    }

    private static func latestRuns(
        taskID: UUID,
        limit: Int,
        modelContext: ModelContext
    ) throws -> PageResult<TaskRun> {
        var descriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.task?.id == taskID },
            sortBy: [
                SortDescriptor(\TaskRun.startedAt, order: .reverse),
                SortDescriptor(\TaskRun.id, order: .reverse)
            ]
        )
        descriptor.fetchLimit = limit + 1
        let fetched = try modelContext.fetch(descriptor)
        return PageResult(items: Array(fetched.prefix(limit)), hasEarlier: fetched.count > limit)
    }

    private static func latestEvents(
        taskID: UUID,
        limit: Int,
        modelContext: ModelContext
    ) throws -> PageResult<TaskEvent> {
        var descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.task?.id == taskID },
            sortBy: [
                SortDescriptor(\TaskEvent.timestamp, order: .reverse),
                SortDescriptor(\TaskEvent.id, order: .reverse)
            ]
        )
        descriptor.fetchLimit = limit + 1
        let fetched = try modelContext.fetch(descriptor)
        return PageResult(items: Array(fetched.prefix(limit)), hasEarlier: fetched.count > limit)
    }

    /// The boundary is inclusive on purpose. `>=` re-reads the cursor row and
    /// its whole timestamp tie group, so a stream chunk coalesced in place
    /// (which bumps `timestamp` forward) and same-millisecond siblings both
    /// come back; a strict composite compare would drop a tie-mate whose UUID
    /// sorts below the cursor. Callers dedupe by id.
    private static func eventsSince(
        taskID: UUID,
        cursor: TaskThreadEventCursor,
        limit: Int,
        modelContext: ModelContext
    ) throws -> PageResult<TaskEvent> {
        let boundaryDate = cursor.timestamp
        var descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID && $0.timestamp >= boundaryDate
            },
            sortBy: [
                SortDescriptor(\TaskEvent.timestamp, order: .reverse),
                SortDescriptor(\TaskEvent.id, order: .reverse)
            ]
        )
        descriptor.fetchLimit = limit + 1
        let fetched = try modelContext.fetch(descriptor)
        return PageResult(items: Array(fetched.prefix(limit)), hasEarlier: fetched.count > limit)
    }

    /// Handles timestamp ties without offset pagination. Boundary rows are read
    /// separately and ordered by UUID, then the query continues strictly before
    /// the timestamp. Newer inserts therefore cannot shift or duplicate a page.
    private static func runs(
        taskID: UUID,
        before cursor: TaskThreadRunCursor,
        limit: Int,
        modelContext: ModelContext
    ) throws -> PageResult<TaskRun> {
        let boundaryDate = cursor.startedAt
        let boundaryID = cursor.id
        var boundaryDescriptor = FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> {
                $0.task?.id == taskID
                    && $0.startedAt == boundaryDate
                    && $0.id < boundaryID
            },
            sortBy: [SortDescriptor(\TaskRun.id, order: .reverse)]
        )
        boundaryDescriptor.fetchLimit = limit + 1
        let boundaryItems = try modelContext.fetch(boundaryDescriptor)
        return try pageBeforeRunBoundary(
            taskID: taskID,
            boundaryItems: boundaryItems,
            boundaryDate: boundaryDate,
            limit: limit,
            modelContext: modelContext
        )
    }

    private static func pageBeforeRunBoundary(
        taskID: UUID,
        boundaryItems: [TaskRun],
        boundaryDate: Date,
        limit: Int,
        modelContext: ModelContext
    ) throws -> PageResult<TaskRun> {
        var candidates = boundaryItems
        let remaining = max(0, limit + 1 - candidates.count)
        if remaining > 0 {
            var earlierDescriptor = FetchDescriptor<TaskRun>(
                predicate: #Predicate<TaskRun> {
                    $0.task?.id == taskID && $0.startedAt < boundaryDate
                },
                sortBy: [
                    SortDescriptor(\TaskRun.startedAt, order: .reverse),
                    SortDescriptor(\TaskRun.id, order: .reverse)
                ]
            )
            earlierDescriptor.fetchLimit = remaining
            candidates.append(contentsOf: try modelContext.fetch(earlierDescriptor))
        }
        return PageResult(items: Array(candidates.prefix(limit)), hasEarlier: candidates.count > limit)
    }

    private static func events(
        taskID: UUID,
        before cursor: TaskThreadEventCursor,
        limit: Int,
        modelContext: ModelContext
    ) throws -> PageResult<TaskEvent> {
        let boundaryDate = cursor.timestamp
        let boundaryID = cursor.id
        var boundaryDescriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID
                    && $0.timestamp == boundaryDate
                    && $0.id < boundaryID
            },
            sortBy: [SortDescriptor(\TaskEvent.id, order: .reverse)]
        )
        boundaryDescriptor.fetchLimit = limit + 1
        let boundaryItems = try modelContext.fetch(boundaryDescriptor)
        var candidates = boundaryItems
        let remaining = max(0, limit + 1 - candidates.count)
        if remaining > 0 {
            var earlierDescriptor = FetchDescriptor<TaskEvent>(
                predicate: #Predicate<TaskEvent> {
                    $0.task?.id == taskID && $0.timestamp < boundaryDate
                },
                sortBy: [
                    SortDescriptor(\TaskEvent.timestamp, order: .reverse),
                    SortDescriptor(\TaskEvent.id, order: .reverse)
                ]
            )
            earlierDescriptor.fetchLimit = remaining
            candidates.append(contentsOf: try modelContext.fetch(earlierDescriptor))
        }
        return PageResult(items: Array(candidates.prefix(limit)), hasEarlier: candidates.count > limit)
    }

    private static func latestStateAnchors(
        taskID: UUID,
        runs: [TaskRun],
        includeRunless: Bool,
        modelContext: ModelContext
    ) throws -> [TaskEventSnapshot] {
        // One fetch per loaded run cost up to 51 round trips per page read on the
        // main actor. The run membership test is applied in memory instead: it is
        // the same predicate, factored, and `TaskEvent` has no scalar run-id
        // column to filter an optional relationship on in SQL.
        guard !runs.isEmpty || includeRunless else { return [] }
        let stateEventTypes = TaskThreadStateEventPolicy.eventTypes
        var descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID && stateEventTypes.contains($0.type)
            }
        )
        // `TaskEventSnapshot` reads `event.run?.id` for every row, so prefetch the
        // relationship rather than faulting it one row at a time.
        descriptor.relationshipKeyPathsForPrefetching = [\TaskEvent.run]
        let events = try modelContext.fetch(descriptor)
        let loadedRunIDs = Set(runs.map(\.id))

        var latestByKey: [TaskThreadStateEventKey: TaskEventSnapshot] = [:]
        for event in events {
            let snapshot = TaskEventSnapshot(event: event)
            if let runID = snapshot.runID {
                guard loadedRunIDs.contains(runID) else { continue }
            } else {
                guard includeRunless else { continue }
            }
            let key = TaskThreadStateEventKey(event: snapshot)
            if let current = latestByKey[key], !isLater(snapshot, than: current) {
                continue
            }
            latestByKey[key] = snapshot
        }
        return Array(latestByKey.values)
    }

    private static func isLater(
        _ candidate: TaskEventSnapshot,
        than current: TaskEventSnapshot
    ) -> Bool {
        if candidate.timestamp != current.timestamp {
            return candidate.timestamp > current.timestamp
        }
        return candidate.id.uuidString > current.id.uuidString
    }

    /// Durations before and after the offload are not comparable, so every read
    /// records where it ran. A `main` value in production means something put
    /// the read back on the UI path.
    private static var isolationField: String {
        Thread.isMainThread ? "main" : "background"
    }

    private static func logRead(
        operation: String,
        page: TaskThreadHistoryPage,
        startedAt: UInt64,
        taskID: UUID
    ) {
        PerformanceTelemetry.logIfNeeded(
            "thread_history_page_read",
            start: startedAt,
            thresholdMilliseconds: PerformanceTelemetry.backgroundThresholdMilliseconds,
            fields: [
                "operation": operation,
                "isolation": Self.isolationField,
                "task_id": PerformanceTelemetryFields.abbreviatedID(taskID),
                "page_events": PerformanceTelemetryFields.count(page.events.count),
                "page_runs": PerformanceTelemetryFields.count(page.runs.count),
                "state_anchors": PerformanceTelemetryFields.count(page.stateAnchors.count),
                "total_events": PerformanceTelemetryFields.count(page.totalEventCount),
                "total_runs": PerformanceTelemetryFields.count(page.totalRunCount),
                "has_earlier_events": PerformanceTelemetryFields.bool(page.cursor.hasEarlierEvents),
                "has_earlier_runs": PerformanceTelemetryFields.bool(page.cursor.hasEarlierRuns)
            ],
            taskID: taskID
        )
    }

    private static func logRead(
        tail: TaskThreadHistoryTailPage,
        startedAt: UInt64,
        taskID: UUID
    ) {
        PerformanceTelemetry.logIfNeeded(
            "thread_history_page_read",
            start: startedAt,
            thresholdMilliseconds: PerformanceTelemetry.backgroundThresholdMilliseconds,
            fields: [
                "operation": "tail",
                "isolation": Self.isolationField,
                "task_id": PerformanceTelemetryFields.abbreviatedID(taskID),
                "page_events": PerformanceTelemetryFields.count(tail.events.count),
                "page_runs": PerformanceTelemetryFields.count(tail.runs.count),
                "total_events": PerformanceTelemetryFields.count(tail.totalEventCount),
                "total_runs": PerformanceTelemetryFields.count(tail.totalRunCount),
                "overflowed": PerformanceTelemetryFields.bool(tail.overflowed),
                "has_earlier_runs": PerformanceTelemetryFields.bool(tail.hasEarlierRuns)
            ],
            taskID: taskID
        )
    }
}
