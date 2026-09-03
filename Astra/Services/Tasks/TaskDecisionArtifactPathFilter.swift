import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Decides which stored artifacts the task decision dock may show, off the main
/// actor.
///
/// **Why this is not a computed property any more.** It used to be
/// `TaskMainView.taskDecisionArtifactPaths`, one of ~25 arguments to
/// `taskDecisionDockPresentation`, which `body` computes unconditionally.
/// `messageText` is `@State` on the same view, so *every keystroke in the
/// composer* re-entered it, and per artifact it cost:
///
/// - a `stat`, because `Artifact.isStale` is `!fileExists` recomputed on read,
/// - a `TaskWorkspaceAccess` rebuild, itself another `fileExists`,
/// - and three separate `resolvingSymlinksInPath()` walks — one in the path
///   normalizer, one to resolve the task-folder root, one for the path itself.
///
/// On the 2026-09-03 production store the open task carried 13,295 artifacts,
/// so a single character cost tens of thousands of synchronous syscalls. The
/// user-visible symptom was a composer that lagged seconds behind the keyboard.
///
/// Roots are resolved once by the caller and paths arrive as plain strings, so
/// everything here is `Sendable` and the whole filter runs in a detached task.
enum TaskDecisionArtifactPathFilter {
    /// The per-task inputs, hoisted out of the per-artifact loop.
    ///
    /// Resolving the root is the expensive half of
    /// `TaskOutputArtifactPathPolicy.relativePath`, and it is identical for
    /// every artifact on a task. Paying it once per rebuild instead of once per
    /// path is most of this type's reason to exist.
    struct Roots: Sendable {
        let workspacePath: String
        let taskFolder: String
        let resolvedTaskFolder: TaskOutputArtifactPathPolicy.ResolvedRoot

        init(workspacePath: String, taskFolder: String) {
            self.workspacePath = workspacePath
            self.taskFolder = taskFolder
            self.resolvedTaskFolder = TaskOutputArtifactPathPolicy.ResolvedRoot(taskFolder)
        }
    }

    /// Artifacts that still exist on disk and whose path a user would
    /// recognize.
    ///
    /// `storedArtifactPaths` must already be extracted from the model objects:
    /// a SwiftData relationship cannot be read from another actor, which is the
    /// reason the caller maps `\.path` before handing the list over.
    static func userFacingPaths(
        storedArtifactPaths: [String],
        roots: Roots,
        fileManager: FileManager = .default
    ) -> [String] {
        storedArtifactPaths.filter { path in
            // Stands in for `!artifact.isStale`, evaluated here rather than on
            // the main actor.
            guard fileManager.fileExists(atPath: path) else { return false }
            return isUserFacing(path, roots: roots)
        }
    }

    static func isUserFacing(_ path: String, roots: Roots) -> Bool {
        let normalized = TaskArtifactPathNormalizer.normalizedPath(
            path,
            workspacePath: roots.workspacePath,
            taskFolder: roots.taskFolder
        )
        guard let relative = TaskOutputArtifactPathPolicy.relativePath(
            normalized,
            under: roots.resolvedTaskFolder
        ) else {
            // Outside the task folder entirely — a workspace file the run
            // touched. The dock has always shown these; only paths *inside* the
            // folder are subject to the internal-state filter.
            return true
        }
        return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(
            relative,
            context: .taskFolder
        ) != nil
    }
}
