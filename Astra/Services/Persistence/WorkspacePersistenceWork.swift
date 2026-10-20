import Foundation
import os
import ASTRACore

/// Distinguishes synchronous store work from mirror projection and file I/O.
/// Timings are wall time, not CPU time; Instruments can inspect the intervals.
enum WorkspacePersistenceWork {
    private static let signposter = OSSignposter(subsystem: AppChannel.current.loggingSubsystem, category: "Persistence")

    static func measure<T>(_ phase: String, workspaceID: String, _ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let interval = signposter.beginInterval("workspace_persistence", id: signposter.makeSignpostID(), "\(phase, privacy: .public)")
        defer {
            signposter.endInterval("workspace_persistence", interval)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if milliseconds >= 8 {
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                    "result": "timing", "phase": phase, "duration_ms": String(format: "%.2f", milliseconds),
                    "main_thread": String(Thread.isMainThread), "workspace_id": workspaceID
                ], level: .debug)
            }
        }
        return try work()
    }
}
