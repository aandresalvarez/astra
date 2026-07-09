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
        TaskOpenResponsivenessTelemetry.resetForTesting()

        TaskOpenResponsivenessTelemetry.begin(task: firstTask, source: "task_selection")
        TaskOpenResponsivenessTelemetry.shellBecameVisible(task: firstTask)

        // This mirrors clicking a second sidebar row while the first task's
        // transcript snapshot is still loading. Before the regression fix,
        // begin() cancelled the trace by ending the shell signpost twice.
        TaskOpenResponsivenessTelemetry.begin(task: secondTask, source: "task_selection")
        TaskOpenResponsivenessTelemetry.resetForTesting()
    }

    @MainActor
    @Test("Completed task-open measurements reach the existing Performance log with task context")
    func completedMeasurementsReachPerformanceLogs() {
        let task = makeTask(goal: "Sensitive task goal")
        TaskOpenResponsivenessTelemetry.resetForTesting()

        TaskOpenResponsivenessTelemetry.begin(task: task, source: "task_selection")
        TaskOpenResponsivenessTelemetry.shellBecameVisible(task: task)
        TaskOpenResponsivenessTelemetry.transcriptBecameReady(
            task: task,
            snapshot: .empty,
            appliedSnapshotRevision: 1,
            cacheState: "not_applicable"
        )
        AppLogger.flushForTesting()

        let entries = AppLogger.entries.filter { $0.taskID == task.id && $0.category == "Performance" }
        let messages = entries.map(\.message).joined(separator: "\n")

        #expect(messages.contains("event=task_selection_to_shell_visible"))
        #expect(messages.contains("event=task_selection_to_transcript_ready"))
        #expect(messages.contains("event=screen_transition_to_interactive"))
        #expect(!messages.contains("Sensitive task goal"))
    }
}
