import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

// Phase 3: runtime projection robustness — credential-presence reporting,
// legacy bare env-name fallback boundaries, and detached-snapshot lifetime.

private func makeRobustnessContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Connector Credential Presence")
@MainActor
struct ConnectorCredentialPresenceTests {

    @Test("Connectors with unloadable declared credentials are reported by key name")
    func missingCredentialsReported() throws {
        let container = try makeRobustnessContainer()
        let store = MockSecretStore()
        let configured = Connector(
            name: "Jira A", serviceType: "jira", icon: "j",
            connectorDescription: "d", baseURL: "https://a.example.com", authMethod: "basic"
        )
        configured.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        let broken = Connector(
            name: "Jira B", serviceType: "jira", icon: "j",
            connectorDescription: "d", baseURL: "https://b.example.com", authMethod: "basic"
        )
        broken.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        container.mainContext.insert(configured)
        container.mainContext.insert(broken)
        let configuredEntity = KeychainSecretStore.connectorEntityID(for: configured.id)
        _ = store.save(key: "JIRA_EMAIL", value: "a@example.com", entityID: configuredEntity, label: nil)
        _ = store.save(key: "JIRA_API_TOKEN", value: "token", entityID: configuredEntity, label: nil)
        let brokenEntity = KeychainSecretStore.connectorEntityID(for: broken.id)
        _ = store.save(key: "JIRA_EMAIL", value: "b@example.com", entityID: brokenEntity, label: nil)

        let projection = ConnectorRuntimeProjection(connectors: [configured, broken], secretStore: store)
        let missing = projection.missingCredentialKeysByConnector()

        #expect(missing.count == 1)
        #expect(missing.first?.connector.id == broken.id)
        #expect(missing.first?.missingKeys == ["JIRA_API_TOKEN"])
    }

    @Test("Fully configured connectors report nothing missing")
    func configuredConnectorsReportNothing() throws {
        let container = try makeRobustnessContainer()
        let store = MockSecretStore()
        let connector = Connector(
            name: "REDCap", serviceType: "redcap", icon: "t",
            connectorDescription: "d", baseURL: "https://redcap.example.com", authMethod: "api_key"
        )
        connector.credentialKeys = ["REDCAP_API_TOKEN"]
        container.mainContext.insert(connector)
        _ = store.save(
            key: "REDCAP_API_TOKEN",
            value: "tok",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )

        let projection = ConnectorRuntimeProjection(connectors: [connector], secretStore: store)
        #expect(projection.missingCredentialKeysByConnector().isEmpty)
    }

    @Test("Stable connector namespace is enough for runtime projection")
    func stableNamespaceCountsAsConfigured() throws {
        let container = try makeRobustnessContainer()
        let store = MockSecretStore()
        let connector = Connector(
            name: "Jira", serviceType: "jira", icon: "j",
            connectorDescription: "d", baseURL: "https://stanfordmed.atlassian.net", authMethod: "basic"
        )
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        container.mainContext.insert(connector)
        let stableEntityID = try #require(KeychainSecretStore.stableConnectorEntityID(for: connector))
        _ = store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: stableEntityID, label: nil)
        _ = store.save(key: "JIRA_API_TOKEN", value: "secret-token", entityID: stableEntityID, label: nil)

        let projection = ConnectorRuntimeProjection(connectors: [connector], secretStore: store)
        let environment = projection.environmentVariables()

        #expect(projection.missingCredentialKeysByConnector().isEmpty)
        #expect(environment.values.contains("user@example.com"))
        #expect(environment.values.contains("secret-token"))
    }
}

@Suite("Legacy Env Fallback Boundaries")
@MainActor
struct LegacyEnvFallbackTests {

    @Test("Single connector per service omits bare legacy names unless explicitly requested")
    func bareNamesRequireExplicitLegacyOptIn() throws {
        let container = try makeRobustnessContainer()
        let store = MockSecretStore()

        func jiraConnector(name: String, host: String) -> Connector {
            let connector = Connector(
                name: name, serviceType: "jira", icon: "j",
                connectorDescription: "d", baseURL: host, authMethod: "basic"
            )
            connector.credentialKeys = ["JIRA_API_TOKEN"]
            container.mainContext.insert(connector)
            _ = store.save(
                key: "JIRA_API_TOKEN",
                value: "tok-\(name)",
                entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
                label: nil
            )
            return connector
        }

        let solo = jiraConnector(name: "Solo Jira", host: "https://solo.example.com")
        let single = ConnectorRuntimeProjection(connectors: [solo], secretStore: store)
            .environmentVariables()
        #expect(single["JIRA_API_TOKEN"] == nil)
        #expect(single.keys.contains { $0.hasSuffix("_JIRA_API_TOKEN") })

        let legacySingle = ConnectorRuntimeProjection(connectors: [solo], secretStore: store)
            .environmentVariables(includeLegacySingleConnectorFallback: true)
        #expect(legacySingle["JIRA_API_TOKEN"] == "tok-Solo Jira")

        let second = jiraConnector(name: "Second Jira", host: "https://second.example.com")
        let dual = ConnectorRuntimeProjection(connectors: [solo, second], secretStore: store)
            .environmentVariables()
        // With two connectors of one service, the bare name must disappear
        // rather than silently rebind to either connector.
        #expect(dual["JIRA_API_TOKEN"] == nil)
        #expect(dual.keys.filter { $0.hasSuffix("_API_TOKEN") && $0 != "JIRA_API_TOKEN" }.count == 2)
    }
}

@Suite("Detached Snapshot Lifetime")
@MainActor
struct DetachedSnapshotLifetimeTests {

    @Test("Fresh-run refresh drops snapshots of deleted skills and keeps live ones")
    func freshRunRefreshDropsDetached() throws {
        let container = try makeRobustnessContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Snapshot", goal: "g")
        context.insert(task)
        let keep = Skill(name: "Keeper", allowedTools: ["Read"], disallowedTools: [], behaviorInstructions: "stay")
        let doomed = Skill(name: "Doomed", allowedTools: ["Read"], disallowedTools: [], behaviorInstructions: "leave")
        context.insert(keep)
        context.insert(doomed)
        task.skills = [keep, doomed]
        TaskCapabilitySnapshotter.capture(for: task)
        #expect(task.skillSnapshots.count == 2)

        // Delete one skill after capture: its snapshot is now detached.
        task.skills = [keep]
        context.delete(doomed)

        let dropped = TaskCapabilitySnapshotter.refreshForFreshRun(task: task)
        #expect(dropped == ["Doomed"])
        #expect(task.skillSnapshots.map(\.name) == ["Keeper"])
    }

    @Test("Refresh with no detached snapshots drops nothing")
    func refreshKeepsLiveSnapshots() throws {
        let container = try makeRobustnessContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Stable", goal: "g")
        context.insert(task)
        let skill = Skill(name: "Stable Skill", allowedTools: ["Read"], disallowedTools: [], behaviorInstructions: "b")
        context.insert(skill)
        task.skills = [skill]
        TaskCapabilitySnapshotter.capture(for: task)

        let dropped = TaskCapabilitySnapshotter.refreshForFreshRun(task: task)
        #expect(dropped.isEmpty)
        #expect(task.skillSnapshots.map(\.name) == ["Stable Skill"])
    }
}
