import Foundation
import ASTRAModels
import ASTRAPersistence

/// Stable correlation data supplied by the task-open trace while its initial
/// snapshot is being prepared. It contains no user content and keeps the
/// snapshot pipeline independent of the UI telemetry implementation.
struct TaskThreadResponsivenessContext: Sendable, Equatable {
    let traceID: String

    var fields: [String: String] {
        ["trace_id": traceID]
    }
}

struct TaskThreadSnapshotReadiness: Equatable, Sendable {
    let taskID: UUID?
    let revision: Int

    func isReady(for taskID: UUID) -> Bool {
        self.taskID == taskID && revision > 0
    }
}

@Observable @MainActor
final class TaskThreadViewModel {
    private(set) var snapshot: TaskThreadSnapshot?
    private(set) var generatedFilePaths: [String] = []
    /// Advances only when a non-placeholder snapshot has been applied. Views use
    /// this cheap revision to distinguish the initial shell from a transcript
    /// that is ready to lay out.
    private(set) var appliedSnapshotRevision = 0
    /// The task that produced the most recently applied non-placeholder
    /// snapshot. This prevents a previous task's ready state from being used
    /// while a newly selected task is still displaying its placeholder.
    private(set) var appliedSnapshotTaskID: UUID?
    /// Cache state for the most recent snapshot refresh, exposed as a safe
    /// diagnostic dimension for task-open responsiveness traces. Set to
    /// "pending" by `reset`, then to "hit" on a cache hit or "miss"/
    /// "not_applicable" as soon as a fresh build is kicked off -- in the
    /// miss/not_applicable case this is set before the detached build
    /// actually applies its result.
    private(set) var lastSnapshotCacheState = "not_applicable"

    /// An Equatable signal that changes when a real transcript snapshot is
    /// applied, even when that snapshot produces the same layout geometry as
    /// the placeholder it replaces.
    var appliedSnapshotReadiness: TaskThreadSnapshotReadiness {
        TaskThreadSnapshotReadiness(
            taskID: appliedSnapshotTaskID,
            revision: appliedSnapshotRevision
        )
    }

    private var snapshotTrigger: TaskThreadSnapshotTrigger?
    private var snapshotTask: Task<Void, Never>?
    private var generatedFilesTask: Task<Void, Never>?
    private var expansionRunCount: Int = 50
    private var lastSnapshotApplyAt: Date = .distantPast
    private(set) var lastSnapshotAppliedUptimeNanoseconds: UInt64?
    /// Trace identity currently attached to the initial snapshot pipeline. This
    /// is diagnostic state only; it is cleared once transcript readiness has
    /// completed so live refreshes cannot inherit a completed open trace.
    private(set) var initialSnapshotResponsivenessTraceID: String?
    private var snapshotRevision: Int = 0
    private var responsivenessContext: TaskThreadResponsivenessContext?
    private var deferredLiveSnapshotCount = 0
    private var lastLiveSnapshotTelemetryAt: Date = .distantPast

    private static let liveSnapshotMinimumInterval: TimeInterval = 0.120
    private static var terminalSnapshotCache = TaskThreadSnapshotCache()

    func reset(for task: AgentTask, responsivenessContext: TaskThreadResponsivenessContext? = nil) {
        PerformanceTelemetry.measure(
            "chat_thread_reset",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: Self.taskFields(task)
        ) {
            expansionRunCount = 50
            snapshotTrigger = nil
            snapshotTask?.cancel()
            lastSnapshotApplyAt = .distantPast
            lastSnapshotAppliedUptimeNanoseconds = nil
            initialSnapshotResponsivenessTraceID = responsivenessContext?.traceID
            appliedSnapshotRevision = 0
            appliedSnapshotTaskID = nil
            lastSnapshotCacheState = "pending"
            self.responsivenessContext = responsivenessContext
            deferredLiveSnapshotCount = 0
            lastLiveSnapshotTelemetryAt = .distantPast
            snapshot = TaskThreadSnapshot.placeholder(goal: task.goal, createdAt: task.createdAt)
            refreshSnapshot(for: task)
            refreshGeneratedFiles(folder: TaskWorkspaceAccess(task: task).taskFolder)
        }
    }

