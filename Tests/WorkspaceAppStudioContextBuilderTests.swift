import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Workspace App Studio Context Builder")
struct WorkspaceAppStudioContextBuilderTests {
    @MainActor
    @Test("context redacts sensitive prompt task event and artifact text")
    func contextRedactsSensitiveInputs() {
        let workspace = Workspace(
            name: "Clinical Research",
            primaryPath: "/tmp/clinical-research",
            instructions: "Use REDCap carefully. REDCAP_TOKEN=rc_1234567890"
        )
        let task = AgentTask(
            title: "REDCap reconciliation",
            goal: "Compare BigQuery rows using api_key=abc123456789",
            workspace: workspace
        )
        task.inputs = ["GitHub token gho_1234567890abcdef should never leak."]
        task.updatedAt = Date(timeIntervalSince1970: 2_000)
        task.events = [
            studioEvent(
                task: task,
                eventType: TaskEventTypes.Conversation.userMessage,
                payload: "Build this from sk-1234567890abcdef.",
                timestamp: Date(timeIntervalSince1970: 2_001)
            ),
            studioEvent(
                task: task,
                eventType: TaskEventTypes.Conversation.agentResponse,
                payload: "I will keep password: hunter2 out of generated app context.",
                timestamp: Date(timeIntervalSince1970: 2_002)
            )
        ]
        task.artifacts = [
            Artifact(
                task: task,
                type: "markdown",
                path: "/tmp/clinical-research/report.md",
                content: "Report uses bearer secret-token-123456 for a source export."
            )
        ]
        workspace.tasks = [task]

        let context = WorkspaceAppStudioContextBuilder.build(WorkspaceAppStudioContextRequest(
            userPrompt: "Build a REDCap app with token=prompt-secret-123456.",
            workspace: workspace,
            capabilityStates: [],
            existingAppManifest: #"{"apiKey":"manifest-secret-123456"}"#
        ))

        let rendered = context.builderContract.renderedPrompt
        #expect(rendered.contains("prompt-secret") == false)
        #expect(rendered.contains("rc_1234567890") == false)
        #expect(rendered.contains("abc123456789") == false)
        #expect(rendered.contains("gho_1234567890") == false)
        #expect(rendered.contains("sk-1234567890") == false)
        #expect(rendered.contains("hunter2") == false)
        #expect(rendered.contains("secret-token-123456") == false)
        #expect(rendered.contains("manifest-secret") == false)
        #expect(rendered.contains("[redacted]"))
    }

    @MainActor
    @Test("context includes enabled capability summaries in stable order")
    func contextIncludesEnabledCapabilitiesInStableOrder() {
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/research")
        workspace.enabledCapabilityIDs = ["redcap-capability", "bigquery-capability"]

        let bigQuery = capabilityPackage(
            id: "bigquery-capability",
            name: "BigQuery Warehouse",
            riskLevel: .low,
            dataAccess: [.externalService],
            externalEffects: [.readOnly]
        )
        let redcap = capabilityPackage(
            id: "redcap-capability",
            name: "REDCap",
            riskLevel: .high,
            dataAccess: [.clinicalData, .connectorCredentials],
            externalEffects: [.externalAPIWrite],
            connectors: [
                PluginConnector(
                    name: "REDCap API",
                    serviceType: "redcap",
                    icon: "cross.case",
                    description: "REDCap project API",
                    baseURL: "https://redcap.example.test",
                    authMethod: "api_key",
                    credentialHints: [.init(key: "REDCAP_TOKEN", hint: "Project token")],
                    configHints: [],
                    notes: "Needs project mapping."
                )
            ]
        )
        let inactive = capabilityPackage(
            id: "disabled-capability",
            name: "Disabled Capability",
            riskLevel: .medium
        )

        let capabilities = WorkspaceCapabilities(workspace: workspace)
        let context = WorkspaceAppStudioContextBuilder.build(WorkspaceAppStudioContextRequest(
            userPrompt: "Build a reconciliation app.",
            workspace: workspace,
            capabilityStates: [
                CapabilityPackageState(package: redcap, workspace: workspace, capabilities: capabilities),
                CapabilityPackageState(package: inactive, workspace: workspace, capabilities: capabilities),
                CapabilityPackageState(package: bigQuery, workspace: workspace, capabilities: capabilities)
            ]
        ))

        #expect(context.capabilities.map(\.id) == ["bigquery-capability", "redcap-capability"])
        #expect(context.capabilities.map(\.readiness) == ["ready", "needsAttention"])
        #expect(context.capabilities[0].governance.riskLevel == "low")
        #expect(context.capabilities[0].governance.externalEffects == ["readOnly"])
        #expect(context.capabilities[1].governance.dataAccess == ["clinicalData", "connectorCredentials"])
        #expect(context.capabilities[1].messages == ["REDCap API: connector not active for this workspace"])
        #expect(context.builderContract.renderedPrompt.contains("BigQuery Warehouse"))
        #expect(context.builderContract.renderedPrompt.contains("REDCap API: connector not active"))
        #expect(context.builderContract.renderedPrompt.contains("Disabled Capability") == false)
    }

