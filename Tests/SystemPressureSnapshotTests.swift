import Foundation
import Testing
@testable import ASTRA

/// A stall line that names only ASTRA's own memory cannot say whether the
/// machine was the cause. These pin the machine-side fields a log search will
/// rely on, and the rule that an unreadable value is absent rather than zero.
@Suite("System pressure snapshot")
struct SystemPressureSnapshotTests {
    @Test("The live snapshot reads from the kernel rather than guessing")
    func liveSnapshotIsReadable() {
        let snapshot = SystemPressureSnapshot.current()

        // Each of these is a syscall that succeeds for an unsandboxed process
        // on every macOS this app supports. A nil means the field would be
        // silently missing from every stall report.
        #expect(snapshot.load1m != nil)
        #expect((snapshot.load1m ?? -1) >= 0)
        #expect((snapshot.logicalCPUCount ?? 0) > 0)
        #expect(snapshot.memoryPressure != nil)
        #expect(snapshot.memoryPressure != .unrecognized)
        #expect(snapshot.memoryFreePercent.map { (0...100).contains($0) } == true)
        #expect((snapshot.swapUsedMegabytes ?? -1) >= 0)
        #expect((snapshot.swapUsedMegabytes ?? 0) <= (snapshot.swapTotalMegabytes ?? 0))
        #expect((snapshot.processPageIns ?? -1) >= 0)
    }

    @Test("Kernel pressure levels map to distinct tokens")
    func pressureLevelsAreNamed() {
        // 1, 2 and 4 are DISPATCH_MEMORYPRESSURE_NORMAL / WARN / CRITICAL.
        #expect(SystemPressureSnapshot.MemoryPressure(kernelLevel: 1).token == "normal")
        #expect(SystemPressureSnapshot.MemoryPressure(kernelLevel: 2).token == "warn")
        #expect(SystemPressureSnapshot.MemoryPressure(kernelLevel: 4).token == "critical")
        // Not folded into `normal`: a level this build has never seen is the
        // one case where the safe-looking default would hide real pressure.
        #expect(SystemPressureSnapshot.MemoryPressure(kernelLevel: 3).token == "unrecognized")
        #expect(SystemPressureSnapshot.MemoryPressure(kernelLevel: 0).token == "unrecognized")
    }

    @Test("A fully read snapshot becomes one field per reading")
    func fieldsCarryEveryReading() {
        let snapshot = SystemPressureSnapshot(
            load1m: 9.5,
            load5m: 6.25,
            load15m: 3.0,
            logicalCPUCount: 10,
            memoryPressure: .warn,
            memoryFreePercent: 12,
            swapUsedMegabytes: 10_882,
            swapTotalMegabytes: 12_288,
            processPageIns: 48_213
        )
        let fields = snapshot.telemetryFields

        #expect(fields["load_1m"] == "9.50")
        #expect(fields["load_5m"] == "6.25")
        #expect(fields["load_15m"] == "3.00")
        #expect(fields["cpu_count"] == "10")
        #expect(fields["mem_pressure"] == "warn")
        #expect(fields["mem_free_pct"] == "12")
        #expect(fields["swap_used_mb"] == "10882")
        #expect(fields["swap_total_mb"] == "12288")
        #expect(fields["pageins"] == "48213")
    }

    @Test("A reading the kernel refused is absent, not zero")
    func unreadableValuesAreOmitted() {
        var snapshot = SystemPressureSnapshot()
        snapshot.load1m = 0.0
        snapshot.memoryPressure = .normal
        let fields = snapshot.telemetryFields

        // A genuine 0.00 load is reported; the readings nobody took are not
        // invented. `swap_used_mb=0` would claim an idle swap file.
        #expect(fields["load_1m"] == "0.00")
        #expect(fields["mem_pressure"] == "normal")
        #expect(fields["swap_used_mb"] == nil)
        #expect(fields["swap_total_mb"] == nil)
        #expect(fields["pageins"] == nil)
        #expect(fields["cpu_count"] == nil)
        #expect(SystemPressureSnapshot().telemetryFields.isEmpty)
    }

    @Test("A stall line carries the machine's state beside ASTRA's own")
    func stallFieldsIncludePressure() {
        let fields = MainThreadStallMonitor.reportFields(
            seconds: 14.2,
            memory: (residentMegabytes: 113, footprintMegabytes: 211),
            activity: .afterWaiting,
            phase: .idle,
            pressure: SystemPressureSnapshot(
                load1m: 8.4,
                logicalCPUCount: 10,
                memoryPressure: .critical,
                swapUsedMegabytes: 10_882
            )
        )

        // The pair this exists to put on one line: a resident size well under
        // the footprint, and a machine that was paging.
        #expect(fields["rss_mb"] == "113")
        #expect(fields["footprint_mb"] == "211")
        #expect(fields["mem_pressure"] == "critical")
        #expect(fields["swap_used_mb"] == "10882")
        #expect(fields["load_1m"] == "8.40")
        // Nothing the earlier format carried is displaced.
        #expect(fields["stalled_s"] == "14.2")
        #expect(fields["phase"] == "none")
        #expect(fields["run_loop_activity"] == "after_waiting")
    }

    @Test("A stall line without a pressure reading keeps its previous shape")
    func stallFieldsWithoutPressureAreUnchanged() {
        let fields = MainThreadStallMonitor.reportFields(
            seconds: 3.1,
            memory: (residentMegabytes: 100, footprintMegabytes: 90),
            activity: .beforeSources,
            phase: nil
        )

        #expect(Set(fields.keys) == ["stalled_s", "rss_mb", "footprint_mb", "run_loop_activity"])
    }
}
