import Foundation
import os
import ASTRACore

/// Distinguishes synchronous store work from mirror projection and file I/O.
/// Timings are wall time, not CPU time; Instruments can inspect the intervals.
public enum WorkspacePersistenceWork {
    private static let signposter = OSSignposter(subsystem: AppChannel.current.loggingSubsystem, category: "Persistence")
    @TaskLocal static var cleanupJob: StartupCleanupAggregate?
    @TaskLocal static var cleanupPass: StartupCleanupAggregate?

    public enum CleanupTrigger: String, Sendable {
        case connectorGeneration = "connector_generation"
        case skillGeneration = "skill_generation"
        case pluginSecretOutbox = "plugin_secret_outbox"
        case unspecified
    }

    @MainActor
    public static func withCleanupJob(_ work: () async -> Void) async {
        let job = StartupCleanupAggregate()
        let start = DispatchTime.now().uptimeNanoseconds
        started("startup_cleanup_job_started", fields: ["job_id": job.id, "trigger": "after_workspace_recovery"])
        await $cleanupJob.withValue(job) { await work() }
        report(job, event: "startup_cleanup_job", start: start,
            fields: ["job_id": job.id, "trigger": "after_workspace_recovery",
                     "outcome": Task.isCancelled ? "cancelled" : "returned"])
    }

    @MainActor
    public static func withCleanupPass<T>(trigger: CleanupTrigger, _ work: () async -> T?) async -> T? {
        let pass = StartupCleanupAggregate()
        cleanupJob?.beginPass()
        pass.beginPass()
        let start = DispatchTime.now().uptimeNanoseconds
        started("startup_cleanup_pass_started", fields: ["job_id": cleanupJob?.id ?? "none",
            "pass_id": pass.id, "trigger": trigger.rawValue])
        let result = await $cleanupPass.withValue(pass) { await work() }
        report(pass, event: "startup_cleanup_pass", start: start,
            fields: ["job_id": cleanupJob?.id ?? "none", "pass_id": pass.id,
                     "trigger": trigger.rawValue, "outcome": result == nil ? "held" : "ready"])
        return result
    }

    private static func started(_ event: String, fields: [String: String]) {
        AuditLoggingSeam.required.audit(.workspaceExported, category: "Performance", fields:
            fields.merging(["event": event, "launch_age_ms": LaunchDiagnosticClock.ageMilliseconds()],
                uniquingKeysWith: { _, new in new }), level: .info)
    }

    private static func report(_ aggregate: StartupCleanupAggregate, event: String, start: UInt64,
                               fields: [String: String]) {
        AuditLoggingSeam.required.audit(.workspaceExported, category: "Performance", fields:
            aggregate.fields().merging(fields, uniquingKeysWith: { _, new in new }).merging([
                "event": event, "launch_age_ms": LaunchDiagnosticClock.ageMilliseconds(),
                "duration_ms": String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            ], uniquingKeysWith: { _, new in new }), level: .info)
    }

    private static func record(_ work: (StartupCleanupAggregate) -> Void) {
        if let cleanupJob { work(cleanupJob) }
        if let cleanupPass { work(cleanupPass) }
    }

    static func snapshotCopy<T>(workspaceID: String, _ work: () throws -> T) rethrows -> T {
        record { $0.attempt(.copy, workspaceID: workspaceID) }
        do {
            let result = try work()
            record { $0.finish(.copy, succeeded: true) }
            return result
        } catch {
            record { $0.finish(.copy, succeeded: false, error: error) }
            throw error
        }
    }

    static func copiedSnapshot(at url: URL) {
        guard cleanupJob != nil || cleanupPass != nil else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        record { $0.snapshotBytes(size) }
    }

    static func jsonEncode(workspaceID: String, _ work: () throws -> Data) rethrows -> Data {
        record { $0.attempt(.jsonEncode, workspaceID: workspaceID) }
        do {
            let data = try work()
            record { $0.finish(.jsonEncode, succeeded: true, bytes: data.count) }
            return data
        } catch {
            record { $0.finish(.jsonEncode, succeeded: false, error: error) }
            throw error
        }
    }

    static func jsonWrite<T>(workspaceID: String, bytes: Int, published: (T) -> Bool,
                             _ work: () throws -> T) rethrows -> T {
        record { $0.attempt(.jsonWrite, workspaceID: workspaceID) }
        do {
            let result = try work()
            record { $0.finish(.jsonWrite, succeeded: published(result), bytes: bytes) }
            return result
        } catch {
            record { $0.finish(.jsonWrite, succeeded: false, error: error, bytes: bytes) }
            throw error
        }
    }

    public static func mirrorAttempt(workspaceID: UUID) {
        record { $0.attempt(.mirror, workspaceID: workspaceID.uuidString) }
    }

    public static func mirrorFinished(succeeded: Bool) {
        record { $0.finish(.mirror, succeeded: succeeded) }
    }

    public static func measure<T>(_ phase: String, workspaceID: String, _ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let interval = signposter.beginInterval("workspace_persistence", id: signposter.makeSignpostID(), "\(phase, privacy: .public)")
        defer {
            signposter.endInterval("workspace_persistence", interval)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            record { $0.phase(phase, milliseconds: milliseconds, main: Thread.isMainThread) }
            if milliseconds >= 8 {
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                    "result": "timing", "phase": phase, "duration_ms": String(format: "%.2f", milliseconds),
                    "main_thread": String(Thread.isMainThread), "workspace_id": workspaceID,
                    "job_id": cleanupJob?.id ?? "none", "pass_id": cleanupPass?.id ?? "none",
                    "launch_age_ms": LaunchDiagnosticClock.ageMilliseconds()
                ], level: .debug)
            }
        }
        let pushed = AuditLoggingSeam.required.beginMainThreadPhase(phase)
        defer { if pushed { AuditLoggingSeam.required.endMainThreadPhase() } }
        return try work()
    }
}
