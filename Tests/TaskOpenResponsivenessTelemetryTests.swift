import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task open responsiveness telemetry")
struct TaskOpenResponsivenessTelemetryTests {
    @Test("Trace records shell and transcript durations once with safe scale fields")
    func traceRecordsEndToEndDurationsOnce() {
        let taskID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        var trace = TaskOpenResponsivenessTrace(
            traceID: "task-open-01234567",
            taskID: taskID,
            startedAtUptimeNanoseconds: 1_000_000_000,
            fields: [
                "source": "task_selection",
                "task_id": "01234567",
                "status": "completed",
                "open_state": "unread"
            ]
        )

        let shell = trace.markShellVisible(at: 1_125_000_000)
        let transcript = trace.markTranscriptReady(
            at: 1_450_000_000,
            snapshotFields: [
                "event_count_bucket": "1000_plus",
                "run_count_bucket": "50_199",
                "conversation_item_count": "51"
            ]
        )

        #expect(shell?.event == "task_selection_to_shell_visible")
        #expect(shell?.durationMilliseconds == 125)
        #expect(shell?.fields["trace_id"] == "task-open-01234567")
        #expect(shell?.fields["task_id"] == "01234567")

        #expect(transcript?.event == "task_selection_to_transcript_ready")
        #expect(transcript?.durationMilliseconds == 450)
        #expect(transcript?.fields["shell_visible_ms"] == "125.00")
        #expect(transcript?.fields["event_count_bucket"] == "1000_plus")
        #expect(transcript?.fields["run_count_bucket"] == "50_199")
        #expect(transcript?.fields["conversation_item_count"] == "51")
        #expect(transcript?.fields["title"] == nil)
        #expect(transcript?.fields["goal"] == nil)
        #expect(transcript?.fields["output"] == nil)

        #expect(trace.markShellVisible(at: 1_500_000_000) == nil)
        #expect(trace.markTranscriptReady(at: 1_500_000_000, snapshotFields: [:]) == nil)
    }

    @Test("Trace includes a bounded main actor hitch summary")
    func traceIncludesMainActorHitchSummary() {
        var trace = TaskOpenResponsivenessTrace(
            traceID: "task-open-hitch",
            taskID: UUID(),
            startedAtUptimeNanoseconds: 0,
            fields: [:]
        )
        trace.recordMainActorProbeGap(12)
        trace.recordMainActorProbeGap(84)

        let result = trace.markTranscriptReady(at: 100_000_000, snapshotFields: [:])

        #expect(result?.fields["max_main_actor_probe_gap_ms"] == "84.00")
        #expect(result?.fields["main_actor_hitch_count"] == "1")
    }

    @Test("Transcript result records a missing shell explicitly when needed")
    func transcriptResultHandlesMissingShell() {
        var trace = TaskOpenResponsivenessTrace(
            traceID: "task-open-fallback",
            taskID: UUID(),
            startedAtUptimeNanoseconds: 0,
            fields: [:]
        )

        let result = trace.markTranscriptReady(at: 300_000_000, snapshotFields: [:])

        #expect(result?.durationMilliseconds == 300)
        #expect(result?.fields["shell_visible_ms"] == "not_recorded")
    }