    func refreshSnapshot(for task: AgentTask) {
        let trigger = TaskThreadSnapshotTrigger(task: task)
        guard snapshotTrigger != trigger else { return }
        snapshotTrigger = trigger
        var fields = Self.taskFields(task)
        fields.merge(Self.triggerFields(trigger), uniquingKeysWith: { _, new in new })
        fields.merge([
            "status": trigger.status.rawValue,
            "latest_run_status": trigger.latestRunStatus?.rawValue ?? "none"
        ], uniquingKeysWith: { _, new in new })

        snapshotTask?.cancel()
        let responsivenessContext = responsivenessContext
        let cacheKey = TaskThreadSnapshotCacheKey(task: task, trigger: trigger, maxRuns: expansionRunCount)
        if let cacheKey,
           let cachedSnapshot = Self.terminalSnapshotCache.snapshot(for: cacheKey) {
            let cacheApplyStart = DispatchTime.now().uptimeNanoseconds
            snapshot = cachedSnapshot
            appliedSnapshotRevision += 1
            appliedSnapshotTaskID = task.id
            lastSnapshotCacheState = "hit"
            lastSnapshotApplyAt = Date()
            lastSnapshotAppliedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            if let responsivenessContext {
                PerformanceTelemetry.log(
                    "task_open_snapshot_cache_apply",
                    durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: cacheApplyStart),
                    fields: fields.merging(responsivenessContext.fields, uniquingKeysWith: { _, new in new }),
                    taskID: task.id
                )
            }
            fields.merge(Self.snapshotFields(cachedSnapshot), uniquingKeysWith: { _, new in new })
            PerformanceTelemetry.log("thread_snapshot_cache", level: .debug, fields: fields.merging([
                "cache_state": "hit"
            ], uniquingKeysWith: { _, new in new }))
            Self.logSnapshotState(
                snapshot: cachedSnapshot,
                trigger: trigger,
                taskID: task.id,
                workspaceID: task.workspace?.id
            )
            return
        }

