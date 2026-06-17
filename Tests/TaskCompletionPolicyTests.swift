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
        #expect(decision.typedStopReason == .validationContractFailed)
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
        #expect(decision.typedStopReason == .noUsableResult)
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
        #expect(decision.typedStopReason == .inferredValidationFailed)
        #expect(decision.userVisibleMessage == "Automatic verification failed: Required inferred proof failed.")
    }

    @Test("Completion blocked event payload encodes typed decision context")
    func completionBlockedEventPayloadEncodesTypedDecisionContext() throws {
        let decision = TaskCompletionPolicyDecision.block(
            gate: .manualArtifactRequirement,
            stopReason: .noUsableResult,
            userVisibleMessage: "Missing artifact.",
            auditFields: ["has_artifact": "false"]
        )

        let payload = TaskCompletionBlockedEventPayload(decision: decision)
        let encoded = try #require(tryEncodedPayload(payload))
        let event = TaskEvent(
            task: AgentTask(title: "Payload", goal: "Encode typed payload"),
            eventType: TaskEventTypes.System.error,
            payload: encoded
        )

        let decoded = try #require(tryDecodedPayload(event, as: TaskCompletionBlockedEventPayload.self))
        #expect(decoded == payload)
        #expect(decoded.gate == "manual_artifact_requirement")
        #expect(decoded.stopReason == "no_usable_result")
        #expect(decoded.auditFields["has_artifact"] == "false")
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

    @Test("manual completion policy names missing explicit deliverables")
    func manualCompletionPolicyNamesMissingExplicitDeliverables() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("manual-completion-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Completion", primaryPath: root)
        let task = AgentTask(
            title: "Results",
            goal: """
            Final deliverables:
            - ./results.txt
            """,
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
        #expect(decision.userVisibleMessage?.contains("Missing explicitly requested deliverable file: results.txt.") == true)
        #expect(decision.userVisibleMessage?.contains("standalone file artifact") == false)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
    }

    private func tryEncodedPayload<T: Encodable>(_ payload: T) -> String? {
        switch TaskEvent.encodePayload(payload) {
        case .success(let encoded):
            encoded
        case .failure:
            nil
        }
    }

    private func tryDecodedPayload<T: Decodable>(_ event: TaskEvent, as type: T.Type) -> T? {
        switch event.decodePayload(as: type, expecting: TaskEventTypes.System.error) {
        case .success(let payload):
            payload
        case .failure:
            nil
        }
    }
}
