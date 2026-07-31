import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Agent Runtime CLI Relay Adapters", .serialized)
struct AgentRuntimeCLIRelayAdapterTests {
    @Test("CLI-relay runtimes receive broker metadata without connector credentials")
    @MainActor
    func cliRelayRuntimesReceiveBrokerMetadataWithoutConnectorCredentials() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-host-control-non-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try makeContainer()
        let modelContext = container.mainContext
        let workspace = Workspace(name: "Jira Host Control", primaryPath: root.path)
        workspace.enabledCapabilityIDs = ["jira-workflow"]
        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use ASTRA's typed Jira host-control route."
        )
        jiraSkill.originPackageID = "jira-workflow"
        jiraSkill.workspace = workspace
        let jiraConnector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira issues",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        jiraConnector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jiraConnector.configKeys = ["JIRA_PROJECTS"]
        jiraConnector.configValues = ["ASTRA"]
        jiraConnector.skill = jiraSkill
        jiraConnector.workspace = workspace
        let task = AgentTask(
            title: "Read Jira issue",
            goal: "Read ASTRA-123 in Jira",
            workspace: workspace,
            model: "test-model",
            runtime: .cursorCLI
        )
        task.skills = [jiraSkill]
        modelContext.insert(workspace)
        modelContext.insert(jiraSkill)
        modelContext.insert(jiraConnector)
        modelContext.insert(task)
        try modelContext.save()

        let intent = TaskTurnIntentSnapshot(
            taskID: task.id,
            sourceEventID: nil,
            acceptedTurn: "Read ASTRA-123 in Jira"
        )
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["jira"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let secrets = [
            "JIRA_EMAIL": "provider-must-not-see@example.edu",
            "JIRA_API_TOKEN": "provider-must-not-see-token"
        ]
        let helperPath = try builtHostControlHelperPath()

        for runtime in [AgentRuntimeID.openCodeCLI, .cursorCLI, .antigravityCLI] {
            task.runtimeID = runtime.rawValue
            let snapshot = TaskCapabilityResolutionSnapshot.capture(
                for: task,
                providerLaunchContextText: intent.acceptedTurn,
                additionalCredentialGrants: [
                    .credential(label: "JIRA_EMAIL"),
                    .credential(label: "JIRA_API_TOKEN")
                ],
                turnIntentSnapshot: intent,
                runtime: runtime,
                secretStore: AdapterSecretStore(values: secrets)
            )
            let runID = UUID()
            #expect(HostControlBrokerSessionRegistry.shared.prepare(
                task: task,
                runID: runID,
                capabilityScope: snapshot.providerLaunch,
                requiredTools: requirements.hostControlTools,
                currentDirectory: workspace.primaryPath,
                expectedHelperPath: helperPath
            ))
            defer {
                HostControlBrokerSessionRegistry.shared.stop(taskID: task.id, runID: runID)
            }

            let plan = AgentRuntimeAdapterRegistry.adapter(for: runtime)
                .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                    prompt: intent.acceptedTurn,
                    task: task,
                    workspacePath: workspace.primaryPath,
                    executablePath: "/bin/echo",
                    providerHomeDirectory: root.appendingPathComponent(runtime.rawValue).path,
                    permissionPolicy: .restricted,
                    executionPolicy: .default.withTurnIntentSnapshot(intent),
                    permissionManifest: nil,
                    timeoutSeconds: 30,
                    phase: "run",
                    contextText: intent.acceptedTurn,
                    runID: runID,
                    capabilityResolutionSnapshot: snapshot,
                    runtimeRequirements: requirements
                ))

            #expect(plan.commandPlannedFields["host_control_plane_tool_count"] == "1")
            #expect(plan.commandPlannedFields["host_control_plane_supported"] == "true")
            #expect(plan.commandPlannedFields["host_control_plane_launch_block_reason"] == "none")
            #expect(HostControlPlaneRuntimeLaunchGuard.launchBlock(for: plan) == nil)
            #expect(plan.environment[HostControlBrokerIPC.endpointEnvironmentKey]?.isEmpty == false)
            #expect(plan.environment["ASTRA_HOST_CONTROL_ALLOWED_TOOLS"] == "jira")
            #expect(plan.environment["PATH"]?.split(separator: ":").contains(
                Substring(RuntimePathResolver.astraToolsPath)
            ) == true)
            #expect(plan.environment["ASTRA_CONNECTORS"] == nil)
            #expect(plan.environment["JIRA_EMAIL"] == nil)
            #expect(plan.environment["JIRA_API_TOKEN"] == nil)
            #expect(plan.environment["JIRA_JIRA_EMAIL"] == nil)
            #expect(plan.environment["JIRA_JIRA_API_TOKEN"] == nil)
            #expect(!plan.environment.values.contains("provider-must-not-see@example.edu"))
            #expect(!plan.environment.values.contains("provider-must-not-see-token"))
        }
    }

    @Test("gcloud host tooling preserves connector project and region projection")
    @MainActor
    func gcloudHostToolingPreservesConnectorConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-gcloud-relay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try makeContainer()
        let modelContext = container.mainContext
        let workspace = Workspace(name: "GCloud", primaryPath: root.path)
        let skill = Skill(
            name: "GCloud Agent",
            skillDescription: "Inspect Google Cloud",
            allowedTools: ["Bash"]
        )
        let connector = Connector(
            name: "Production GCP",
            serviceType: "gcloud",
            connectorDescription: "Configured Google Cloud account",
            authMethod: "none"
        )
        connector.configKeys = ["GCP_PROJECT", "GCP_REGION"]
        connector.configValues = ["astra-production", "us-central1"]
        connector.skill = skill
        connector.workspace = workspace
        let task = AgentTask(
            title: "Inspect Cloud Run",
            goal: "Use gcloud to inspect Cloud Run",
            workspace: workspace,
            model: "test-model",
            runtime: .cursorCLI
        )
        task.skills = [skill]
        modelContext.insert(workspace)
        modelContext.insert(skill)
        modelContext.insert(connector)
        modelContext.insert(task)
        try modelContext.save()

        let intent = TaskTurnIntentSnapshot(
            taskID: task.id,
            sourceEventID: nil,
            acceptedTurn: task.goal
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: intent.acceptedTurn,
            turnIntentSnapshot: intent,
            runtime: .cursorCLI
        )
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: ["gcloud"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let runID = UUID()
        #expect(HostControlBrokerSessionRegistry.shared.prepare(
            task: task,
            runID: runID,
            capabilityScope: snapshot.providerLaunch,
            requiredTools: requirements.hostControlTools,
            currentDirectory: workspace.primaryPath,
            expectedHelperPath: try builtHostControlHelperPath()
        ))
        defer {
            HostControlBrokerSessionRegistry.shared.stop(taskID: task.id, runID: runID)
        }

        let plan = AgentRuntimeAdapterRegistry.adapter(for: .cursorCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: intent.acceptedTurn,
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/echo",
                providerHomeDirectory: root.appendingPathComponent("provider").path,
                permissionPolicy: .restricted,
                executionPolicy: .default.withTurnIntentSnapshot(intent),
                permissionManifest: nil,
                timeoutSeconds: 30,
                phase: "run",
                contextText: intent.acceptedTurn,
                runID: runID,
                capabilityResolutionSnapshot: snapshot,
                runtimeRequirements: requirements
            ))
        let projected = ConnectorRuntimeProjection(connectors: [connector])
            .environmentBindings()
            .filter { $0.kind == .config }

        #expect(projected.count == 2)
        for binding in projected {
            #expect(plan.environment[binding.envKey] == binding.value)
            #expect(plan.environment["ASTRA_CONNECTORS"]?.contains(binding.envKey) == true)
        }
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func builtHostControlHelperPath() throws -> String {
        let path = Bundle.module.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("astra-host-control", isDirectory: false)
            .path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return path
    }
}

private struct AdapterSecretStore: SecretStore {
    let values: [String: String]

    func load(key: String, entityID _: String) -> String? { values[key] }
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool { false }
    func delete(key _: String, entityID _: String) -> Bool { false }
    func deleteAll(entityID _: String) {}
    func exists(key: String, entityID _: String) -> Bool { values[key] != nil }
}
