import Foundation
import Testing
import ASTRACore
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Startup cleanup telemetry")
struct StartupCleanupTelemetryTests {
    @Test("Aggregates repeated copies, distinct workspaces, bytes and safe error categories across actor hops")
    func aggregate() async throws {
        let job = StartupCleanupAggregate()
        let pass = StartupCleanupAggregate()
        try await WorkspacePersistenceWork.$cleanupJob.withValue(job) {
            try await WorkspacePersistenceWork.$cleanupPass.withValue(pass) {
                let child = Task { try await SyntheticCopyWorker().run() }
                try await child.value
            }
        }
        let fields = job.fields()
        #expect(fields == pass.fields())
        #expect(fields["distinct_workspaces"] == "2")
        #expect(fields["copy_attempts"] == "3")
        #expect(fields["copy_succeeded"] == "2")
        #expect(fields["copy_failed"] == "1")
        #expect(fields["logical_snapshot_bytes"] == "8192")
        #expect(fields["json_encoded_bytes"] == "128")
        #expect(fields["json_written_bytes"] == "64")
        #expect(fields["error_disk_full"] == "2")
        #expect(!fields.values.contains { $0.contains("private fixture path") })
    }

    @Test("Successive passes retain their trigger scope and get independent IDs")
    @MainActor
    func passContexts() async {
        let job = StartupCleanupAggregate()
        var ids: Set<String> = []
        await WorkspacePersistenceWork.$cleanupJob.withValue(job) {
            for trigger in [WorkspacePersistenceWork.CleanupTrigger.connectorGeneration, .skillGeneration, .pluginSecretOutbox] {
                let result: Bool? = await WorkspacePersistenceWork.withCleanupPass(trigger: trigger) {
                    #expect(WorkspacePersistenceWork.cleanupJob === job)
                    if let pass = WorkspacePersistenceWork.cleanupPass { ids.insert(pass.id) }
                    return true
                }
                #expect(result == true)
                #expect(WorkspacePersistenceWork.cleanupPass == nil)
            }
        }
        #expect(ids.count == 3)
        #expect(job.fields()["pass_count"] == "3")
        #expect(WorkspacePersistenceWork.cleanupJob == nil)
    }

    @Test("Disk full, quota, nested Cocoa errors and SQLite backup codes remain distinct from generic errors")
    func categories() {
        #expect(StartupCleanupAggregate.errorCategory(CocoaError(.fileWriteOutOfSpace)) == "disk_full")
        #expect(StartupCleanupAggregate.errorCategory(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))) == "disk_full")
        #expect(StartupCleanupAggregate.errorCategory(NSError(domain: "outer", code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])) == "disk_full")
        #expect(StartupCleanupAggregate.errorCategory(WorkspaceRecoveryService.PersistentStorePreparationError
            .migrationFailed("SQLite backup failed with step 13, finish 13")) == "disk_full")
        #expect(StartupCleanupAggregate.errorCategory(CocoaError(.fileReadNoPermission)) == "permission")
        #expect(StartupCleanupAggregate.errorCategory(CancellationError()) == "cancelled")
    }

    @MainActor
    @Test("Persistence timing names the active main-thread phase through the existing logging seam")
    func phaseBridge() {
        WorkspacePersistenceWork.measure("synthetic_mirror_phase", workspaceID: UUID().uuidString) {
            #expect(MainThreadPhase.snapshot() == .inside(label: "synthetic_mirror_phase", depth: 1))
        }
        #expect(MainThreadPhase.snapshot() == .idle)
    }
}

private actor SyntheticCopyWorker {
    func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("synthetic.store")
        try Data(count: 4096).write(to: snapshot)
        for _ in 0..<2 {
            WorkspacePersistenceWork.snapshotCopy(workspaceID: "synthetic-a") {
                WorkspacePersistenceWork.copiedSnapshot(at: snapshot)
            }
        }
        do {
            try WorkspacePersistenceWork.snapshotCopy(workspaceID: "synthetic-b") {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
                    userInfo: [NSFilePathErrorKey: "private fixture path"])
            }
        } catch {}
        for succeed in [true, false] {
            let data = WorkspacePersistenceWork.jsonEncode(workspaceID: "synthetic-a") { Data(count: 64) }
            do {
                _ = try WorkspacePersistenceWork.jsonWrite(workspaceID: "synthetic-a", bytes: data.count,
                    published: { $0 }) {
                        if !succeed { throw CocoaError(.fileWriteOutOfSpace) }
                        return true
                    }
            } catch {}
        }
    }
}
