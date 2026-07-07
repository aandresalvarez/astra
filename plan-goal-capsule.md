# Plan: Stop long threads from re-anchoring to a stale original goal

## Problem

On long threads the original `AgentTask.goal` is often already delivered and the
real work has moved on, but the agent keeps trying to re-address the original goal
every turn. Two mechanical causes:

1. **Unconditional goal injection.** `FollowUpIntroSectionProvider` emits
   `Goal: <task.goal>` verbatim on every follow-up turn
   (`Astra/Services/Runtime/AgentPromptBuilder.swift:695`), and the follow-up
   artifact contract (`:700`) re-asserts "your first action must be a file write."
   Neither is aware of whether the goal is already done.
2. **Objective only pivots on exact phrases.** `activeObjectiveResolution` supersedes
   the original goal only when a later message contains one of ~18 hardcoded markers
   (`Astra/Services/Persistence/TaskActiveObjectiveResolver.swift:236`). Natural drift
   ("great, now also do X") matches nothing, so `Current objective` stays pinned to
   the original goal.

The capsule already computes the signal we need — `mode == .completed` and
`verification.completionVerified` (`TaskContextStateManager.swift:1656`, `:83`) — but
nothing in the prompt framing reads it.

## Goals / Non-goals

**Goals**
- Tier 1: when the original goal is *structurally* delivered, demote it from an
  imperative to background context — deterministic, zero model cost.
- Tier 2: when the goal is *informally* satisfied with no structured signal, use the
  Utility Model to detect the pivot — gated so it costs ~1 call per drift episode.

**Non-goals**
- Never delete the original goal. It stays as `startingRequest` background so the
  user can always say "go back to X." Everything here is demotion, not deletion.
- No change to the initial-run prompt path (`currentTaskBlock` `:161`,
  `InitialTaskDetailsSectionProvider` `:953`) — a first run cannot be "delivered."

## Invariants to preserve
- **Never silently re-anchor.** When we demote/pivot the objective, always emit an
  `objectiveDivergenceNote`-style line so it is auditable and reversible.
- **Nothing expensive on the refresh/render path.** `refresh` / `promptContext` run
  synchronously on task open. The Tier 2 model call MUST be async/background and must
  never block prompt assembly (same invariant behind the recent render-path fixes).
- **Fail safe.** Any Tier 2 uncertainty or failure resolves to `original_active`
  (i.e. current behavior), never to abandoning an unfinished goal.
- **Fitness budgets.** `AgentPromptBuilder.swift` and `TaskContextStateManager.swift`
  are large owner files with per-file line caps. Keep each diff compact; prefer new
  small files over growing these.

---

# Tier 1 — Deterministic completion-aware framing (no model)

Handles the common case: the goal reached a structured completion signal
(`task.status == .completed`, plan lifecycle `.completed`, or
`verification.completionVerified`).

## PR 1 — Deterministic "original goal delivered?" classifier
**What**
- Add a pure classifier, e.g.
  `TaskContextStateManager.originalGoalDelivery(for: AgentTask) -> OriginalGoalStatus`
  returning `.active` or `.delivered`.
- Compute it from the SAME inputs `inferredMode` (`:1637`) and `verificationState`
  already use — `task.status`, plan lifecycle, verification events — **not** from the
  persisted capsule file, to avoid any refresh-ordering/staleness coupling.
- Factor the shared bits out of the currently-private `inferredMode` if needed.

**Tests** (`Tests/` — new `OriginalGoalDeliveryTests.swift`)
- Table: (task.status, plan lifecycle, verification.status/completionVerified) →
  expected `.active` / `.delivered`.
- Edge cases: plan-less conversational thread that completed via `task.status`;
  executing plan → `.active`; blocked/failed → `.active`.

**Parallelizable?** Standalone. No dependency. Pure + fully unit-tested.

## PR 2 — Apply completion-aware framing in the follow-up prompt
**What** (depends on PR 1)
- In `FollowUpIntroSectionProvider` (`AgentPromptBuilder.swift:679`):
  - `.active` → unchanged (`Goal: <task.goal>`).
  - `.delivered` → replace with:
    `Original request (already delivered — background context only; do not
    re-address unless the user asks): <task.goal>`, and rely on the capsule's
    `Current objective` (already injected via `appendThreadIntentContext` `:1403`)
    for the live directive.
