import Foundation
import os

/// Monotonic age since ASTRAApp.init entered, shared by UI and persistence
/// diagnostics. An unstarted clock is explicit in headless tools/tests.
public enum LaunchDiagnosticClock {
    private static let start = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    public static func markLaunch() {
        start.withLock { if $0 == nil { $0 = ProcessInfo.processInfo.systemUptime } }
    }

    public static func ageMilliseconds(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
        start.withLock { launch in
            launch.map { String(format: "%.2f", max(0, uptime - $0) * 1000) } ?? "unavailable"
        }
    }
}
