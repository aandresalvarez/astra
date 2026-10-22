import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import HostControlToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Run-bound Outlook access", .serialized)
struct OutlookRuntimeAccessTests {
    @Test("Approval of one account never grants another reachable mailbox or follows live edits")
    func grantsArePerAccount() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let a = Connector(name: "Mailbox Alpha"), b = Connector(name: "Mailbox Beta")
        for account in [a, b] {
            account.applyStanfordOutlookDefaults()
            account.workspace = env.workspace
            account.credentialNamespaceID = UUID()
            account.outlookCredentialFormat = OutlookCredentialIdentity.generationFormat
            env.context.insert(account)
        }
        let task = AgentTask(title: "Recipe", goal: "Bake a chocolate cake", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()
        let scope = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: task.goal).providerLaunch
        #expect(scope.reachableConnectors.filter(\.isStanfordOutlookMail).count == 2)
        #expect(scope.connectors.filter(\.isStanfordOutlookMail).isEmpty)
        let grant = PermissionGrant.credential(label: "connector:\(a.id.uuidString):\(StanfordOutlookMail.accessTokenKey)")
        let captured = StanfordOutlookMailRuntimeAccess.capture(for: task, in: scope, runtime: nil, additionalGrants: [grant])
        let record = PluginAccountRecord(a)
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: task), from: task)
        _ = TaskRuntimePermissionGrants.record(grants: [grant], providerID: .claudeCode,
            task: task, modelContext: env.context, source: "late_preflight")
        #expect(StanfordOutlookMailRuntimeAccess.capture(for: detached, in: scope,
            runtime: .claudeCode, additionalGrants: []).accounts.isEmpty)
        #expect(StanfordOutlookMailRuntimeAccess.capture(for: task, in: scope,
            runtime: .claudeCode, additionalGrants: []).accounts.map(\.id) == [a.id])
        a.credentialNamespaceID = UUID()
        #expect(captured.accounts == [record])
        #expect(captured.withheldAccountCount == 1)
        #expect(HostControlPlaneMCPProjection.offeredToolNames(capabilityScope: scope).contains("mail"))
        #expect(!HostControlPlaneMCPProjection.requiredToolNames(capabilityScope: scope).contains("mail"))
        let environment = AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task, capabilityScope: scope)
        #expect(environment["ASTRA_MAIL_REGISTRY_PATH"] == nil)
        #expect(environment["ASTRA_CONNECTORS"] == nil)
    }

    @Test("A mail tool declaration alone grants no account access")
    func toolCannotAuthorizeAccounts() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let account = Connector(name: "Unrelated mailbox")
        account.applyStanfordOutlookDefaults()
        account.workspace = env.workspace
        let tool = LocalTool(name: "Zenith", command: StanfordOutlookMail.toolCommand)
        tool.workspace = env.workspace
        let task = AgentTask(title: "Use Zenith", goal: "Use Zenith", workspace: env.workspace)
        for model in [account, tool, task] as [any PersistentModel] { env.context.insert(model) }
        try env.context.save()
        let scope = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: task.goal).providerLaunch
        #expect(scope.localTools.contains { $0.id == tool.id })
        let captured = StanfordOutlookMailRuntimeAccess.capture(for: task, in: scope, runtime: nil, additionalGrants: [])
        #expect(captured.accounts.isEmpty)
        #expect(captured.withheldAccountCount == 1)
    }
}
