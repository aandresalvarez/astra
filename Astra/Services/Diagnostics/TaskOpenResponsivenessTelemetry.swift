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
    private(set) var maxMainActorProbeGapMilliseconds: Double = 0
    private(set) var mainActorHitchCount = 0

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
        let duration = durationMilliseconds(at: uptimeNanoseconds)
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
        let duration = durationMilliseconds(at: uptimeNanoseconds)
        transcriptReadyDurationMilliseconds = duration
        return result(
            event: "task_selection_to_transcript_ready",
            durationMilliseconds: duration,
            extraFields: snapshotFields.merging([
                "shell_visible_ms": shellVisibleDurationMilliseconds.map { String(format: "%.2f", $0) } ?? "not_recorded"
            ], uniquingKeysWith: { _, new in new })
        )
    }

    mutating func recordMainActorProbeGap(_ gapMilliseconds: Double) {
        let normalizedGap = max(0, gapMilliseconds)
        maxMainActorProbeGapMilliseconds = max(maxMainActorProbeGapMilliseconds, normalizedGap)
        if normalizedGap >= 50 {
            mainActorHitchCount += 1
        }
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
                    "trace_id": traceID,
                    "max_main_actor_probe_gap_ms": String(format: "%.2f", maxMainActorProbeGapMilliseconds),
                    "main_actor_hitch_count": PerformanceTelemetryFields.count(mainActorHitchCount)
                ], uniquingKeysWith: { _, new in new })
                .merging(extraFields, uniquingKeysWith: { _, new in new })
        )
    }

    private func durationMilliseconds(at uptimeNanoseconds: UInt64) -> Double {
        Double(uptimeNanoseconds - startedAtUptimeNanoseconds) / 1_000_000
    }

    func elapsedMilliseconds(at uptimeNanoseconds: UInt64) -> Double {
        durationMilliseconds(at: uptimeNanoseconds)
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
    static let timeoutNanoseconds: UInt64 = 5_000_000_000
    private static let mainActorProbeIntervalMilliseconds: Double = 16
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

    static func responsivenessContext(task: AgentTask, scope: UUID) -> TaskThreadResponsivenessContext? {
        guard let activeTrace = activeTraces[scope], activeTrace.trace.taskID == task.id else { return nil }
        return TaskThreadResponsivenessContext(traceID: activeTrace.trace.traceID)
    }

    static func isActive(task: AgentTask, scope: UUID) -> Bool {
        activeTraces[scope]?.trace.taskID == task.id
    }

    /// Records a bounded main-actor probe gap while a task-open trace is in
    /// flight. This is deliberately a summary, not per-frame logging, so it
    /// surfaces apparent freezes without adding a high-volume telemetry loop.
    static func recordMainActorProbe(task: AgentTask, observedIntervalMilliseconds: Double, scope: UUID) {
        guard var activeTrace = activeTraces[scope], activeTrace.trace.taskID == task.id else { return }
        activeTrace.trace.recordMainActorProbeGap(observedIntervalMilliseconds - mainActorProbeIntervalMilliseconds)
        activeTraces[scope] = activeTrace
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
        snapshotAppliedUptimeNanoseconds: UInt64?,
        scope: UUID
    ) {
        guard var activeTrace = activeTraces[scope], activeTrace.trace.taskID == task.id,
              appliedSnapshotRevision > 0 else { return }

        if activeTrace.trace.shellVisibleDurationMilliseconds == nil,
           let shellResult = activeTrace.trace.markShellVisible(at: DispatchTime.now().uptimeNanoseconds) {
            endShellVisibleInterval(&activeTrace)
            log(shellResult, taskID: task.id)
        }

        let readyAt = DispatchTime.now().uptimeNanoseconds
        guard let result = activeTrace.trace.markTranscriptReady(
            at: readyAt,
            snapshotFields: snapshotFields(
                snapshot,
                appliedSnapshotRevision: appliedSnapshotRevision,
                cacheState: cacheState,
                snapshotAppliedUptimeNanoseconds: snapshotAppliedUptimeNanoseconds,
                transcriptReadyUptimeNanoseconds: readyAt
            )
        ) else { return }
        endTranscriptReadyInterval(&activeTrace)
        if let snapshotAppliedUptimeNanoseconds, snapshotAppliedUptimeNanoseconds <= readyAt {
            PerformanceTelemetry.log(
                "task_open_snapshot_apply_to_transcript_ready",
                durationMilliseconds: Double(readyAt - snapshotAppliedUptimeNanoseconds) / 1_000_000,
                level: .debug,
                fields: activeTrace.trace.phaseFields(name: "snapshot_apply_to_transcript_ready"),
                taskID: task.id
            )
        }
        log(result, taskID: task.id)
        activeTraces[scope] = nil
    }

    static func cancel(task: AgentTask, reason: String, scope: UUID) {
        guard activeTraces[scope]?.trace.taskID == task.id else { return }
        cancelActiveTrace(in: scope, reason: reason)
    }

    /// ContentView owns the window scope before a TaskMainView is mounted.
    /// Cancelling by scope closes a trace when the window disappears during
    /// that gap, where no task view lifecycle observer exists yet.
    static func cancel(scope: UUID, reason: String) {
        cancelActiveTrace(in: scope, reason: reason)
    }

    /// Emits an explicit warning when an open never reaches transcript-ready
    /// while its view remains alive. Without this watchdog, the only evidence
    /// for a stuck open would be a later disappearance cancellation.
    static func timeout(task: AgentTask, scope: UUID) {
        guard let activeTrace = activeTraces[scope], activeTrace.trace.taskID == task.id else { return }
        PerformanceTelemetry.log(
            "task_selection_timeout",
            durationMilliseconds: activeTrace.trace.elapsedMilliseconds(at: DispatchTime.now().uptimeNanoseconds),
            level: .warning,
            fields: activeTrace.trace.fields.merging([
                "trace_id": activeTrace.trace.traceID,
                "shell_visible": PerformanceTelemetryFields.bool(activeTrace.trace.shellVisibleDurationMilliseconds != nil),
                "transcript_ready": PerformanceTelemetryFields.bool(activeTrace.trace.transcriptReadyDurationMilliseconds != nil)
            ], uniquingKeysWith: { _, new in new }),
            taskID: task.id
        )
        cancelActiveTrace(in: scope, reason: "timeout")
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
            durationMilliseconds: activeTrace.trace.elapsedMilliseconds(at: DispatchTime.now().uptimeNanoseconds),
            level: .debug,
            fields: activeTrace.trace.fields.merging([
                "trace_id": activeTrace.trace.traceID,
                "reason": reason,
                "shell_visible": PerformanceTelemetryFields.bool(activeTrace.trace.shellVisibleDurationMilliseconds != nil),
                "transcript_ready": PerformanceTelemetryFields.bool(activeTrace.trace.transcriptReadyDurationMilliseconds != nil)
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
            "screen_transition_to_view_ready",
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
        cacheState: String,
        snapshotAppliedUptimeNanoseconds: UInt64?,
        transcriptReadyUptimeNanoseconds: UInt64
    ) -> [String: String] {
        let latestOutputBytes = snapshot.latestRun?.output.utf8.count ?? 0
        let contentMetrics = snapshot.transcriptMetrics
        let applyToReadyMilliseconds = snapshotAppliedUptimeNanoseconds.map { appliedAt in
            max(0, Double(transcriptReadyUptimeNanoseconds - appliedAt) / 1_000_000)
        }
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
            "latest_run_output_byte_bucket": PerformanceTelemetryFields.byteBucket(latestOutputBytes),
            "visible_transcript_bytes_bucket": PerformanceTelemetryFields.byteBucket(contentMetrics.textBytes),
            "visible_agent_response_count": PerformanceTelemetryFields.count(contentMetrics.agentResponseCount),
            "visible_code_fence_count_bucket": PerformanceTelemetryFields.countBucket(contentMetrics.codeFenceCount),
            "visible_table_row_count_bucket": PerformanceTelemetryFields.countBucket(contentMetrics.tableRowCount),
            "snapshot_apply_to_transcript_ready_ms": applyToReadyMilliseconds.map { String(format: "%.2f", $0) } ?? "not_recorded"
        ]
    }
}