    @Test("Phase fields retain only the trace identity and fixed phase name")
    func phaseFieldsAreSafeAndCorrelated() {
        let trace = TaskOpenResponsivenessTrace(
            traceID: "task-open-phase",
            taskID: UUID(),
            startedAtUptimeNanoseconds: 0,
            fields: ["source": "task_selection"]
        )

        let fields = trace.phaseFields(name: "context_state_refresh")

        #expect(fields == [
            "source": "task_selection",
            "trace_id": "task-open-phase",
            "phase": "context_state_refresh"
        ])
    }

    @Test("Interval cancellation only ends each OS signpost once")
    func intervalLifecyclePreventsDoubleEnd() {
        var lifecycle = TaskOpenResponsivenessIntervalLifecycle()
        let endedShellFirstTime = lifecycle.endShellVisibleIfNeeded()
        let endedShellSecondTime = lifecycle.endShellVisibleIfNeeded()
        let endedTranscriptFirstTime = lifecycle.endTranscriptReadyIfNeeded()
        let endedTranscriptSecondTime = lifecycle.endTranscriptReadyIfNeeded()

        #expect(endedShellFirstTime)
        #expect(!endedShellSecondTime)
        #expect(endedTranscriptFirstTime)
        #expect(!endedTranscriptSecondTime)
        #expect(lifecycle.shellVisibleEnded)
        #expect(lifecycle.transcriptReadyEnded)
    }

    @MainActor
    @Test("Selecting another task after its shell appears safely cancels the prior trace")
    func supersedingTraceAfterShellVisibilityDoesNotEndSignpostTwice() {
        let firstTask = makeTask(goal: "First task")
        let secondTask = makeTask(goal: "Second task")
        let scope = UUID()
        TaskOpenResponsivenessTelemetry.resetForTesting()

        TaskOpenResponsivenessTelemetry.begin(task: firstTask, source: "task_selection", scope: scope)
        TaskOpenResponsivenessTelemetry.shellBecameVisible(task: firstTask, scope: scope)

        // This mirrors clicking a second sidebar row while the first task's
        // transcript snapshot is still loading. Before the regression fix,
        // begin() cancelled the trace by ending the shell signpost twice.
        TaskOpenResponsivenessTelemetry.begin(task: secondTask, source: "task_selection", scope: scope)
        // A cancelled view's delayed callback must not replace the trace for
        // the task that is now opening.
        TaskOpenResponsivenessTelemetry.shellBecameVisible(task: firstTask, scope: scope)
        TaskOpenResponsivenessTelemetry.transcriptBecameReady(
            task: secondTask,
            snapshot: .empty,
            appliedSnapshotRevision: 1,
            cacheState: "not_applicable",
            snapshotAppliedUptimeNanoseconds: nil,
            scope: scope
        )
        TaskOpenResponsivenessTelemetry.resetForTesting()
    }

    @MainActor
    @Test("Window-scoped traces complete independently")
    func windowScopedTracesDoNotCancelOneAnother() {
        let firstTask = makeTask(goal: "First window task")
        let secondTask = makeTask(goal: "Second window task")
        let firstScope = UUID()
        let secondScope = UUID()
        TaskOpenResponsivenessTelemetry.resetForTesting()

        TaskOpenResponsivenessTelemetry.begin(task: firstTask, source: "task_selection", scope: firstScope)
        TaskOpenResponsivenessTelemetry.begin(task: secondTask, source: "task_selection", scope: secondScope)
        TaskOpenResponsivenessTelemetry.shellBecameVisible(task: firstTask, scope: firstScope)
        TaskOpenResponsivenessTelemetry.transcriptBecameReady(
            task: firstTask,
            snapshot: .empty,
            appliedSnapshotRevision: 1,
            cacheState: "not_applicable",
            snapshotAppliedUptimeNanoseconds: nil,
            scope: firstScope
        )
        AppLogger.flushForTesting()

        let entries = AppLogger.entries.filter { $0.taskID == firstTask.id && $0.category == "Performance" }
        #expect(entries.contains { $0.message.contains("event=task_selection_to_transcript_ready") })
        TaskOpenResponsivenessTelemetry.resetForTesting()
    }

    @MainActor
    @Test("Draft selection does not start a task-open trace")
    func draftSelectionsDoNotStartTaskOpenTraces() {
        let openedTask = makeTask(goal: "Opened task")
        let draftTask = makeTask(goal: "Draft task", status: .draft)
        let scope = UUID()
        TaskOpenResponsivenessTelemetry.resetForTesting()

        TaskOpenResponsivenessTelemetry.begin(task: openedTask, source: "task_selection", scope: scope)
        TaskOpenResponsivenessTelemetry.beginForSelection(task: draftTask, source: "task_selection", scope: scope)
        TaskOpenResponsivenessTelemetry.shellBecameVisible(task: draftTask, scope: scope)
        AppLogger.flushForTesting()

        let draftMeasurements = AppLogger.entries.filter {
            $0.taskID == draftTask.id
                && $0.category == "Performance"
                && $0.message.contains("event=task_selection_to_")
        }
        #expect(draftMeasurements.isEmpty)
        TaskOpenResponsivenessTelemetry.resetForTesting()
    }

    @MainActor
    @Test("Completed task-open measurements reach the existing Performance log with task context")
    func completedMeasurementsReachPerformanceLogs() {
        let task = makeTask(goal: "Sensitive task goal")
        let scope = UUID()
        TaskOpenResponsivenessTelemetry.resetForTesting()

        TaskOpenResponsivenessTelemetry.begin(task: task, source: "task_selection", scope: scope)
        TaskOpenResponsivenessTelemetry.shellBecameVisible(task: task, scope: scope)
        TaskOpenResponsivenessTelemetry.transcriptBecameReady(
            task: task,
            snapshot: .empty,
            appliedSnapshotRevision: 1,
            cacheState: "not_applicable",
            snapshotAppliedUptimeNanoseconds: nil,
            scope: scope
        )
        AppLogger.flushForTesting()

        let entries = AppLogger.entries.filter { $0.taskID == task.id && $0.category == "Performance" }
        let messages = entries.map(\.message).joined(separator: "\n")

        #expect(messages.contains("event=task_selection_to_shell_visible"))
        #expect(messages.contains("event=task_selection_to_transcript_ready"))
        #expect(messages.contains("event=screen_transition_to_view_ready"))
        #expect(!messages.contains("Sensitive task goal"))
    }

    @MainActor
    @Test("A stuck task-open trace emits a timeout with its reached stage")
    func stuckTraceEmitsTimeout() {
        let task = makeTask(goal: "Task that never becomes ready")
        let scope = UUID()
        TaskOpenResponsivenessTelemetry.resetForTesting()

        TaskOpenResponsivenessTelemetry.begin(task: task, source: "task_selection", scope: scope)
        TaskOpenResponsivenessTelemetry.shellBecameVisible(task: task, scope: scope)
        TaskOpenResponsivenessTelemetry.timeout(task: task, scope: scope)
        AppLogger.flushForTesting()

        let timeout = AppLogger.entries.first { entry in
            entry.taskID == task.id && entry.message.contains("event=task_selection_timeout")
        }
        #expect(timeout?.logLevel == .warning)
        #expect(timeout?.message.contains("shell_visible=true") == true)
        #expect(timeout?.message.contains("transcript_ready=false") == true)
        TaskOpenResponsivenessTelemetry.resetForTesting()
    }

    @MainActor
    @Test("Window disappearance cancels a task-open trace before its task view mounts")
    func windowDisappearanceCancelsTraceBeforeTaskViewMounts() {
        let task = makeTask(goal: "Close the window immediately")
        let scope = UUID()
        TaskOpenResponsivenessTelemetry.resetForTesting()

        TaskOpenResponsivenessTelemetry.begin(task: task, source: "task_selection", scope: scope)
        TaskOpenResponsivenessTelemetry.cancel(scope: scope, reason: "content_view_disappeared")

        #expect(!TaskOpenResponsivenessTelemetry.isActive(task: task, scope: scope))
        TaskOpenResponsivenessTelemetry.resetForTesting()
    }
}
