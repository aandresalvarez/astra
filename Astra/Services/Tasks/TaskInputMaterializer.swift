import Foundation
import ASTRAModels

/// Moves composer temp attachments out of `$TMPDIR` before a task launches.
///
/// `ComposerPasteIntake` and the composer's image drop both write to
/// `NSTemporaryDirectory()`, and the task then keeps that path in `inputs`
/// for life — but macOS purges that directory after three days, after which
/// the launch resolver could never establish the read-only boundary and every
/// provider reported as incompatible. This runs right after the task folder
/// is prepared and copies each still-present ephemeral input into
/// `<taskFolder>/inputs/`, rewriting `task.inputs` to the durable copy so the
/// launch snapshot, prompt context, and forks all see the path that survives.
///
/// Prose inputs and ordinary user paths are left untouched. An ephemeral
/// input that is already gone is also left in place: the resolver degrades it
/// to a warning, and `TaskStoreMaintenance` strips it on the next launch. The
/// temp original is never deleted — autosave drafts may still point at it.
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
        var outcome = Outcome()
        guard !taskFolder.isEmpty else { return outcome }

        var rewritten = task.inputs
        for (index, rawInput) in task.inputs.enumerated() {
            guard EphemeralComposerAttachment.isEphemeralPath(rawInput) else { continue }
            let source = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let destinationFolder = (taskFolder as NSString).appendingPathComponent(inputsFolderName)
            let destination = (destinationFolder as NSString)
                .appendingPathComponent((source as NSString).lastPathComponent)
            guard fileManager.fileExists(atPath: source) else {
                // A previous launch may have copied the file and then exited
                // before the rewritten path was saved; the durable copy is the
                // one that matters, so adopt it rather than report a loss.
                if fileManager.fileExists(atPath: destination) {
                    rewritten[index] = destination
                    outcome.materialized.append(destination)
                } else {
                    outcome.alreadyMissing.append(source)
                }
                continue
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
                rewritten[index] = destination
                outcome.materialized.append(destination)
            } catch {
                outcome.failed.append(source)
            }
        }

        if outcome.didChange {
            task.inputs = rewritten
        }
        if !outcome.isEmpty {
            AppLogger.audit(.taskStarted, category: "Queue", taskID: task.id, fields: [
                "event": "task_inputs_materialized",
                "materialized": String(outcome.materialized.count),
                "already_missing": String(outcome.alreadyMissing.count),
                "failed": String(outcome.failed.count)
            ], level: outcome.failed.isEmpty ? .info : .warning)
        }
        return outcome
    }
}
