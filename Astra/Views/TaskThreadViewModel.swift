import Foundation
import ASTRAModels
import ASTRAPersistence

@Observable @MainActor
final class TaskThreadViewModel {
    private(set) var snapshot: TaskThreadSnapshot?
    private(set) var generatedFilePaths: [String] = []

    private var snapshotTrigger: TaskThreadSnapshotTrigger?
    private var snapshotTask: Task<Void, Never>?
    private var generatedFilesTask: Task<Void, Never>?
    private var expansionRunCount: Int = 50
    private var lastSnapshotApplyAt: Date = .distantPast
    private var snapshotRevision: Int = 0

    private static let liveSnapshotMinimumInterval: TimeInterval = 0.120
    private static var terminalSnapshotCache = TaskThreadSnapshotCache()

    func reset(for task: AgentTask) {
        PerformanceTelemetry.measure(
            "chat_thread_reset",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: Self.taskFields(task)
        ) {
            expansionRunCount = 50
            snapshotTrigger = nil
            snapshotTask?.cancel()
            lastSnapshotApplyAt = .distantPast
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
        let cacheKey = TaskThreadSnapshotCacheKey(task: task, trigger: trigger, maxRuns: expansionRunCount)
        if let cacheKey,
           let cachedSnapshot = Self.terminalSnapshotCache.snapshot(for: cacheKey) {
            snapshot = cachedSnapshot
            lastSnapshotApplyAt = Date()
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

        let input = TaskThreadSnapshotInput(task: task, maxRuns: expansionRunCount)
        fields.merge(Self.inputFields(input), uniquingKeysWith: { _, new in new })

        let isLive = trigger.status == .running
            || trigger.status == .queued
            || trigger.latestRunStatus == .running
        let elapsed = Date().timeIntervalSince(lastSnapshotApplyAt)
        let minimumInterval = Self.liveSnapshotMinimumInterval
        let delay = isLive && elapsed < minimumInterval ? (minimumInterval - elapsed) : 0
        let taskID = task.id
        let workspaceID = task.workspace?.id
        snapshotRevision += 1
        let revision = snapshotRevision
        snapshotTask = Task.detached(priority: .userInitiated) { [self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            let builtSnapshot = await TaskThreadSnapshot.buildAsync(input: input, fields: fields)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, revision == self.snapshotRevision else { return }
                self.snapshot = builtSnapshot
                if let cacheKey {
                    Self.terminalSnapshotCache.store(builtSnapshot, for: cacheKey)
                }
                self.lastSnapshotApplyAt = Date()
                Self.logSnapshotState(
                    snapshot: builtSnapshot,
                    trigger: trigger,
                    taskID: taskID,
                    workspaceID: workspaceID
                )
            }
        }
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
            "latest_run_output_chars": PerformanceTelemetryFields.count(trigger.latestRunOutputCount),
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
            "latest_run_output_chars": snapshot.latestRun.map { String($0.output.count) } ?? "0",
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
