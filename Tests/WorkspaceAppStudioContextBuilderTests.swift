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
    @Test("context redacts capability linked resource names")
    func contextRedactsCapabilityLinkedResourceNames() {
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/research")
        workspace.enabledCapabilityIDs = ["secret-capability"]

        let skill = Skill(name: "Skill token=skill-secret-123456")
        skill.originPackageID = "secret-capability"
        let connector = Connector(name: "Connector ghp_1234567890abcdef", serviceType: "custom")
        connector.originPackageID = "secret-capability"
        let tool = LocalTool(name: "Tool sk-1234567890abcdef")
        tool.originPackageID = "secret-capability"
        workspace.skills = [skill]
        workspace.connectors = [connector]
        workspace.localTools = [tool]

        let package = capabilityPackage(
            id: "secret-capability",
            name: "Secret Resource Names",
            riskLevel: .medium
        )
        let context = WorkspaceAppStudioContextBuilder.build(WorkspaceAppStudioContextRequest(
            userPrompt: "Build with linked resources.",
            workspace: workspace,
            capabilityStates: [
                CapabilityPackageState(
                    package: package,
                    workspace: workspace,
                    capabilities: WorkspaceCapabilities(workspace: workspace)
                )
            ]
        ))

        #expect(context.capabilities.first?.skills == ["Skill token=[redacted]"])
        #expect(context.capabilities.first?.connectors == ["Connector [redacted]"])
        #expect(context.capabilities.first?.tools == ["Tool [redacted]"])
        let rendered = context.builderContract.renderedPrompt
        #expect(rendered.contains("skill-secret") == false)
        #expect(rendered.contains("ghp_1234567890") == false)
        #expect(rendered.contains("sk-1234567890") == false)
    }

    @MainActor
    @Test("context caps doubled manifest excerpt limit")
    func contextCapsDoubledManifestExcerptLimit() {
        let workspace = Workspace(name: "Research", primaryPath: "/tmp/research")

        let context = WorkspaceAppStudioContextBuilder.build(WorkspaceAppStudioContextRequest(
            userPrompt: "Build safely.",
            workspace: workspace,
            capabilityStates: [],
            existingAppManifest: #"{"token":"manifest-secret-123456"}"#,
            excerptCharacterLimit: Int.max
        ))

        #expect(context.existingAppManifest == #"{"token":"[redacted]"}"#)
        #expect(context.builderContract.renderedPrompt.contains("manifest-secret") == false)
    }

    @MainActor
    @Test("generation task draft carries redacted Workspace App Studio context")
    func generationTaskDraftCarriesRedactedWorkspaceAppStudioContext() {
        let workspace = Workspace(
            name: "Clinical Ops",
            primaryPath: "/tmp/clinical-ops",
            instructions: "Use REDCap carefully with token=workspace-secret-123456."
        )
        workspace.enabledCapabilityIDs = ["redcap-capability"]
        let task = AgentTask(
            title: "REDCap reconciliation",
            goal: "Compare warehouse rows with api_key=task-secret-123456.",
            workspace: workspace
        )
        task.updatedAt = Date(timeIntervalSince1970: 2_000)
        task.events = [
            studioEvent(
                task: task,
                eventType: TaskEventTypes.Conversation.userMessage,
                payload: "Build the app from ghp_1234567890abcdef.",
                timestamp: Date(timeIntervalSince1970: 2_001)
            )
        ]
        workspace.tasks = [task]

        let redcap = capabilityPackage(
            id: "redcap-capability",
            name: "REDCap",
            riskLevel: .high,
            dataAccess: [.clinicalData],
            externalEffects: [.readOnly]
        )

        let draft = WorkspaceAppStudioGenerationTaskBuilder.draft(
            userPrompt: "Build a reconciliation app using token=prompt-secret-123456.",
            workspace: workspace,
            packages: [redcap],
            existingAppManifest: #"{"token":"manifest-secret-123456"}"#
        )

        #expect(draft.title == "Design Workspace App: Clinical Ops")
        #expect(draft.goal.contains("Build a reconciliation app using token=[redacted]"))
        #expect(draft.goal.contains("Workspace App Studio context"))
        #expect(draft.inputs.count == 1)
        #expect(draft.inputs[0].contains("## Recent tasks"))
        #expect(draft.inputs[0].contains("REDCap"))
        #expect(draft.inputs[0].contains("Existing app manifest"))
        #expect(draft.acceptanceCriteria.contains("Proposes the app storage, views, actions, automations, and permission mode."))
        let combined = ([draft.goal] + draft.inputs + draft.acceptanceCriteria).joined(separator: "\n")
        #expect(combined.contains("workspace-secret") == false)
        #expect(combined.contains("task-secret") == false)
        #expect(combined.contains("ghp_1234567890") == false)
        #expect(combined.contains("prompt-secret") == false)
        #expect(combined.contains("manifest-secret") == false)
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
