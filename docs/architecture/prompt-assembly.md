# Prompt Assembly and Context Capsule Contract

`AgentPromptBuilder` owns prompt construction. It builds a manifest-backed,
budgeted prompt from task state, workspace state, memories, capabilities,
recent transcript, task output, and the Context Capsule.

## Owners

- `AgentPromptBuilder` assembles initial, follow-up, and approved-plan prompts.
- `TaskContextStateManager` writes `current_state.json` and
  `current_state.md`, labeled in prompts as `Context Capsule v2`.
- `PromptAssemblyManifest` records included sections, token budgets, estimated
  original and included token counts, truncation state, and source pointers.
- `PromptContextPreviewView` presents the manifest for "What will be sent"
  inspection.

## Assembly Flow

1. Build raw sections from task goal, constraints, acceptance criteria,
   workspace instructions, workspace memories, capabilities, selected skills,
   tools, task state, recent transcript, task outputs, browser/mail context,
   and runtime protocol instructions.
2. Merge sections by `PromptContextSectionKind`.
3. Apply the selected `PromptContextBudgetProfile`.
4. Replace omitted or truncated content with a budget notice and durable source
   pointers.
5. Join budgeted sections into the provider prompt and return a
   `PromptAssemblyManifest`.

Follow-up prompts rebuild ASTRA state instead of relying only on provider
memory. When provider-native continuation is available, the prompt explicitly
states that the Context Capsule and Context Source Index remain authoritative.

## Context Capsule

`current_state` is task-local compact memory. It carries the current objective,
constraints, acceptance criteria, decisions, blockers, changed files,
artifacts, verification state, validation contract state, handoff, corrective
work, next action, and source pointers.

Workspace memories are separate. Prompt text identifies them as
workspace-saved memories and instructs the provider to use `Context Capsule
v2/current_state` for task objective, decisions, blockers, changed files, and
verification.

## Invariants

- Prompt assembly is deterministic for a stable task state and budget profile.
- Every budgeted section should carry source pointers when durable sources
  exist.
- Truncation must preserve a pointer to omitted detail instead of silently
  dropping context.
- Task-local state belongs in the Context Capsule; workspace memories belong in
  workspace memory retrieval.
- ASTRA-owned files in the task folder are readable context, not deliverables
  for the provider to overwrite.

## Related Files

- `Astra/Services/Runtime/AgentPromptBuilder.swift`
- `Astra/Services/Persistence/TaskContextStateManager.swift`
- `Astra/Views/PromptContextPreviewView.swift`
- `Astra/Services/Runtime/AgentRuntimeWorker.swift`
- `Tests/AgentRuntimeWorkerTests.swift`
- `Tests/TaskContextStateTests.swift`
- `Tests/PromptContextPreviewPresentationTests.swift`
