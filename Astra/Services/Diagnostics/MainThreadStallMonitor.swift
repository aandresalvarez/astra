import Foundation
import Darwin
import ASTRACore

/// Reports when the main thread stops servicing its run loop.
///
/// **Why the existing telemetry cannot see this.** Every `PerformanceTelemetry`
/// call site measures a scope it eventually leaves. A SwiftUI AttributeGraph
/// live-lock never leaves one: the main thread enters `NSHostingView.layout()`
/// → `GraphHost.flushTransactions()` and stays there. Nothing logs, because
/// nothing finishes. In the 2026-09-02 production logs that produced minutes
/// classified as *idle at 0.5% busy* while the process burned 99% of a core —
/// the quietest the log ever gets is when the app is most wedged, which is
/// exactly backwards.
///
/// So the heartbeat is written by a run-loop observer on the main thread, and
/// the *check* runs on a background queue that the stall cannot reach. A main
/// thread that never returns to its run loop stops stamping, and the watchdog
/// notices on its own schedule.
///
/// **What it records, and why that field.** `rss_mb` and `footprint_mb` are
/// sampled at every report because they are what separates ASTRA's two freeze
/// signatures without a debugger attached: the AttributeGraph live-lock grows
/// roughly 0.7 GB/min in autoreleased temporaries that the parked run loop
/// never drains, while a main-actor compute loop (a path filter over a huge
/// task folder, say) sits flat. Working that out from the outside costs a
/// `sample` and a `vmmap` against a process the user usually just wants to
/// kill; recording two integers makes the next report answer it by itself.
///
/// The monitor is diagnostic only. It never interrupts, kills, or unwinds
/// anything — a watchdog that acts on its own reading is a second failure mode.
final class MainThreadStallMonitor: @unchecked Sendable {
    /// Long enough that a slow-but-finishing operation — a big fetch, a
    /// synchronous export — does not report, short enough to catch a stall
    /// while the user still associates it with what they just did. Beachballing
    /// starts somewhere around 2 s; this sits above the noisy end of that.
    static let defaultStallThreshold: TimeInterval = 3.0

    /// The watchdog wakes on this cadence. Fine enough to time a stall to
    /// within a poll, coarse enough that an idle app is not being woken to no
    /// purpose.
    static let defaultPollInterval: TimeInterval = 1.0

    /// Re-reports an ongoing stall on a widening schedule. A live-lock lasts
    /// hours — the 2026-08-18 instance ran 2h56m — and one line at the start
    /// tells you nothing about whether it ever ended or how the footprint
    /// moved. Doubling keeps a long wedge to a couple of dozen lines while
    /// still sampling memory often enough to show a growth rate.
    static let escalationFactor: Double = 2.0

    static let shared = MainThreadStallMonitor()

    private let lock = NSLock()
    private let stallThreshold: TimeInterval
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.astra.main-thread-stall-monitor", qos: .utility)

    private var observer: CFRunLoopObserver?
    private var timer: DispatchSourceTimer?
    /// Mach absolute time of the last run-loop activity on the main thread.
    private var lastHeartbeat: UInt64 = DispatchTime.now().uptimeNanoseconds
    /// Whether the last activity seen was `.beforeWaiting` — the run loop
    /// parking itself because it has nothing to do. An app sitting idle in the
    /// background stops stamping for exactly as long as nobody touches it,
    /// which looks identical to a wedge if you only read the timestamp. It is
    /// the opposite: the main thread reached the one point in the loop it can
    /// only reach by being free.
    private var isWaiting = false
    /// Set while a stall is being reported, so recovery can log the total.
    private var stallStartedAt: UInt64?
    private var nextReportThreshold: TimeInterval = 0
    private var reportCount = 0

    /// Stalls seen since launch. Nothing in the app reads it; it exists so a
    /// test can tell "detected and reported" from "never fired".
    private(set) var reportedStallCountForTesting = 0

