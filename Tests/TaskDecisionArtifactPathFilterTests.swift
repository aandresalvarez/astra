import Foundation
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// The decision dock's artifact list moved off the main actor because it was
/// costing a `stat` and three symlink walks per artifact on every keystroke.
/// What matters now is that the cheaper form still answers the same questions:
/// a moved-away file is gone, an internal-state file stays hidden, and a
/// workspace file outside the task folder is still shown.
@Suite("Task decision artifact path filter")
struct TaskDecisionArtifactPathFilterTests {
    /// `/tmp` is a symlink to `/private/tmp`, and a root resolved through it
    /// would not match paths built from the unresolved form. Resolve up front
    /// so the fixture tests the filter, not the temporary directory.
    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("astra-decision-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relativePath: String, under root: URL) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url.path
    }

    @Test("A path with no file behind it is dropped without consulting the policy")
    func missingFileIsDropped() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskFolder = root.appendingPathComponent("tasks/T1")
        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)

        let present = try write("tasks/T1/report.md", under: root)
        let absent = taskFolder.appendingPathComponent("deleted.md").path

        let roots = TaskDecisionArtifactPathFilter.Roots(
            workspacePath: root.path,
            taskFolder: taskFolder.path
        )
        let kept = TaskDecisionArtifactPathFilter.userFacingPaths(
            storedArtifactPaths: [present, absent],
            roots: roots
        )

        // This is what `Artifact.isStale` used to answer, one syscall per read.
        #expect(kept == [present])
    }

    @Test("Internal state inside the task folder stays hidden")
    func internalStateIsHidden() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskFolder = root.appendingPathComponent("tasks/T1")

        let deliverable = try write("tasks/T1/reports/summary.md", under: root)
        let venvFile = try write("tasks/T1/.venv/lib/python3.12/site.py", under: root)

        let roots = TaskDecisionArtifactPathFilter.Roots(
            workspacePath: root.path,
            taskFolder: taskFolder.path
        )
        let kept = TaskDecisionArtifactPathFilter.userFacingPaths(
            storedArtifactPaths: [deliverable, venvFile],
            roots: roots
        )

        #expect(kept == [deliverable])
    }

    @Test("A workspace file outside the task folder is still offered")
    func fileOutsideTaskFolderIsKept() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskFolder = root.appendingPathComponent("tasks/T1")
        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)

        // A run that edited the repository rather than writing into its own
        // folder. The dock has always shown these; only paths inside the task
        // folder go through the internal-state filter.
        let repoFile = try write("src/main.swift", under: root)

        let roots = TaskDecisionArtifactPathFilter.Roots(
            workspacePath: root.path,
            taskFolder: taskFolder.path
        )
        let kept = TaskDecisionArtifactPathFilter.userFacingPaths(
            storedArtifactPaths: [repoFile],
            roots: roots
        )

        #expect(kept == [repoFile])
    }

    @Test("Hoisting the root does not change the verdict")
    func hoistedRootMatchesPerPathResolution() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskFolder = root.appendingPathComponent("tasks/T1")

        let deliverable = try write("tasks/T1/notes.md", under: root)
        let hidden = try write("tasks/T1/node_modules/pkg/index.js", under: root)

        let roots = TaskDecisionArtifactPathFilter.Roots(
            workspacePath: root.path,
            taskFolder: taskFolder.path
        )

        // The root is resolved once in `Roots`; the old code rebuilt it per
        // path. Same answer, and that equivalence is the whole optimization.
        for path in [deliverable, hidden] {
            let relative = TaskOutputArtifactPathPolicy.relativePath(path, under: taskFolder.path)
            let expected = relative.map {
                TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath($0, context: .taskFolder) != nil
            } ?? true
            #expect(TaskDecisionArtifactPathFilter.isUserFacing(path, roots: roots) == expected)
        }
    }

    @Test("The nonisolated normalizer matches the task-based one for absolute paths")
    func normalizerRootOverloadAgrees() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("tasks/T1/out.txt", under: root)

        // Absolute paths never read the roots, so the two forms must agree
        // regardless of what is passed for them.
        #expect(
            TaskArtifactPathNormalizer.normalizedPath(file, workspacePath: "", taskFolder: "") == file
        )

        // A relative path is resolved against the workspace.
        let relative = TaskArtifactPathNormalizer.normalizedPath(
            "tasks/T1/out.txt",
            workspacePath: root.path,
            taskFolder: root.appendingPathComponent("tasks/T1").path
        )
        #expect(relative == file)
    }

    @Test("An empty stored path never reaches the filesystem")
    func emptyPathIsDropped() throws {
        let roots = TaskDecisionArtifactPathFilter.Roots(workspacePath: "", taskFolder: "")
        #expect(TaskDecisionArtifactPathFilter.userFacingPaths(
            storedArtifactPaths: ["", "   "],
            roots: roots
        ).isEmpty)
    }
}
