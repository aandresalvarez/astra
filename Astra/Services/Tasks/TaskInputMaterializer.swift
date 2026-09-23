import Foundation
import ASTRAModels
import ASTRAPersistence

/// Moves composer temp attachments out of `$TMPDIR` into the task folder.
///
/// `ComposerPasteIntake` and the composer's image drop both write to
/// `NSTemporaryDirectory()`, but macOS purges that directory after three days,
/// after which the launch resolver could never establish the read-only
/// boundary and every provider reported as incompatible. Every still-present
/// ephemeral path is therefore copied into `<taskFolder>/inputs/` and replaced
/// by the durable copy, so the launch snapshot, prompt context, and forks all
/// see the path that survives. That happens at two points, because a paste
/// reaches the task by two routes:
///
/// - Attachments on a new task land in `task.inputs`, which
///   `materialize(task:taskFolder:)` rewrites right after the task folder is
///   prepared for launch.
/// - Attachments on a follow-up only ever appear in that message's text, so
///   `durableAttachmentPaths(_:for:)` swaps them before the text is composed.
///
/// Prose inputs and ordinary user paths are left untouched. An ephemeral path
/// that is already gone is also left in place: the resolver degrades it to a
/// warning, and `TaskStoreMaintenance` strips it from `inputs` on the next
/// launch. The temp original is never deleted — autosave drafts may still
/// point at it.
enum TaskInputMaterializer {
    struct Outcome: Equatable {
        var materialized: [String] = []
        var alreadyMissing: [String] = []
        var failed: [String] = []

        var didChange: Bool { !materialized.isEmpty }
        var isEmpty: Bool { materialized.isEmpty && alreadyMissing.isEmpty && failed.isEmpty }
    }

    static let inputsFolderName = "inputs"

    @discardableResult
    static func materialize(
        task: AgentTask,
        taskFolder: String,
        fileManager: FileManager = .default
    ) -> Outcome {
        let (rewritten, outcome) = materialize(paths: task.inputs, taskFolder: taskFolder, fileManager: fileManager)
        if outcome.didChange {
            task.inputs = rewritten
        }
        audit(outcome, .taskStarted, category: "Queue", taskID: task.id, event: "task_inputs_materialized")
        return outcome
    }

    /// The follow-up composer's attachments, with each paste or image drop
    /// swapped for its durable copy in the task folder.
    ///
    /// A follow-up's attachments never enter `task.inputs`, so the launch-time
    /// pass cannot see them. Swapping them before the message text is composed
    /// means the persisted message, the prompt, and any later review all name
    /// the copy rather than a temp file that is about to disappear.
    ///
    /// Anything that cannot be made durable keeps its original path, so a
    /// failed copy degrades exactly like an unmaterialized paste and never
    /// blocks the send. A task with no workspace has no folder to copy into.
    static func durableAttachmentPaths(
        _ paths: [String],
        for task: AgentTask,
        fileManager: FileManager = .default
    ) -> [String] {
        guard paths.contains(where: { EphemeralComposerAttachment.isEphemeralPath($0) }) else { return paths }
        let access = TaskWorkspaceAccess(task: task)
        guard !access.effectiveWorkspacePath.isEmpty else { return paths }

        let taskFolder: String
        do {
            taskFolder = try access.ensureTaskFolder()
        } catch {
            AppLogger.audit(.userAction, category: "UI", taskID: task.id, fields: [
                "event": "follow_up_attachments_materialized",
                "reason": "task_folder_unavailable"
            ], level: .warning)
            return paths
        }
        let (durable, outcome) = materialize(paths: paths, taskFolder: taskFolder, fileManager: fileManager)
        audit(outcome, .userAction, category: "UI", taskID: task.id, event: "follow_up_attachments_materialized")
        return durable
    }

    /// Copies each ephemeral entry of `paths` into `<taskFolder>/inputs/` and
    /// returns the list with the durable copies in place, preserving order.
    static func materialize(
        paths: [String],
        taskFolder: String,
        fileManager: FileManager = .default
    ) -> (paths: [String], outcome: Outcome) {
        var outcome = Outcome()
        guard !taskFolder.isEmpty else { return (paths, outcome) }

        var rewritten = paths
        for (index, rawPath) in paths.enumerated() {
            guard EphemeralComposerAttachment.isEphemeralPath(rawPath) else { continue }
            let source = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            switch materialize(source: source, taskFolder: taskFolder, fileManager: fileManager) {
            case .durable(let destination):
                rewritten[index] = destination
                outcome.materialized.append(destination)
            case .alreadyMissing:
                outcome.alreadyMissing.append(source)
            case .failed:
                outcome.failed.append(source)
            }
        }
        return (rewritten, outcome)
    }

    private enum PathResult {
        case durable(String)
        case alreadyMissing
        case failed
    }

    private static func materialize(
        source: String,
        taskFolder: String,
        fileManager: FileManager
    ) -> PathResult {
        let destinationFolder = (taskFolder as NSString).appendingPathComponent(inputsFolderName)
        let destination = (destinationFolder as NSString)
            .appendingPathComponent((source as NSString).lastPathComponent)
        guard fileManager.fileExists(atPath: source) else {
            // A previous launch may have copied the file and then exited
            // before the rewritten path was saved; the durable copy is the
            // one that matters, so adopt it rather than report a loss.
            return fileManager.fileExists(atPath: destination) ? .durable(destination) : .alreadyMissing
        }

        do {
            try fileManager.createDirectory(atPath: destinationFolder, withIntermediateDirectories: true)
            // Paste names carry a random suffix, so an existing destination
            // is this same file from an earlier launch, not a collision —
            // and it is complete, because the copy lands under a staging
            // name and is only renamed into place once it has succeeded.
            // A failed copy can therefore never masquerade as materialized.
            if !fileManager.fileExists(atPath: destination) {
                let staging = (destinationFolder as NSString)
                    .appendingPathComponent(".\((source as NSString).lastPathComponent).partial-\(UUID().uuidString.prefix(8))")
                do {
                    try fileManager.copyItem(atPath: source, toPath: staging)
                    try fileManager.moveItem(atPath: staging, toPath: destination)
                } catch {
                    try? fileManager.removeItem(atPath: staging)
                    throw error
                }
            }
            return .durable(destination)
        } catch {
            return .failed
        }
    }

    private static func audit(
        _ outcome: Outcome,
        _ auditEvent: AuditEvent,
        category: String,
        taskID: UUID,
        event: String
    ) {
        guard !outcome.isEmpty else { return }
        AppLogger.audit(auditEvent, category: category, taskID: taskID, fields: [
            "event": event,
            "materialized": String(outcome.materialized.count),
            "already_missing": String(outcome.alreadyMissing.count),
            "failed": String(outcome.failed.count)
        ], level: outcome.failed.isEmpty ? .info : .warning)
    }
}
