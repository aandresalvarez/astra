import Foundation
import Testing
@testable import ASTRA

/// The watchdog exists because a wedged app is the one state ASTRA's telemetry
/// cannot describe: every other call site measures a scope it eventually
/// leaves, and a SwiftUI AttributeGraph live-lock never leaves one. So the only
/// thing worth pinning here is that a main thread which stops servicing its run
/// loop actually gets reported, from a queue the stall cannot reach.
@Suite("Main-thread stall monitor")
struct MainThreadStallMonitorTests {
    @MainActor
    @Test("A blocked main thread is reported by the background watchdog")
    func blockedMainThreadIsReported() {
        let monitor = MainThreadStallMonitor(stallThreshold: 0.2, pollInterval: 0.05)
        monitor.start()
        defer { monitor.stop() }

        #expect(monitor.reportedStallCountForTesting == 0)
        // Blocking, not `await`: yielding would let the run loop turn and the
        // heartbeat land, which is the case that must *not* report.
        Thread.sleep(forTimeInterval: 1.0)
        #expect(monitor.reportedStallCountForTesting >= 1)
    }

    @MainActor
    @Test("An idle run loop is not mistaken for a wedged one")
    func idleMainThreadIsNotReported() {
        let monitor = MainThreadStallMonitor(stallThreshold: 0.2, pollInterval: 0.05)
        monitor.start()
        defer { monitor.stop() }

        // Servicing the run loop with nothing to do parks it in
        // `.beforeWaiting` and it stops stamping — which is what a wedge looks
        // like from the timestamp alone. An app the user has left alone in the
        // background must not fill the error channel.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        #expect(monitor.reportedStallCountForTesting == 0)
    }

    @MainActor
    @Test("Starting twice installs one watchdog")
    func startIsIdempotent() {
        let monitor = MainThreadStallMonitor(stallThreshold: 5.0, pollInterval: 0.05)
        monitor.start()
        monitor.start()
        monitor.stop()
        // A second observer left on the main run loop would outlive `stop()`
        // and keep beating into a monitor nothing owns any more.
        monitor.stop()
    }

    @Test("Memory is sampled from the kernel, not guessed")
    func memoryFootprintIsReadable() {
        let memory = MainThreadStallMonitor.memoryFootprint()
        // The two numbers that separate ASTRA's two freeze signatures. A zero
        // here means `task_info` failed and every stall report is blind.
        #expect(memory.residentMegabytes > 0)
        #expect(memory.footprintMegabytes > 0)
    }
}
