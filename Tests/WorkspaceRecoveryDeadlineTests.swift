import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

private actor RecoveryProbeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    private(set) var finished = false
    private(set) var observedCancellation = false
    func wait() async {
        started = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        observedCancellation = Task.isCancelled
        finished = true
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Workspace recovery read deadline")
struct WorkspaceRecoveryDeadlineTests {
    @Test("Successful discovery preserves its result")
    func successfulRead() async {
        let value = await WorkspaceRecoveryReadDeadline.read(timeout: .seconds(1)) { [URL(fileURLWithPath: "/tmp/mirror")] }
        #expect(value == [URL(fileURLWithPath: "/tmp/mirror")])
    }

    @Test("A noncooperative read cannot hold its caller past the deadline")
    func blockedReadTimesOut() async {
        let gate = RecoveryProbeGate()
        let clock = ContinuousClock()
        let started = clock.now
        let value = await WorkspaceRecoveryReadDeadline.read(timeout: .milliseconds(30)) {
            await gate.wait()
            return 17
        }
        #expect(value == nil)
        #expect(started.duration(to: clock.now) < .seconds(2))
        await gate.release()
    }

    @Test("Parent cancellation returns without joining a blocked probe", arguments: [false, true])
    func cancellationReturnsWithoutJoining(bounded: Bool) async {
        let gate = RecoveryProbeGate()
        let task = Task {
            await WorkspaceRecoveryReadDeadline.read(timeout: bounded ? .seconds(30) : nil) {
                await gate.wait()
                return 17
            }
        }
        for _ in 0..<100 {
            if await gate.started { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started)
        task.cancel()
        #expect(await task.value == nil)
        await gate.release()
        for _ in 0..<100 {
            if await gate.finished { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.observedCancellation)
    }

    @Test("Completion racing the timer resolves exactly once")
    func completionRace() async {
        for value in 0..<40 {
            let result = await WorkspaceRecoveryReadDeadline.read(timeout: .nanoseconds(1)) { value }
            #expect(result == nil || result == value)
        }
    }

    @Test("Discovery bounds saved stores, preserves slow initial restoration and rejects late results", arguments: [0, 1, 2])
    @MainActor
    func timeoutKeepsRecoveryUntrustedAndDoesNotImportLate(scenario: Int) async throws {
        let hasSavedWorkspace = scenario == 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = ASTRASchema.current
        let source = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let later = Workspace(name: "Recovered only on a completed scan", primaryPath: root.appendingPathComponent("later").path)
        source.mainContext.insert(later)
        try source.mainContext.save()
        let mirror = root.appendingPathComponent("later/.astra/.astra-workspace.json")
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceConfigManager.exportToFile(workspace: later, modelContext: source.mainContext, url: mirror)
        let saved = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let kept = Workspace(name: "Saved", primaryPath: root.appendingPathComponent("kept").path)
        if hasSavedWorkspace { saved.mainContext.insert(kept) }
        try saved.mainContext.save()
        let marker = root.appendingPathComponent("recovery-incomplete")
        let gate = RecoveryProbeGate()
        var imports = 0
        let recovery = WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: saved.mainContext, extraRoots: [root.path], includeDefaultRoots: false,
            incompleteMarker: marker, pendingCleanup: true, afterImport: { imports += 1 },
            discoveryTimeout: .milliseconds(30), discover: {
                await gate.wait()
                return (configs: [mirror], complete: true)
            }
        )
        for _ in 0..<100 {
            if await gate.started { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started)
        if !hasSavedWorkspace {
            try? await Task.sleep(for: .milliseconds(80))
            if scenario == 1 {
                await gate.release()
                #expect(await recovery.value)
                #expect(imports == 1)
                #expect(try saved.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.id) == [later.id])
                #expect(!FileManager.default.fileExists(atPath: marker.path))
                return
            }
            recovery.cancel()
        }
        #expect(await recovery.value == false)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try saved.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.id) == (hasSavedWorkspace ? [kept.id] : []))
        await gate.release()
        for _ in 0..<100 {
            if await gate.finished { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await gate.finished)
        #expect(imports == 0)
        #expect(try saved.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.id) == (hasSavedWorkspace ? [kept.id] : []))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(atPath: mirror.path))
    }
}
