import Foundation
import Testing
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace file index store")
struct WorkspaceFileIndexStoreTests {
    @Test("Warm cache presents the last snapshot until refresh replaces it")
    func warmCacheThenRefresh() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = makeRoot(directory, id: "primary")
        try "first".write(
            to: directory.appendingPathComponent("first.txt"),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceFileIndexStore(capacity: 2)

        let first = await store.refreshedSnapshot(roots: [root])
        #expect(first.nodes.map(\.name) == ["first.txt"])
        #expect(first.nodesByRoot[root.id]?.map(\.name) == ["first.txt"])

        try "second".write(
            to: directory.appendingPathComponent("second.txt"),
            atomically: true,
            encoding: .utf8
        )
        let cached = await store.cachedSnapshot(roots: [root])
        #expect(cached?.nodes.map(\.name) == ["first.txt"])

        let refreshed = await store.refreshedSnapshot(roots: [root])
        #expect(Set(refreshed.nodes.map(\.name)) == ["first.txt", "second.txt"])
        let replaced = await store.cachedSnapshot(roots: [root])
        #expect(Set(replaced?.nodes.map(\.name) ?? []) == ["first.txt", "second.txt"])
    }

    @Test("Cache is bounded and evicts the least recently used snapshot")
    func boundedEviction() async throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let firstRoot = makeRoot(firstDirectory, id: "first")
        let secondRoot = makeRoot(secondDirectory, id: "second")
        let store = WorkspaceFileIndexStore(capacity: 1)

        _ = await store.refreshedSnapshot(roots: [firstRoot])
        _ = await store.refreshedSnapshot(roots: [secondRoot])

        #expect(await store.cachedEntryCountForTesting() == 1)
        #expect(await store.cachedSnapshot(roots: [firstRoot]) == nil)
        #expect(await store.cachedSnapshot(roots: [secondRoot]) != nil)
    }

    @Test("Node search text is normalized once when the snapshot is built")
    func normalizedSearchText() {
        let node = WorkspaceFileNode(
            id: "node",
            rootID: "root",
            path: "/TMP/Reports/Final.JSON",
            relativePath: "Reports/Final.JSON",
            name: "Final.JSON",
            isDirectory: false,
            depth: 1,
            size: 12,
            modifiedAt: nil,
            destination: nil
        )

        #expect(node.normalizedSearchText.contains("final.json"))
        #expect(node.normalizedSearchText.contains("reports/final.json"))
        #expect(!node.normalizedSearchText.contains("Final.JSON"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-files-shelf-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRoot(_ directory: URL, id: String) -> WorkspaceFileRoot {
        WorkspaceFileRoot(
            id: id,
            kind: .primary,
            title: id,
            path: directory.path,
            isDirectory: true
        )
    }
}
