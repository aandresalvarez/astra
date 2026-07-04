# Post-Rollup Architecture Backlog — PR Plan

**Date:** 2026-07-04
**Baseline:** `main @ 857cec9` (merge of PR #177 — the full 2026-07-01 architectural-review rollup: 22 stacked branches, 8 follow-up PRs #178–#185, and 10 post-merge adversarial-review fixes).
**Predecessors:** `docs/specs/2026-06-04-architecture-debt-pr-plan.md` (superseded), `docs/architecture/swiftpm-target-extraction-models-persistence.md` (still authoritative for Track A).

This document is the single list of what architectural work remains after the rollup, organized as concrete PRs with an adversarial-review charge for each, and an explicit map of what can run in parallel.

---

## 1. What is already done (do not re-open)

Verified against `main @ 857cec9` — these appear in older docs/reviews as open items but are **closed**:

| Formerly-open item | Status on main |
| --- | --- |
| 6 P0 defects (stranded-running, token resets, first-wins transcripts, per-body disk IO, schema freeze hazard, unbounded mirror) | Fixed, regression-tested |
| Policy render as sole launch-arg source; duplicate mode-clamp | Done (single `ProviderPolicyModeResolver`) |
| Policy vocabulary collapse | Done + **proven correct**: 3-case `PermissionPolicy` is the genuine ceiling for 4/6 provider CLIs; Claude/Copilot fine-grained enforcement flows through `AgentPolicy` tool lists (regression-tested: locked ≠ review in rendered enforcement) |
| Event-recorder convergence (one recorder, 6 providers) | Done, including failed-run accounting, repeated-edit, and tool-use-transcript fidelity fixes |
| `HardenedProcessExecutor` / `ProcessGroupSpawn` rollout | Done (group set at spawn, pre-exec) |
| `MCPServerKit` rollout | Done for HostControl + MCPGateway + Workspace (BrowserMCPServer deliberately excluded — see §6) |
| Browser: engine operation protocol, Google Workspace extraction, unified batch dispatch | Done (`ShelfBrowserSession` 5,879 → ~4,414 lines) |
| Credential egress ask path (`PermissionBroker` `.credential`) | Implemented (no longer vestigial) |
| Dead code: `MCPToolPolicyEngine`, `ChatBubbleView`, `WorkspaceAppWebViewBridge` | Removed |
| UTF-8 chunk/truncation robustness (BinaryRunner + both AgentRuntimeProcessRunner paths) | Fixed |
| CI deadlock (full suite hung 6 h, 0 tests completing) | Root-caused + fixed; `--no-parallel` validated (4,415 tests in ~187 s serialized) |

---

## 2. Review protocol (applies to every PR below)

Each PR ships with a three-step review, mirroring what caught 10 real bugs during the rollup:

1. **Self-gate:** `swift build` clean; `script/prepush.sh` green; suite(s) named in the PR card pass; budget bumps only with justification in the commit message.
2. **Adversarial pass:** request `@codex review`, and paste the PR card's *adversarial charge* into the PR description as explicit refutation prompts. The reviewer's job is to **refute** the PR's claim, not to approve it. Every finding gets a fix-or-documented-rebuttal comment; all threads resolved before merge.
3. **Fidelity rule:** refactor PRs (Tracks A, C, D, E) must state their equivalence claim ("no behavior change" / "identical bytes on the wire" / "same save ordering") in the description — that claim is what the adversarial pass attacks.

**Conflict-hotspot etiquette:** `Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift` (budget table + save allowlist) is touched by most PRs; conflicts there are trivial — rebase last, re-run the fitness suite, never resolve by deleting the other PR's entry. `Package.swift` belongs to Track A alone.

---

## 3. Parallelization map

```
Wave 1 (all parallel, separate worktrees):
  A1  AppLogger → leaf target            [starts the serial A-chain]
  B1  Stabilize abandoned-pipe test      [tiny]
  C1  Saves: Tasks/ batch                [disjoint files]
  C2  Saves: WorkspaceApps/ batch        [disjoint files]
  D1  Right-panel single owner           [Views only]
  F1  Delete orphan ASTRAUITests         [trivial]

Wave 2:
  A2  Break Runtime↔Models cycle         [needs A1]
  B2  Re-enable per-PR full suite        [needs B1 + green dispatch run]
  C3  Saves: Views batch                 [disjoint from C1/C2]
  E1  AgentProcessRunning seam           [independent; avoid landing same day as A2 — adjacent Runtime files]

Wave 3:
  A3  Extract ASTRAModels target          [needs A2]
  A4  Extract ASTRAPersistence target     [needs A3]
```

Hard dependencies are only inside Track A and B. Everything else is limited by review bandwidth, not by code coupling.

| | A1 | A2 | A3/A4 | B1 | B2 | C1–C3 | D1 | E1 | F1 |
|---|---|---|---|---|---|---|---|---|---|
| **Files that overlap** | Package.swift, Logger.swift, mass imports | ASTRACore + Models refs | Package.swift, Models/, Persistence/ | 1 test file | ci.yml | 18 allowlisted files, disjoint batches | Views/ right-rail | Runtime launch context | ASTRAUITests/ |
| **Safe alongside** | everything except A2+ | A-chain only | A-chain only | everything | everything | everything (incl. each other) | everything | everything except A2 same-day | everything |

---

## 4. Track cards

### Track A — Modularization chain (the highest-leverage work; SERIAL)

The 216k-line single `ASTRA` target is why builds/type-checks are slow and why file budgets keep rising. The extraction is **blocked, not just undone** — `docs/architecture/swiftpm-target-extraction-models-persistence.md` is the authoritative analysis; these PRs execute its chain in order.

#### A1 — Extract `AppLogger` into a leaf `ASTRALogging` target
- **Why first:** `AppLogger` (defined in `Astra/Services/Diagnostics/Logger.swift:415`) is imported-by-everything and depends-on-nothing app-specific; it is the reference the extraction doc identifies as the first knot to cut.
- **Scope:** new SwiftPM leaf target (Foundation/os only); move the logger + audit-event vocabulary; add `import ASTRALogging` across the app (mechanically large, semantically nil).
- **Size:** large diff / small brain. One session.
- **Adversarial charge:** *Refute that logging is byte-identical: audit event names, categories, levels, and field ordering unchanged (diff a captured log run before/after). Refute the new target is leaf: it must import nothing from ASTRA/ASTRACore. Refute no perf cliff: cross-module calls on hot paths (`AppLogger.audit` in stream loops) — check inlinability. Refute no fitness regression.*
- **Done when:** target builds standalone; full suite green; extraction doc's "phase 1" checked off.

#### A2 — Break the Runtime↔Models cycle
- **Scope:** per the extraction doc — invert or relocate the specific Runtime-type references inside model files (protocol seams or moving enums to `ASTRACore`) so `Models` no longer needs `Runtime`.
- **Size:** the thinking-heavy PR of the chain. Keep it *reference-moves only* — no behavior.
- **Adversarial charge:** *Refute acyclicity: produce the import graph after the change and show Models → Runtime edges are zero. Refute type-identity breakage: SwiftData model schema must hash identically (V-current must not need a bump — verify container opens an existing store). Refute Codable stability for any moved enum (raw values, coding keys byte-identical).*
- **Done when:** `swift package show-dependencies`-level cleanliness for the future Models target is demonstrable; schema untouched.

#### A3 — Extract `ASTRAModels` target
- **Scope:** move `Astra/Models/*` into a target depending only on `ASTRACore` (+ `ASTRALogging`).
- **Adversarial charge:** *Refute store compatibility: an app built from this PR must open a store created by `main` (manual + automated migration test). Refute access-level drift: internals that became `public` — audit each for least exposure. Refute the schema-freeze hazard is respected (`SchemaVersions.swift`: versioned schemas V7–V10 still reference live model classes rather than frozen copies; extraction must not silently change what those aliases point to).*
- **Done when:** `ASTRAModels` builds + tests standalone; incremental app build time measurably drops (record before/after numbers in the PR).

#### A4 — Extract `ASTRAPersistence` target
- **Scope:** `Astra/Services/Persistence/*` → target depending on `ASTRAModels`.
- **Adversarial charge:** *Refute mirror-file byte-stability: `.astra-workspace.json` export from before/after must diff empty for the same store. Refute recovery-path parity (store-aside + rehydrate). Refute main-actor assumptions still hold across the module boundary.*
- **Done when:** same as A3, plus the persistence fitness tests run inside the new target. Stretch: **lower** `WorkspaceConfigManager.swift`'s 2,800 budget after any splitting this enables.

### Track B — CI: make the full suite gate PRs again (SERIAL, tiny)

#### B1 — Stabilize `HostControlToolSupportTests` "abandoned pipe reads"
- **Why:** the deadlock is fixed and validated; this **one timing-sensitive test** (`Tests/HostControlToolSupportTests.swift:1025` — orphan `(sleep 2; …) &` vs a 5 s cap) is now the only blocker to per-PR gating. It flaked even serialized (run 28687236618: 6 issues, all in this test; the other 4,414 tests passed).
- **Scope:** make the timing deterministic (signal pipe-abandonment explicitly rather than racing wall-clock), or as fallback mark the suite `.serialized` with wide margins. Do **not** delete the assertions.
- **Adversarial charge:** *Refute stability: 50 consecutive local runs + one serialized full-suite run, zero flakes. Refute weakened safety: the properties under test (abandoned reads reported as truncated, `exit_code: 125`, secret prefixes never leak — `super-secr`/`et-token` assertions) must survive verbatim.*

#### B2 — Re-enable per-PR full-suite gating
- **Prereq:** B1 merged **and** one green `workflow_dispatch` run of the full suite (the rule encoded in `ci.yml`'s job comment: never re-enable per-PR gating on faith — the 2026-07-03 deadlock burned four 6-hour runners before it was caught).
- **Scope:** `ci.yml`: add `pull_request` back to `full-swift-test-suite`'s triggers, **keeping** `swift test --no-parallel` and `timeout-minutes: 150`; make it a required check.
- **Adversarial charge:** *Refute pool-exhaustion regression: the job must keep `--no-parallel` (or prove the process-spawning suites are `.serialized`). Refute runner-economics harm: estimate macOS-runner minutes/PR at current PR volume; confirm the 150 min cap + concurrency won't rebuild the queue starvation that motivated the revert. Refute fitness-test conflicts ("Repository protection artifacts stay wired" asserts ci.yml contents).*

### Track C — Retire the raw-`save()` allowlist (PARALLEL batches)

18 files remain on the migrate-later allowlist in `ArchitectureFitnessTests.swift` (blanket scan already blocks new offenders). Batches are file-disjoint → fully parallelizable, including with each other.

- **C1 — Tasks batch:** `TaskLifecycleCoordinator`, `TaskQueue`, `TaskRunLifecycleService`, `TaskStateMachine`, `AgentRuntimeBudgetPolicy`, `TaskExecutionArtifactPreparer`.
- **C2 — WorkspaceApps batch:** `WorkspaceAppService`, `WorkspaceAppVersionService`, `WorkspaceAppAutomationExecutionService`, `WorkspaceAppRunResumptionService`, `CapabilityDefinitionRepairService`.
- **C3 — Views + app batch:** `ASTRAApp`, `ChatPanelView`, `TaskDetailView`, `TaskSidebarView`, `KanbanBoardView`, `WorkspaceCanvasPanelView`, `GoogleWorkspaceCapabilityInstallSheet`.
- **Scope per PR:** route each `modelContext.save()` through `WorkspacePersistenceCoordinator`; delete the file from the allowlist in the same commit (the fitness test then enforces it forever).
- **Adversarial charge (all batches):** *Refute save-semantics drift: the coordinator debounces/coalesces — find any call site that relied on a synchronous, immediate save (e.g., save-then-read-in-same-tick, save-before-process-spawn, save-in-`deinit`/termination paths) and prove each is either safe under coalescing or explicitly flushed. Refute error-handling changes: sites that `try?`-swallowed vs the coordinator's reporting. `TaskStateMachine` and `TaskQueue` are the dangerous ones — status transitions must persist before workers observe them.*
- **Done when:** allowlist is empty and the escape-hatch comment is deleted.

### Track D — Right-panel presentation: one owner (PARALLEL)

#### D1 — `RightPanelPresentationModel`
- **Why:** the sidebar's multi-writer bug class was fixed by giving it a single owner (`SidebarPresentationModel` — the repo's reference pattern); the right panel still has ~3 independent writers (the residual instance of that class).
- **Scope:** enumerate every writer/reader of right-panel visibility/width/content state (the enumeration is part of the PR); consolidate behind one observable model, mirroring the sidebar fix commit-for-commit where possible.
- **Adversarial charge:** *Refute completeness of the writer census (grep-audit in review). Refute behavior parity for: relaunch restore, mid-drag collapse, keyboard toggle during animation, and interaction with `navigationSplitViewColumnWidth` placement (the width spec must stay the outermost modifier — enforced by the "Docked sidebar keeps its column width spec outermost" fitness test; don't regress its right-panel analog).*

### Track E — Process seam (PARALLEL)

#### E1 — `AgentProcessRunning` protocol + value-type launch context
- **Why:** `AgentRuntimeProcessLaunchContext` embeds the live `AgentTask` SwiftData model, so process launch code can touch the model store from launch paths, and adapters can't be tested against a fake runner.
- **Scope:** snapshot the fields launch actually reads into a `Sendable` value type; introduce the protocol seam so tests inject a fake process runner.
- **Adversarial charge:** *Refute snapshot completeness: field-by-field audit of every `task.` read downstream of launch — each is either in the snapshot or proven launch-invariant. Refute staleness hazards: identify reads that intentionally observed **live** mutations mid-launch (approvals arriving between plan and spawn) — those must stay live or re-read at a defined point. Refute Sendable correctness (no smuggled reference types).*

### Track F — Cleanup (PARALLEL, trivial)

#### F1 — Delete orphan `ASTRAUITests/`
- One unreferenced file, no target wires it. Delete; grep for stragglers from the old dead-code list while in there.
- **Adversarial charge:** *Refute "unreferenced": search Package.swift, schemes, CI, scripts.*

---

## 5. Not PRs — housekeeping

- **Prune worktrees/branches:** 26 stale `arch-review-pr*` / `followup-*` worktrees plus their merged branches. `git worktree list | grep -E 'arch-review-pr|followup-' `→ `git worktree remove` each → `git worktree prune` → delete merged remotes (`git push origin --delete …` after `gh pr list --state merged` cross-check). Keep `arch-review-rollup-local-validation` until B2 lands (it is the warm-cache validation environment).
- **Budget watch:** budgets raised during the rollup (`AgentRuntimeAdapterTests` 3,200; `WorkspaceConfigManager` 2,800; `GitService` 2,100; `AgentPolicyTests` 2,650; `WorkspacePersistenceTests` 2,450). Direction should reverse as Track A lands — treat any *further* bump in these files as a review flag, not a routine fix.

---

## 6. Explicit non-items (decided, documented — do not re-litigate)

| Item | Decision & where it's recorded |
| --- | --- |
| `readPage` / `navigate` / `reload` in the browser engine protocol | Excluded on purpose — genuinely asymmetric embedded/controlled behavior; forcing them changes behavior, not location (PR #184 description) |
| `BrowserMCPServer` on `MCPServerKit` | Excluded on purpose — async dispatch mismatch + `Tools/`↔`ASTRACore` layering inversion risk (commit `94815dd` message) |
| `approvedPlanAllowedTools` "5th resolution" | Design decision, not a gap — resolve-once is architecturally blocked by snapshot ordering (`refreshForFreshRun` runs inside `execute()`, after the policy input is built); documented in place (commit `bc099da`) |
| A 4th/5th `PermissionPolicy` case | Rejected — 3 cases proven to be the ceiling for 4/6 provider CLIs; finer enforcement flows through `AgentPolicy` tool lists (PR #181 tests) |
| Folding App Studio chat into `AgentTask`/`ChatPanelView` | Separate surface by design — different turn semantics (ephemeral `StudioMessage`, no run/resume lifecycle); agreed direction is persist-conversation + extract-shared-components, not a merge |
