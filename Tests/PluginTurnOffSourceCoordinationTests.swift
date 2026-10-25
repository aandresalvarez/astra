import Foundation
import Darwin
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Turn off and recovery use the source mutation lock", .serialized)
struct PluginTurnOffSourceCoordinationTests {
    @Test("An unrelated source change excludes the actual Turn off action without saving")
    func turnOffRespectsSourceLock() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, skill in
            let store = PluginSourceStore(root: env.disk.root.appendingPathComponent("sources"))
            let actions = CapabilityCatalogActionService(library: env.disk.library, sourceStore: store)
            let before = WorkspaceCapabilityActivation.snapshot(env.workspace)
            let namespace = skill.secretNamespaceID
            try withHeldLibraryFileLock(store) {
                let start = ContinuousClock.now
                let result = actions.disable(package, workspace: env.workspace, modelContext: env.context)
                #expect(start.duration(to: .now) < .seconds(1))
                #expect(!result.persisted && result.problem == .libraryBusy)
                #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == before)
                let receiptCount = try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>())
                #expect(receiptCount == 0)
            }
            #expect(skill.secretNamespaceID == namespace)
            let retry = actions.disable(package, workspace: env.workspace, modelContext: env.context)
            #expect(retry.persisted && retry.problem == nil)
            #expect(!env.workspace.enabledCapabilityIDs.contains(package.id))
        }
    }

    @Test("The direct Turn off writer cannot bypass the source lock either", arguments: [false, true])
    func directWriterRespectsSourceLock(samePlugin: Bool) throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, _ in
            let before = WorkspaceCapabilityActivation.snapshot(env.workspace)
            try PluginSourceStore().exclusively(pluginID: samePlugin ? package.id : "unrelated-source") {
                let result = CapabilityActivationDisabler().disable(package, in: env.workspace,
                    modelContext: env.context, library: env.disk.library)
                #expect(!result.persisted && result.problem == .libraryBusy)
                #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == before)
                let receiptCount = try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>())
                #expect(receiptCount == 0)
            }
        }
    }

    @Test("Finishing generic state recovery respects the same source lock and remains retryable")
    func recoveryRespectsSourceLock() throws {
        try LegacyPluginDisableTests().withLegacySkill { env, package, skill in
            let result = CapabilityActivationDisabler().disable(package, in: env.workspace,
                modelContext: env.context, library: env.disk.library, rewriteMirror: { _ in false })
            let id = try #require(result.problem?.operationID)
            let namespace = skill.secretNamespaceID
            let store = PluginSourceStore(root: env.disk.root.appendingPathComponent("sources"))
            let actions = CapabilityCatalogActionService(library: env.disk.library, sourceStore: store)
            try withHeldLibraryFileLock(store) {
                let start = ContinuousClock.now
                #expect(throws: PluginSourceStoreError.libraryBusy) { try actions.finishStateRecovery(id, modelContext: env.context) }
                #expect(start.duration(to: .now) < .seconds(1))
                let pending = try PluginOperationCommit.read(id, container: env.context.container)
                #expect(pending?.completedAt == nil)
            }
            try actions.finishStateRecovery(id, modelContext: env.context)
            #expect(try PluginOperationCommit.read(id, container: env.context.container)?.completedAt != nil)
            #expect(skill.secretNamespaceID == namespace)
        }
    }
    /// Hold the actual file descriptor without the in-process busy marker:
    /// callers must honor the configured store's lock, not a default root.
    private func withHeldLibraryFileLock(_ store: PluginSourceStore, _ body: () throws -> Void) throws {
        try store.exclusively(pluginID: "prepare-lock-file") {}
        let descriptor = open(store.libraryLockURL.path, O_RDWR | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { flock(descriptor, LOCK_UN) }
        try body()
    }

}
