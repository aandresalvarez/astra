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
    /// Overshoot below this is timer coalescing, not occupancy. A main-actor
    /// `Task.sleep` routinely wakes a millisecond or two late on a completely
    /// idle actor, and unlike the telemetry counters above the control window
    /// *sums* every sample: at 20 Hz, 2 ms of per-wake jitter would forge 40 ms
    /// of "busy" every second and make `TaskThreadLiveSnapshotPacer` throttle a
    /// thread that is doing nothing. The bar is one frame -- the same amount of
    /// main-actor work `PerformanceTelemetry.uiFrameThresholdMilliseconds`
    /// already treats as free. The known bias this buys is that occupancy
    /// delivered in sub-frame slices is invisible to the pacer; the failure the
    /// pacer exists to bound -- one uninterruptible multi-hundred-millisecond
    /// layout pass -- is not.
    static let controlWindowNoiseFloorNanoseconds: UInt64 = 8_000_000

    /// Main-actor occupancy observed over one control window.
    struct Occupancy: Equatable, Sendable {
        let busyNanoseconds: UInt64
        let longestBlockNanoseconds: UInt64

        static let none = Occupancy(busyNanoseconds: 0, longestBlockNanoseconds: 0)

        var busyMilliseconds: Double { Double(busyNanoseconds) / 1_000_000 }
        var longestBlockMilliseconds: Double { Double(longestBlockNanoseconds) / 1_000_000 }
    }

    private var probeTask: Task<Void, Never>?
    private var lastStartRequestAt = Date(timeIntervalSince1970: 0)
    private(set) var maxOvershootNanoseconds: UInt64 = 0
    private(set) var hitchCount = 0
    private(set) var probeCount = 0
    // A second accumulator, deliberately not shared with the three above.
    // `consumeTelemetryFields` is drained at most once per second and only by a
    // cadence sample that actually got logged, while the pacer must drain on
    // every scheduling decision. One shared read-and-clear pair would mean
    // whichever consumer ran first blinded the other.
    private var controlWindowBusyNanoseconds: UInt64 = 0
    private var controlWindowLongestBlockNanoseconds: UInt64 = 0

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
        guard overshoot >= Self.controlWindowNoiseFloorNanoseconds else { return }
        // Sum, not max: the pacer needs total occupancy over the window,
        // because a period can contain the layout pass *and* the pre-read save
        // *and* the storage-backed input sort, and a duty cycle computed from
        // only the largest of those under-throttles.
        controlWindowBusyNanoseconds &+= overshoot
        controlWindowLongestBlockNanoseconds = max(controlWindowLongestBlockNanoseconds, overshoot)
    }

    /// Returns the occupancy accumulated since the previous call and clears it.
    /// Independent of `consumeTelemetryFields`: a caller of either must never
    /// change what the other observes.
    ///
    /// A probe cycle that straddles the start of a block absorbs the whole block
    /// into one overshoot, so a contiguous block is under-reported by at most
    /// the remaining sleep at the moment it began -- bounded by
    /// `probeIntervalNanoseconds`, i.e. 50 ms on a 700 ms render. The error is in
    /// the permissive direction and is quantified here rather than corrected so
    /// the number stays a measurement rather than an estimate.
    func consumeControlWindow() -> Occupancy {
        defer {
            controlWindowBusyNanoseconds = 0
            controlWindowLongestBlockNanoseconds = 0
        }
        return Occupancy(
            busyNanoseconds: controlWindowBusyNanoseconds,
            longestBlockNanoseconds: controlWindowLongestBlockNanoseconds
        )
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
