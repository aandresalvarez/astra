import Darwin
import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence

@MainActor
@Suite("Saved export snapshot directory lifecycle", .serialized)
struct WorkspaceSnapshotDirectoryTests {
    @Test("Only abandoned snapshot directories are reclaimed, including legacy copies")
    func orphanCleanup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer(root)
        let abandoned = root.appendingPathComponent(".astra-mirror-\(UUID())")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try WorkspaceRecoveryService.copyStoreSnapshot(from: root.appendingPathComponent("source.store"),
            to: abandoned.appendingPathComponent("snapshot.store"))
        let unrelated = root.appendingPathComponent(".astra-mirror-personal-notes")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let foreign = root.appendingPathComponent(".astra-mirror-\(UUID())")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("Keep user file".utf8).write(to: foreign.appendingPathComponent("notes.txt"))
        let link = root.appendingPathComponent(".astra-mirror-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        try WorkspaceSavedExportSnapshot.read(container: container) { _ in }
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("A live cross-process lease protects its copy; abrupt death makes it reclaimable")
    func crashReleasesLease() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer(root)
        let abandoned = root.appendingPathComponent(".astra-mirror-\(UUID())")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try WorkspaceRecoveryService.copyStoreSnapshot(from: root.appendingPathComponent("source.store"),
            to: abandoned.appendingPathComponent("snapshot.store"))
        let ready = root.appendingPathComponent("ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import fcntl, pathlib, sys, time
        with open(sys.argv[1], 'a') as lease:
            fcntl.flock(lease, fcntl.LOCK_EX)
            pathlib.Path(sys.argv[2]).touch()
            while True: time.sleep(1)
        """, abandoned.appendingPathComponent("owner.lock").path, ready.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        let startupDeadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path), "Lease fixture did not start")
        try WorkspaceSavedExportSnapshot.read(container: container) { _ in }
        #expect(FileManager.default.fileExists(atPath: abandoned.appendingPathComponent("snapshot.store").path))
        // SIGKILL bypasses scope-exit cleanup. Only the kernel releases flock.
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        try WorkspaceSavedExportSnapshot.read(container: container) { _ in }
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test("Concurrent snapshots preserve each other and normal failures clean their own copy")
    func concurrentAndFailingReads() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer(root)
        enum Failure: Error { case injected }
        var outer: URL?
        do {
            try WorkspaceSavedExportSnapshot.read(container: container) { snapshot in
                outer = try #require(snapshot.configurations.first?.url.deletingLastPathComponent())
                try WorkspaceSavedExportSnapshot.read(container: container) { _ in
                    let path = try #require(outer).path
                    #expect(FileManager.default.fileExists(atPath: path))
                }
                throw Failure.injected
            }
        } catch Failure.injected {}
        let path = try #require(outer).path
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-snapshot-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeContainer(_ root: URL) throws -> ModelContainer {
        let container = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("source.store"))])
        container.mainContext.autosaveEnabled = false
        container.mainContext.insert(Workspace(name: "Synthetic", primaryPath: root.path))
        try container.mainContext.save()
        return container
    }
}
