import Darwin
import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence

@MainActor
@Suite("Saved export snapshot directory lifecycle", .serialized)
struct WorkspaceSnapshotDirectoryTests {
    @Test("One retained batch copy closes each reader before the next projection", arguments: ["success", "failure", "cancellation"])
    func retainedBatchReadersClose(outcome: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer(root)
        try await Task.detached {
            try autoreleasepool {
                enum ProjectionFailure: Error { case injected }
                let captured = try WorkspaceSavedExportSnapshot.capture(container: container, workspaceID: "synthetic")
                let directory = captured.directory.root
                for _ in 0..<3 {
                    var identities = Set<SnapshotFileIdentity>()
                    let references = SnapshotProjectionReferences()
                    do {
                        try captured.read { snapshot in
                            let context = ModelContext(snapshot)
                            context.autosaveEnabled = false
                            _ = Unmanaged.passRetained(snapshot).autorelease()
                            _ = Unmanaged.passRetained(context).autorelease()
                            let workspace = try #require(context.fetch(FetchDescriptor<Workspace>()).first)
                            let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
                            #expect(!context.hasChanges, "Projection must not tear down relationships by mutating the reader")
                            references.capture(snapshot, context: context, workspace: workspace)
                            #expect(config.installedPlugins?.first?.credentialRecoveryEvidence?.unresolvedSettingKeys == ["synthetic-legacy-key"])
                            #expect(config.installedPlugins?.first?.credentialRecoveryEvidence?.admittedActivationID == nil)
                            identities = try snapshotFileIdentities(in: directory)
                            #expect(!openSnapshotDescriptors(identities).isEmpty)
                            if outcome == "failure" { throw ProjectionFailure.injected }
                            if outcome == "cancellation" { throw CancellationError() }
                        }
                    } catch is CancellationError { #expect(outcome == "cancellation") }
                    catch ProjectionFailure.injected { #expect(outcome == "failure") }
                    #expect(!identities.isEmpty)
                    references.expectReleased()
                    #expect(openSnapshotDescriptors(identities).isEmpty)
                    #expect(FileManager.default.fileExists(atPath: directory.path))
                }
                withExtendedLifetime(captured) {}
            }
        }.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".astra-mirror-") && !$0.hasSuffix(".lock") }.isEmpty)
    }

    @Test("Repeated projections close snapshot descriptors before removing their directory",
          arguments: ["success", "failure", "cancellation"])
    func fileDescriptorsClose(outcome: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer(root)
        try await Task.detached {
            try autoreleasepool {
                enum ProjectionFailure: Error { case injected }
                for _ in 0..<5 {
                    var identities = Set<SnapshotFileIdentity>()
                    let references = SnapshotProjectionReferences()
                    do {
                        try WorkspaceSavedExportSnapshot.read(container: container) { snapshot in
                            let context = ModelContext(snapshot)
                            context.autosaveEnabled = false
                            // Reproduce Objective-C deferred ownership deterministically,
                            // independently of the host framework's retention choices.
                            _ = Unmanaged.passRetained(snapshot).autorelease()
                            _ = Unmanaged.passRetained(context).autorelease()
                            let workspace = try #require(context.fetch(FetchDescriptor<Workspace>()).first)
                            let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
                            #expect(!context.hasChanges, "Projection must not tear down relationships by mutating the reader")
                            references.capture(snapshot, context: context, workspace: workspace)
                            #expect(config.installedPlugins?.first?.credentialRecoveryEvidence?.unresolvedSettingKeys == ["synthetic-legacy-key"])
                            #expect(config.installedPlugins?.first?.credentialRecoveryEvidence?.admittedActivationID == nil)
                            let directory = try #require(snapshot.configurations.first?.url.deletingLastPathComponent())
                            identities = try snapshotFileIdentities(in: directory)
                            #expect(!openSnapshotDescriptors(identities).isEmpty, "Exercise real disk-backed readers")
                            if outcome == "failure" { throw ProjectionFailure.injected }
                            if outcome == "cancellation" { withUnsafeCurrentTask { $0?.cancel() } }
                            try Task.checkCancellation()
                        }
                    } catch is CancellationError {
                        #expect(outcome == "cancellation")
                    } catch ProjectionFailure.injected {
                        #expect(outcome == "failure")
                    }
                    #expect(!identities.isEmpty)
                    references.expectReleased()
                    #expect(openSnapshotDescriptors(identities).isEmpty,
                        "Snapshot files, including unlinked inodes, must have no open descriptors after projection")
                }
            }
        }.value
    }

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
        let workspace = Workspace(name: "Synthetic", primaryPath: root.path)
        container.mainContext.insert(workspace)
        let activation = PluginActivation(pluginID: "synthetic-reader-lifetime", isEnabled: false, recordedVersion: "1.0.0")
        container.mainContext.insert(activation)
        activation.workspace = workspace
        WorkspaceCapabilityActivation.setKnownComponents(["skill:agent"], on: activation)
        WorkspaceCapabilityActivation.preserveCredentialRecoveryEvidence(.init(
            unresolvedSettingKeys: ["synthetic-legacy-key"],
            namespaceSeed: "", credentialNamespaceSeed: "", admittedActivationID: activation.id.uuidString), on: activation)
        let task = AgentTask(title: "Synthetic task", goal: "Reader lifetime", workspace: workspace)
        container.mainContext.insert(task)
        container.mainContext.insert(TaskEvent(task: task, type: "user.message", payload: "Synthetic history"))
        try container.mainContext.save()
        return container
    }
}

/// A real bidirectional workspace/plugin graph reproduced the reader leak in
/// Dev. Observe only forward relationships here; reading activation.workspace
/// in the test would itself recreate the cycle that export must avoid.
private final class SnapshotProjectionReferences {
    weak var container: ModelContainer?
    weak var context: ModelContext?
    weak var workspace: Workspace?
    weak var activation: PluginActivation?
    weak var task: AgentTask?
    weak var event: TaskEvent?

    func capture(_ container: ModelContainer, context: ModelContext, workspace: Workspace) {
        self.container = container
        self.context = context
        self.workspace = workspace
        activation = workspace.pluginActivations.first
        task = workspace.tasks.first
        event = task?.events.first
        #expect(activation != nil && task != nil && event != nil)
    }

    func expectReleased() {
        // Keep failure diagnostics from reflecting and retaining the models.
        let alive = ["activation": activation != nil, "workspace": workspace != nil,
            "task": task != nil, "event": event != nil,
            "context": context != nil, "container": container != nil]
        #expect(alive.values.allSatisfy { !$0 }, "Reader objects still alive: \(alive)")
    }
}

struct SnapshotFileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
}

func snapshotFileIdentities(in directory: URL) throws -> Set<SnapshotFileIdentity> {
    var identities = Set<SnapshotFileIdentity>()
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("snapshot.store") {
        var info = stat()
        try #require(stat(file.path, &info) == 0)
        identities.insert(SnapshotFileIdentity(info))
    }
    return identities
}

func openSnapshotDescriptors(_ identities: Set<SnapshotFileIdentity>) -> [String] {
    (0..<Int32(getdtablesize())).compactMap { descriptor in
        var info = stat()
        guard fstat(descriptor, &info) == 0, identities.contains(SnapshotFileIdentity(info)) else { return nil }
        return "fd=\(descriptor), inode=\(info.st_ino), links=\(info.st_nlink)"
    }
}
