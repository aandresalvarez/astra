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
        #expect(TaskRunStopReason.credentialProjectionRequired.rawValue == "credential_projection_required")
        #expect(TaskRunStopReason.timeout.rawValue == "timeout")
        #expect(TaskRunStopReason.maxBudgetReached.rawValue == "max_budget_reached")
        #expect(TaskRunStopReason.maxTurnsReached.rawValue == "max_turns_reached")
        #expect(TaskRunStopReason.noUsableResult.rawValue == "no_usable_result")
        #expect(TaskRunStopReason.validationContractFailed.rawValue == "validation_contract_failed")
        #expect(TaskRunStopReason.deliverableVerificationFailed.rawValue == "deliverable_verification_failed")
        #expect(TaskRunStopReason.inferredValidationFailed.rawValue == "inferred_validation_failed")
        #expect(TaskRunStopReason.dockerProviderExecutableMissing.rawValue == "docker_provider_executable_missing")
        #expect(TaskRunStopReason.dockerDaemonUnavailable.rawValue == "docker_daemon_unavailable")
        #expect(TaskRunStopReason.dockerContextUnapproved.rawValue == "docker_context_unapproved")
        #expect(TaskRunStopReason.dockerImageUnavailable.rawValue == "docker_image_unavailable")
        #expect(TaskRunStopReason.dockerMountFailed.rawValue == "docker_mount_failed")
        #expect(TaskRunStopReason.dockerLaunchFailed.rawValue == "docker_launch_failed")
        #expect(TaskRunStopReason.permissionApprovalRequired.rawValue == "permission_approval_required")
        #expect(TaskRunStopReason.policyViolation.rawValue == "policy_violation")
        #expect(TaskRunStopReason.repetitionDetected.rawValue == "repetition_detected")
        #expect(TaskRunStopReason.providerActiveToolStalled.rawValue == "provider_active_tool_stalled")
        #expect(TaskRunStopReason.providerWorkspaceJobStalled.rawValue == "provider_workspace_job_stalled")
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

    @Test("Docker runtime stop reasons are grouped for terminal failures")
    func dockerRuntimeStopReasonsAreGroupedForTerminalFailures() {
        #expect(TaskRunStopReason.dockerProviderExecutableMissing.isDockerRuntimeBlocked)
        #expect(TaskRunStopReason.dockerDaemonUnavailable.isDockerRuntimeBlocked)
        #expect(TaskRunStopReason.dockerContextUnapproved.isDockerRuntimeBlocked)
        #expect(!TaskRunStopReason.noUsableResult.isDockerRuntimeBlocked)
    }

    @Test("String literal stop reasons apply the same trimming normalization")
    func stringLiteralStopReasonsApplySameTrimmingNormalization() {
        let literal: TaskRunStopReason = "  no_usable_result\n"

        #expect(literal.rawValue == TaskRunStopReason.noUsableResult.rawValue)
        #expect(TaskRunStopReason(rawValue: "  no_usable_result\n") == literal)
    }
}
