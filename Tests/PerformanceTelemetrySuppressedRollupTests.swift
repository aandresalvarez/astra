import Foundation
import Testing
@testable import ASTRA

/// Covers the fix for the blind spot that made this whole investigation harder
/// than it needed to be: during the worst typing windows the performance log
/// was *quiet*, because every operation came in under the 8 ms threshold — a
/// few hundred times a second. Silence has to mean no work.
@Suite("Performance telemetry suppressed-sample rollup")
struct PerformanceTelemetrySuppressedRollupTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Samples inside the window accumulate silently")
    func samplesInsideWindowEmitNothing() {
        let ledger = PerformanceTelemetrySuppressedLedger(flushInterval: 30)

        for index in 0..<100 {
            let rollups = ledger.record(
                event: "sidebar_index_signature",
                milliseconds: 1.5,
                thresholdMilliseconds: 8,
                now: epoch.addingTimeInterval(Double(index) * 0.1)
            )
            #expect(rollups.isEmpty, "Nothing should be emitted before the window elapses")
        }
    }

    @Test("The window's totals surface what the threshold hid")
    func flushReportsAccumulatedTotals() throws {
        let ledger = PerformanceTelemetrySuppressedLedger(flushInterval: 30)

        // 400 calls at 7 ms: individually invisible, 2.8 seconds together.
        for index in 0..<400 {
            _ = ledger.record(
                event: "sidebar_index_signature",
                milliseconds: 7,
                thresholdMilliseconds: 8,
                now: epoch.addingTimeInterval(Double(index) * 0.01)
            )
        }
        _ = ledger.record(
            event: "sidebar_index_signature",
            milliseconds: 7.9,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(20)
        )

        let rollups = ledger.record(
            event: "sidebar_index_signature",
            milliseconds: 0.1,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(31)
        )

        #expect(rollups.count == 1)
        let rollup = try #require(rollups.first)
        #expect(rollup.event == "sidebar_index_signature")
        #expect(rollup.count == 402)
        #expect(abs(rollup.totalMilliseconds - (400 * 7 + 7.9 + 0.1)) < 0.001)
        #expect(abs(rollup.maxMilliseconds - 7.9) < 0.001)
        #expect(rollup.thresholdMilliseconds == 8)
    }

    @Test("Each event gets its own line, costliest first")
    func rollupsAreGroupedByEventAndRanked() {
        let ledger = PerformanceTelemetrySuppressedLedger(flushInterval: 10)

        _ = ledger.record(event: "cheap", milliseconds: 0.5, thresholdMilliseconds: 8, now: epoch)
        _ = ledger.record(event: "expensive", milliseconds: 7, thresholdMilliseconds: 8, now: epoch)
        _ = ledger.record(event: "expensive", milliseconds: 7, thresholdMilliseconds: 8, now: epoch)

        let rollups = ledger.record(
            event: "cheap",
            milliseconds: 0.5,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(11)
        )

        #expect(rollups.map(\.event) == ["expensive", "cheap"])
        #expect(rollups.map(\.count) == [2, 2])
    }

    /// Each line has to describe its own window, or consecutive rollups can't
    /// be compared and a burst looks like a permanent condition.
    @Test("A flush resets the window")
    func flushClearsAccumulatedState() {
        let ledger = PerformanceTelemetrySuppressedLedger(flushInterval: 10)

        for _ in 0..<50 {
            _ = ledger.record(event: "probe", milliseconds: 2, thresholdMilliseconds: 8, now: epoch)
        }
        let first = ledger.record(
            event: "probe",
            milliseconds: 2,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(11)
        )
        #expect(first.first?.count == 51)

        _ = ledger.record(
            event: "probe",
            milliseconds: 2,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(12)
        )
        let second = ledger.record(
            event: "probe",
            milliseconds: 2,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(22)
        )
        #expect(
            second.first?.count == 2,
            "The second window carried over the first window's samples"
        )
    }

    /// The logs are read by filtering on a task, so a rollup attributed to the
    /// wrong one sends the reader to the wrong place — and does it confidently.
    /// Aggregating by event alone folded every task's samples into one bucket
    /// and then stamped the whole flush with whichever sample closed the
    /// window, so a burst in one task was reported against another.
    @Test("A rollup is attributed to the task whose samples it totals")
    func rollupsKeepTheirOwnTaskAttribution() throws {
        let ledger = PerformanceTelemetrySuppressedLedger(flushInterval: 10)
        let busy = UUID()
        let quiet = UUID()

        for _ in 0..<10 {
            _ = ledger.record(
                event: "render_task_thread", taskID: busy,
                milliseconds: 7, thresholdMilliseconds: 8, now: epoch)
        }
        _ = ledger.record(
            event: "render_task_thread", taskID: quiet,
            milliseconds: 1, thresholdMilliseconds: 8, now: epoch)

        // The flush is tripped by the quiet task, which is exactly the shape
        // that used to hand it the busy task's totals.
        let rollups = ledger.record(
            event: "render_task_thread", taskID: quiet,
            milliseconds: 1, thresholdMilliseconds: 8, now: epoch.addingTimeInterval(11))

        #expect(rollups.count == 2)
        let heaviest = try #require(rollups.first)
        #expect(heaviest.taskID == busy)
        #expect(heaviest.count == 10)
        let lighter = try #require(rollups.last)
        #expect(lighter.taskID == quiet)
        #expect(lighter.count == 2)
    }

    /// Attribution splits the buckets, so the unattributed call sites — the
    /// `measure` overloads, which have no task in hand — must still land
    /// together rather than fragmenting one per call.
    @Test("Samples with no task share a single unattributed rollup")
    func unattributedSamplesShareOneBucket() {
        let ledger = PerformanceTelemetrySuppressedLedger(flushInterval: 10)

        for _ in 0..<5 {
            _ = ledger.record(
                event: "build_thread_snapshot",
                milliseconds: 2, thresholdMilliseconds: 8, now: epoch)
        }
        let rollups = ledger.record(
            event: "build_thread_snapshot",
            milliseconds: 2, thresholdMilliseconds: 8, now: epoch.addingTimeInterval(11))

        #expect(rollups.count == 1)
        #expect(rollups.first?.taskID == nil)
        #expect(rollups.first?.count == 6)
    }

    /// The ledger is constructed at process start but the window has to begin
    /// at the first suppressed sample. Anchoring it to construction would make
    /// the first rollup cover however long the app happened to sit idle, and
    /// report it as one window's worth of work.
    @Test("The window starts at the first sample, not at construction")
    func windowStartsAtFirstSample() {
        let ledger = PerformanceTelemetrySuppressedLedger(flushInterval: 10)

        // An hour after this ledger was built — but its first sample.
        let first = ledger.record(
            event: "only",
            milliseconds: 1,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(3_600)
        )
        #expect(first.isEmpty, "The first sample opens the window; it cannot also close it")

        let tooSoon = ledger.record(
            event: "only",
            milliseconds: 1,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(3_605)
        )
        #expect(tooSoon.isEmpty)

        let due = ledger.record(
            event: "only",
            milliseconds: 1,
            thresholdMilliseconds: 8,
            now: epoch.addingTimeInterval(3_611)
        )
        #expect(due.first?.count == 3)
    }
}

