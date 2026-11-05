import Foundation
import os
import ASTRACore

/// Metadata-only aggregates, scoped to one retained startup job or mirror
/// rewrite pass. No path, config, task text, namespace or secret is retained.
final class StartupCleanupAggregate: @unchecked Sendable {
    enum Operation: String {
        case copy
        case jsonEncode = "json_encode"
        case jsonWrite = "json_write"
        case mirror = "mirror_request"
    }
    private struct Totals {
        var workspaces: Set<String> = []
        var attempts: [Operation: Int] = [:]
        var successes: [Operation: Int] = [:]
        var failures: [Operation: Int] = [:]
        var skippedWrites = 0
        var errors: [String: Int] = [:]
        var snapshotBytes: Int64 = 0
        var snapshotSizeUnknown = 0
        var jsonEncodedBytes = 0
        var jsonWrittenBytes = 0
        var jsonAttemptedBytes = 0
        var phases: [String: (count: Int, total: Double, main: Double, max: Double)] = [:]
        var passes = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: Totals())
    let id = UUID().uuidString

    func attempt(_ operation: Operation, workspaceID: String) {
        state.withLock {
            $0.attempts[operation, default: 0] += 1
            $0.workspaces.insert(workspaceID)
        }
    }

    func finish(_ operation: Operation, succeeded: Bool, error: (any Error)? = nil, bytes: Int = 0) {
        state.withLock {
            if succeeded { $0.successes[operation, default: 0] += 1 }
            else if operation == .jsonWrite && error == nil { $0.skippedWrites += 1 }
            else { $0.failures[operation, default: 0] += 1 }
            if let error { $0.errors[Self.errorCategory(error), default: 0] += 1 }
            if succeeded && operation == .jsonEncode { $0.jsonEncodedBytes += bytes }
            if succeeded && operation == .jsonWrite { $0.jsonWrittenBytes += bytes }
            if operation == .jsonWrite { $0.jsonAttemptedBytes += bytes }
        }
    }

    func snapshotBytes(_ bytes: Int64?) {
        state.withLock {
            if let bytes { $0.snapshotBytes += bytes }
            else { $0.snapshotSizeUnknown += 1 }
        }
    }

    func phase(_ name: String, milliseconds: Double, main: Bool) {
        state.withLock {
            var phase = $0.phases[name] ?? (0, 0, 0, 0)
            phase.count += 1
            phase.total += milliseconds
            if main { phase.main += milliseconds }
            phase.max = max(phase.max, milliseconds)
            $0.phases[name] = phase
        }
    }

    func beginPass() { state.withLock { $0.passes += 1 } }

    func fields() -> [String: String] {
        state.withLock { totals in
            var fields = [
                "distinct_workspaces": String(totals.workspaces.count),
                "pass_count": String(totals.passes),
                // Successful backup file lengths, summed once per copy.
                // Logical bytes do not measure allocated blocks or device I/O.
                "logical_snapshot_bytes": String(totals.snapshotBytes),
                "snapshot_size_unknown": String(totals.snapshotSizeUnknown),
                "json_encoded_bytes": String(totals.jsonEncodedBytes),
                "json_written_bytes": String(totals.jsonWrittenBytes),
                "json_write_attempted_bytes": String(totals.jsonAttemptedBytes),
                "json_write_skipped": String(totals.skippedWrites)
            ]
            for operation in [Operation.copy, .jsonEncode, .jsonWrite, .mirror] {
                fields[operation.rawValue + "_attempts"] = String(totals.attempts[operation, default: 0])
                fields[operation.rawValue + "_succeeded"] = String(totals.successes[operation, default: 0])
                fields[operation.rawValue + "_failed"] = String(totals.failures[operation, default: 0])
            }
            for (category, count) in totals.errors { fields["error_" + category] = String(count) }
            for (name, phase) in totals.phases {
                fields[name + "_count"] = String(phase.count)
                fields[name + "_total_ms"] = String(format: "%.2f", phase.total)
                fields[name + "_main_ms"] = String(format: "%.2f", phase.main)
                fields[name + "_max_ms"] = String(format: "%.2f", phase.max)
            }
            return fields
        }
    }

    static func errorCategory(_ error: any Error, depth: Int = 0) -> String {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain {
            if value.code == NSFileWriteOutOfSpaceError { return "disk_full" }
            if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code) { return "permission" }
            if [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code) { return "missing" }
        }
        if value.domain == NSPOSIXErrorDomain {
            switch value.code {
            case Int(ENOSPC), Int(EDQUOT): return "disk_full"
            case Int(EACCES), Int(EPERM): return "permission"
            case Int(ENOENT): return "missing"
            case Int(EBUSY): return "busy"
            default: break
            }
        }
        if depth < 4, let underlying = value.userInfo[NSUnderlyingErrorKey] as? any Error {
            let category = errorCategory(underlying, depth: depth + 1)
            if category != "other" { return category }
        }
        // The existing backup API wraps SQLite results in this typed error.
        // Inspect only its fixed diagnostic vocabulary; never log the string.
        if case WorkspaceRecoveryService.PersistentStorePreparationError.migrationFailed(let detail) = error {
            if detail.contains("step 13,") || detail.contains("database or disk is full")
                || detail.contains("NSCocoaErrorDomain Code=\(NSFileWriteOutOfSpaceError)")
                || detail.contains("NSPOSIXErrorDomain Code=\(ENOSPC)")
                || detail.contains("NSPOSIXErrorDomain Code=\(EDQUOT)") { return "disk_full" }
            if detail.contains("step 5,") || detail.contains("step 6,") { return "busy" }
            return "snapshot"
        }
        if error is EncodingError { return "encoding" }
        if error is CancellationError { return "cancelled" }
        return "other"
    }
}
