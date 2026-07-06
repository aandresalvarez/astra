import Testing
import Foundation
import SwiftData
import ASTRAModels
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
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll() // connector.credentials(store:) needs ConnectorSecretSeam

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

        let projection = ConnectorRuntimeProjection(
            connectors: [connector],
            secretStore: store,
            credentialExposurePolicy: .approvedLabels([
                ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_EMAIL"),
                ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_API_TOKEN")
            ])
        )
        let environment = projection.environmentVariables()

        #expect(projection.missingCredentialKeysByConnector().isEmpty)
        #expect(environment.values.contains("user@example.com"))
        #expect(environment.values.contains("secret-token"))
    }

    @Test("HTTP connector credentials are withheld until their label is approved")
    func httpConnectorCredentialsRequireApprovedLabel() throws {
        let container = try makeRobustnessContainer()
        let store = MockSecretStore()
        let connector = Connector(
            name: "Jira", serviceType: "jira", icon: "j",
            connectorDescription: "d", baseURL: "https://stanfordmed.atlassian.net", authMethod: "basic"
        )
        connector.credentialKeys = ["JIRA_API_TOKEN"]
        container.mainContext.insert(connector)
        _ = store.save(
            key: "JIRA_API_TOKEN",
            value: "secret-token",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )

        let label = ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_API_TOKEN")
        let withheld = ConnectorRuntimeProjection(connectors: [connector], secretStore: store)
        let approved = ConnectorRuntimeProjection(
            connectors: [connector],
            secretStore: store,
            credentialExposurePolicy: .approvedLabels([label])
        )

        #expect(withheld.environmentVariables()["JIRA_JIRA_API_TOKEN"] == nil)
        #expect(withheld.unapprovedCredentialLabelsRequiringApproval() == [label])
        #expect(approved.environmentVariables()["JIRA_JIRA_API_TOKEN"] == "secret-token")
        #expect(approved.unapprovedCredentialLabelsRequiringApproval().isEmpty)
    }

    @Test("Non-HTTP connector credentials are withheld by default even for local service names")
    func nonHTTPConnectorCredentialsFailClosedByDefault() throws {
        let container = try makeRobustnessContainer()
        let store = MockSecretStore()
        let connector = Connector(
            name: "Forged Local Cloud", serviceType: "gcloud", icon: "cloud",
            connectorDescription: "d", baseURL: "", authMethod: "api_key"
        )
        connector.credentialKeys = ["GCLOUD_TOKEN"]
        container.mainContext.insert(connector)
        _ = store.save(
            key: "GCLOUD_TOKEN",
            value: "secret-token",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )

        let label = ConnectorRuntimeProjection.credentialLabel(for: connector, key: "GCLOUD_TOKEN")
        let withheld = ConnectorRuntimeProjection(connectors: [connector], secretStore: store)
        let explicitCompatibility = ConnectorRuntimeProjection(
            connectors: [connector],
            secretStore: store,
            credentialExposurePolicy: .approvedLabels(
                [],
                allowUnapprovedNonHTTPConnectorCredentials: true
            )
        )

        #expect(!withheld.environmentVariables().values.contains("secret-token"))
        #expect(withheld.unapprovedCredentialLabelsRequiringApproval() == [label])
        #expect(explicitCompatibility.environmentVariables().values.contains("secret-token"))
    }
}

@Suite("Legacy Env Fallback Boundaries")
@MainActor
struct LegacyEnvFallbackTests {
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll() // connector.credentials(store:) needs ConnectorSecretSeam

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
        let policy = ConnectorRuntimeProjection.CredentialExposurePolicy.approvedLabels([
            ConnectorRuntimeProjection.credentialLabel(for: solo, key: "JIRA_API_TOKEN")
        ])
        let single = ConnectorRuntimeProjection(connectors: [solo], secretStore: store, credentialExposurePolicy: policy)
            .environmentVariables()
        #expect(single["JIRA_API_TOKEN"] == nil)
        #expect(single.keys.contains { $0.hasSuffix("_JIRA_API_TOKEN") })

        let legacySingle = ConnectorRuntimeProjection(connectors: [solo], secretStore: store, credentialExposurePolicy: policy)
            .environmentVariables(includeLegacySingleConnectorFallback: true)
        #expect(legacySingle["JIRA_API_TOKEN"] == "tok-Solo Jira")

        let second = jiraConnector(name: "Second Jira", host: "https://second.example.com")
        let dualPolicy = ConnectorRuntimeProjection.CredentialExposurePolicy.approvedLabels([
            ConnectorRuntimeProjection.credentialLabel(for: solo, key: "JIRA_API_TOKEN"),
            ConnectorRuntimeProjection.credentialLabel(for: second, key: "JIRA_API_TOKEN")
        ])
        let dual = ConnectorRuntimeProjection(connectors: [solo, second], secretStore: store, credentialExposurePolicy: dualPolicy)
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
