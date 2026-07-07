import Foundation
import ASTRAModels
import ASTRACore

/// Tier 1 deterministic classifier: has the original goal already been delivered?
///
/// This intentionally mirrors (without calling into) the private inference logic in
/// `TaskContextStateManager` -- see `inferredMode` and the validation-contract status
/// computation near `verificationState` -- reimplemented here using only public APIs so
/// this file stays independent of `TaskContextStateManager`'s private helpers.
///
/// Fail-safe direction: any uncertainty resolves to `.active`, never `.delivered`.
public enum OriginalGoalDeliveryStatus: Equatable, Sendable {
    case active
    case delivered
}

extension TaskContextStateManager {
    @MainActor
    public static func originalGoalDelivery(for task: AgentTask) -> OriginalGoalDeliveryStatus {
        if task.status == .completed {
            return .delivered
        }

        let planState = TaskPlanReconstructionSeam.required.reconstruct(for: task)
        if planState.lifecycleStatus == .completed {
            return .delivered
        }

        if let plan = planState.plan,
           originalGoalHasPassedOrOverriddenContract(task: task, planID: plan.planID) {
            return .delivered
        }

        if let plan = planState.plan,
           let contract = plan.validationContract,
           !contract.assertions.isEmpty,
           originalGoalHasDerivedPassedContract(task: task, planID: plan.planID, contract: contract) {
            return .delivered
        }

        if originalGoalHasVerifiedCompletion(task: task) {
            return .delivered
        }

        if originalGoalHasManualApproval(task: task) {
            return .delivered
        }

        return .active
    }
}

/// Returns true when the most recent completion-signal event (whichever of the two
/// event families `TaskContextStateManager.verificationState` prioritizes is newer)
/// reports `completionVerified == true`. Mirrors `verificationState`'s two leading
/// branches -- generic validation events (`task.completed` / `error` outcome markers,
/// validation-contract outcome events) and `TaskDeliverableVerificationEventTypes`
/// events -- so a plan-less or contract-less thread whose deliverable was verified via
/// either signal is recognized here too, not just plan-lifecycle and contract-pass
/// events scoped to a specific plan.
private func originalGoalHasVerifiedCompletion(task: AgentTask) -> Bool {
    let latestValidation = task.events
        .filter(deliveryIsValidationEvent)
        .sorted { $0.timestamp > $1.timestamp }
        .first
    let latestDeliverableVerification = task.events
        .filter { $0.type == TaskDeliverableVerificationEventTypes.passed
            || $0.type == TaskDeliverableVerificationEventTypes.reviewNeeded
            || $0.type == TaskDeliverableVerificationEventTypes.failed }
        .sorted { $0.timestamp > $1.timestamp }
        .first

    if let event = latestValidation,
       latestDeliverableVerification == nil || event.timestamp >= latestDeliverableVerification!.timestamp {
        return deliveryVerificationStatus(for: event) == "passed"
    }

    if let event = latestDeliverableVerification,
       let payload = TaskDeliverableVerificationCodec.decode(event.payload) {
        return payload.status == "passed"
    }

    return false
}

/// Returns true when the task has ever recorded a genuine user-initiated
/// "mark this task done" approval (`TaskEventTypes.Task.approved`,
/// `TaskLifecycleCoordinator.approveTask`), as opposed to the same event type
/// recorded when the user merely grants a runtime tool permission mid-run
/// (`approveSimilarRuntimePermissionForTask` / `approveRuntimePermissionAndContinue`,
/// which leave `task.status == .running`, not `.completed`). The two are
/// distinguished only by payload text -- there is no separate event type or
/// planID to scope by -- mirroring the same disambiguation already used in
/// `TaskThreadSnapshot.isRuntimePermissionApprovalEvent`. Intentionally
/// unscoped to "the current plan" (unlike the contract-outcome checks above):
/// the payload carries no planID, and a manual whole-task approval is a
/// whole-task signal, consistent with the unscoped `task.status` check at the
/// top of `originalGoalDelivery(for:)`. Adversarial finding: without this, a
/// task the user explicitly approved/completed -- with no plan-lifecycle or
/// validation-contract event to otherwise prove it -- reads as `.active`
/// again the moment a follow-up message resets `task.status` to `.running`.
private func originalGoalHasManualApproval(task: AgentTask) -> Bool {
    task.events.contains {
        $0.type == TaskEventTypes.Task.approved.rawValue
            && !$0.payload.localizedCaseInsensitiveContains("runtime permission approved")
    }
}