        let inputStart = DispatchTime.now().uptimeNanoseconds
        let input = TaskThreadSnapshotInput(
            task: task,
            maxRuns: expansionRunCount,
            performanceFields: responsivenessContext?.fields ?? [:]
        )
        if let responsivenessContext {
            PerformanceTelemetry.log(
                "task_open_snapshot_input_capture",
                durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: inputStart),
                fields: fields.merging(responsivenessContext.fields, uniquingKeysWith: { _, new in new }),
                taskID: task.id
            )
        }
        lastSnapshotCacheState = cacheKey == nil ? "not_applicable" : "miss"
        fields.merge(Self.inputFields(input), uniquingKeysWith: { _, new in new })

        let isLive = trigger.status == .running
            || trigger.status == .queued
            || trigger.latestRunStatus == .running
        let elapsed = Date().timeIntervalSince(lastSnapshotApplyAt)
        let minimumInterval = Self.liveSnapshotMinimumInterval
        let delay = isLive && elapsed < minimumInterval ? (minimumInterval - elapsed) : 0
        if isLive, delay > 0 {
            deferredLiveSnapshotCount += 1
        }
        let taskID = task.id
        let workspaceID = task.workspace?.id
        snapshotRevision += 1
        let revision = snapshotRevision
        let scheduledAt = DispatchTime.now().uptimeNanoseconds
        let traceFields = responsivenessContext?.fields ?? [:]
        let snapshotPerformanceFields = fields.merging(traceFields, uniquingKeysWith: { _, new in new })
        let shouldLogLiveCadence = isLive
            && Date().timeIntervalSince(lastLiveSnapshotTelemetryAt) >= 1
        if shouldLogLiveCadence {
            lastLiveSnapshotTelemetryAt = Date()
        }
        snapshotTask = Task.detached(priority: .userInitiated) { [self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            if responsivenessContext != nil {
                PerformanceTelemetry.log(
                    "task_open_snapshot_queue_wait",
                    durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: scheduledAt),
                    fields: snapshotPerformanceFields,
                    taskID: taskID
                )
            }
            let buildStartedAt = DispatchTime.now().uptimeNanoseconds
            let builtSnapshot = await TaskThreadSnapshot.buildAsync(input: input, fields: snapshotPerformanceFields)
            guard !Task.isCancelled else { return }
            let buildCompletedAt = DispatchTime.now().uptimeNanoseconds
            await MainActor.run {
                guard !Task.isCancelled, revision == self.snapshotRevision else { return }
                if responsivenessContext != nil {
                    PerformanceTelemetry.log(
                        "task_open_snapshot_main_actor_apply_wait",
                        durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: buildCompletedAt),
                        fields: snapshotPerformanceFields,
                        taskID: taskID
                    )
                }
                let applyStartedAt = DispatchTime.now().uptimeNanoseconds
                self.snapshot = builtSnapshot
                self.appliedSnapshotRevision += 1
                self.appliedSnapshotTaskID = taskID
                if let cacheKey {
                    Self.terminalSnapshotCache.store(builtSnapshot, for: cacheKey)
                }
                self.lastSnapshotApplyAt = Date()
                self.lastSnapshotAppliedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                if responsivenessContext != nil {
                    PerformanceTelemetry.log(
                        "task_open_snapshot_apply",
                        durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: applyStartedAt),
                        fields: snapshotPerformanceFields,
                        taskID: taskID
                    )
                }
                if shouldLogLiveCadence {
                    PerformanceTelemetry.log(
                        "chat_stream_snapshot_cadence",
                        durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: buildStartedAt),
                        level: .debug,
                        fields: fields.merging([
                            "throttle_delay_ms": String(format: "%.2f", delay * 1_000),
                            "deferred_snapshot_count": PerformanceTelemetryFields.count(self.deferredLiveSnapshotCount)
                        ], uniquingKeysWith: { _, new in new }),
                        taskID: taskID
                    )
                    self.deferredLiveSnapshotCount = 0
                }
                Self.logSnapshotState(
                    snapshot: builtSnapshot,
                    trigger: trigger,
                    taskID: taskID,
                    workspaceID: workspaceID
                )
            }
        }
    }

    /// Ends correlation for the initial task-open snapshot after the view has
    /// emitted transcript readiness. Subsequent streaming refreshes retain
    /// their own bounded cadence telemetry but are not misattributed to open.
    func completeInitialResponsivenessTrace(for taskID: UUID) {
        guard appliedSnapshotTaskID == taskID else { return }
        responsivenessContext = nil
        initialSnapshotResponsivenessTraceID = nil
    }

    /// Stops the initial snapshot pipeline when its task-open trace ends before
    /// the transcript becomes ready, preventing late phases from using a stale
    /// trace ID.
    func cancelInitialResponsivenessSnapshot(for taskID: UUID) {
        guard snapshotTrigger?.taskID == taskID, responsivenessContext != nil else { return }
        snapshotTask?.cancel()
        responsivenessContext = nil
        initialSnapshotResponsivenessTraceID = nil
    }

    static func resetSnapshotCacheForTesting() {
        terminalSnapshotCache.removeAll()
    }

    static var snapshotCacheStatsForTesting: TaskThreadSnapshotCache.Stats {
        terminalSnapshotCache.stats
    }

    private static func taskFields(_ task: AgentTask) -> [String: String] {
        [
            "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
            "workspace_id": PerformanceTelemetryFields.abbreviatedID(task.workspace?.id),
            "status": task.status.rawValue
        ]
    }

    private static func triggerFields(_ trigger: TaskThreadSnapshotTrigger) -> [String: String] {
        [
            "event_count": PerformanceTelemetryFields.count(trigger.eventCount),
            "visible_event_count": PerformanceTelemetryFields.count(trigger.visibleEventCount),
            "run_count": PerformanceTelemetryFields.count(trigger.runCount),
            "latest_run_output_bucket": PerformanceTelemetryFields.count(trigger.latestRunOutputBucket),
            "latest_run_output_bytes": PerformanceTelemetryFields.count(trigger.latestRunOutputCount),
            "latest_run_output_byte_bucket": PerformanceTelemetryFields.byteBucket(trigger.latestRunOutputCount)
        ]
    }

    private static func inputFields(_ input: TaskThreadSnapshotInput) -> [String: String] {
        [
            "snapshot_input_events": PerformanceTelemetryFields.count(input.events.count),
            "snapshot_input_runs": PerformanceTelemetryFields.count(input.runs.count),
            "omitted_events": PerformanceTelemetryFields.count(input.omittedEventCount),
            "omitted_runs": PerformanceTelemetryFields.count(input.omittedRunCount)
        ]
    }

    private static func snapshotFields(_ snapshot: TaskThreadSnapshot) -> [String: String] {
        [
            "snapshot_input_events": PerformanceTelemetryFields.count(snapshot.sortedEvents.count),
            "snapshot_input_runs": PerformanceTelemetryFields.count(snapshot.sortedRuns.count),
            "omitted_events": PerformanceTelemetryFields.count(snapshot.omittedEventCount),
            "omitted_runs": PerformanceTelemetryFields.count(snapshot.omittedRunCount),
            "conversation_item_count": PerformanceTelemetryFields.count(snapshot.conversationItems.count)
        ]
    }

    func expandWindow(for task: AgentTask) {
        guard snapshot?.omittedRunCount ?? 0 > 0 else { return }
        expansionRunCount += 50
        snapshotTrigger = nil
        refreshSnapshot(for: task)
    }

    func refreshGeneratedFiles(folder: String) {
        generatedFilesTask?.cancel()

        guard !folder.isEmpty else {
            generatedFilePaths = []
            return
        }

        generatedFilesTask = Task { [weak self] in
            let paths = await TaskGeneratedFiles.filesAsync(in: folder)
            guard !Task.isCancelled else { return }
            self?.generatedFilePaths = paths
        }
    }

    func cancelGeneratedFilesRefresh() {
        generatedFilesTask?.cancel()
        generatedFilesTask = nil
    }

    private static func logSnapshotState(
        snapshot: TaskThreadSnapshot,
        trigger: TaskThreadSnapshotTrigger,
        taskID: UUID,
        workspaceID: UUID?
    ) {
        let agentResponseCount = snapshot.conversationItems.filter { item in
            if case .agentResponse = item { return true }
            return false
        }.count
        let userMessageCount = snapshot.conversationItems.filter { item in
            if case .userMessage = item { return true }
            return false
        }.count
        let blankReason = blankReason(
            snapshot: snapshot,
            trigger: trigger,
            agentResponseCount: agentResponseCount
        )
        let level: LogLevel = blankReason == "has_visible_response" || trigger.status == .running || trigger.status == .queued
            ? .debug
            : .warning
        AppLogger.audit(.threadSnapshotBuilt, category: "UI", taskID: taskID, fields: [
            "status": trigger.status.rawValue,
            "workspace_id": PerformanceTelemetryFields.abbreviatedID(workspaceID),
            "event_count": String(trigger.eventCount),
            "visible_event_count": String(trigger.visibleEventCount),
            "run_count": String(trigger.runCount),
            "latest_run_output_bucket": String(trigger.latestRunOutputBucket),
            "snapshot_event_count": String(snapshot.sortedEvents.count),
            "snapshot_run_count": String(snapshot.sortedRuns.count),
            "omitted_events": String(snapshot.omittedEventCount),
            "omitted_runs": String(snapshot.omittedRunCount),
            "conversation_item_count": String(snapshot.conversationItems.count),
            "agent_response_count": String(agentResponseCount),
            "user_message_count": String(userMessageCount),
            "latest_run_status": snapshot.latestRun?.status.rawValue ?? "none",
            "latest_run_output_bytes": String(trigger.latestRunOutputCount),
            "blank_reason": blankReason
        ], level: level)
    }

    private static func blankReason(
        snapshot: TaskThreadSnapshot,
        trigger: TaskThreadSnapshotTrigger,
        agentResponseCount: Int
    ) -> String {
        if agentResponseCount > 0 {
            return "has_visible_response"
        }
        if trigger.runCount == 0 {
            return "no_runs"
        }
        if snapshot.sortedRuns.contains(where: { !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "output_present_but_not_visible"
        }
        if snapshot.sortedEvents.contains(where: { $0.type == "agent.response" }) {
            return "response_events_present_but_not_visible"
        }
        if trigger.status == .running || trigger.status == .queued {
            return "run_in_progress"
        }
        return "terminal_without_visible_response"
    }
}
