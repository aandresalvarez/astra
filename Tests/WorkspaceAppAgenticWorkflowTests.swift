import Foundation
import SwiftData
import Testing
@testable import ASTRA

// Slice 9 Phase A: the Agentic Workflow archetype generates a valid Workspace App
// manifest that orchestrates a workflow of governed ASTRA agents using existing
// primitives only — task-backed steps, an agent recommendation gate, a human
// approval gate, and a bounded loop. No parallel agent runtime is introduced.
@Suite("Workspace App Agentic Workflow (Slice 9 Phase A)")
struct WorkspaceAppAgenticWorkflowTests {

    @Test("agentic request proposes the agentic workflow archetype")
    func ideatorProposesAgenticWorkflow() {
        let ideas = WorkspaceAppStudioIdeator.proposals(
            for: WorkspaceAppStudioIdeationContext(
                userRequest: "Build a workflow of agents that orchestrate solving this problem"
            )
        )
        #expect(ideas.contains { $0.id == "agentic-workflow" })
    }

    @MainActor
    @Test("agentic workflow archetype generates a valid manifest")
    func agenticWorkflowManifestIsValid() throws {
        let idea = try #require(
            WorkspaceAppStudioIdeator.proposals(
                for: WorkspaceAppStudioIdeationContext(userRequest: "orchestrate agents to solve this")
            ).first { $0.id == "agentic-workflow" }
        )
        let workspace = Workspace(name: "Agentic", primaryPath: "/tmp/agentic-workflow-test")
        let draft = WorkspaceAppStudioBuilder.draft(from: idea, workspace: workspace)

        #expect(draft.validationReport.isValid)
        #expect(draft.manifest.app.archetypes.contains("Agentic Workflow"))
    }

    @MainActor
    @Test("agentic workflow manifest composes task steps, an agent gate, and a bounded loop")
    func agenticWorkflowManifestComposesPrimitives() throws {
        let idea = try #require(
            WorkspaceAppStudioIdeator.proposals(
                for: WorkspaceAppStudioIdeationContext(userRequest: "agent workflow")
            ).first { $0.id == "agentic-workflow" }
        )
        let workspace = Workspace(name: "Agentic", primaryPath: "/tmp/agentic-workflow-test")
        let actions = WorkspaceAppStudioBuilder.draft(from: idea, workspace: workspace).manifest.actions

        // Task-backed agent steps run through the normal task runtime.
        #expect(actions.contains { $0.type == "task.createAndRun" })
        // Governed by an agent recommendation gate and a human approval gate.
        #expect(actions.contains { $0.type == "gate.agentRecommendation" })
        #expect(actions.contains { $0.type == "gate.humanApproval" })
        // Bounded by a loop with a positive iteration cap and a stop condition.
        let loop = try #require(actions.first { $0.type == "loop.run" })
        #expect((loop.maxIterations ?? 0) > 0)
        #expect(loop.gateField?.isEmpty == false)
        #expect(!loop.steps.isEmpty)
    }
}