    @MainActor
    @Test("context orders and limits recent tasks events and artifacts")
    func contextOrdersAndLimitsRecentWorkspaceEvidence() {
        let workspace = Workspace(name: "Evidence", primaryPath: "/tmp/evidence")
        let newest = task(
            title: "Newest",
            goal: "Latest workflow",
            workspace: workspace,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            events: [
                (TaskEventTypes.Conversation.agentResponse, "Second newest event", 3_002),
                (TaskEventTypes.Tool.result, "Ignored tool event", 3_004),
                (TaskEventTypes.Conversation.userMessage, "Newest event", 3_003),
                (TaskEventTypes.Conversation.agentResponse, "Older event", 3_001)
            ],
            artifacts: [
                ("summary.md", "Summary content", 3_002),
                ("chart.json", "Chart content", 3_003)
            ]
        )
        let middle = task(
            title: "Middle",
            goal: "Earlier workflow",
            workspace: workspace,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            events: [(TaskEventTypes.Conversation.userMessage, "Middle event", 2_001)],
            artifacts: [("middle.csv", "Middle content", 2_001)]
        )
        let oldest = task(
            title: "Oldest",
            goal: "Stale workflow",
            workspace: workspace,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            events: [(TaskEventTypes.Conversation.userMessage, "Old event", 1_001)],
            artifacts: [("old.txt", "Old content", 1_001)]
        )
        workspace.tasks = [middle, oldest, newest]

        let context = WorkspaceAppStudioContextBuilder.build(WorkspaceAppStudioContextRequest(
            userPrompt: "Turn this process into an app.",
            workspace: workspace,
            capabilityStates: [],
            recentTaskLimit: 2,
            eventLimitPerTask: 2,
            artifactLimit: 2
        ))

        #expect(context.tasks.map(\.title) == ["Newest", "Middle"])
        #expect(context.tasks[0].eventExcerpts.map(\.payload) == ["Newest event", "Second newest event"])
        #expect(context.artifacts.map(\.fileName) == ["chart.json", "summary.md"])
        #expect(context.builderContract.sections.map(\.title) == [
            "User request",
            "Workspace",
            "Capabilities",
            "Recent tasks",
            "Artifacts",
            "Existing app manifest"
        ])
    }
}

private func studioEvent(
    task: AgentTask,
    eventType: TaskEventType,
    payload: String,
    timestamp: Date
) -> TaskEvent {
    let event = TaskEvent(task: task, eventType: eventType, payload: payload)
    event.timestamp = timestamp
    return event
}

private func capabilityPackage(
    id: String,
    name: String,
    riskLevel: CapabilityRiskLevel,
    dataAccess: [CapabilityDataAccessKind] = [],
    externalEffects: [CapabilityExternalEffectKind] = [.readOnly],
    connectors: [PluginConnector] = []
) -> PluginPackage {
    PluginPackage(
        id: id,
        name: name,
        icon: "puzzlepiece.extension",
        description: "\(name) test capability",
        author: "Tests",
        category: "Tests",
        tags: [],
        version: "1.0.0",
        skills: [],
        connectors: connectors,
        localTools: [],
        templates: [],
        governance: .builtInApproved(
            riskLevel: riskLevel,
            dataAccess: dataAccess,
            externalEffects: externalEffects
        )
    )
}

private func task(
    title: String,
    goal: String,
    workspace: Workspace,
    updatedAt: Date,
    events: [(TaskEventType, String, TimeInterval)],
    artifacts: [(String, String, TimeInterval)]
) -> AgentTask {
    let task = AgentTask(title: title, goal: goal, workspace: workspace)
    task.updatedAt = updatedAt
    task.events = events.map { type, payload, timestamp in
        studioEvent(task: task, eventType: type, payload: payload, timestamp: Date(timeIntervalSince1970: timestamp))
    }
    task.artifacts = artifacts.map { fileName, content, timestamp in
        let artifact = Artifact(
            task: task,
            type: ArtifactKind.forPath(fileName).rawValue,
            path: "/tmp/evidence/\(fileName)",
            content: content
        )
        artifact.createdAt = Date(timeIntervalSince1970: timestamp)
        return artifact
    }
    return task
}
