import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

@Suite("Files shelf index controller")
struct ShelfFileIndexControllerTests {
    @MainActor
    @Test("Scope selection happens before filesystem scanning")
    func scopeSelection() {
        let primary = root(id: "primary", kind: .primary)
        let additional = root(id: "additional", kind: .additional)
        let task = root(id: "task", kind: .taskFolder)
        let input = root(id: "input", kind: .input)
        let roots = [primary, additional, task, input]

        #expect(ShelfFileIndexController.roots(roots, for: .task).map(\.id) == ["task", "input"])
        #expect(ShelfFileIndexController.roots(roots, for: .workspace).map(\.id) == ["primary", "additional"])
        #expect(ShelfFileIndexController.roots(roots, for: .all).map(\.id) == roots.map(\.id))
    }

    @MainActor
    @Test("Changing scope cancels the prior scan and publishes only the latest roots")
    func changingScopeKeepsLatestSnapshot() async throws {
        let workspaceDirectory = try temporaryDirectory(name: "workspace")
        let taskDirectory = try temporaryDirectory(name: "task")
        defer {
            try? FileManager.default.removeItem(at: workspaceDirectory)
            try? FileManager.default.removeItem(at: taskDirectory)
        }
        try "workspace".write(
            to: workspaceDirectory.appendingPathComponent("workspace.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "task".write(
            to: taskDirectory.appendingPathComponent("task.txt"),
            atomically: true,
            encoding: .utf8
        )
        let workspace = WorkspaceFileRoot(
            id: "workspace",
            kind: .primary,
            title: "Workspace",
            path: workspaceDirectory.path,
            isDirectory: true
        )
        let task = WorkspaceFileRoot(
            id: "task",
            kind: .taskFolder,
            title: "Task",
            path: taskDirectory.path,
            isDirectory: true
        )
        let controller = ShelfFileIndexController(store: WorkspaceFileIndexStore())

        controller.refresh(
            allRoots: [workspace, task],
            scope: .workspace,
            includeHidden: false,
            force: false,
            reason: "test",
            taskID: nil,
            workspaceID: nil,
            responsivenessScope: nil
        )
        controller.refresh(
            allRoots: [workspace, task],
            scope: .task,
            includeHidden: false,
            force: false,
            reason: "test",
            taskID: nil,
            workspaceID: nil,
            responsivenessScope: nil
        )

        for _ in 0..<100 where controller.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!controller.isScanning)
        #expect(controller.roots.map(\.id) == ["task"])
        #expect(controller.nodes.map(\.name) == ["task.txt"])
    }

    private func root(id: String, kind: WorkspaceFileRoot.Kind) -> WorkspaceFileRoot {
        WorkspaceFileRoot(
            id: id,
            kind: kind,
            title: id,
            path: "/tmp/\(id)",
            isDirectory: true
        )
    }

    private func temporaryDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
