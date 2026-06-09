import Foundation

/// Recovers task context state on load so a bad `current_state.json` can never silently
/// erase real task history.
///
/// - A present-but-unusable file (unreadable, corrupt, or written by an incompatible
///   schema) is **quarantined** — moved aside under a `current_state.corrupt-<stamp>.json`
///   name — instead of being overwritten in place by a blank capsule.
/// - A **newer but structurally-readable** file is backed up once and its
///   current-schema-compatible content is reused (degraded read), rather than discarded.
/// - A missing file is normal for a brand-new task and is left untouched.
///
/// `promptContext` intentionally keeps using the plain, side-effect-free loader: recovery
/// belongs on the mutation paths (`recordTurn` / `refresh`), not on read-only rendering.
enum TaskContextStateRecovery {
    /// Returns usable state, or `nil` when the task should start from a fresh capsule.
    /// May quarantine or back up the on-disk file as a side effect.
    static func recoverState(taskFolder: String, taskID: UUID?) -> TaskContextState? {
        let result = TaskContextStateManager.loadResult(taskFolder: taskFolder)
        switch result.status {
        case .loadedCurrent, .migratedLegacy:
            return result.state
        case .missingFile:
            return nil
        case .unreadableFile, .decodeFailed:
            quarantine(path: result.path, reason: result.status.rawValue, taskID: taskID, diagnostic: result.errorDescription)
            return nil
        case .unsupportedSchema:
            if let decoded = decode(atPath: result.path),
               decoded.schemaVersion > TaskContextStateManager.schemaVersion {
                backupNewerSchema(path: result.path, version: decoded.schemaVersion, taskID: taskID)
                // Re-label to the current schema: the in-memory value only carries
                // current-schema fields, so the next save must produce a clean file
                // rather than re-writing the unknown version and looping on this path.
                var downgraded = decoded
                downgraded.schemaVersion = TaskContextStateManager.schemaVersion
                return downgraded
            }
            quarantine(path: result.path, reason: result.status.rawValue, taskID: taskID, diagnostic: result.errorDescription)
            return nil
        }
    }

    private static func decode(atPath path: String) -> TaskContextState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return StructuredJSONDecoder.decode(TaskContextState.self, from: data).value
    }

    @discardableResult
    private static func quarantine(path: String, reason: String, taskID: UUID?, diagnostic: String?) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil }
        // Never overwrite an existing quarantine — deleting it would reintroduce the
        // silent data loss this guards against. Find the next free suffix instead.
        let base = (path as NSString).deletingPathExtension + ".corrupt-\(timestampSlug())"
        var destination = base + ".json"
        var counter = 1
        while fileManager.fileExists(atPath: destination) {
            destination = "\(base)-\(counter).json"
            counter += 1
        }
        guard (try? fileManager.moveItem(atPath: path, toPath: destination)) != nil else { return nil }
        audit(result: "quarantined", reason: reason, path: destination, taskID: taskID, diagnostic: diagnostic)
        return destination
    }

    /// Copies a newer-schema capsule aside exactly once before the running build may
    /// re-save it in the current (older) schema, so newer-only fields are never lost.
    private static func backupNewerSchema(path: String, version: Int, taskID: UUID?) {
        let fileManager = FileManager.default
        let destination = (path as NSString).deletingPathExtension + ".v\(version)-backup.json"
        guard fileManager.fileExists(atPath: path), !fileManager.fileExists(atPath: destination) else { return }
        guard (try? fileManager.copyItem(atPath: path, toPath: destination)) != nil else { return }
        audit(result: "schema_downgrade_backup", reason: "schema_v\(version)", path: destination, taskID: taskID, diagnostic: nil)
    }

    private static func audit(result: String, reason: String, path: String, taskID: UUID?, diagnostic: String?) {
        guard let taskID else { return }
        AppLogger.audit(.contextStateUpdated, category: "Worker", taskID: taskID, fields: [
            "result": result,
            "reason": reason,
            "recovery_path": path,
            "error": diagnostic ?? "none"
        ], level: .warning)
    }

    private static func timestampSlug() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
