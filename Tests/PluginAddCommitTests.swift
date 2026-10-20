import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin Add commit proof", .serialized)
struct PluginAddCommitTests {
    @Test("A successful callback without saving cannot confirm an activation")
    func successMustBeSaved() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        #expect(throws: (any Error).self) {
            try env.installer.enable(env.package, in: env.workspace, modelContext: env.context, persist: { _, _ in true })
        }
        #expect(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace) == nil)
        #expect(try ModelContext(env.disk.container).fetch(FetchDescriptor<PluginActivation>()).isEmpty)
    }

    @Test("A callback failing after saving must preserve the committed activation and mirror debt")
    func failureAfterSaveIsNotRollback() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        var operationID: UUID?
        do {
            _ = try env.installer.enable(env.package, in: env.workspace, modelContext: env.context,
                persist: { _, context in try! context.save(); return false })
            Issue.record("The saved operation must report pending recovery")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        #expect(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace) != nil)
        let reopened = try env.disk.reopen()
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).count == 1)
        #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt == nil)
        #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext).completed == 1)
    }

    @Test("An Add with no secret cleanup still retains a failed mirror for retry")
    func mirrorDebtNeedsNoSecrets() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        var operationID: UUID?
        do {
            _ = try env.installer.enable(env.package, in: env.workspace, modelContext: env.context, rewriteMirror: { _ in false })
            Issue.record("A failed mirror must not be acknowledged as complete")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        let reopened = try env.disk.reopen()
        let receipt = try #require(try PluginOperationCommit.read(id, container: reopened))
        #expect(receipt.kind == .add && receipt.workspaceIDs == [env.workspace.id])
        #expect(receipt.completedAt == nil)
        #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext).completed == 1)
        let config = try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath)))
        #expect(config.installedPlugins?.contains { $0.id == env.package.id } == true)
    }

    @Test("Install and Create retain committed files and approval while a mirror is pending", arguments: [false, true])
    func savedDefinitionSurvivesMirrorFailure(create: Bool) throws {
        let env = try Fixture(installed: !create)
        defer { env.disk.removeFiles() }
        var package = env.package
        package.version = "2.0.0"
        let approvals = CapabilityApprovalStore(directory: env.disk.root.appendingPathComponent("Approvals"))
        if create { package.governance = .localDraft() }
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        try Data("Blocked recovery mirror".utf8).write(to: support)
        #expect(throws: PluginOperationProblem.self) {
            if create {
                _ = try CapabilityPackageCreationService(library: env.disk.library, approvalStore: approvals).create(
                    package, enableHere: true, sourceURL: nil, workspace: env.workspace, modelContext: env.context)
            } else {
                _ = try env.installer.install(package, into: env.workspace, modelContext: env.context)
            }
        }
        #expect(env.disk.library.installedPackage(id: package.id)?.version == "2.0.0")
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace)?.recordedVersion == "2.0.0")
        if create { #expect(approvals.records().contains { $0.packageID == package.id && $0.status == .approved }) }
        let reopened = try env.disk.reopen()
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first?.recordedVersion == "2.0.0")
        try FileManager.default.removeItem(at: support)
        #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext).completed == 1)
    }

    @MainActor
    struct Fixture {
        let disk: PluginFileOperationRecoveryTests.Fixture
        let workspace: Workspace
        let package: PluginPackage
        var context: ModelContext { disk.context }
        var installer: CapabilityInstaller { .init(library: disk.library, appVersion: SemanticVersion(1, 0, 0)) }
        init(installed: Bool = true) throws {
            disk = try PluginFileOperationRecoveryTests.Fixture()
            let path = disk.root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            workspace = Workspace(name: "Add commit", primaryPath: path.path)
            var definition = PluginOperationsTests.package(version: "1.0.0")
            definition.id = "add-commit-" + UUID().uuidString.lowercased()
            definition.connectors = []; definition.localTools = []; definition.templates = []
            definition.skills = []
            definition.governance = .builtInApproved()
            package = definition
            context.insert(workspace)
            try context.save()
            if installed { try disk.library.install(package) }
        }
    }
}
