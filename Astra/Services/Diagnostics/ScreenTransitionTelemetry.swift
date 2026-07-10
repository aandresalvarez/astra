import Foundation
import os
import ASTRACore

/// Pure lifecycle for a major in-window screen transition. The endpoint is
/// deliberately named `view_ready`: it is a committed SwiftUI destination
/// state, not a claim that a user interaction or a GPU-presented frame has
/// already completed.
struct ScreenTransitionTrace: Equatable {
    let traceID: String
    let destination: String
    let source: String
    let taskID: UUID?
    let startedAtUptimeNanoseconds: UInt64

    func result(at uptimeNanoseconds: UInt64) -> TaskOpenResponsivenessResult {
        TaskOpenResponsivenessResult(
            event: "screen_transition_to_view_ready",
            durationMilliseconds: Double(uptimeNanoseconds - startedAtUptimeNanoseconds) / 1_000_000,
            fields: [
                "trace_id": traceID,
                "source": source,
                "destination": destination,
                "task_id": PerformanceTelemetryFields.abbreviatedID(taskID)
            ]
        )
    }
}

/// Reusable telemetry for transitions between the task chat and major shelf
/// surfaces. It intentionally has no UI dependency so new destinations can be
/// measured by beginning and completing the same small lifecycle.
@MainActor
enum ScreenTransitionTelemetry {
    private static let slowTransitionThresholdMilliseconds: Double = 250
    private static let signposter = OSSignposter(
        subsystem: AppChannel.current.loggingSubsystem,
        category: "Performance"
    )

    private struct ActiveTransition {
        let trace: ScreenTransitionTrace
        let interval: OSSignpostIntervalState
    }

    private static var activeTransitions: [UUID: ActiveTransition] = [:]

    static func begin(destination: String, source: String, taskID: UUID?, scope: UUID) {
        cancel(scope: scope, reason: "superseded")
        let id = signposter.makeSignpostID()
        activeTransitions[scope] = ActiveTransition(
            trace: ScreenTransitionTrace(
                traceID: AuditTrace.make("screen-transition"),
                destination: destination,
                source: source,
                taskID: taskID,
                startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            interval: signposter.beginInterval("screen_transition_to_view_ready", id: id)
        )
    }

    static func viewBecameReady(destination: String, scope: UUID) {
        guard let active = activeTransitions[scope], active.trace.destination == destination else { return }
        signposter.endInterval("screen_transition_to_view_ready", active.interval)
        let result = active.trace.result(at: DispatchTime.now().uptimeNanoseconds)
        PerformanceTelemetry.log(
            result.event,
            durationMilliseconds: result.durationMilliseconds,
            level: result.durationMilliseconds >= slowTransitionThresholdMilliseconds ? .warning : .info,
            fields: result.fields,
            taskID: active.trace.taskID
        )
        activeTransitions[scope] = nil
    }

    static func cancel(scope: UUID, reason: String) {
        guard let active = activeTransitions[scope] else { return }
        signposter.endInterval("screen_transition_to_view_ready", active.interval)
        PerformanceTelemetry.log(
            "screen_transition_cancelled",
            durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - active.trace.startedAtUptimeNanoseconds) / 1_000_000,
            level: .debug,
            fields: [
                "source": active.trace.source,
                "destination": active.trace.destination,
                "trace_id": active.trace.traceID,
                "reason": reason,
                "task_id": PerformanceTelemetryFields.abbreviatedID(active.trace.taskID)
            ],
            taskID: active.trace.taskID
        )
        activeTransitions[scope] = nil
    }

    static func resetForTesting() {
        for scope in Array(activeTransitions.keys) {
            cancel(scope: scope, reason: "test_reset")
        }
    }
}