    init(
        stallThreshold: TimeInterval = MainThreadStallMonitor.defaultStallThreshold,
        pollInterval: TimeInterval = MainThreadStallMonitor.defaultPollInterval
    ) {
        self.stallThreshold = stallThreshold
        self.pollInterval = pollInterval
    }

    /// Installs the heartbeat and starts the watchdog. Call once, from the main
    /// thread, after AppKit has a run loop to observe.
    @MainActor
    func start() {
        lock.lock()
        guard observer == nil, timer == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Every activity, not just `.beforeWaiting`: the point is to know the
        // run loop is still turning at all, and a stall inside a source-0
        // callback never reaches the waiting phase.
        let activities = CFRunLoopActivity.allActivities.rawValue
        let runLoopObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,
            0
        ) { [weak self] _, activity in
            self?.beat(activity: activity)
        }
        if let runLoopObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
        }

        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(100))
        watchdog.setEventHandler { [weak self] in
            self?.check()
        }

        lock.lock()
        observer = runLoopObserver
        timer = watchdog
        lastHeartbeat = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        watchdog.resume()
    }

    func stop() {
        lock.lock()
        let runLoopObserver = observer
        let watchdog = timer
        observer = nil
        timer = nil
        lock.unlock()

        watchdog?.cancel()
        if let runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
        }
    }

    private func beat(activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let stalledSince = stallStartedAt
        lastHeartbeat = now
        isWaiting = activity == .beforeWaiting
        stallStartedAt = nil
        nextReportThreshold = 0
        let count = reportCount
        reportCount = 0
        lock.unlock()

        guard let stalledSince, count > 0 else { return }
        let seconds = Double(now &- stalledSince) / 1_000_000_000
        report(event: "main_thread_stall_recovered", seconds: seconds, level: .warning)
    }

    private func check() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        // Parked, not wedged. `beat` already cleared any stall in progress and
        // logged its recovery on the way in here.
        guard !isWaiting else {
            lock.unlock()
            return
        }
        let elapsed = Double(now &- lastHeartbeat) / 1_000_000_000
        guard elapsed >= stallThreshold else {
            lock.unlock()
            return
        }
        if stallStartedAt == nil {
            stallStartedAt = lastHeartbeat
            nextReportThreshold = stallThreshold
        }
        guard elapsed >= nextReportThreshold else {
            lock.unlock()
            return
        }
        nextReportThreshold = elapsed * Self.escalationFactor
        reportCount += 1
        reportedStallCountForTesting += 1
        let isFirst = reportCount == 1
        lock.unlock()

        report(
            event: "main_thread_stall",
            seconds: elapsed,
            // The first line of a stall is the one a log search has to find.
            // Continuations of the same stall stay at warning so a two-hour
            // wedge does not fill the error channel with one event.
            level: isFirst ? .error : .warning
        )
    }

    private func report(event: String, seconds: Double, level: LogLevel) {
        let memory = Self.memoryFootprint()
        PerformanceTelemetry.log(
            event,
            durationMilliseconds: seconds * 1000,
            level: level,
            fields: [
                "stalled_s": String(format: "%.1f", seconds),
                "rss_mb": String(memory.residentMegabytes),
                "footprint_mb": String(memory.footprintMegabytes)
            ]
        )
    }

    /// Resident size and phys-footprint in MB, read out of the kernel's task
    /// info. `phys_footprint` is the number Activity Monitor shows as "Memory"
    /// and the one that keeps climbing during the live-lock; RSS alone has
    /// under-reported it before, with tens of gigabytes sitting in swap.
    static func memoryFootprint() -> (residentMegabytes: Int, footprintMegabytes: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let megabyte = 1024.0 * 1024.0
        return (
            residentMegabytes: Int(Double(info.resident_size) / megabyte),
            footprintMegabytes: Int(Double(info.phys_footprint) / megabyte)
        )
    }
}
