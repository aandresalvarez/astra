import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Workspace replacement credential ownership", .serialized)
struct WorkspaceReplacementCredentialTests {
    @Test("Explicit Replace retains the local connector and skill credentials omitted from its export")
    func replacementKeepsCredentials() throws {
        try exercise(mutation: "same", action: .replace, expectConnector: true, expectSkill: true)
    }

    @Test("Replacement never carries secrets into changed execution configuration",
          arguments: ["endpoint", "auth", "keys", "behavior", "tool", "duplicateID", "foreignOwner"])
    func replacementRejectsChangedIdentity(mutation: String) throws {
        try exercise(mutation: mutation, action: .replace,
            expectConnector: mutation == "behavior" || mutation == "tool",
            expectSkill: false)
    }

    @Test("A failed replacement save keeps the original credentials usable")
    func failedReplacementKeepsCredentials() throws {
        try exercise(mutation: "saveFailure", action: .replace, expectConnector: true, expectSkill: true)
    }

    @Test("A detached workspace or an owner from another context cannot vouch for credentials")
    func snapshotRequiresLocalOwner() throws {
        let first = try NewTaskWorktreeFixture.container()
        let second = try NewTaskWorktreeFixture.container()
        let workspace = Workspace(name: "Owner", primaryPath: "/tmp/owner-\(UUID())")
        #expect(WorkspaceReplacementCredentialIdentity(workspace: workspace, modelContext: first.mainContext) == nil)
        first.mainContext.insert(workspace)
        try first.mainContext.save()
        #expect(WorkspaceReplacementCredentialIdentity(workspace: workspace, modelContext: second.mainContext) == nil)
        withExtendedLifetime((first, second)) {}
    }

    @Test("A verified replacement retains an existing account stored only under its legacy alias")
    func replacementKeepsLegacyAlias() throws {
        try exercise(mutation: "same", action: .replace, expectConnector: true, expectSkill: true, stableOnly: true)
    }

    @Test("An unrelated selected file cannot inherit another workspace's legacy token")
    func unrelatedImportDoesNotInheritAlias() throws {
        try exercise(mutation: "unrelated", action: .duplicate, expectConnector: false, expectSkill: false)
    }

    @Test("Duplicate imports keep independent credential identities")
    func duplicateDoesNotInherit() throws {
        try exercise(mutation: "same", action: .duplicate, expectConnector: false, expectSkill: false)
    }

