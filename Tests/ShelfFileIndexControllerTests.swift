import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

private final class ShelfRootProbeFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadProbes = 0
    var checkedMainThread: Bool { lock.withLock { mainThreadProbes > 0 } }
    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if Thread.isMainThread { lock.withLock { mainThreadProbes += 1 } }
        return FileManager.default.fileExists(atPath: path, isDirectory: isDirectory)
    }
}

private actor BlockingShelfFileIndexFilter: ShelfFileIndexFiltering {
    private var queryToBlock: String?
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func blockNext(_ query: String) {
        queryToBlock = query
        blocked = false
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func filter(
        _ nodesByRoot: [String: [WorkspaceFileNode]],
        searchText: String
    ) async -> [String: [WorkspaceFileNode]] {
        if queryToBlock == searchText {
            queryToBlock = nil
            blocked = true
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters = []
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        guard !searchText.isEmpty else { return nodesByRoot }
        return nodesByRoot.mapValues { nodes in
            nodes.filter { $0.normalizedSearchText.contains(searchText) }
        }
    }
}

@Suite("Files shelf index controller")
struct ShelfFileIndexControllerTests {
    @MainActor
    @Test("Historical attachment metadata resolves away from the UI actor and refreshes with the index")
    func historyRootsResolveOffMainActor() async throws {
        let directory = try temporaryDirectory(name: "history-roots")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("docs.html")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("reference.txt")
        try "Synthetic reference".write(to: file, atomically: true, encoding: .utf8)
        let manager = ShelfRootProbeFileManager()
        let paths = [folder.path, file.path, file.path, directory.appendingPathComponent("missing").path, ""]
        let history = await ShelfAttachmentRootResolver.resolve(paths: paths, fileManager: manager)
        #expect(!manager.checkedMainThread)
        #expect(history.map(\.path) == [folder.path, file.path])
        #expect(history.map(\.isDirectory) == [true, false])
        let workspace = WorkspaceFileRoot(id: "workspace", kind: .primary,
            title: "Workspace", path: directory.path, isDirectory: true)
        let initialInput = WorkspaceFileRoot(id: "initial", kind: .input,
            title: "Input 1", path: file.path, isDirectory: false)
        let combined = ShelfAttachmentRootResolver.merging(history, into: [initialInput, workspace])
        #expect(combined.map(\.path) == [file.path, folder.path, directory.path])
        #expect(combined.map(\.title) == ["Input 1", "Input 2", "Workspace"])
        let controller = ShelfFileIndexController(store: WorkspaceFileIndexStore())
        controller.refresh(allRoots: [workspace], additionalInputPaths: paths, scope: .task,
            includeHidden: false, force: true, reason: "history", taskID: UUID(), responsivenessScope: nil)
        for _ in 0..<100 where controller.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isScanning)
        #expect(controller.roots.map(\.path) == [folder.path, file.path])
        #expect(controller.nodes.contains { $0.name == "reference.txt" })
    }

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
            responsivenessScope: nil
        )
        controller.refresh(
            allRoots: [workspace, task],
            scope: .task,
            includeHidden: false,
            force: false,
            reason: "test",
            taskID: nil,
            responsivenessScope: nil
        )

        for _ in 0..<100 where controller.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!controller.isScanning)
        #expect(controller.roots.map(\.id) == ["task"])
        #expect(controller.nodes.map(\.name) == ["task.txt"])
    }

    @MainActor
    @Test("Cached and fresh scan results never publish a stale search query")
    func scanResultsUseLatestSearchQuery() async throws {
        let directory = try temporaryDirectory(name: "search-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        try "alpha".write(
            to: directory.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "beta".write(
            to: directory.appendingPathComponent("beta.txt"),
            atomically: true,
            encoding: .utf8
        )
        let root = WorkspaceFileRoot(
            id: "workspace",
            kind: .primary,
            title: "Workspace",
            path: directory.path,
            isDirectory: true
        )
        let filtering = BlockingShelfFileIndexFilter()
        let controller = ShelfFileIndexController(
            store: WorkspaceFileIndexStore(),
            filtering: filtering
        )

        controller.refresh(
            allRoots: [root], scope: .workspace, includeHidden: false, force: false,
            reason: "warm", taskID: nil, responsivenessScope: nil
        )
        for _ in 0..<100 where controller.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await controller.applySearchText("alpha")
        await filtering.blockNext("alpha")

        controller.refresh(
            allRoots: [root], scope: .workspace, includeHidden: false, force: false,
            reason: "race", taskID: nil, responsivenessScope: nil
        )
        await filtering.waitUntilBlocked()
        await controller.applySearchText("beta")
        await filtering.release()
        for _ in 0..<100 where controller.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(controller.nodes(for: root).map(\.name) == ["beta.txt"])
    }

    @MainActor
    @Test("A filter over an old index cannot replace results from a newer scan")
    func staleFilterCannotReplaceNewIndex() async throws {
        let directory = try temporaryDirectory(name: "index-filter-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let alpha = directory.appendingPathComponent("alpha.txt")
        try "alpha".write(to: alpha, atomically: true, encoding: .utf8)
        let root = WorkspaceFileRoot(
            id: "workspace",
            kind: .primary,
            title: "Workspace",
            path: directory.path,
            isDirectory: true
        )
        let filtering = BlockingShelfFileIndexFilter()
        let controller = ShelfFileIndexController(
            store: WorkspaceFileIndexStore(),
            filtering: filtering
        )
        controller.refresh(
            allRoots: [root], scope: .workspace, includeHidden: false, force: true,
            reason: "initial", taskID: nil, responsivenessScope: nil
        )
        for _ in 0..<100 where controller.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await filtering.blockNext("alpha")
        let staleFilter = Task { await controller.applySearchText("alpha") }
        await filtering.waitUntilBlocked()
        try FileManager.default.removeItem(at: alpha)
        try "beta".write(
            to: directory.appendingPathComponent("beta.txt"),
            atomically: true,
            encoding: .utf8
        )
        controller.refresh(
            allRoots: [root], scope: .workspace, includeHidden: false, force: true,
            reason: "replacement", taskID: nil, responsivenessScope: nil
        )
        for _ in 0..<100 where controller.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await filtering.release()
        await staleFilter.value

        #expect(controller.nodes.map(\.name) == ["beta.txt"])
        #expect(controller.nodes(for: root).isEmpty)
        #expect(controller.snapshotSource == .fresh)
    }

    @MainActor
    @Test("Starting a replacement scan marks the presented snapshot stale")
    func replacementScanMarksPresentedSnapshotStale() async throws {
        let directory = try temporaryDirectory(name: "stale-snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        try "old".write(
            to: directory.appendingPathComponent("old.txt"),
            atomically: true,
            encoding: .utf8
        )
        let root = WorkspaceFileRoot(
            id: "workspace",
            kind: .primary,
            title: "Workspace",
            path: directory.path,
            isDirectory: true
        )
        let controller = ShelfFileIndexController(store: WorkspaceFileIndexStore())
        controller.refresh(
            allRoots: [root], scope: .workspace, includeHidden: false, force: true,
            reason: "initial", taskID: nil, responsivenessScope: nil
        )
        for _ in 0..<100 where controller.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.snapshotSource == .fresh)

        controller.refresh(
            allRoots: [root], scope: .workspace, includeHidden: false, force: true,
            reason: "replacement", taskID: nil, responsivenessScope: nil
        )

        #expect(controller.snapshotSource == .stale)
        controller.cancel(responsivenessScope: nil)
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
