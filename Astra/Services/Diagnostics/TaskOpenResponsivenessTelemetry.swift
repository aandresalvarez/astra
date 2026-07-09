import Foundation
import os
import ASTRACore
import ASTRAModels

/// The completed, user-visible measurements emitted for an existing task open.
///
/// This intentionally owns only identifiers, scale counts, and duration data.
/// Task titles, prompts, paths, and provider output must never enter the
/// diagnostic stream through this type.
struct TaskOpenResponsivenessResult: Equatable {
    let event: String
    let durationMilliseconds: Double
    let fields: [String: String]
}

/// Tracks which OS signpost intervals are still open for a task-open trace.
///
/// `OSSignposter` treats ending an interval twice as a programmer error and
/// traps in debug builds. The shell interval can legitimately complete before
/// the transcript interval, so cancellation must only end intervals that are
/// still open.
struct TaskOpenResponsivenessIntervalLifecycle: Equatable {
    private(set) var shellVisibleEnded = false
    private(set) var transcriptReadyEnded = false

    mutating func endShellVisibleIfNeeded() -> Bool {
        guard !shellVisibleEnded else { return false }
        shellVisibleEnded = true
        return true
    }

    mutating func endTranscriptReadyIfNeeded() -> Bool {
        guard !transcriptReadyEnded else { return false }
        transcriptReadyEnded = true
        return true
    }
}

/// Testable state for one task selection. `TaskOpenResponsivenessTelemetry`
/// supplies the app-facing clock, signposts, and log delivery around this pure
/// value type.
struct TaskOpenResponsivenessTrace: Equatable {
    let traceID: String
    let taskID: UUID
    let startedAtUptimeNanoseconds: UInt64
    let fields: [String: String]

    private(set) var shellVisibleDurationMilliseconds: Double?
    private(set) var transcriptReadyDurationMilliseconds: Double?

    init(
        traceID: String,
        taskID: UUID,
        startedAtUptimeNanoseconds: UInt64,
        fields: [String: String]
    ) {
        self.traceID = traceID
        self.taskID = taskID
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        self.fields = fields
    }

    mutating func markShellVisible(at uptimeNanoseconds: UInt64) -> TaskOpenResponsivenessResult? {
        guard shellVisibleDurationMilliseconds == nil else { return nil }
        let duration = elapsedMilliseconds(at: uptimeNanoseconds)
        shellVisibleDurationMilliseconds = duration
        return result(
            event: "task_selection_to_shell_visible",
            durationMilliseconds: duration
        )
    }

    mutating func markTranscriptReady(
        at uptimeNanoseconds: UInt64,
        snapshotFields: [String: String]
    ) -> TaskOpenResponsivenessResult? {
        guard transcriptReadyDurationMilliseconds == nil else { return nil }
        let duration = elapsedMilliseconds(at: uptimeNanoseconds)
        transcriptReadyDurationMilliseconds = duration
        return result(
            event: "task_selection_to_transcript_ready",
            durationMilliseconds: duration,
            extraFields: snapshotFields.merging([
                "shell_visible_ms": shellVisibleDurationMilliseconds.map { String(format: "%.2f", $0) } ?? "not_recorded"
            ], uniquingKeysWith: { _, new in new })
        )
    }

    func phaseFields(name: String) -> [String: String] {
        fields.merging([
            "trace_id": traceID,
            "phase": name
        ], uniquingKeysWith: { _, new in new })
    }

    private func result(
        event: String,
        durationMilliseconds: Double,
        extraFields: [String: String] = [:]
    ) -> TaskOpenResponsivenessResult {
        TaskOpenResponsivenessResult(
            event: event,
            durationMilliseconds: durationMilliseconds,
            fields: fields
                .merging([
                    "trace_id": traceID
                ], uniquingKeysWith: { _, new in new })
                .merging(extraFields, uniquingKeysWith: { _, new in new })
        )
    }

    private func elapsedMilliseconds(at uptimeNanoseconds: UInt64) -> Double {
        Double(uptimeNanoseconds - startedAtUptimeNanoseconds) / 1_000_000
    }
}

