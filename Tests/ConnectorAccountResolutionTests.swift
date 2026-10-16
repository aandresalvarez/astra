import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Two accounts of one service in a workspace: the task or the workspace picks
/// one, and only that one is narrated to the agent (Plugins 2.0 phase 1).
@Suite("Connector account resolution")
@MainActor
struct ConnectorAccountResolutionTests {
    @Test("An alias named in the task picks that account")
    func aliasInTextPicksAccount() {
        let (stanford, personal) = twoJiraAccounts()
        let resolution = ConnectorAccountResolver.resolve(
            [stanford, personal],
            contextText: "Download the SS tickets from the Stanford Jira",
            activation: nil
        )
        #expect(resolution.connectors.map(\.id) == [stanford.id])
        #expect(resolution.excludedConnectorIDs == [personal.id])
    }

    @Test("The service word alone names no account, so both stay in scope")
    func serviceWordNamesNothing() {
        let first = jira(name: "Jira")
        let second = jira(name: "Jira-new")
        let resolution = ConnectorAccountResolver.resolve(
            [first, second],
            contextText: "Download the SS tickets from Jira",
            activation: nil
        )
        #expect(resolution.connectors.map(\.id) == [first.id, second.id])
        #expect(resolution.excludedConnectorIDs.isEmpty)
    }

    @Test("Naming both accounts keeps both, even when one name's words are adjacent")
    func namingBothAccountsKeepsBoth() {
        let eng = jira(name: "Eng Jira")
        let ops = jira(name: "Ops Jira")
        let resolution = ConnectorAccountResolver.resolve(
            [eng, ops], contextText: "Compare ENG and OPS Jira work queues", activation: nil
        )
        #expect(resolution.connectors.map(\.id) == [eng.id, ops.id])

        let onlyOps = ConnectorAccountResolver.resolve(
            [eng, ops], contextText: "List the OPS Jira queue", activation: nil
        )
        #expect(onlyOps.connectors.map(\.id) == [ops.id])
    }

    @Test("Without a name in the task, the workspace default decides")
    func workspaceDefaultDecides() {
        let (stanford, personal) = twoJiraAccounts()
        var activation = WorkspaceCapabilityActivationState()
        activation.setDefaultAccount(personal.id.uuidString, forService: "jira")
        let resolution = ConnectorAccountResolver.resolve(
            [stanford, personal],
            contextText: "Summarise this week's Jira tickets",
            activation: activation
        )
        #expect(resolution.connectors.map(\.id) == [personal.id])
    }

    @Test("A named account beats the default, and the default breaks a tie between named accounts")
    func namedBeatsDefaultAndDefaultBreaksTies() {
        let (stanford, personal) = twoJiraAccounts()
        var activation = WorkspaceCapabilityActivationState()
        activation.setDefaultAccount(personal.id.uuidString, forService: "jira")

        let named = ConnectorAccountResolver.resolve(
            [stanford, personal], contextText: "Use the stanford account", activation: activation
        )
        #expect(named.connectors.map(\.id) == [stanford.id])

        let both = ConnectorAccountResolver.resolve(
            [stanford, personal], contextText: "Compare stanford and personal", activation: activation
        )
        #expect(both.connectors.map(\.id) == [personal.id])
    }

    @Test("With no name and no default every account stays in scope")
    func noSignalKeepsEveryAccount() {
        let (stanford, personal) = twoJiraAccounts()
        let resolution = ConnectorAccountResolver.resolve(
            [stanford, personal], contextText: "Read Jira", activation: WorkspaceCapabilityActivationState()
        )
        #expect(resolution.connectors.count == 2)
    }

    @Test("A two-account Jira workspace launches with the chosen account only")
    func twoAccountWorkspaceLaunchesWithChosenAccount() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Two Jira Accounts", primaryPath: "/tmp/two-jira-accounts")
        context.insert(workspace)
        let (stanford, personal) = twoJiraAccounts()
        for connector in [stanford, personal] {
            connector.workspace = workspace
            context.insert(connector)
        }
        let task = AgentTask(title: "Export", goal: "Export the SS tickets", workspace: workspace)
        context.insert(task)
        try context.save()

