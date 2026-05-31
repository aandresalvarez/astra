import Foundation

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

    func reset(for task: AgentTask) {
        expansionRunCount = 50
        snapshotTrigger = nil
        snapshotTask?.cancel()
        lastSnapshotApplyAt = .distantPast
        snapshot = TaskThreadSnapshot.placeholder(goal: task.goal, createdAt: task.createdAt)
        refreshSnapshot(for: task)
        refreshGeneratedFiles(folder: TaskWorkspaceAccess(task: task).taskFolder)
    }

    func refreshSnapshot(for task: AgentTask) {
        let trigger = TaskThreadSnapshotTrigger(task: task)
        guard snapshotTrigger != trigger else { return }
        snapshotTrigger = trigger
        let input = TaskThreadSnapshotInput(task: task, maxRuns: expansionRunCount)
        let fields = [
            "task_id": String(task.id.uuidString.prefix(8)),
            "event_count": String(trigger.eventCount),
            "visible_event_count": String(trigger.visibleEventCount),
            "run_count": String(trigger.runCount),
            "status": trigger.status.rawValue,
            "latest_run_output_bucket": String(trigger.latestRunOutputBucket),
            "latest_run_output_chars": String(trigger.latestRunOutputCount),
            "snapshot_input_events": String(input.events.count),
            "snapshot_input_runs": String(input.runs.count),
            "omitted_events": String(input.omittedEventCount),
            "omitted_runs": String(input.omittedRunCount)
        ]

        snapshotTask?.cancel()
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
            "workspace_id": workspaceID?.uuidString ?? "none",
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