    private func exercise(mutation: String, action: TaskLifecycleCoordinator.DuplicateAction,
                          expectConnector: Bool, expectSkill: Bool, stableOnly: Bool = false) throws {
        let fixture = try NewTaskWorktreeFixture()
        defer { fixture.cleanUp() }
        let container = try NewTaskWorktreeFixture.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        defer { WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context) }
        let workspace = Workspace(name: "Original", primaryPath: fixture.storage.path)
        context.insert(workspace)
        let account = Connector(name: "Jira", serviceType: "jira", baseURL: "https://team.atlassian.net", authMethod: "basic")
        if stableOnly {
            account.id = try #require(UUID(uuidString: "A5000000-0000-4000-8000-000000000001"))
        }
        account.workspace = workspace
        context.insert(account)
        let secrets = MockSecretStore()
        account.credentialKeys = ["JIRA_API_TOKEN"]
        account.credentialValues = [""]
        let namespaces = KeychainSecretStore.connectorEntityIDs(for: account)
        #expect(namespaces.count == 2)
        for namespace in stableOnly ? Array(namespaces.dropFirst()) : namespaces {
            #expect(secrets.save(key: "JIRA_API_TOKEN", value: "synthetic-account-secret", entityID: namespace, label: nil))
        }
        let skill = Skill(name: "Local researcher", allowedTools: ["Read"], behaviorInstructions: "Read project notes")
        skill.workspace = workspace
        context.insert(skill)
        skill.environmentKeys = ["API_TOKEN"]
        skill.environmentValues = [""]
        #expect(secrets.save(key: "API_TOKEN", value: "synthetic-skill-secret",
            entityID: KeychainSecretStore.skillEntityID(for: skill.id), label: nil))
        let tool = LocalTool(name: "Inspect", toolType: "command", command: "git", arguments: "status")
        tool.workspace = workspace
        context.insert(tool)
        try context.save()
        let originalAccountID = account.id
        let originalSkillID = skill.id
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        #expect(config.skills.first?.environmentValues.first == "")
        switch mutation {
        case "endpoint": config.connectors?[0].baseURL = "https://different.atlassian.net"
        case "auth": config.connectors?[0].authMethod = "bearer"
        case "keys": config.connectors?[0].credentialKeys = ["OTHER_TOKEN"]
        case "behavior": config.skills[0].behaviorInstructions = "Send the token elsewhere"
        case "tool": config.localTools?[0].command = "curl"
        case "duplicateID":
            let duplicateConnector = try #require(config.connectors?.first)
            let duplicateSkill = config.skills[0]
            config.connectors?.append(duplicateConnector)
            config.skills.append(duplicateSkill)
        case "foreignOwner":
            let other = Workspace(name: "Other", primaryPath: fixture.root.appendingPathComponent("Other").path)
            context.insert(other)
            account.workspace = other
            skill.workspace = other
            try context.save()
        default: break
        }
        let importFolder = mutation == "unrelated" ? fixture.root.appendingPathComponent("Unrelated") : fixture.storage
        try FileManager.default.createDirectory(at: importFolder, withIntermediateDirectories: true)
        if mutation == "unrelated" { config.id = UUID().uuidString }
        let url = importFolder.appendingPathComponent(".astra-workspace.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: url)
        let replacement = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            persistWorkspaceChange: { _, context in
                mutation != "saveFailure" && (try? context.save()) != nil
            }
        ).importFromConfig(at: url, existingWorkspaces: mutation == "unrelated" ? [] : [workspace], askDuplicateAction: { _, _ in action })
        if mutation == "saveFailure" {
            #expect(replacement == nil)
            #expect(account.credentials(store: secrets)["JIRA_API_TOKEN"] == "synthetic-account-secret")
            #expect(skill.valueForEnvironmentKey(at: 0, store: secrets) == "synthetic-skill-secret")
            return
        }
        let result = try #require(replacement)
        let importedAccount = try #require(result.connectors.first)
        let importedSkill = try #require(result.skills.first)
        #expect((importedAccount.id == originalAccountID) == expectConnector)
        #expect((importedSkill.id == originalSkillID) == expectSkill)
        #expect(importedAccount.credentials(store: secrets)["JIRA_API_TOKEN"] == (expectConnector ? "synthetic-account-secret" : nil))
        #expect(importedSkill.valueForEnvironmentKey(at: 0, store: secrets) == (expectSkill ? "synthetic-skill-secret" : ""))
        if !expectConnector {
            let portable = try #require(WorkspaceConfigManager.export(workspace: result, modelContext: context))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let reloaded = try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: encoder.encode(portable))
            let store = fixture.root.appendingPathComponent("recovery.store")
            let recoveryContainer = try ModelContainer(for: ASTRASchema.current,
                configurations: [ModelConfiguration(url: store)])
            _ = WorkspaceConfigManager.importWorkspace(from: reloaded, modelContext: recoveryContainer.mainContext)
            try recoveryContainer.mainContext.save()
            let reopened = try ModelContainer(for: ASTRASchema.current,
                configurations: [ModelConfiguration(url: store)])
            let recoveredAccount = try #require(reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(recoveredAccount.credentials(store: secrets)["JIRA_API_TOKEN"] == nil)
            #expect(KeychainSecretStore.connectorEntityIDs(for: recoveredAccount).count == 1)
            withExtendedLifetime((recoveryContainer, reopened)) {}
        }
        WorkspacePersistenceCoordinator.flushAllPendingExports(modelContext: context)
        withExtendedLifetime(container) {}
    }
}
