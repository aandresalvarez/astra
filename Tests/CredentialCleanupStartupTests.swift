import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Credential cleanup yields during startup", .serialized)
struct CredentialCleanupStartupTests {
    @Test("A failed write or changed workspace scope retains cleanup debt", arguments: ["failure", "move", "add", "trust"])
    func invalidatedScope(reason: String) async throws {
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let trust = WorkspaceRecoveryTrust.state
        defer { WorkspaceRecoveryTrust.set(trust) }
        let namespace = UUID()
        try env.outbox.write([namespace])
        #expect(GenerationSecrets.saveSecretValue("retained", key: "API_TOKEN", skillID: namespace,
            skillName: "Test", allowUserInteraction: false))
        var writes = 0
        await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context,
            outbox: env.outbox, secrets: GenerationSecrets.self, rewriteMirrors: { context in
                await CredentialCleanupStartupMirrors.rewrite(modelContext: context, write: { _, _ in
                    writes += 1
                    // The UI actor can run while cleanup waits; the producer
                    // lock must still exclude credential publication.
                    await Task.yield()
                    #expect(throws: (any Error).self) {
                        _ = try PluginCredentialProducerLease.acquire(modelContext: env.context)
                    }
                    if reason == "move" { env.workspace.primaryPath += "/moved"; try? env.context.save() }
                    if reason == "add" {
                        env.context.insert(Workspace(name: "Added during write", primaryPath: ""))
                        try? env.context.save()
                    }
                    if reason == "trust" { WorkspaceRecoveryTrust.set(.untrusted) }
                    return reason != "failure"
                })
            })
        #expect(writes > 0)
        #expect(GenerationSecrets.value(in: namespace) == "retained")
        #expect(GenerationSecrets.deleted.isEmpty)
        #expect(try env.outbox.pending().contains(namespace))
        let released = try PluginCredentialProducerLease.acquire(modelContext: env.context)
        withExtendedLifetime(released) {}
    }

    @Test("Actual asynchronous mirror writes release only orphaned fake credentials")
    func realWriteThenCleanup() async throws {
        let env = try PluginCredentialGenerationTests.Fixture()
        defer { env.disk.disk.removeFiles() }
        let namespace = UUID()
        try env.outbox.write([namespace])
        #expect(GenerationSecrets.saveSecretValue("orphan", key: "API_TOKEN", skillID: namespace,
            skillName: "Test", allowUserInteraction: false))
        await PluginSecretCleanupOutbox.resumePendingAsync(modelContext: env.context,
            outbox: env.outbox, secrets: GenerationSecrets.self)
        #expect(GenerationSecrets.value(in: namespace) == nil)
        #expect(try env.outbox.pending().isEmpty)
    }
}
