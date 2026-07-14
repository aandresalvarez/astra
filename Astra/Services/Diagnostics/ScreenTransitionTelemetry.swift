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
    private(set) var stateCommittedAtUptimeNanoseconds: UInt64?
    private(set) var lastMainActorProbeAtUptimeNanoseconds: UInt64?
    private(set) var maxMainActorProbeGapNanoseconds: UInt64 = 0
    private(set) var mainActorHitchCount = 0

    init(
        traceID: String,
        destination: String,
        source: String,
        taskID: UUID?,
        startedAtUptimeNanoseconds: UInt64
    ) {
        self.traceID = traceID
        self.destination = destination
        self.source = source
        self.taskID = taskID
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        lastMainActorProbeAtUptimeNanoseconds = startedAtUptimeNanoseconds
    }

    mutating func markStateCommitted(at uptimeNanoseconds: UInt64) {
        guard stateCommittedAtUptimeNanoseconds == nil else { return }
        stateCommittedAtUptimeNanoseconds = uptimeNanoseconds
    }

    mutating func recordMainActorProbe(at uptimeNanoseconds: UInt64) {
        guard let prior = lastMainActorProbeAtUptimeNanoseconds,
              uptimeNanoseconds >= prior else {
            lastMainActorProbeAtUptimeNanoseconds = uptimeNanoseconds
            return
        }
        let gap = uptimeNanoseconds - prior
        maxMainActorProbeGapNanoseconds = max(maxMainActorProbeGapNanoseconds, gap)
        if gap >= 50_000_000 {
            mainActorHitchCount += 1
        }
        lastMainActorProbeAtUptimeNanoseconds = uptimeNanoseconds
    }

    func result(at uptimeNanoseconds: UInt64) -> TaskOpenResponsivenessResult {
        TaskOpenResponsivenessResult(
            event: "screen_transition_to_view_ready",
            durationMilliseconds: Double(uptimeNanoseconds - startedAtUptimeNanoseconds) / 1_000_000,
            fields: [
                "trace_id": traceID,
                "source": source,
                "destination": destination,
                "task_id": PerformanceTelemetryFields.abbreviatedID(taskID),
                "state_commit_ms": milliseconds(
                    from: startedAtUptimeNanoseconds,
                    to: stateCommittedAtUptimeNanoseconds
                ),
                "state_to_view_ready_ms": milliseconds(
                    from: stateCommittedAtUptimeNanoseconds,
                    to: uptimeNanoseconds
                ),
                "max_main_actor_probe_gap_ms": String(
                    format: "%.2f",
                    Double(maxMainActorProbeGapNanoseconds) / 1_000_000
                ),
                "main_actor_hitch_count": PerformanceTelemetryFields.count(mainActorHitchCount)
            ]
        )
    }

    private func milliseconds(from start: UInt64?, to end: UInt64?) -> String {
        guard let start, let end, end >= start else { return "not_recorded" }
        return String(format: "%.2f", Double(end - start) / 1_000_000)
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
        var trace: ScreenTransitionTrace
        let interval: OSSignpostIntervalState
    }

    private static var activeTransitions: [UUID: ActiveTransition] = [:]
    private static var probeTasks: [UUID: Task<Void, Never>] = [:]

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
        probeTasks[scope] = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                recordMainActorProbe(scope: scope)
            }
        }
    }

    static func stateCommitted(scope: UUID) {
        guard var active = activeTransitions[scope] else { return }
        active.trace.markStateCommitted(at: DispatchTime.now().uptimeNanoseconds)
        activeTransitions[scope] = active
    }

    static func viewBecameReady(destination: String, scope: UUID) {
        guard var active = activeTransitions[scope], active.trace.destination == destination else { return }
        active.trace.recordMainActorProbe(at: DispatchTime.now().uptimeNanoseconds)
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
        probeTasks.removeValue(forKey: scope)?.cancel()
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
        probeTasks.removeValue(forKey: scope)?.cancel()
    }

    static func resetForTesting() {
        for scope in Array(activeTransitions.keys) {
            cancel(scope: scope, reason: "test_reset")
        }
    }

    private static func recordMainActorProbe(scope: UUID) {
        guard var active = activeTransitions[scope] else { return }
        active.trace.recordMainActorProbe(at: DispatchTime.now().uptimeNanoseconds)
        activeTransitions[scope] = active
    }
}
