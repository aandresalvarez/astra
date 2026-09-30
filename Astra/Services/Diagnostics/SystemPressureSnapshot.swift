import Foundation
import Darwin

/// Machine-wide load and memory pressure, sampled next to a stall report.
///
/// `MainThreadStallMonitor` records how long the main thread stopped and how
/// much memory ASTRA held while it did. Neither says whether the stall was
/// ASTRA's. In the 2026-09-26..29 logs the recovered stalls of 8 s or more all
/// fell in windows where several worktrees were compiling, ASTRA Dev and
/// production stalled in the same minutes with separate stores, and the long
/// ones showed a resident size near 0.6 of their footprint — a process being
/// paged back in. The shorter, isolated stalls had no such company. From the
/// app's own log alone those two populations were indistinguishable, and
/// telling them apart took an overlay against build-output mtimes and agent
/// transcripts.
///
/// So the report now carries the machine's state as well: load averages with
/// the CPU count to read them against, the kernel's memory-pressure level,
/// free memory and swap in use, and this process's own page-in count. The last
/// is cumulative; the first stall line and the recovery line of one stall
/// differ by what was paged in between them.
///
/// Every reading is a single cheap syscall, so it is safe on the watchdog
/// queue and on the main thread's recovery path. A reading the kernel refuses
/// is left out rather than written as zero — a zero load average is a claim,
/// and these fields exist to make claims about the machine.
struct SystemPressureSnapshot: Equatable {
    /// The kernel's `kern.memorystatus_vm_pressure_level`, the same signal
    /// Activity Monitor's memory-pressure graph is drawn from.
    enum MemoryPressure: Equatable {
        case normal
        case warn
        case critical
        /// The kernel answered with a level this build does not know. Kept
        /// distinct from an absent field, which means it could not be read.
        case unrecognized

        init(kernelLevel: Int32) {
            switch kernelLevel {
            case 1: self = .normal
            case 2: self = .warn
            case 4: self = .critical
            default: self = .unrecognized
            }
        }

        var token: String {
            switch self {
            case .normal: return "normal"
            case .warn: return "warn"
            case .critical: return "critical"
            case .unrecognized: return "unrecognized"
            }
        }
    }

    var load1m: Double?
    var load5m: Double?
    var load15m: Double?
    var logicalCPUCount: Int?
    var memoryPressure: MemoryPressure?
    /// `kern.memorystatus_level`: the percentage of memory the kernel considers
    /// available, the figure `memory_pressure` prints as "free percentage".
    var memoryFreePercent: Int?
    var swapUsedMegabytes: Int?
    var swapTotalMegabytes: Int?
    /// Pages this process has faulted in from disk or the compressor since it
    /// launched. Cumulative — read it as a difference between two lines.
    var processPageIns: Int?

    /// Log fields for whatever could be read. Keys follow the stall line's
    /// existing `_mb` / `_s` suffix style.
    var telemetryFields: [String: String] {
        var fields: [String: String] = [:]
        if let load1m { fields["load_1m"] = String(format: "%.2f", load1m) }
        if let load5m { fields["load_5m"] = String(format: "%.2f", load5m) }
        if let load15m { fields["load_15m"] = String(format: "%.2f", load15m) }
        if let logicalCPUCount { fields["cpu_count"] = String(logicalCPUCount) }
        if let memoryPressure { fields["mem_pressure"] = memoryPressure.token }
        if let memoryFreePercent { fields["mem_free_pct"] = String(memoryFreePercent) }
        if let swapUsedMegabytes { fields["swap_used_mb"] = String(swapUsedMegabytes) }
        if let swapTotalMegabytes { fields["swap_total_mb"] = String(swapTotalMegabytes) }
        if let processPageIns { fields["pageins"] = String(processPageIns) }
        return fields
    }

    /// Reads the machine as it is now.
    static func current() -> SystemPressureSnapshot {
        var snapshot = SystemPressureSnapshot()

        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        if loadCount >= 1 { snapshot.load1m = loads[0] }
        if loadCount >= 2 { snapshot.load5m = loads[1] }
        if loadCount >= 3 { snapshot.load15m = loads[2] }

        snapshot.logicalCPUCount = sysctlInt32("hw.logicalcpu").map(Int.init)
        snapshot.memoryPressure = sysctlInt32("kern.memorystatus_vm_pressure_level")
            .map(MemoryPressure.init(kernelLevel:))
        snapshot.memoryFreePercent = sysctlInt32("kern.memorystatus_level").map(Int.init)

        if let swap = swapUsage() {
            snapshot.swapUsedMegabytes = swap.usedMegabytes
            snapshot.swapTotalMegabytes = swap.totalMegabytes
        }
        snapshot.processPageIns = processPageIns()
        return snapshot
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func swapUsage() -> (usedMegabytes: Int, totalMegabytes: Int)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        let megabyte = 1024.0 * 1024.0
        return (Int(Double(usage.xsu_used) / megabyte), Int(Double(usage.xsu_total) / megabyte))
    }

    private static func processPageIns() -> Int? {
        var info = task_events_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_events_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.pageins)
    }
}
