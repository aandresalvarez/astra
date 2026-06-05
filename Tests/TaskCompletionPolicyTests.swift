import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Task completion policy")
@MainActor
struct TaskCompletionPolicyTests {
    @Test("validation contract policy blocks failed required assertions")
    func validationContractPolicyBlocksFailedRequiredAssertions() {
        let evaluation = TaskValidationContractEvaluation(
            didRun: true,
            outcome: .failed,
            canComplete: false,
            summary: "Validation contract failed.",
            failedRequiredAssertionIDs: ["proof"]
        )

        let decision = TaskCompletionPolicy.decide(validationContract: evaluation)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .validationContract)
        #expect(decision.stopReason == "validation_contract_failed")
        #expect(decision.userVisibleMessage == "Validation contract failed.")
        #expect(decision.auditFields["outcome"] == "failed")
    }

    @Test("deliverable policy maps missing artifacts to no usable result")
    func deliverablePolicyMapsMissingArtifactsToNoUsableResult() {
        let result = TaskDeliverableVerificationResult(
            version: 1,
            profile: .standaloneWebArtifact,
            level: .noArtifact,
            status: "failed",
            canComplete: false,
            requiresHumanReview: false,
            summary: "No artifact found.",
            checks: [],
            evidencePaths: [],
            runID: UUID(),
            verifiedAt: Date(timeIntervalSince1970: 1_000)
        )

        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .deliverableVerification)
        #expect(decision.stopReason == "no_usable_result")
        #expect(decision.userVisibleMessage == "No artifact found.")
    }

    @Test("inferred validation policy uses inferred stop reason")
    func inferredValidationPolicyUsesInferredStopReason() {
        let evaluation = TaskValidationContractEvaluation(
            didRun: true,
            outcome: .failed,
            canComplete: false,
            summary: "Required inferred proof failed.",
            failedRequiredAssertionIDs: ["artifact-1"]
        )

        let decision = TaskCompletionPolicy.decide(inferredValidation: evaluation)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .inferredValidation)
        #expect(decision.stopReason == "inferred_validation_failed")
        #expect(decision.userVisibleMessage == "Automatic verification failed: Required inferred proof failed.")
    }

    @Test("manual completion policy blocks standalone artifact tasks without artifacts")
    func manualCompletionPolicyBlocksStandaloneArtifactTasksWithoutArtifacts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Completion", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(
            title: "Web page",
            goal: "write a web page with html and javascript",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()

        let decision = TaskCompletionPolicy.decideManualCompletion(task: task, run: run)

        #expect(decision.shouldBlockCompletion)
        #expect(decision.gate == .manualArtifactRequirement)
        #expect(decision.stopReason == "no_usable_result")
        #expect(decision.userVisibleMessage?.contains("standalone file artifact") == true)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
    }
}
