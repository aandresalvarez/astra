# Validation and Completion Policy

ASTRA separates runtime success from task completion. A provider process can
exit successfully while the task still needs artifact verification, validation
evidence, or user review.

## Completion Flow

`AgentRuntimeWorker` owns the primary completion transition after a runtime
returns:

1. Mark the run completed when the provider exits with code `0`.
2. Apply budget warnings.
3. Run deliverable verification when the task appears to require a standalone
   artifact.
4. If the adapter requires validation for the phase, apply the task validation
   strategy: manual, configured test command, or AI check.
5. For manual completion, verify required standalone artifacts before marking
   the task complete.
6. Optionally run inferred baseline validation after successful manual
   completion.
7. Persist events, artifacts, context state, handoff, mission checkpoint, and
   workspace config.

## Validation Contracts

`ValidationService.runContract(...)` evaluates a plan validation contract when
one exists. It records assertion-started and assertion-result events, computes
failed required assertions, records a contract passed or failed event, and
returns `canComplete`.

Supported assertion methods currently include command, artifact, manual,
structured text evidence, text-contains, browser behavior, and verifier review.
Command assertions are allowlisted, and artifact/text paths must resolve inside
the task folder or workspace.

## Gates

- Deliverable verification can block completion by setting the run failed,
  using stop reasons such as `no_usable_result` or
  `deliverable_verification_failed`, and returning the task to
  `pending_user`.
- Missing required standalone artifacts block manual completion with
  `no_usable_result`.
- Failed required validation assertions block plan completion and leave the task
  pending user review.
- Failed configured test validation marks the task failed; validation errors
  return the task to pending user review.
- AI-check failures return the task to pending user review.
- `TaskRunLifecycleService` and `PendingTaskReviewPolicy` handle user approval,
  dismissal, recovery, and artifact-attention states after a run has completed
  or failed.

## Invariants

- A successful provider exit is not sufficient evidence of task completion.
- Required validation assertions must pass before a validation contract can
  allow completion.
- Review-needed outcomes should surface as pending user decisions rather than
  silent task completion.
- `task.completedAt` is set during final persistence only when the task is in a
  terminal status; pending-user review clears completion time.
- User dismissal of a failed run acknowledges review state without necessarily
  marking the task completed.

## Related Files

- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `Astra/Services/Validation/ValidationService.swift`
- `Astra/Services/Validation/TaskDeliverableVerificationService.swift`
- `Astra/Services/Validation/TaskInferredValidationService.swift`
- `Astra/Services/Tasks/PendingTaskReviewPolicy.swift`
- `Astra/Services/Tasks/TaskRunLifecycleService.swift`
- `Astra/Services/Tasks/TaskPlanService.swift`
- `Astra/Models/AgentTask.swift`
- `Astra/Models/TaskRun.swift`