/// The stall sampler used to exist only while a task streamed, so the window
/// the lag was actually reported in — typing — produced no evidence.
@Suite("Composer typing stall probe")
@MainActor
struct ComposerTypingStallProbeTests {
    @Test("Typing arms the probe")
    func typingStartsTheProbe() {
        let probe = ComposerTypingStallProbe(flushInterval: 60)
        #expect(!probe.isRunning)
        probe.noteTyping()
        #expect(probe.isRunning)
        probe.stop()
    }

    @Test("The probe keeps running while typing continues")
    func continuedTypingKeepsTheProbeAlive() {
        let probe = ComposerTypingStallProbe(flushInterval: 60)
        probe.noteTyping()

        #expect(probe.flush(), "A window with typing in it should keep the probe armed")
        probe.noteTyping()
        #expect(probe.flush())

        probe.stop()
    }

    /// A 20 Hz probe left running behind an idle composer is exactly the kind
    /// of background cost this whole change is trying to remove.
    @Test("The probe shuts itself down after a quiet window")
    func quietWindowStopsTheProbe() {
        let probe = ComposerTypingStallProbe(flushInterval: 60)
        probe.noteTyping()
        #expect(probe.isRunning)

        // First flush consumes the typing that armed it.
        #expect(probe.flush())
        // Second sees no typing at all.
        #expect(!probe.flush(), "A quiet window should retire the probe")
        #expect(!probe.isRunning)
    }
}
