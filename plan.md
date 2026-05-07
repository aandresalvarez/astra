# Plan Mode Execution Plan

## Goal

Make Plan mode a first-class ASTRA workflow for both new tasks and existing task threads. Planning must be read-only until the user explicitly confirms execution, and the right rail should show the approved plan and execution progress.

## Product Rules

- Planning does not execute tools, mutate files, or start a runtime task.
- The user must confirm with **Run plan** before execution starts.
- The approved plan is stored as task events, not a new SwiftData schema.
- Review/Auto mode remains the execution safety boundary.
- Claude Code and GitHub Copilot CLI use the same ASTRA-level plan behavior.
- Runtime step progress is reported with `ASTRA_EVENT plan.step.*` markers and shown in the Plan panel.

## Event Model

Use task events:

- `plan.created`
- `plan.updated`
- `plan.approved`
- `plan.cancelled`
- `plan.execution.started`
- `plan.execution.completed`
- `plan.step.started`
- `plan.step.completed`
- `plan.step.blocked`
- `plan.step.skipped`
- `plan.user.message`
- `plan.assistant.message`

The structured plan payload has a `planID`, `title`, `goal`, and ordered `steps` with stable ids, status, risk, likely tools, and done signals.

## Execution Model

ASTRA sends the full approved plan to the selected runtime for context, then tracks step progress from runtime events. ASTRA only needs step-by-step prompting at boundaries such as blocked permissions, high-risk checkpoints, edited remaining steps, or runtime switching.

## UX

- New-task Plan mode creates a draft task and a plan, but no `TaskRun`.
- Existing-task Plan mode records planning messages and plan events, but does not call `continueSession`.
- The right rail includes a **Plan** tab that shows steps, status, risk, likely tools, runtime, permission mode, and Run/Edit/Cancel controls.
- During execution, the current step is highlighted and blocked/completed/skipped steps are visible.

## Diagnostics

Telemetry should emit bounded `plan.*` lifecycle and step events. Diagnostics should report active blocked or stalled plans, but suppress blockers that are later resolved by progress, cancellation, or task completion.

## Verification

Run focused parser/service/runtime/diagnostics tests first, then `swift test`, `git diff --check`, and `./script/build_and_run.sh --verify`.
