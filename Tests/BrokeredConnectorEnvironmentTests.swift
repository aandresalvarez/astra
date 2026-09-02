import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private func makeBrokeredConnectorEnvironmentContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

/// The launch environment is the last place a brokered credential could still
/// escape into the agent process, so these are enforcement tests rather than
/// behaviour tests: they assert an absence, and the absence has to hold under
/// the conditions that previously produced an exception.
@Suite("Brokered connector environment")
@MainActor
struct BrokeredConnectorEnvironmentTests {
    private func makeREDCapTask(in context: ModelContext) throws -> (AgentTask, Connector) {
        let workspace = Workspace(name: "Attestation Workspace", primaryPath: "/tmp/brokered-env-workspace")
        context.insert(workspace)

        let connector = Connector(
            name: "Study REDCap",
            serviceType: "redcap",
            connectorDescription: "Study project",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        connector.workspace = workspace
        // Shaped like the connector the setup flow builds: the endpoint is
        // config, the token is a declared credential resolved from the
        // Keychain (which a test process cannot write to, hence the config
        // value below carrying the observable payload).
        connector.configKeys = ["REDCAP_API_URL"]
        connector.configValues = ["https://redcap.example.edu/api/"]
        connector.credentialKeys = ["REDCAP_API_TOKEN"]
        context.insert(connector)

        let task = AgentTask(
            title: "Data privacy attestation",
            goal: "Check the attestation status of the study project",
            workspace: workspace
        )
        context.insert(task)
        try context.save()
        return (task, connector)
    }

    @Test("A brokered connector declares keys that the launch environment does not carry")
    func brokeredConnectorKeysAreAbsentFromTheLaunchEnvironment() throws {
        let container = try makeBrokeredConnectorEnvironmentContainer()
        let context = container.mainContext
        let (task, connector) = try makeREDCapTask(in: context)

        let scope = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: "").providerLaunch
        #expect(scope.connectors.map(\.id) == [connector.id])
        let declaredKeys = ConnectorRuntimeProjection(connectors: [connector])
            .declaredEnvironmentBindingKeys()

        // Without this the absence below proves nothing: the resolver does
        // project this connector's values, and the strip is what removes them.
        let resolved = scope.resolver.resolvedEnvironmentVariables
        #expect(resolved["REDCAP_STUDY_REDCAP_API_URL"] == "https://redcap.example.edu/api/")

        let environment = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: task,
            capabilityScope: scope
        )
        for key in declaredKeys {
            #expect(environment[key] == nil, "Brokered key survived into the launch environment: \(key)")
        }
        // The manifest is a second route to the same values, so pruning the
        // keys without pruning the manifest would move the leak, not close it.
        #expect(environment["ASTRA_CONNECTORS"]?.contains(connector.id.uuidString.lowercased()) != true)
        #expect(environment["ASTRA_CONNECTORS"]?.contains("redcap.example.edu") != true)
    }

    /// `scopedEnvironmentVariables` only ever saw the capability overlay, and
    /// that is not what the child process gets. Every adapter builds its own
    /// environment starting from `RuntimeProcessEnvironment.enriched`, which
    /// starts from `ProcessInfo.processInfo.environment` — so a brokered key
    /// exported in the shell that launched ASTRA was inherited straight past the
    /// strip. Six adapters, one plan: the plan is where it has to be caught.
    @Test("The assembled launch plan drops brokered keys ASTRA itself inherited")
    func launchPlanDropsInheritedBrokeredKeys() throws {
        let container = try makeBrokeredConnectorEnvironmentContainer()
        let context = container.mainContext
        let (task, connector) = try makeREDCapTask(in: context)

        let scope = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: "").providerLaunch
        let brokeredKey = try #require(
            ConnectorRuntimeProjection(connectors: [connector]).declaredEnvironmentBindingKeys().first
        )

        let plan = AgentRuntimeProcessLaunchPlan(
            runtime: .codexCLI,
            executablePath: "/opt/homebrew/bin/codex",
            arguments: ["run"],
            currentDirectory: "/tmp/astra-workspace",
            // As if the developer had this exported in the shell they launched
            // ASTRA from. Nothing in the capability overlay put it here.
            environment: ["HOME": "/tmp/astra-home", brokeredKey: "inherited-secret-value"],
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: true
        )

        let stripped = plan.strippingBrokeredConnectorEnvironment(capabilityScope: scope)

        #expect(stripped.environment[brokeredKey] == nil)
        #expect(stripped.environment["HOME"] == "/tmp/astra-home")
        #expect(stripped.commandPlannedFields["brokered_env_keys_stripped_at_launch"] == "1")

        // Idempotent, and a clean plan is returned untouched rather than rebuilt.
        let again = stripped.strippingBrokeredConnectorEnvironment(capabilityScope: scope)
        #expect(again.environment == stripped.environment)
    }

    /// The regression this exists for: stripping used to be conditional on the
    /// run having host-control tools. A runtime that could not mount the broker
    /// therefore got the raw credential as a silent fallback - the one case
    /// where the agent is least able to use it safely.
    @Test("Credentials stay stripped when the broker tool is not delivered to the runtime")
    func credentialsStayStrippedWhenTheBrokerToolIsNotDelivered() throws {
        let container = try makeBrokeredConnectorEnvironmentContainer()
        let context = container.mainContext
        let (task, connector) = try makeREDCapTask(in: context)

        let scope = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: "").providerLaunch
        let environment = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: task,
            capabilityScope: scope,
            runtimeRequirements: TaskRuntimeRequirementSet(
                hostControlTools: [],
                requiresDockerWorkspaceShell: false,
                requiresBrowserControl: false
            )
        )

        for key in ConnectorRuntimeProjection(connectors: [connector]).declaredEnvironmentBindingKeys() {
            #expect(environment[key] == nil, "Brokered key survived a run without host-control tools: \(key)")
        }
    }

    /// The 09:18 manifest from the incident listed `JIRA_JIRA_NEW_API_TOKEN`
    /// for a run that had already had it stripped. An exposure report that
    /// overstates is as useless as one that understates: both mean the reader
    /// cannot use it to answer "what did this run hold".
    @Test("The permission manifest reports the stripped environment and names the broker's credentials")
    func permissionManifestReportsTheStrippedEnvironment() throws {
        let container = try makeBrokeredConnectorEnvironmentContainer()
        let context = container.mainContext
        let (task, connector) = try makeREDCapTask(in: context)
        let run = TaskRun(task: task)
        context.insert(run)
        try context.save()

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: "/tmp/brokered-env-workspace",
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        for key in ConnectorRuntimeProjection(connectors: [connector]).declaredEnvironmentBindingKeys() {
            #expect(!manifest.environmentKeyNames.contains(key), "Manifest reported a stripped key: \(key)")
        }
        // Nothing to echo, so the connector-manifest shell probe must not be
        // allowed either.
        #expect(!manifest.environmentKeyNames.contains("ASTRA_CONNECTORS"))
        #expect(!manifest.providerRender.allowedShellPatterns.contains(#"echo "$ASTRA_CONNECTORS""#))

        // The credential is still reportable - the run can use it - but only
        // as something ASTRA holds.
        #expect(manifest.brokeredCredentialLabels == [
            "connector:\(connector.id.uuidString):REDCAP_API_TOKEN"
        ])
        #expect(PolicySummaryPresentation.brokeredCredentialsFactValue(manifest) != "None")
    }

    @Test("An unbrokered connector keeps its environment projection")
    func unbrokeredConnectorKeepsItsEnvironmentProjection() throws {
        let container = try makeBrokeredConnectorEnvironmentContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Unbrokered Workspace", primaryPath: "/tmp/unbrokered-env-workspace")
        context.insert(workspace)
        let connector = Connector(
            name: "Study Portal",
            serviceType: "custom_http",
            connectorDescription: "A service ASTRA has no broker for",
            baseURL: "https://portal.example.edu",
            authMethod: "api_key"
        )
        connector.workspace = workspace
        connector.configKeys = ["PORTAL_BASE_URL"]
        connector.configValues = ["https://portal.example.edu"]
        context.insert(connector)
        let task = AgentTask(
            title: "Read the portal",
            goal: "Read the study portal",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: "").providerLaunch
        #expect(BrokeredConnectorEnvironment.brokeredConnectors(in: scope).isEmpty)
        #expect(BrokeredConnectorEnvironment.strippedKeys(in: scope).isEmpty)

        let environment = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: task,
            capabilityScope: scope
        )
        #expect(environment["CUSTOM_HTTP_STUDY_PORTAL_PORTAL_BASE_URL"] == "https://portal.example.edu")
        #expect(environment["ASTRA_CONNECTORS"]?.contains("study_portal") == true)
    }
}
