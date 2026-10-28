import Foundation
import os
import ASTRACore

/// How the detail area was laid out around a right-side panel: the layout
/// mode, the width proposed to the transcript, and the panel's width. A
/// transition records the layout before it began and the first one after, so
/// a slow `view_ready` can be read against how much the transcript had to
/// reflow (`detail_width_delta`) and in which mode.
struct ScreenTransitionLayout: Equatable {
    let mode: String
    let detailWidth: Double
    let panelWidth: Double
}

/// Whether a right-side transition opened a panel, closed one, or swapped one
/// for another, from the panel names before and after ("none" for no panel).
enum ScreenTransitionDirection {
    static func resolve(previousPanel: String?, nextPanel: String?) -> String {
        switch (previousPanel, nextPanel) {
        case (nil, nil): return "none"
        case (nil, _): return "open"
        case (_, nil): return "close"
        case let (previous?, next?): return previous == next ? "none" : "switch"
        }
    }
}

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
    /// Caller-supplied facts that never change during the transition: the
    /// direction, and the size of the task whose transcript is affected.
    let context: [String: String]
    let layoutBefore: ScreenTransitionLayout?
    private(set) var layoutAfter: ScreenTransitionLayout?
    private(set) var stateCommittedAtUptimeNanoseconds: UInt64?
    private(set) var lastMainActorProbeAtUptimeNanoseconds: UInt64?
    private(set) var maxMainActorProbeGapNanoseconds: UInt64 = 0
    private(set) var mainActorHitchCount = 0

    init(
        traceID: String,
        destination: String,
        source: String,
        taskID: UUID?,
        startedAtUptimeNanoseconds: UInt64,
        context: [String: String] = [:],
        layoutBefore: ScreenTransitionLayout? = nil
    ) {
        self.traceID = traceID
        self.destination = destination
        self.source = source
        self.taskID = taskID
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        self.context = context
        self.layoutBefore = layoutBefore
        lastMainActorProbeAtUptimeNanoseconds = startedAtUptimeNanoseconds
    }

    mutating func markStateCommitted(at uptimeNanoseconds: UInt64) {
        guard stateCommittedAtUptimeNanoseconds == nil else { return }
        stateCommittedAtUptimeNanoseconds = uptimeNanoseconds
    }

    /// The first layout the detail area reports after the state change; later
    /// reports (a resize, a drag) belong to no transition and are ignored.
    mutating func recordLayout(_ layout: ScreenTransitionLayout) {
        guard layoutAfter == nil, layout != layoutBefore else { return }
        layoutAfter = layout
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
        var fields: [String: String] = [
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
        fields.merge(layoutFields) { current, _ in current }
        fields.merge(context) { current, _ in current }
        return TaskOpenResponsivenessResult(
            event: "screen_transition_to_view_ready",
            durationMilliseconds: Double(uptimeNanoseconds - startedAtUptimeNanoseconds) / 1_000_000,
            fields: fields
        )
    }

    /// `detail_width_delta` is the reflow the transcript paid: how many points
    /// its proposed width moved. Zero means the panel overlapped margin only.
    private var layoutFields: [String: String] {
        var fields: [String: String] = [
            "layout_mode": layoutAfter?.mode ?? layoutBefore?.mode ?? "not_recorded",
            "detail_width_before": points(layoutBefore?.detailWidth),
            "detail_width_after": points(layoutAfter?.detailWidth),
            "panel_width": points((layoutAfter ?? layoutBefore)?.panelWidth)
        ]
        if let before = layoutBefore, let after = layoutAfter {
            fields["detail_width_delta"] = points(abs(after.detailWidth - before.detailWidth))
        } else {
            fields["detail_width_delta"] = "not_recorded"
        }
        return fields
    }

    private func points(_ value: Double?) -> String {
        guard let value else { return "not_recorded" }
        return String(format: "%.0f", value)
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

    static func begin(
        destination: String,
        source: String,
        taskID: UUID?,
        scope: UUID,
        context: [String: String] = [:],
        layoutBefore: ScreenTransitionLayout? = nil
    ) {
        cancel(scope: scope, reason: "superseded")
        let id = signposter.makeSignpostID()
        activeTransitions[scope] = ActiveTransition(
            trace: ScreenTransitionTrace(
                traceID: AuditTrace.make("screen-transition"),
                destination: destination,
                source: source,
                taskID: taskID,
                startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                context: context,
                layoutBefore: layoutBefore
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

    static func recordLayout(_ layout: ScreenTransitionLayout, scope: UUID) {
        guard var active = activeTransitions[scope] else { return }
        active.trace.recordLayout(layout)
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
