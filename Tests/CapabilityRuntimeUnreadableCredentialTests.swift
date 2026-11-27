import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// A saved key that this build of ASTRA is refused when it reads it, as every
/// key is after an ad-hoc rebuild until it is saved again.
private final class RefusingSecretStore: SecretStore {
    let saved = MockSecretStore()
    var refused: Set<String> = []

    func read(key: String, entityID: String) -> SecretReadOutcome {
        refused.contains(entityID) ? .unavailable : saved.read(key: key, entityID: entityID)
    }

    func load(key: String, entityID: String) -> String? {
        refused.contains(entityID) ? nil : saved.load(key: key, entityID: entityID)
    }

    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool {
        saved.save(key: key, value: value, entityID: entityID, label: label)
    }

    @discardableResult
    func delete(key: String, entityID: String) -> Bool {
        saved.delete(key: key, entityID: entityID)
    }

    func deleteAll(entityID: String) {
        saved.deleteAll(entityID: entityID)
    }

    func exists(key: String, entityID: String) -> Bool {
        saved.exists(key: key, entityID: entityID)
    }
}

@Suite("CapabilityRuntimeUnreadableCredentialTests")
@MainActor
struct CapabilityRuntimeUnreadableCredentialTests {
    private struct Fixture {
        let container: ModelContainer
        let task: AgentTask
        let jira: Connector
        let package: PluginPackage
    }

    private func makeFixture(goal: String) throws -> Fixture {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Locked Jira", primaryPath: "/tmp/locked-jira")
        workspace.testEnabledCapabilityIDs = [package.id]
        context.insert(workspace)

        let jira = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Configured shared Jira",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        jira.isGlobal = true
        jira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        workspace.enabledGlobalConnectorIDs = [jira.id.uuidString]
        context.insert(jira)

        let task = AgentTask(title: "Request", goal: goal, workspace: workspace)
        context.insert(task)
        try context.save()
        return Fixture(container: container, task: task, jira: jira, package: package)
    }

    /// Saved values for every key, refused on every namespace the connector reads.
    private func lockedStore(for connector: Connector) -> RefusingSecretStore {
        let store = RefusingSecretStore()
        for entityID in KeychainSecretStore.connectorEntityIDs(for: connector) {
            store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: entityID, label: nil)
            store.save(key: "JIRA_API_TOKEN", value: "token", entityID: entityID, label: nil)
            store.refused.insert(entityID)
        }
        return store
    }

    @Test("A key the Keychain refuses to read is reported as unreadable, not missing")
    func unreadableKeyIsNotReportedMissing() throws {
        let fixture = try makeFixture(goal: "List Jira tickets")

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: fixture.task,
            packages: [fixture.package],
            checkExecutables: false,
            secretStore: lockedStore(for: fixture.jira)
        )

        let issue = try #require(issues.first { $0.resourceKind == .credential })
        #expect(issue.resourceName == "Jira-new")
        #expect(issue.message == "connector Jira-new has Keychain values ASTRA could not read: "
            + "JIRA_EMAIL, JIRA_API_TOKEN. Retry; if it keeps failing after ASTRA was rebuilt or updated, "
            + "enter them again in Connectors and save before testing")
    }

    @Test("A key absent on one connector and refused on another keeps the recovery step")
    func mixedConnectorsKeepTheRefusedKeys() throws {
        let fixture = try makeFixture(goal: "List Jira tickets")
        let context = fixture.container.mainContext
        let stale = Connector(
            name: "Jira-old",
            serviceType: "jira",
            connectorDescription: "Old local Jira row",
            baseURL: "https://other.atlassian.net",
            authMethod: "basic"
        )
        stale.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        stale.workspace = fixture.task.workspace
        context.insert(stale)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: fixture.task,
            packages: [fixture.package],
            checkExecutables: false,
            secretStore: lockedStore(for: fixture.jira)
        )

        let issue = try #require(issues.first { $0.resourceKind == .credential })
        #expect(issue.message.contains("are missing Keychain values: JIRA_API_TOKEN, JIRA_EMAIL"))
        #expect(issue.message.contains("have Keychain values ASTRA could not read: JIRA_API_TOKEN, JIRA_EMAIL"))
    }

    @Test("A launch that leaves the connector out does not fail over its unreadable key")
    func unreadableKeyOfConnectorOutsideLaunchDoesNotBlock() throws {
        // The package is checked for this request (its text says "tickets"),
        // but nothing in the request names the Jira account.
        let goal = "Summarize my open support tickets"
        let fixture = try makeFixture(goal: goal)
        let scope = TaskCapabilityResolutionScope.providerLaunch(contextText: goal)
        let launch = TaskCapabilityResolutionSnapshot.capture(for: fixture.task, providerLaunchContextText: goal)
        #expect(!launch.providerLaunch.connectors.contains { $0.id == fixture.jira.id })

        // The same launch with the key truly absent still fails, so the
        // package is checked here.
        let absent = CapabilityRuntimeIntegrityService.issues(
            for: fixture.task,
            packages: [fixture.package],
            checkExecutables: false,
            scope: scope,
            capabilityResolutionSnapshot: launch,
            secretStore: MockSecretStore()
        )
        #expect(absent.contains { $0.resourceKind == .credential })

        let locked = CapabilityRuntimeIntegrityService.issues(
            for: fixture.task,
            packages: [fixture.package],
            checkExecutables: false,
            scope: scope,
            capabilityResolutionSnapshot: launch,
            secretStore: lockedStore(for: fixture.jira)
        )
        #expect(!locked.contains { $0.resourceKind == .credential })
    }

    @Test("A launch that hands the connector to the agent still fails over its unreadable key")
    func unreadableKeyOfConnectorInLaunchBlocks() throws {
        let goal = "List Jira tickets in Jira-new"
        let fixture = try makeFixture(goal: goal)
        let launch = TaskCapabilityResolutionSnapshot.capture(for: fixture.task, providerLaunchContextText: goal)
        #expect(launch.providerLaunch.connectors.contains { $0.id == fixture.jira.id })

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: fixture.task,
            packages: [fixture.package],
            checkExecutables: false,
            scope: .providerLaunch(contextText: goal),
            capabilityResolutionSnapshot: launch,
            secretStore: lockedStore(for: fixture.jira)
        )

        let issue = try #require(issues.first { $0.resourceKind == .credential })
        #expect(issue.message.contains("could not read: JIRA_EMAIL, JIRA_API_TOKEN"))
    }

    @Test("A key that is absent on one namespace and refused on another counts as unreadable")
    func refusedNamespaceOutranksAbsentOne() throws {
        let fixture = try makeFixture(goal: "List Jira tickets")
        let entityIDs = KeychainSecretStore.connectorEntityIDs(for: fixture.jira)
        try #require(entityIDs.count == 2)
        let store = RefusingSecretStore()
        store.refused.insert(entityIDs[1])

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: fixture.task,
            packages: [fixture.package],
            checkExecutables: false,
            secretStore: store
        )

        let issue = try #require(issues.first { $0.resourceKind == .credential })
        #expect(issue.message.contains("could not read"))
        #expect(!issue.message.contains("missing"))
    }
}
