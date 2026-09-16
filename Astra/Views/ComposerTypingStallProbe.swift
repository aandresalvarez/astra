import Foundation

/// Measures main-actor stalls while the user is typing, rather than only while
/// a task streams.
///
/// `TaskThreadViewModel` already owns a `TaskThreadMainActorStallSampler`, but
/// it starts it only on a *live* refresh and reports its counters on the
/// `chat_stream_snapshot_cadence` line. So the probe exists exactly when a task
/// is streaming and nowhere else — and the complaint that started this work was
/// about typing, which is not the same window. A stall while typing into an
/// idle task produced no cadence line, so it produced no evidence at all.
///
/// This runs the same sampler on the typing window instead, and emits its own
/// `composer_typing_stall` line so the counters have somewhere to land. When a
/// task happens to be streaming too, the two probes run independently and
/// report under different event names; neither consumes the other's counters.
///
/// It is deliberately short-lived. `noteTyping()` arms it, and the first flush
/// window that sees no typing shuts it down, so the 20 Hz probe exists only
/// while someone is actually at the keyboard.
/// Outside the actor so it can be a default argument; see `ComposerTypingStallProbe`.
enum ComposerTypingStallProbeDefaults {
    /// Matches the window the investigation read stalls in: healthy windows
    /// carried 165–430 probes, the stalled ones 3–8.
    static let flushIntervalSeconds: TimeInterval = 2
}

@MainActor
final class ComposerTypingStallProbe {
    static let shared = ComposerTypingStallProbe()

    private let sampler = TaskThreadMainActorStallSampler()
    private let flushInterval: TimeInterval
    private var flushTask: Task<Void, Never>?
    private var typedSinceLastFlush = false

    init(flushInterval: TimeInterval = ComposerTypingStallProbeDefaults.flushIntervalSeconds) {
        self.flushInterval = flushInterval
    }

    var isRunning: Bool { flushTask != nil }

    /// Called on every composer text change. Idempotent and cheap enough to sit
    /// on the keystroke path.
    func noteTyping() {
        typedSinceLastFlush = true
        sampler.start()
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.flushInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if !self.flush() { return }
            }
        }
    }

    /// Emits one window's counters. Returns whether the probe should keep
    /// running — separated from the loop so tests can drive it directly.
    @discardableResult
    func flush() -> Bool {
        let fields = sampler.consumeTelemetryFields()
        let probeCount = Int(fields["main_actor_probe_count"] ?? "0") ?? 0
        // An armed sampler that recorded nothing means the main actor never got
        // to run the probe at all, which is itself the finding. Report the
        // window either way; only silence is misleading.
        if probeCount > 0 || typedSinceLastFlush {
            PerformanceTelemetry.log(
                "composer_typing_stall",
                level: .debug,
                fields: fields.merging(
                    ["window_s": String(format: "%.0f", flushInterval)],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }

        guard typedSinceLastFlush else {
            stop()
            return false
        }
        typedSinceLastFlush = false
        return true
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
        sampler.stop()
        _ = sampler.consumeTelemetryFields()
        typedSinceLastFlush = false
    }
}
