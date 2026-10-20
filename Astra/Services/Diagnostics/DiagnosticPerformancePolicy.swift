import Foundation
import ASTRACore

enum DiagnosticPerformancePolicy {
    static func isActionable(_ entry: LogEntry) -> Bool {
        guard entry.category == "Performance" else { return false }
        let fields = UIResponsivenessDiagnostics.fields(in: entry.message)
        if let stall = Double(fields["main_actor_max_stall_ms"] ?? ""), stall >= 1_000 { return true }
        guard let event = fields["event"], let duration = Double(fields["duration_ms"] ?? "") else { return false }
        let userVisible = UIResponsivenessDiagnostics.isRoutineMeasurement(event)
            && !UIResponsivenessDiagnostics.isFilesShelfInternalTiming(event)
        return (userVisible || event == "main_thread_stall") && duration >= 3_000
    }
}
