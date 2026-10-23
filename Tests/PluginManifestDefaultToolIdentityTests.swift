import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Manifest default tool identity")
struct PluginManifestDefaultToolIdentityTests {
    @Test("A manifest default tool ID survives a command or type change and keeps its override", arguments: [false, true])
    func defaultIDIsStable(changesType: Bool) throws {
        let env = try PluginOperationsTests.Environment()
        var legacy = PluginOperationsTests.package(version: "1.0.0")
        legacy.localTools[0].id = nil
        let manifest = PluginManifestConverter.manifest(from: legacy)
        let index = try #require(manifest.components.firstIndex { $0.kind == .tool })
        let first = try PluginManifestConverter.checkedPackage(from: manifest)
        let firstTool = try #require(first.localTools.first)
        let componentID = CapabilityResourceOrigin.componentID(for: firstTool)
        #expect(firstTool.id == manifest.components[index].id)
        #expect(CapabilityResourceOrigin.replacedComponentIDs(for: firstTool).contains(
            CapabilityResourceOrigin.componentID(for: legacy.localTools[0])))
        try env.install(first)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: first.id, in: env.workspace))
        let rowID = UUID()
        WorkspaceCapabilityActivation.setOverridden(true, componentID: componentID, rowID: rowID, on: activation)
        try env.context.save()
        let projectedID = PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)
        var changed = manifest
        changed.version = "2.0.0"
        if changesType { changed.components[index].tool?.toolType = "python" }
        else { changed.components[index].tool?.command += " --new-option" }
        let next = try PluginManifestConverter.checkedPackage(from: changed)
        let nextTool = try #require(next.localTools.first)
        let nextID = CapabilityResourceOrigin.componentID(for: nextTool)
        #expect(nextID == componentID)
        #expect(PluginRuntimeProjection.derivedID(of: activation, componentID: nextID) == projectedID)
        try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [next], mode: .release)
        #expect(activation.overriddenComponentIDs == [componentID])
        #expect(activation.overridingRowID(forComponent: componentID) == rowID)
        let again = try PluginManifestConverter.checkedPackage(from: PluginManifestConverter.manifest(from: next))
        #expect(try CapabilityApprovalDigest.digest(for: again) == CapabilityApprovalDigest.digest(for: next))
    }
}