        let named = TaskCapabilityResolver(task: task).promptScope(contextText: "Export the SS tickets from Stanford")
        #expect(named.connectors.map(\.id) == [stanford.id])

        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.setDefaultAccount(personal.id.uuidString, forService: "jira")
        }
        let defaulted = TaskCapabilityResolver(task: task).promptScope(contextText: "Export the SS tickets from Jira")
        #expect(defaulted.connectors.map(\.id) == [personal.id])
        #expect(Set(defaulted.reachableConnectors.map(\.id)) == [stanford.id, personal.id])
        withExtendedLifetime(container) {}
    }

    @Test("Naming one account excludes its siblings even when a shared skill would bring them back")
    func namingOneAccountExcludesSkillSiblings() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Shared Jira Skill", primaryPath: "/tmp/shared-jira-skill")
        context.insert(workspace)
        let skill = Skill(name: "Jira Agent", icon: "ticket", skillDescription: "", behaviorInstructions: "Help.")
        skill.workspace = workspace
        context.insert(skill)
        let (stanford, personal) = twoJiraAccounts()
        for connector in [stanford, personal] {
            connector.workspace = workspace
            connector.skill = skill
            context.insert(connector)
        }
        let task = AgentTask(title: "Export", goal: "Export the SS tickets", workspace: workspace)
        context.insert(task)
        task.skills = [skill]
        try context.save()

        let named = TaskCapabilityResolver(task: task).promptScope(contextText: "Export the SS tickets from Stanford")
        #expect(named.connectors.map(\.id) == [stanford.id])
        // Still reachable, but not offered to the agent as "also connected".
        #expect(named.reachableConnectors.contains { $0.id == personal.id })
        #expect(!named.reachableButNotNarratedConnectors.contains { $0.id == personal.id })
        withExtendedLifetime(container) {}
    }

    @Test("Copying an account keeps its alias, and a workspace copy takes over as the default")
    func copiesKeepTheAccountIdentity() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Copies", primaryPath: "/tmp/account-copies")
        context.insert(workspace)
        let (shared, _) = twoJiraAccounts()
        shared.isGlobal = true
        context.insert(shared)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableGlobalConnector(shared.id.uuidString)
            $0.setDefaultAccount(shared.id.uuidString, forService: "jira")
        }

        let copy = CapabilitySharing.duplicateForWorkspace(shared, in: workspace, secretStore: NoSecrets())
        #expect(copy.accountAlias == "Stanford")
        #expect(workspace.capabilityActivation.defaultAccountID(forService: "jira") == copy.id.uuidString)

        let snapshot = ConnectorSnapshotConfig(connector: shared)
        let decoded = try JSONDecoder().decode(ConnectorSnapshotConfig.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.accountAlias == "Stanford")
        let legacy = #"{"name":"Jira","serviceType":"jira","icon":"","description":"","baseURL":"","authMethod":"none","credentialKeys":[],"configKeys":[],"configValues":[],"notes":""}"#
        #expect(try JSONDecoder().decode(ConnectorSnapshotConfig.self, from: Data(legacy.utf8)).accountAlias == nil)

        let share = ShareConnector(
            name: "Jira", serviceType: "jira", icon: "", description: "", baseURL: "", authMethod: "none",
            credentialKeys: [], configKeys: [], notes: "", accountAlias: "Stanford"
        )
        #expect(try JSONDecoder().decode(ShareConnector.self, from: JSONEncoder().encode(share)).accountAlias == "Stanford")
        withExtendedLifetime(container) {}
    }

    @Test("An account alias becomes the agent's alias and survives a rename")
    func accountAliasDrivesRuntimeAlias() {
        let (stanford, personal) = twoJiraAccounts()
        let before = ConnectorRuntimeProjection.aliasesByConnectorID(for: [stanford, personal])
        stanford.name = "Renamed connector"
        let after = ConnectorRuntimeProjection.aliasesByConnectorID(for: [stanford, personal])
        #expect(before[stanford.id] == "stanford")
        #expect(after[stanford.id] == "stanford")
        #expect(after[personal.id] == "personal")
    }

    @Test("Account alias and default account survive the workspace mirror")
    func accountChoicesSurviveTheMirror() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Mirror", primaryPath: "/tmp/account-mirror-\(UUID().uuidString)")
        context.insert(workspace)
        let (stanford, personal) = twoJiraAccounts()
        for connector in [stanford, personal] {
            connector.workspace = workspace
            context.insert(connector)
        }
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.setDefaultAccount(personal.id.uuidString, forService: "jira")
        }
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        context.delete(workspace)
        try context.save()
        let restored = WorkspaceConfigManager.importWorkspace(
            from: config, modelContext: context, capabilityTrust: .preserveRecordedState
        )

        #expect(Set(restored.connectors.compactMap(\.accountAlias)) == ["Stanford", "Personal"])
        #expect(WorkspaceCapabilityActivation.state(of: restored).defaultAccountID(forService: "jira") == personal.id.uuidString)
        withExtendedLifetime(container) {}
    }

    // MARK: - Fixtures

    private func twoJiraAccounts() -> (Connector, Connector) {
        let stanford = jira(name: "Jira (work)")
        stanford.accountAlias = "Stanford"
        let personal = jira(name: "Jira (home)")
        personal.accountAlias = "Personal"
        return (stanford, personal)
    }

    private func jira(name: String) -> Connector {
        Connector(name: name, serviceType: "jira", baseURL: "https://\(UUID().uuidString.prefix(8)).atlassian.net/", authMethod: "none")
    }
}

private final class NoSecrets: SecretStore {
    func load(key: String, entityID: String) -> String? { nil }
    func save(key: String, value: String, entityID: String, label: String?) -> Bool { true }
    func delete(key: String, entityID: String) -> Bool { true }
    func deleteAll(entityID: String) {}
    func exists(key: String, entityID: String) -> Bool { false }
}
