import Foundation
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Covers the exclusion that a `python -m venv` inside a task folder walked
/// straight through.
///
/// The production case: 14,917 files / 691 MB under `.venv`, none of it a
/// deliverable, all of it classified one path at a time by a filter that
/// resolved symlinks per call. The main thread never came back, and artifact
/// reconciliation persisted 13,295 rows before it stopped. Three separate
/// places had to learn about it — the path policy, the task-folder walker, and
/// the file-change detector — so the list lives in one place and these tests
/// pin each entry point to it.
@Suite("Generated dependency trees are not user output")
struct GeneratedDependencyPathPolicyTests {
    /// Resolved up front: `/tmp` is a symlink to `/private/tmp`, and the
    /// lexical pre-filter compares standardized paths without resolving. A root
    /// that still reads as `/tmp/...` would miss every lexical match and quietly
    /// test the slow path instead of the fast one.
    private func makeTemporaryRoot(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent("astra-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("A generated dependency directory matches at any depth")
    func matchesAtAnyDepth() {
        #expect(TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("node_modules/left-pad/index.js"))
        // The old spelling was a root-anchored prefix, so this one got through.
        #expect(TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("packages/web/node_modules/left-pad/index.js"))
        #expect(TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent(".venv/lib/python3.13/site-packages/pip/__init__.py"))
        #expect(TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("venv/bin/activate"))
        #expect(TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("src/__pycache__/module.cpython-313.pyc"))
        // Case-folded: the volume usually is.
        #expect(TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("Library/DerivedData/Astra/Build/x"))
    }

    @Test("Names that merely contain a dependency directory are left alone")
    func doesNotMatchSubstrings() {
        #expect(!TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("venv-notes/setup.md"))
        #expect(!TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("my_node_modules/report.md"))
        #expect(!TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("reports/venv.md"))
        #expect(!TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent(""))
        // Left out on purpose: a user's own deliverable lands in these.
        #expect(!TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("dist/report.html"))
        #expect(!TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("build/summary.md"))
        #expect(!TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("target/output.csv"))
    }

    @Test("The walker's per-component predicate agrees with the path form")
    func directoryNamePredicateMatchesPathForm() {
        for name in TaskOutputArtifactPathPolicy.generatedDependencyDirectoryNames {
            #expect(TaskOutputArtifactPathPolicy.isGeneratedDependencyDirectoryName(name))
            #expect(TaskOutputArtifactPathPolicy.hasGeneratedDependencyComponent("a/\(name)/b.txt"))
        }
        #expect(TaskOutputArtifactPathPolicy.isGeneratedDependencyDirectoryName("DerivedData"))
        #expect(!TaskOutputArtifactPathPolicy.isGeneratedDependencyDirectoryName("dist"))
    }

    @Test("Dependency trees are internal state in both contexts")
    func internalStateInBothContexts() {
        for context in [TaskOutputArtifactPathPolicy.RelativePathContext.taskFolder, .workspace] {
            #expect(TaskOutputArtifactPathPolicy.isInternalStateRelativePath(".venv/bin/python", context: context))
            #expect(TaskOutputArtifactPathPolicy.isInternalStateRelativePath("web/node_modules/x/index.js", context: context))
            #expect(TaskOutputArtifactPathPolicy.visibility(for: ".venv/pyvenv.cfg", context: context) == .internalState)
            #expect(TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(".venv/pyvenv.cfg", context: context) == nil)
            // The exclusion is narrow: everything beside it still shows.
            #expect(TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath("reports/summary.md", context: context) == "reports/summary.md")
        }
    }

    @Test("A pre-resolved root answers the same as the string overload")
    func resolvedRootMatchesStringOverload() throws {
        let realRoot = try makeTemporaryRoot("resolved-root")
        let linkRoot = realRoot.deletingLastPathComponent()
            .appendingPathComponent("astra-resolved-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        defer {
            try? FileManager.default.removeItem(at: linkRoot)
            try? FileManager.default.removeItem(at: realRoot)
        }
        let output = realRoot.appendingPathComponent("reports/summary.md")
        try write("done", to: output)

        let root = TaskOutputArtifactPathPolicy.ResolvedRoot(linkRoot.path)
        #expect(!root.isEmpty)
        #expect(TaskOutputArtifactPathPolicy.relativePath(output.path, under: root) == "reports/summary.md")
        #expect(
            TaskOutputArtifactPathPolicy.relativePath(output.path, under: root)
                == TaskOutputArtifactPathPolicy.relativePath(output.path, under: linkRoot.path)
        )
        #expect(TaskOutputArtifactPathPolicy.ResolvedRoot("").isEmpty)
        #expect(TaskOutputArtifactPathPolicy.relativePath(output.path, under: .init("")) == nil)
    }

    @Test("Lexical containment skips the symlink-escape check the resolving form makes")
    func lexicalContainmentDoesNotCheckEscape() throws {
        let root = try makeTemporaryRoot("lexical-root")
        let outside = try makeTemporaryRoot("lexical-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let secret = outside.appendingPathComponent("secret.md")
        try write("elsewhere", to: secret)
        let escape = root.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: secret)

        let resolved = TaskOutputArtifactPathPolicy.ResolvedRoot(root.path)
        // The whole point of the cheap form: it admits what the resolving form
        // rejects, so nothing may trust it on its own.
        #expect(TaskOutputArtifactPathPolicy.lexicalRelativePath(escape.path, under: resolved) == "escape.md")
        #expect(TaskOutputArtifactPathPolicy.relativePath(escape.path, under: resolved) == nil)
        #expect(TaskOutputArtifactPathPolicy.lexicalRelativePath(secret.path, under: resolved) == nil)
    }

    @Test("The task-folder walker does not return virtualenv contents")
    func walkerSkipsVirtualenv() throws {
        let folder = try makeTemporaryRoot("walker")
        defer { try? FileManager.default.removeItem(at: folder) }
        let deliverable = folder.appendingPathComponent("reports/summary.md")
        try write("done", to: deliverable)
        try write("noise", to: folder.appendingPathComponent(".venv/lib/python3.13/site-packages/pip/__init__.py"))
        try write("noise", to: folder.appendingPathComponent(".venv/bin/activate"))
        try write("noise", to: folder.appendingPathComponent("web/node_modules/left-pad/index.js"))

        let files = TaskGeneratedFiles.files(in: folder.path)
        #expect(files == [deliverable.path])
    }

    @Test("The diagnostics walker prunes dependency trees instead of classifying them")
    func diagnosticsWalkerPrunesDependencyTrees() throws {
        let folder = try makeTemporaryRoot("diagnostics")
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("log", to: folder.appendingPathComponent("jobs/job-1/stdout.log"))
        try write("{}", to: folder.appendingPathComponent(".runtime/client/config.json"))
        // A virtualenv holds files that look exactly like diagnostics — logs,
        // JSON config, `.runtime`-shaped nesting — so without the prune they do
        // not merely cost a walk, they land in the popover as task output.
        try write("noise", to: folder.appendingPathComponent(".venv/lib/python3.13/site-packages/pip/__init__.py"))
        try write("noise", to: folder.appendingPathComponent(".venv/jobs/job-9/stdout.log"))
        try write("noise", to: folder.appendingPathComponent("web/node_modules/left-pad/config.json"))

        let relativePaths = Set(
            TaskDiagnosticsIndex.groups(in: folder.path).flatMap(\.items).map(\.relativePath)
        )

        #expect(relativePaths == ["jobs/job-1/stdout.log", ".runtime/client/config.json"])
    }

    @MainActor
    @Test("A virtualenv inside the task folder is not user-facing output")
    func virtualenvIsNotUserFacing() throws {
        let taskFolder = try makeTemporaryRoot("visibility-task")
        let workspace = try makeTemporaryRoot("visibility-workspace")
        defer {
            try? FileManager.default.removeItem(at: taskFolder)
            try? FileManager.default.removeItem(at: workspace)
        }
        let scope = TaskOutputVisibilityScope(taskFolder: taskFolder.path, workspacePath: workspace.path)
        let task = makeTask()

        let deliverable = taskFolder.appendingPathComponent("reports/summary.md")
        try write("done", to: deliverable)
        #expect(TaskContextStateManager.isUserFacingOutputPath(deliverable.path, task: task, scope: scope))

        for noise in [
            taskFolder.appendingPathComponent(".venv/lib/python3.13/site-packages/pip/__init__.py"),
            taskFolder.appendingPathComponent("web/node_modules/left-pad/index.js"),
            workspace.appendingPathComponent(".venv/bin/activate"),
            workspace.appendingPathComponent("packages/api/node_modules/x/index.js")
        ] {
            // Deliberately never created on disk: the filter has to settle this
            // before it touches the filesystem, which is the only reason a
            // 14,917-entry tree stops costing anything.
            #expect(!TaskContextStateManager.isUserFacingOutputPath(noise.path, task: task, scope: scope))
        }
    }

    @MainActor
    @Test("A workspace living under a directory named venv still shows its outputs")
    func workspaceUnderVenvSurvives() throws {
        let container = try makeTemporaryRoot("venv-container")
        defer { try? FileManager.default.removeItem(at: container) }
        // The exclusion is judged on the path *relative to a root*. Judged
        // absolutely, this workspace and everything in it would disappear.
        let workspace = container
            .appendingPathComponent("venv", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
        let taskFolder = workspace.appendingPathComponent(".astra-tasks/task-1", isDirectory: true)
        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)

        let scope = TaskOutputVisibilityScope(taskFolder: taskFolder.path, workspacePath: workspace.path)
        let task = makeTask()

        let deliverable = workspace.appendingPathComponent("reports/summary.md")
        try write("done", to: deliverable)
        #expect(TaskContextStateManager.isUserFacingOutputPath(deliverable.path, task: task, scope: scope))
        #expect(!TaskContextStateManager.isUserFacingOutputPath(
            workspace.appendingPathComponent("venv/bin/activate").path,
            task: task,
            scope: scope
        ))
    }
}