private func deliveryIsValidationEvent(_ event: TaskEvent) -> Bool {
    if event.type == TaskValidationEventTypes.contractPassed ||
        event.type == TaskValidationEventTypes.contractFailed ||
        event.type == TaskValidationEventTypes.contractOverridden {
        return true
    }
    if event.type == "task.completed" {
        return ValidationOutcomeMarker.testsPassed.matches(event.payload)
            || ValidationOutcomeMarker.aiCheckPassed.matches(event.payload)
    }
    guard event.type == "error" else { return false }
    return ValidationOutcomeMarker.testsFailed.matches(event.payload)
        || ValidationOutcomeMarker.validationError.matches(event.payload)
        || ValidationOutcomeMarker.aiCheckFlagged.matches(event.payload)
        || ValidationOutcomeMarker.aiCheckError.matches(event.payload)
}

private func deliveryVerificationStatus(for event: TaskEvent) -> String {
    if event.type == TaskValidationEventTypes.contractPassed {
        return "passed"
    }
    if event.type == TaskValidationEventTypes.contractFailed {
        return "failed"
    }
    if event.type == TaskValidationEventTypes.contractOverridden {
        return "overridden"
    }
    if event.type == "task.completed" {
        return "passed"
    }
    if ValidationOutcomeMarker.validationError.matches(event.payload)
        || ValidationOutcomeMarker.aiCheckError.matches(event.payload) {
        return "error"
    }
    return "failed"
}

/// Returns true when the most recent validation-contract outcome event for the given
/// plan is a pass or an explicit override. Mirrors the outcome-type checks in
/// `TaskContextStateManager` (`TaskValidationEventTypes.contractPassed` /
/// `.contractOverridden`), reimplemented locally against the same public event/payload
/// types since the manager's decoding helper is private.
private func originalGoalHasPassedOrOverriddenContract(task: AgentTask, planID: UUID) -> Bool {
    let outcomeEvents = task.events.filter {
        $0.type == TaskValidationEventTypes.contractPassed ||
            $0.type == TaskValidationEventTypes.contractOverridden ||
            $0.type == TaskValidationEventTypes.contractFailed
    }
    guard let latest = outcomeEvents
        .sorted(by: { $0.timestamp > $1.timestamp })
        .first(where: { deliveryDecodeContractPayload($0.payload)?.planID == planID }) else {
        return false
    }
    return latest.type == TaskValidationEventTypes.contractPassed
        || latest.type == TaskValidationEventTypes.contractOverridden
}

private func deliveryDecodeContractPayload(_ payload: String) -> TaskValidationContractEventPayload? {
    guard let data = payload.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(TaskValidationContractEventPayload.self, from: data)
}

/// Returns true when the contract's own per-assertion counts independently derive a
/// "passed" outcome (`requiredPassed == requiredTotal`, or zero required assertions
/// with every assertion terminal) even though no `contractPassed`/`contractOverridden`
/// outcome event was ever recorded. Mirrors the derived-status branch in
/// `TaskContextStateManager.validationContractState` (the `requiredPassed == requiredTotal`
/// / `allAssertionsTerminal` fallback), reimplemented locally against public event and
/// contract types so a divergent assertion-recording path (e.g. import/replay) that never
/// pairs an outcome event still gets recognized here.
private func originalGoalHasDerivedPassedContract(
    task: AgentTask,
    planID: UUID,
    contract: TaskValidationContract
) -> Bool {
    let assertionEvents = deliveryLatestAssertionEventsByID(task: task, planID: planID)
    var requiredPassed = 0
    var hasRequiredFailure = false
    var hasStartedAssertions = false
    var allAssertionsTerminal = true
    for assertion in contract.assertions {
        let status = assertionEvents[assertion.id]?.status ?? "not_run"
        if assertion.required && status == "passed" {
            requiredPassed += 1
        }
        if assertion.required && status == "failed" {
            hasRequiredFailure = true
        }
        if status == "started" {
            hasStartedAssertions = true
        }
        if !["passed", "failed", "skipped", "reviewed"].contains(status) {
            allAssertionsTerminal = false
        }
    }
    let requiredTotal = contract.assertions.filter(\.required).count
    guard !hasRequiredFailure else { return false }
    if requiredTotal > 0 {
        return requiredPassed == requiredTotal
    }
    return allAssertionsTerminal && !hasStartedAssertions
}

private func deliveryLatestAssertionEventsByID(
    task: AgentTask,
    planID: UUID
) -> [String: TaskValidationAssertionEventPayload] {
    let validationEventTypes = [
        TaskValidationEventTypes.assertionDefined,
        TaskValidationEventTypes.assertionStarted,
        TaskValidationEventTypes.assertionPassed,
        TaskValidationEventTypes.assertionFailed,
        TaskValidationEventTypes.assertionSkipped,
        TaskValidationEventTypes.assertionReviewed
    ]
    var results: [String: TaskValidationAssertionEventPayload] = [:]
    for event in task.events
        .filter({ validationEventTypes.contains($0.type) })
        .sorted(by: { $0.timestamp > $1.timestamp }) {
        guard let data = event.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TaskValidationAssertionEventPayload.self, from: data),
              payload.planID == planID,
              results[payload.assertionID] == nil else {
            continue
        }
        results[payload.assertionID] = payload
    }
    return results
}
