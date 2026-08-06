import Foundation

/// Samples main-actor scheduling latency while a task streams.
///
/// `chat_stream_snapshot_cadence` decomposes into build time, the hop back to
/// the main actor, and the apply. Production samples show the hop reaching
/// several seconds while every instrumented main-thread operation in the same
/// window stays fast, which leaves two incompatible explanations: the main
/// actor was blocked inside one long uninstrumented operation, or it was idle
/// and the continuation was starved. Nothing currently in the app can tell
/// those apart.
///
/// This probe can. It re-arms a 50 ms main-actor sleep and records how far each
/// wake overshoots. A blocked main actor shows overshoot tracking the stall; a
/// starved continuation shows overshoot near zero while `apply_hop_ms` is
/// large. The counters ride on the cadence line rather than emitting their own
/// event, so the probe adds no log volume of its own.
@MainActor
final class TaskThreadMainActorStallSampler {
    static let probeIntervalNanoseconds: UInt64 = 50_000_000
    /// A wake later than this counts as a hitch, matching the 50 ms bar the
    /// task-open and screen-transition probes already use.
    static let hitchThresholdNanoseconds: UInt64 = 50_000_000
    /// Backstop against a leaked 20 Hz wakeup if a caller never stops the
    /// sampler. `start()` is called on every live refresh, so a live stream
    /// re-arms this continuously.
    static let idleShutdownSeconds: TimeInterval = 120

    private var probeTask: Task<Void, Never>?
    private var lastStartRequestAt = Date(timeIntervalSince1970: 0)
    private(set) var maxOvershootNanoseconds: UInt64 = 0
    private(set) var hitchCount = 0
    private(set) var probeCount = 0

    var isRunning: Bool { probeTask != nil }

    var maxOvershootMilliseconds: Double {
        Double(maxOvershootNanoseconds) / 1_000_000
    }

    /// Idempotent: safe to call on every live refresh.
    func start() {
        lastStartRequestAt = Date()
        guard probeTask == nil else { return }
        probeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let armedAt = DispatchTime.now().uptimeNanoseconds
                try? await Task.sleep(nanoseconds: Self.probeIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                self.record(wakeGapNanoseconds: DispatchTime.now().uptimeNanoseconds &- armedAt)
                if Date().timeIntervalSince(self.lastStartRequestAt) > Self.idleShutdownSeconds {
                    self.stop()
                    return
                }
            }
        }
    }

    func stop() {
        probeTask?.cancel()
        probeTask = nil
    }

    /// Separated from the loop so tests can drive it without real time.
    func record(wakeGapNanoseconds: UInt64) {
        probeCount += 1
        guard wakeGapNanoseconds > Self.probeIntervalNanoseconds else { return }
        let overshoot = wakeGapNanoseconds &- Self.probeIntervalNanoseconds
        maxOvershootNanoseconds = max(maxOvershootNanoseconds, overshoot)
        if overshoot >= Self.hitchThresholdNanoseconds {
            hitchCount += 1
        }
    }

    /// Returns the counters accumulated since the previous call and clears
    /// them, so each cadence sample reports only its own window.
    func consumeTelemetryFields() -> [String: String] {
        defer {
            maxOvershootNanoseconds = 0
            hitchCount = 0
            probeCount = 0
        }
        return [
            "main_actor_max_stall_ms": String(format: "%.2f", maxOvershootMilliseconds),
            "main_actor_hitch_count": PerformanceTelemetryFields.count(hitchCount),
            "main_actor_probe_count": PerformanceTelemetryFields.count(probeCount)
        ]
    }
}
