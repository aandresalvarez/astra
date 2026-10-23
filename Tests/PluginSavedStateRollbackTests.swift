import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Saved plugin graph rollback")
@MainActor
struct PluginSavedStateRollbackTests {
    @Test("Restoring a saved array graph settles its pending tracking without another save")
    func restoredGraphTracking() throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let snapshot = WorkspaceCapabilityActivation.snapshot(env.workspace)
        activation.configKeys = ["skill:report-agent#PROJECT"]
        activation.configValues = ["rejected"]
        WorkspaceCapabilityActivation.restore(snapshot, to: env.workspace)
        // This is the older runtime's failure mode: restored arrays match
        // the saved owner, but their writeback still counts as pending work.
        #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == snapshot)
        #expect(env.context.hasChanges)
        PluginSavedStateRollback.finish(in: env.context)
        #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == snapshot)
        #expect(!env.context.hasChanges)
    }
}
