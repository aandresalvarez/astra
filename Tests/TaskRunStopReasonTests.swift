import Foundation
import Testing
@testable import ASTRA

@Suite("Task run stop reasons")
struct TaskRunStopReasonTests {
    @Test("Known stop reason raw values stay stable")
    func knownStopReasonRawValuesStayStable() {
        #expect(TaskRunStopReason.completed.rawValue == "completed")
        #expect(TaskRunStopReason.failed.rawValue == "failed")
        #expect(TaskRunStopReason.cancelled.rawValue == "cancelled")
        #expect(TaskRunStopReason.timeout.rawValue == "timeout")
        #expect(TaskRunStopReason.maxBudgetReached.rawValue == "max_budget_reached")
        #expect(TaskRunStopReason.maxTurnsReached.rawValue == "max_turns_reached")
        #expect(TaskRunStopReason.noUsableResult.rawValue == "no_usable_result")
        #expect(TaskRunStopReason.validationContractFailed.rawValue == "validation_contract_failed")
        #expect(TaskRunStopReason.deliverableVerificationFailed.rawValue == "deliverable_verification_failed")
        #expect(TaskRunStopReason.inferredValidationFailed.rawValue == "inferred_validation_failed")
        #expect(TaskRunStopReason.permissionApprovalRequired.rawValue == "permission_approval_required")
        #expect(TaskRunStopReason.policyViolation.rawValue == "policy_violation")
        #expect(TaskRunStopReason.repetitionDetected.rawValue == "repetition_detected")
    }

    @Test("TaskRun typed stop reason preserves raw storage compatibility")
    func taskRunTypedStopReasonPreservesRawStorageCompatibility() {
        let task = AgentTask(title: "Typed stop", goal: "Verify stop reason storage")
        let run = TaskRun(task: task)

        run.typedStopReason = .noUsableResult
        #expect(run.stopReason == "no_usable_result")
        #expect(run.typedStopReason == .noUsableResult)

        run.stopReason = "future_provider_reason"
        #expect(run.typedStopReason?.rawValue == "future_provider_reason")

        run.typedStopReason = nil
        #expect(run.stopReason == "")
        #expect(run.typedStopReason == nil)
    }

    @Test("Policy stop reason detection uses typed wrapper")
    func policyStopReasonDetectionUsesTypedWrapper() {
        #expect(TaskRunStopReason.policyViolation.isPolicyBlocked)
        #expect(TaskRunStopReason.policyBlocked.isPolicyBlocked)
        #expect(!TaskRunStopReason.noUsableResult.isPolicyBlocked)
        #expect(PendingTaskReviewPolicy.stopReasonIsPolicyBlocked(.policyViolation))
        #expect(!PendingTaskReviewPolicy.stopReasonIsPolicyBlocked(.completed))
    }
}
