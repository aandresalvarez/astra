import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Which mirrors a changed account leaves stale is never a partial answer:
/// shared rows that can't be read fail the question, and a destructive
/// caller then does nothing rather than skip a workspace's mirror.
@Suite("Mirror scope fails closed")
@MainActor
struct MirrorScopeFailsClosedTests {
    @Test("Unreadable shared rows throw instead of answering with fewer workspaces")
    func unreadableRowsThrow() throws {
        let (container, workspace, account) = try Self.workspaceWithAccount()
        let context = container.mainContext
        let answered = try WorkspaceConfigManager.workspacesMirroring(accountIDs: [account.id], among: [workspace], modelContext: context)
        #expect(answered.map(\.id) == [workspace.id])
        #expect(throws: CocoaError.self) {
            try WorkspaceConfigManager.workspacesMirroring(
                accountIDs: [account.id], among: [workspace], modelContext: context,
                globalRows: { throw CocoaError(.fileReadUnknown) }
            )
        }
        withExtendedLifetime(container) {}
    }

    @Test("A Configure-surface deletion whose workspaces can't be read deletes nothing")
    func deletionFailsClosed() throws {
        let (container, workspace, account) = try Self.workspaceWithAccount()
        let context = container.mainContext
        var saved = 0
        let deleted = ConnectorCredentialCleanup.deleteConnector(
            account, in: workspace, modelContext: context,
            fetchWorkspaces: { throw CocoaError(.fileReadUnknown) },
            save: { saved += 1; return true }
        )
        #expect(!deleted)
        #expect(saved == 0)
        #expect(!account.isDeleted)
        #expect(workspace.connectors.contains { $0.id == account.id })
        withExtendedLifetime(container) {}
    }

    @Test("A post-save export that can't learn its scope reports the mirror as not written")
    func postSaveExportFailsClosed() throws {
        let (container, workspace, account) = try Self.workspaceWithAccount()
        let context = container.mainContext
        var exported: [UUID] = []
        let written = PluginStateMirrors.exportAfterSave(
            workspace: workspace, accounts: [account], modelContext: context,
            export: { exported.append($0.id); return true },
            fetchWorkspaces: { throw CocoaError(.fileReadUnknown) }
        )
        #expect(!written)
        #expect(exported.isEmpty)
        #expect(PluginStateMirrors.exportAfterSave(
            workspace: workspace, accounts: [account], modelContext: context, export: { exported.append($0.id); return true }
        ))
        #expect(exported == [workspace.id])
        withExtendedLifetime(container) {}
    }

    @Test("An account row shows the name this workspace knows the account by")
    func accountRowShowsTheWorkspaceAlias() throws {
        let container = try Self.container()
        let context = container.mainContext
        let joining = Workspace(name: "Joining", primaryPath: "/tmp/alias-row-\(UUID().uuidString)")
        context.insert(joining)
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let component = CapabilityResourceOrigin.componentID(for: jira.connectors[0])
        let shared = Connector(name: "Stanford", serviceType: jira.connectors[0].serviceType)
        shared.isGlobal = true
        let local = Connector(name: "Stanford", serviceType: jira.connectors[0].serviceType)
        [shared, local].forEach(context.insert)
        local.workspace = joining
        WorkspaceCapabilityActivation.mutate(joining) { $0.enableCapability(jira.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: joining))
        WorkspaceCapabilityActivation.bind(local, toComponent: component, of: activation)
        WorkspaceCapabilityActivation.bind(shared, toComponent: component, of: activation)
        #expect(PluginsSurfacePresentation.accountTitle(local, in: joining) == "Stanford")
        // Whether the row itself was renamed or only its binding aliased.
        #expect(PluginsSurfacePresentation.accountTitle(shared, in: joining) == "Stanford 2")
        withExtendedLifetime(container) {}
    }

    private static func container() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private static func workspaceWithAccount() throws -> (ModelContainer, Workspace, Connector) {
        let container = try container()
        let context = container.mainContext
        let workspace = Workspace(name: "Scope", primaryPath: "/tmp/mirror-scope-\(UUID().uuidString)")
        context.insert(workspace)
        let account = Connector(name: "Work", serviceType: "jira")
        account.workspace = workspace
        context.insert(account)
        try context.save()
        return (container, workspace, account)
    }
}