/// Correlates a sidebar task selection with the first visible task shell and
/// the first fully laid-out transcript. The interval signposts cross async
/// boundaries, while completed results are mirrored into ASTRA's sanitized
/// `Performance` log category for the in-app Logs window and diagnostics export.
@MainActor
enum TaskOpenResponsivenessTelemetry {
    private static let slowInteractionThresholdMilliseconds: Double = 250
    private static let slowPhaseThresholdMilliseconds: Double = 50
    private static let signposter = OSSignposter(
        subsystem: AppChannel.current.loggingSubsystem,
        category: "Performance"
    )

    private struct SignpostIntervals {
        let shellVisible: OSSignpostIntervalState
        let transcriptReady: OSSignpostIntervalState
    }

    private struct ActiveTrace {
        var trace: TaskOpenResponsivenessTrace
        let intervals: SignpostIntervals
        var intervalLifecycle = TaskOpenResponsivenessIntervalLifecycle()
    }

    /// Each `ContentView` owns a stable scope for the lifetime of one main
    /// window. Keeping traces in that scope prevents task opens in one window
    /// from cancelling measurements that are still in flight in another.
    private static var activeTraces: [UUID: ActiveTrace] = [:]

    static func begin(task: AgentTask, source: String, scope: UUID) {
        guard task.status != .draft else {
            cancelActiveTrace(in: scope, reason: "draft_selected")
            return
        }
        cancelActiveTrace(in: scope, reason: "superseded")

        let traceID = AuditTrace.make("task-open")
        let id = signposter.makeSignpostID()
        let intervals = SignpostIntervals(
            shellVisible: signposter.beginInterval("task_selection_to_shell_visible", id: id),
            transcriptReady: signposter.beginInterval("task_selection_to_transcript_ready", id: id)
        )
        activeTraces[scope] = ActiveTrace(
            trace: TaskOpenResponsivenessTrace(
                traceID: traceID,
                taskID: task.id,
                startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                fields: baseFields(task: task, source: source)
            ),
            intervals: intervals
        )
    }

    static func beginForSelection(task: AgentTask?, source: String, scope: UUID) {
        guard let task else {
            cancelActiveTrace(in: scope, reason: "selection_cleared")
            return
        }
        begin(task: task, source: source, scope: scope)
    }