- Suppress the follow-up artifact contract (`:700`) when `.delivered` so it stops
  re-triggering redelivery.
- Emit a one-line transparency note in the section when demoting.

**Tests** (`Tests/HeadlessChatScenarioTests.swift` or new
`FollowUpGoalFramingTests.swift`)
- Delivered-goal task: assembled prompt does **not** contain the imperative
  `Goal:` / artifact-first-action phrasing; **does** contain the background phrasing.
- Active-goal task: prompt unchanged (regression guard).
- Snapshot of the follow-up section for both states.

**Parallelizable?** No — depends on PR 1's API. Sequential (PR 1 → PR 2).

> **Tier 1 ships and is validated on its own before any Tier 2 work begins.**

---

# Tier 2 — Utility-model objective assessment (gated, async, off-path)

Handles implicit drift: goal informally satisfied, no structured completion signal.
Runs the Utility Model only when the cheap deterministic layer is ambiguous.

## PR 3 — Capsule field for the assessment verdict
**What**
- Add optional `objectiveAssessment` to `TaskContextState`
  (`TaskContextStateManager.swift`):
  ```
  struct ObjectiveAssessment: Codable, Sendable, Equatable {
      var verdict: String        // "original_active" | "original_satisfied" | "superseded"
      var currentObjective: String?   // only when superseded
      var assessedAtTurn: Int
      var inputHash: String
  }
  var objectiveAssessment: ObjectiveAssessment?
  ```
- Use `decodeIfPresent` and **keep `schemaVersion = 2`** — an added optional field is
  backward/forward compatible (old capsules decode as `nil`; older app builds ignore
  the extra key). No migration needed. (This is the capsule JSON schema, unrelated to
  the SwiftData `ASTRASchemaV*`.)
- Render it in `promptContext` (`:407`) and `renderMarkdown` (`:529`) when present.

**Tests** (`Tests/CompactionTests.swift` / new `ObjectiveAssessmentCodableTests.swift`)
- Encode/decode round-trip.
- A v2 capsule JSON **without** the field decodes with `objectiveAssessment == nil`.
- `promptContext` includes the assessment line only when present.

**Parallelizable?** Independent of PR 4. Can run in parallel. (Depends on nothing.)

## PR 4 — Deterministic trigger predicate (no model call)
**What**
- Pure function, field-agnostic (takes primitives, not the capsule, so it is
  independent of PR 3):
  ```
  shouldAssessObjective(
      turnCount: Int,
      hasSubstantiveLaterUserMessage: Bool,
      hasExplicitObjectiveMarker: Bool,
      currentInputHash: String,
      lastInputHash: String?,
      lastAssessedAtTurn: Int?,
      currentTurn: Int
  ) -> Bool
  ```
  Fires only when ALL hold:
  1. `turnCount >= threshold` (~6).
  2. `hasSubstantiveLaterUserMessage` (reuse `isLowSignalObjectiveAcknowledgement`
     to ignore "ok/thanks").
  3. `!hasExplicitObjectiveMarker` (the deterministic resolver already handles those).
  4. `currentInputHash != lastInputHash` **or** last assessment is ≥ N turns stale
     (debounce floor).
- Add `objectiveInputHash(for: AgentTask) -> String` over
  {original goal + recent user turns + verification status}.

**Tests** (new `ObjectiveAssessmentTriggerTests.swift`)
- Table covering each gate on/off → expected fire/skip.
- Hash stability: same inputs → same hash; changed later message → different hash.
- Debounce: unchanged hash within N turns → skip; after N turns → fire.

**Parallelizable?** Yes — independent of PR 3 (pure primitives). PR 3 ∥ PR 4.

