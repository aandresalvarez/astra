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

/// Reads bounded pages directly from SwiftData. The durable `TaskRun` and
/// `TaskEvent` rows remain the only owners of thread history; this service
/// returns immutable presentation inputs and never persists a second copy.
@MainActor
enum TaskThreadHistoryReader {
    nonisolated static let defaultRunPageSize = 50
    nonisolated static let defaultEventPageSize = 1_200

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
        let totalRunCount = try modelContext.fetchCount(FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.task?.id == taskID }
        ))
        let totalEventCount = try modelContext.fetchCount(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.task?.id == taskID }
        ))
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
        let stateEventTypes = TaskThreadStateEventPolicy.eventTypes
        var events: [TaskEvent] = []
        for run in runs {
            let runID = run.id
            let descriptor = FetchDescriptor<TaskEvent>(
                predicate: #Predicate<TaskEvent> {
                    $0.task?.id == taskID
                        && $0.run?.id == runID
                        && stateEventTypes.contains($0.type)
                }
            )
            events.append(contentsOf: try modelContext.fetch(descriptor))
        }
        if includeRunless {
            let descriptor = FetchDescriptor<TaskEvent>(
                predicate: #Predicate<TaskEvent> {
                    $0.task?.id == taskID
                        && $0.run == nil
                        && stateEventTypes.contains($0.type)
                }
            )
            events.append(contentsOf: try modelContext.fetch(descriptor))
        }

        var latestByKey: [TaskThreadStateEventKey: TaskEventSnapshot] = [:]
        for event in events {
            let snapshot = TaskEventSnapshot(event: event)
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

    private static func logRead(
        operation: String,
        page: TaskThreadHistoryPage,
        startedAt: UInt64,
        taskID: UUID
    ) {
        PerformanceTelemetry.logIfNeeded(
            "thread_history_page_read",
            start: startedAt,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "operation": operation,
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
}