    static func measurePhase<T>(
        _ name: String,
        task: AgentTask,
        scope: UUID,
        _ work: () -> T
    ) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        recordPhase(name, task: task, scope: scope, start: start)
        return result
    }

    static func shellBecameVisible(task: AgentTask, scope: UUID) {
        guard var activeTrace = activeTraces[scope], activeTrace.trace.taskID == task.id,
              let result = activeTrace.trace.markShellVisible(at: DispatchTime.now().uptimeNanoseconds)
        else { return }

        endShellVisibleInterval(&activeTrace)
        activeTraces[scope] = activeTrace
        log(result, taskID: task.id)
    }

    static func transcriptBecameReady(
        task: AgentTask,
        snapshot: TaskThreadSnapshot,
        appliedSnapshotRevision: Int,
        cacheState: String,
        scope: UUID
    ) {
        guard var activeTrace = activeTraces[scope], activeTrace.trace.taskID == task.id,
              appliedSnapshotRevision > 0 else { return }

        if activeTrace.trace.shellVisibleDurationMilliseconds == nil,
           let shellResult = activeTrace.trace.markShellVisible(at: DispatchTime.now().uptimeNanoseconds) {
            endShellVisibleInterval(&activeTrace)
            log(shellResult, taskID: task.id)
        }

        guard let result = activeTrace.trace.markTranscriptReady(
            at: DispatchTime.now().uptimeNanoseconds,
            snapshotFields: snapshotFields(
                snapshot,
                appliedSnapshotRevision: appliedSnapshotRevision,
                cacheState: cacheState
            )
        ) else { return }
        endTranscriptReadyInterval(&activeTrace)
        log(result, taskID: task.id)
        activeTraces[scope] = nil
    }

    static func cancel(task: AgentTask, reason: String, scope: UUID) {
        guard activeTraces[scope]?.trace.taskID == task.id else { return }
        cancelActiveTrace(in: scope, reason: reason)
    }

    static func resetForTesting() {
        for scope in Array(activeTraces.keys) {
            cancelActiveTrace(in: scope, reason: "test_reset")
        }
    }

    private static func recordPhase(_ name: String, task: AgentTask, scope: UUID, start: UInt64) {
        let elapsed = PerformanceTelemetry.elapsedMilliseconds(since: start)
        guard let activeTrace = activeTraces[scope], activeTrace.trace.taskID == task.id,
              elapsed >= PerformanceTelemetry.uiFrameThresholdMilliseconds
        else { return }

        PerformanceTelemetry.log(
            "task_open_phase",
            durationMilliseconds: elapsed,
            level: elapsed >= slowPhaseThresholdMilliseconds ? .warning : .debug,
            fields: activeTrace.trace.phaseFields(name: name),
            taskID: task.id
        )
    }

    private static func cancelActiveTrace(in scope: UUID, reason: String) {
        guard var activeTrace = activeTraces[scope] else { return }
        endShellVisibleInterval(&activeTrace)
        endTranscriptReadyInterval(&activeTrace)
        PerformanceTelemetry.log(
            "task_selection_cancelled",
            level: .debug,
            fields: activeTrace.trace.fields.merging([
                "trace_id": activeTrace.trace.traceID,
                "reason": reason
            ], uniquingKeysWith: { _, new in new }),
            taskID: activeTrace.trace.taskID
        )
        activeTraces[scope] = nil
    }

    private static func endShellVisibleInterval(_ activeTrace: inout ActiveTrace) {
        guard activeTrace.intervalLifecycle.endShellVisibleIfNeeded() else { return }
        signposter.endInterval("task_selection_to_shell_visible", activeTrace.intervals.shellVisible)
    }

    private static func endTranscriptReadyInterval(_ activeTrace: inout ActiveTrace) {
        guard activeTrace.intervalLifecycle.endTranscriptReadyIfNeeded() else { return }
        signposter.endInterval("task_selection_to_transcript_ready", activeTrace.intervals.transcriptReady)
    }

    private static func log(_ result: TaskOpenResponsivenessResult, taskID: UUID) {
        let level: LogLevel = result.durationMilliseconds >= slowInteractionThresholdMilliseconds ? .warning : .info
        PerformanceTelemetry.log(
            result.event,
            durationMilliseconds: result.durationMilliseconds,
            level: level,
            fields: result.fields,
            taskID: taskID
        )
        guard result.event == "task_selection_to_shell_visible" else { return }
        PerformanceTelemetry.log(
            "screen_transition_to_interactive",
            durationMilliseconds: result.durationMilliseconds,
            level: level,
            fields: result.fields.merging([
                "destination": "task"
            ], uniquingKeysWith: { _, new in new }),
            taskID: taskID
        )
    }

    private static func baseFields(task: AgentTask, source: String) -> [String: String] {
        [
            "source": source,
            "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
            "workspace_id": PerformanceTelemetryFields.abbreviatedID(task.workspace?.id),
            "status": task.status.rawValue,
            "open_state": task.unreadAt == nil ? "read" : "unread"
        ]
    }

    private static func snapshotFields(
        _ snapshot: TaskThreadSnapshot,
        appliedSnapshotRevision: Int,
        cacheState: String
    ) -> [String: String] {
        let latestOutputBytes = snapshot.latestRun?.output.utf8.count ?? 0
        return [
            "applied_snapshot_revision": PerformanceTelemetryFields.count(appliedSnapshotRevision),
            "snapshot_cache_state": cacheState,
            "event_count": PerformanceTelemetryFields.count(snapshot.totalEventCount),
            "event_count_bucket": PerformanceTelemetryFields.countBucket(snapshot.totalEventCount),
            "run_count": PerformanceTelemetryFields.count(snapshot.totalRunCount),
            "run_count_bucket": PerformanceTelemetryFields.countBucket(snapshot.totalRunCount),
            "snapshot_event_count": PerformanceTelemetryFields.count(snapshot.sortedEvents.count),
            "snapshot_run_count": PerformanceTelemetryFields.count(snapshot.sortedRuns.count),
            "omitted_events": PerformanceTelemetryFields.count(snapshot.omittedEventCount),
            "omitted_runs": PerformanceTelemetryFields.count(snapshot.omittedRunCount),
            "conversation_item_count": PerformanceTelemetryFields.count(snapshot.conversationItems.count),
            "latest_run_output_bucket": PerformanceTelemetryFields.byteBucket(latestOutputBytes)
        ]
    }
}
