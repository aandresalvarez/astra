import Foundation
import Testing
@testable import ASTRA

// The live Agentic Workflow path is the archetype classifier plus
// WorkspaceAppStudioRecipes, not the retired proposal-card ideator.
@Suite("Workspace App Agentic Workflow Recipes")
struct WorkspaceAppAgenticWorkflowTests {

    @Test("agentic request classifies to the agentic workflow archetype")
    func agenticRequestClassifiesToWorkflow() {
        #expect(
            WorkspaceAppArchetype.classify("Build a workflow of agents that orchestrate solving this problem")
                == .agenticWorkflow
        )
    }

    @Test("agentic workflow recipe generates a valid HTML workflow manifest")
    func agenticWorkflowRecipeIsValid() {
        let manifest = WorkspaceAppStudioRecipes.manifest(
            for: .agenticWorkflow,
            intent: "orchestrate agents to solve this"
        )

        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        #expect(manifest.app.archetypes.contains("Agentic Workflow"))
        #expect(manifest.app.archetypes.contains("HTML App"))
        #expect(manifest.html?.contains("astra.query") == true)
    }

    @Test("agentic workflow recipe composes task steps and approval gates inside one runnable pipeline")
    func agenticWorkflowRecipeComposesPrimitives() throws {
        let manifest = WorkspaceAppStudioRecipes.manifest(
            for: .agenticWorkflow,
            intent: "agent workflow"
        )
        let actions = manifest.actions

        // Task-backed agent steps run through the normal task runtime.
        #expect(actions.contains { $0.type == "task.createAndRun" })
        // Governed by an agent recommendation gate and human gates before external task effects.
        #expect(actions.contains { $0.type == "gate.agentRecommendation" })
        #expect(actions.filter { $0.type == "gate.humanApproval" }.count == 2)
        // The pipeline composes the data read, pre-agent gate, AI work, agent gate, human gate, and implementation.
        let pipeline = try #require(manifest.actions.first { $0.type == "pipeline.run" })
        #expect(pipeline.steps == ["list_review_items", "approve_analysis", "analyze", "agent_review", "human_approval", "implement"])

        // The analysis answer is captured and fed into the implementation step.
        #expect(actions.contains { $0.outputBinding != nil })
        #expect(actions.contains { $0.inputBinding != nil })
        #expect(manifest.permissions.defaultMode == .approvalRequired)
    }
}
