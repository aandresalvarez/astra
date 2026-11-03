import Foundation
import SQLite3
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Credential cleanup shared committed-store snapshot", .serialized)
struct WorkspaceCleanupMirrorBatchTests {
    @Test("A stable 23-workspace cleanup makes one backup and 23 equivalent distinct recovery exports")
    func stablePass() async throws {
        let env = try Fixture(count: 23)
        defer { env.removeFiles() }
        var expected: [UUID: Data] = [:]
        for workspace in env.workspaces {
            // The existing per-workspace immutable export is the baseline.
            let prepared = try #require(try await WorkspaceSavedAutoExport().prepare(
                container: env.container, workspaceID: workspace.id))
            expected[workspace.id] = try canonical(prepared.config)
        }
        let totals = StartupCleanupAggregate()
        let observed = OSAllocatedUnfairLock(initialState: (copies: 0, bytes: Int64(0)))
        let copy = WorkspaceExportFileIO.copySnapshot
        let saved = await WorkspaceExportFileIO.$copySnapshot.withValue({ source, destination in
            try copy(source, destination)
            let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
            observed.withLock { $0.copies += 1; $0.bytes += size?.int64Value ?? 0 }
        }) {
            await WorkspacePersistenceWork.$cleanupJob.withValue(totals) {
                await CredentialCleanupStartupMirrors.rewrite(modelContext: env.context)
            }
        }
        #expect(saved != nil)
        let fields = totals.fields()
        #expect(fields["pass_count"] == "1")
        #expect(fields["distinct_workspaces"] == "23")
        #expect(fields["copy_attempts"] == "1")
        #expect(fields["copy_succeeded"] == "1")
        #expect(fields["copy_failed"] == "0")
        #expect(fields["json_encode_succeeded"] == "23")
        #expect(fields["json_write_succeeded"] == "23")
        #expect(fields["mirror_request_succeeded"] == "23")
        let logical = try #require(Int64(fields["logical_snapshot_bytes"] ?? ""))
        #expect(logical > 0)
        #expect(observed.withLock { $0.copies } == 1)
        #expect(observed.withLock { $0.bytes } == logical)
        var ids = Set<String>()
        var jsonBytes = 0
        for workspace in env.workspaces {
            let data = try Data(contentsOf: env.mirror(workspace))
            jsonBytes += data.count
            let actual = try WorkspaceConfigManager.loadConfig(from: env.mirror(workspace))
            ids.insert(try #require(actual.id))
            #expect(try canonical(actual) == expected[workspace.id])
            #expect(!String(decoding: data, as: UTF8.self).contains("fake-secret-never-export"))
        }
        #expect(ids.count == 23)
        #expect(fields["json_written_bytes"] == String(jsonBytes))
        #expect(try env.snapshotDirectories().isEmpty)
        print("CLEANUP_BATCH_MEASUREMENT workspaces=23 backup_successes=1 logical_snapshot_bytes=\(logical) json_written_bytes=\(jsonBytes)")
    }

    @Test("An edit from another context invalidates even an already-staged old batch",
          arguments: ["edit", "rename", "move", "delete", "add"])
    func concurrentCommit(change: String) async throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let workspace = env.workspaces[0]
        try env.writePreviousMirror(workspace)
        let mirror = env.mirror(workspace)
        let previous = try Data(contentsOf: mirror)
        let batch = try #require(await WorkspaceCleanupMirrorBatch.prepare(modelContext: env.context))
        let container = env.container
        let id = workspace.id
        let moved = env.root.appendingPathComponent("moved").path
        let result = await WorkspaceExportFileIO.$writeStaging.withValue({ data, staging in
            try data.write(to: staging)
            // This context has never registered a save/export lease. Commit
            // after staging, immediately before the final publication gate.
            let other = ModelContext(container)
            other.autosaveEnabled = false
            let owner = try #require(other.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
            switch change {
            case "edit": owner.tasks.first?.title = "New committed task"
            case "rename": owner.name = "New committed name"
            case "move": owner.primaryPath = moved
            case "delete": other.delete(owner)
            default: other.insert(Workspace(name: "Added", primaryPath: ""))
            }
            try other.save()
        }) {
            await batch.write(workspaceID: id, modelContext: env.context)
        }
        #expect(!result)
        #expect(!batch.isCurrent)
        #expect(try Data(contentsOf: mirror) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: mirror.deletingLastPathComponent().path)
            .filter { $0.contains(".astra-export-") }.isEmpty)
    }

    @Test("Commits during capture reject the pass, with generation registered before the copy",
          arguments: [false, true])
    func commitDuringCapture(afterBackup: Bool) async throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let container = env.container
        let copy = WorkspaceExportFileIO.copySnapshot
        let batch = await WorkspaceExportFileIO.$copySnapshot.withValue({ source, destination in
            if afterBackup { try copy(source, destination) }
            let other = ModelContext(container)
            other.autosaveEnabled = false
            let workspace = try #require(other.fetch(FetchDescriptor<Workspace>()).first)
            workspace.name = "Committed during capture"
            try other.save()
            if !afterBackup { try copy(source, destination) }
        }) { await WorkspaceCleanupMirrorBatch.prepare(modelContext: env.context) }
        #expect(batch == nil)
        #expect(try env.snapshotDirectories().isEmpty)
    }

    @Test("A newer explicit publication cannot be overwritten by an older batch with late projection")
    func newerMirrorWins() async throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let workspace = env.workspaces[0]
        let batch = try #require(await WorkspaceCleanupMirrorBatch.prepare(modelContext: env.context))
        // Same committed generation, but a newer publication boundary. This
        // specifically exercises pre-capture ticket order, not data_version.
        #expect(WorkspaceConfigManager.exportMirrorNow(workspace: workspace, modelContext: env.context))
        let newer = try Data(contentsOf: env.mirror(workspace))
        #expect(await batch.write(workspaceID: workspace.id, modelContext: env.context) == false)
        #expect(try Data(contentsOf: env.mirror(workspace)) == newer)
    }

    @Test("A newer committed edit and mirror from a different context survive a queued old batch")
    func newerCommittedMirrorWins() async throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let workspace = env.workspaces[0]
        let id = workspace.id
        let batch = try #require(await WorkspaceCleanupMirrorBatch.prepare(modelContext: env.context))
        let container = env.container
        let writer = WorkspaceAutoExportWriter(beforeWrite: {
            try? await MainActor.run {
                let other = ModelContext(container)
                other.autosaveEnabled = false
                let owner = try #require(other.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
                owner.tasks.first?.title = "Newer committed mirror"
                try other.save()
                #expect(WorkspaceConfigManager.exportMirrorNow(workspace: owner, modelContext: other))
            }
        })
        #expect(await batch.write(workspaceID: id, modelContext: env.context, writer: writer) == false)
        let config = try WorkspaceConfigManager.loadConfig(from: env.mirror(workspace))
        #expect(config.tasks?.first?.title == "Newer committed mirror")
    }

    @Test("An active SQLite writer holds publication without waiting or consuming the prior mirror")
    func activeWriterHoldsPublication() async throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let workspace = env.workspaces[0]
        try env.writePreviousMirror(workspace)
        let previous = try Data(contentsOf: env.mirror(workspace))
        let batch = try #require(await WorkspaceCleanupMirrorBatch.prepare(modelContext: env.context))
        let source = try #require(env.container.configurations.first?.url)
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        #expect(await batch.write(workspaceID: workspace.id, modelContext: env.context) == false)
        #expect(try Data(contentsOf: env.mirror(workspace)) == previous)
        #expect(try env.stagingFiles(workspace).isEmpty)
    }

    @Test("Replacing the backing store rejects an old batch without recreating its mirror")
    func replacedStore() async throws {
        let env = try Fixture()
        defer { env.removeFiles() }
        let workspace = env.workspaces[0]
        try env.writePreviousMirror(workspace)
        let previous = try Data(contentsOf: env.mirror(workspace))
        let batch = try #require(await WorkspaceCleanupMirrorBatch.prepare(modelContext: env.context))
        let source = try #require(env.container.configurations.first?.url)
        let replacement = env.root.appendingPathComponent("replacement.store")
        try WorkspaceRecoveryService.copyStoreSnapshot(from: source, to: replacement)
        try FileManager.default.moveItem(at: source, to: env.root.appendingPathComponent("removed.store"))
        try FileManager.default.moveItem(at: replacement, to: source)
        #expect(!batch.isCurrent)
        #expect(await batch.write(workspaceID: workspace.id, modelContext: env.context) == false)
        #expect(try Data(contentsOf: env.mirror(workspace)) == previous)
    }

    @Test("Backup/write disk-full failures and cancellation retain fake credentials, pending debt and the previous mirror",
          arguments: ["backup", "staging", "replace", "cancel"])
    func failedPassKeepsDebt(failure: String) async throws {
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let id = UUID()
        try env.outbox.write([id])
        #expect(GenerationSecrets.saveSecretValue("fake-kept-secret", key: "API_TOKEN", skillID: id,
            skillName: "Synthetic", allowUserInteraction: false))
        #expect(WorkspaceConfigManager.exportMirrorNow(workspace: env.workspace, modelContext: env.context))
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath))
        let previous = try Data(contentsOf: mirror)
        let totals = StartupCleanupAggregate()
        let copy = WorkspaceExportFileIO.copySnapshot
        let replace = WorkspaceExportFileIO.replace
        await WorkspaceExportFileIO.$copySnapshot.withValue({ source, destination in
            if failure == "backup" { throw CocoaError(.fileWriteOutOfSpace) }
            try copy(source, destination)
        }) {
            await WorkspaceExportFileIO.$writeStaging.withValue({ data, staging in
                try data.prefix(17).write(to: staging)
                if failure == "staging" { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: staging)
                if failure == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
            }) {
                await WorkspaceExportFileIO.$replace.withValue({ staging, destination in
                    if failure == "replace" { throw CocoaError(.fileWriteOutOfSpace) }
                    try replace(staging, destination)
                }) {
                    // Isolate cancellation from this test's own task.
                    await Task { @MainActor in
                        await WorkspacePersistenceWork.$cleanupJob.withValue(totals) {
                            await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context,
                                outbox: env.outbox, secrets: GenerationSecrets.self)
                        }
                    }.value
                }
            }
        }
        #expect(try Data(contentsOf: mirror) == previous)
        #expect(try env.outbox.pending().contains(id))
        #expect(GenerationSecrets.value(in: id) == "fake-kept-secret")
        #expect(GenerationSecrets.deleted.isEmpty)
        #expect(totals.fields()["copy_attempts"] == "1")
        if failure != "cancel" { #expect(totals.fields()["error_disk_full"] == "1") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: mirror.deletingLastPathComponent().path)
            .allSatisfy { !$0.contains(".astra-export-") })
        // Failure must not poison the next stable pass or consume its debt.
        await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context,
            outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(try env.outbox.pending().isEmpty)
        #expect(GenerationSecrets.value(in: id) == nil)
    }

    @Test("Destructive cleanup re-reads a recoverable mirror changed after batch completion")
    func rechecksActualRecoveryMirror() async throws {
        let previousSecrets = SkillSecretSeam.required
        SkillSecretSeam.register(GenerationSecrets.self)
        defer { SkillSecretSeam.register(previousSecrets) }
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let previous = WorkspaceRecoveryTrust.loadedMirrors
        defer { WorkspaceRecoveryTrust.recordLoadedMirrors(previous) }
        _ = try env.enable("fake-recoverable-secret")
        let namespace = try #require(GenerationSecrets.namespace(holding: "fake-recoverable-secret"))
        let own = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath))
        let retained = try Data(contentsOf: own)
        try env.removeLeavingLegacyMirror(namespace)
        let extra = env.disk.disk.root.appendingPathComponent("recoverable-copy.json")
        WorkspaceRecoveryTrust.recordLoadedMirrors([extra.path])
        await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context,
            outbox: env.outbox, secrets: GenerationSecrets.self, rewriteMirrors: { context in
                let ready = await CredentialCleanupStartupMirrors.rewrite(modelContext: context)
                // No store commit: an actual recovery file now contains an
                // owner that a cached snapshot of mirrors would overlook.
                try? retained.write(to: extra)
                return ready
            })
        #expect(GenerationSecrets.value(in: namespace) == "fake-recoverable-secret")
        #expect(try env.outbox.pending().contains(namespace))
        try FileManager.default.removeItem(at: extra)
        await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context,
            outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: namespace) == nil)
        #expect(try env.outbox.pending().isEmpty)
    }

    @Test("In-memory and empty-path workspaces preserve their existing behavior without database copies",
          arguments: [false, true])
    func specialStores(emptyPath: Bool) async throws {
        let env = try Fixture(memory: true)
        defer { env.removeFiles() }
        if emptyPath { env.workspaces[0].primaryPath = "  "; try env.context.save() }
        let totals = StartupCleanupAggregate()
        let result = await WorkspacePersistenceWork.$cleanupJob.withValue(totals) {
            await CredentialCleanupStartupMirrors.rewrite(modelContext: env.context)
        }
        #expect(result != nil)
        #expect(totals.fields()["copy_attempts"] == "0")
        if !emptyPath { #expect(FileManager.default.fileExists(atPath: env.mirror(env.workspaces[0]).path)) }
    }

    private func canonical(_ value: WorkspaceConfigManager.WorkspaceConfig) throws -> Data {
        var config = value
        config.exportedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(config)
    }

    @MainActor
    struct Fixture {
        let root: URL
        let container: ModelContainer
        let workspaces: [Workspace]
        var context: ModelContext { container.mainContext }

        init(count: Int = 1, memory: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-cleanup-batch-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configuration = memory ? ModelConfiguration(isStoredInMemoryOnly: true)
                : ModelConfiguration(url: root.appendingPathComponent("source.store"))
            container = try ModelContainer(for: ASTRASchema.current, configurations: [configuration])
            let context = container.mainContext
            context.autosaveEnabled = false
            var owners: [Workspace] = []
            for index in 0..<count {
                let path = root.appendingPathComponent("workspace-\(index)")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                let workspace = Workspace(name: "Workspace \(index)", primaryPath: path.path)
                context.insert(workspace)
                let task = AgentTask(title: "Task \(index)", goal: "Synthetic recovery", workspace: workspace)
                context.insert(task)
                let run = TaskRun(task: task)
                context.insert(run)
                for event in 0..<15 {
                    context.insert(TaskEvent(task: task, type: "agent.response", payload: "Synthetic \(index)/\(event)", run: run))
                }
                let connector = Connector(name: "Fake account \(index)", serviceType: "rest_api")
                connector.workspace = workspace
                connector.credentialKeys = ["API_TOKEN"]
                connector.credentialValues = ["fake-secret-never-export"]
                context.insert(connector)
                owners.append(workspace)
            }
            try context.save()
            workspaces = owners
        }

        func mirror(_ workspace: Workspace) -> URL {
            URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath))
        }
        func writePreviousMirror(_ workspace: Workspace) throws {
            #expect(WorkspaceConfigManager.exportMirrorNow(workspace: workspace, modelContext: context))
        }
        func snapshotDirectories() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".astra-mirror-") && $0.hasDirectoryPath }
        }
        func stagingFiles(_ workspace: Workspace) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: mirror(workspace).deletingLastPathComponent().path)
                .filter { $0.contains(".astra-export-") }
        }
        func removeFiles() { try? FileManager.default.removeItem(at: root) }
    }
}