## PR 5 — Utility-model assessor job (async, background, off-path)
**What** (depends on PR 3 + PR 4)
- New `ObjectiveAssessmentService`:
  - Builds a tight, low-reasoning prompt: original goal + recent user turns +
    verification status → strict JSON
    `{"verdict": "...", "currentObjective": "..."}`.
  - Calls the Utility Model through the SAME utility-prompt plumbing title
    generation uses (SpecEngine's `runUtilityPrompt`), honoring the Utility Model
    setting + Execution timeout.
  - Parses strict JSON; writes `objectiveAssessment` back via `saveState`.
- **Invocation site:** background, after a run completes / after `recordTurn`,
  gated by PR 4's predicate. **Never** inline in `refresh` / `promptContext`.
- Robustness: timeout, low reasoning; malformed/empty output or provider error →
  leave prior verdict untouched (fail-safe to `original_active`).
- Feature flag: gate the model call behind a setting (e.g. "Objective drift
  detection") so the cost is opt-in; when off, Tier 1 still fully applies.
- Add an audit event (extend `AppLogger.audit(.contextStateUpdated ...)` pattern or a
  new `.objectiveReassessed`) recording verdict + whether a call was made.

**Tests** (new `ObjectiveAssessmentServiceTests.swift` with a stub utility provider)
- Stub returns canned JSON → verdict persisted into capsule.
- Malformed JSON → no-op, prior verdict retained.
- Gate predicate false → provider never invoked (assert zero calls).
- Provider timeout/error → fail-safe, capsule unchanged.

**Parallelizable?** No — needs PR 3 (field) + PR 4 (predicate). Sequential after both.

## PR 6 — Consume the verdict in prompt framing
**What** (depends on PR 3 + PR 2; independent of PR 5 at code level)
- Extend Tier 1 framing to read `objectiveAssessment.verdict`:
  - `original_satisfied` → same demotion as Tier 1 `.delivered`.
  - `superseded` → demote original goal **and** set the live directive to
    `objectiveAssessment.currentObjective`; emit divergence note.
  - `original_active` / `nil` → unchanged.
- The prompt builder only READS the persisted verdict — it never triggers or waits
  for the model (eventual consistency; worst case one stale turn between drift and
  the background verdict landing).

**Tests** (`FollowUpGoalFramingTests.swift`)
- `superseded` assessment → prompt uses `currentObjective`, original demoted,
  divergence note present.
- `original_active` / no assessment → identical to Tier 1 behavior (regression).

**Parallelizable?** Can proceed once PR 3 + PR 2 land, in parallel with PR 5 (it only
reads the field; verdicts simply stay `nil` until PR 5 produces them).

---

# Dependency & parallelization summary

| PR | Title | Depends on | Can run in parallel with |
|----|-------|-----------|--------------------------|
| 1 | Deterministic delivery classifier | — | (start immediately) |
| 2 | Apply Tier 1 framing | PR 1 | — |
| 3 | Capsule assessment field | — | PR 1, PR 4 |
| 4 | Trigger predicate (pure) | — | PR 1, PR 3 |
| 5 | Utility-model assessor job | PR 3, PR 4 | PR 6 |
| 6 | Consume verdict in framing | PR 3, PR 2 | PR 5 |

**Critical path:** PR 1 → PR 2 (Tier 1, shippable alone) → then PR 3/PR 4 (parallel)
→ PR 5 and PR 6 (parallel) for Tier 2.

**Recommended sequencing**
1. Land PR 1 → PR 2, validate Tier 1 in real long threads. This alone should remove
   most of the observed re-anchoring at zero cost.
2. Only if implicit drift is still a problem, proceed with Tier 2 (PR 3–6) behind the
   feature flag.

# Risks & mitigations
- **False "delivered" (Tier 1):** classifier keys off structured signals only; a
  plan-less thread may under-fire (stays `.active`) — safe direction (no regression).
- **Wrong pivot (Tier 2):** fail-safe to `original_active`; divergence note keeps it
  reversible; user can always restate the goal.
- **Cost creep (Tier 2):** change-hash + debounce + feature flag bound calls to ~1
  per drift episode; gate 3 (skip when an explicit marker exists) avoids paying when
  the deterministic path already knows the answer.
- **Latency on the turn:** none — the assessor is background/off-path; the prompt
  builder reads only persisted state.
