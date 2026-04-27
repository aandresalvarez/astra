# ASTRA — Workspace UI/UX Analysis

**Prepared for:** UX/UI team review
**Scope:** Workspace detail view (Kanban + sidebar + right inspector + bottom plugins strip)
**Method:** Heuristic critique (Nielsen + WCAG 2.1 AA) combined with SwiftUI code review to ground findings in the actual data model and state transitions.
**Date:** 2026-04-18
**Codebase snapshot:** branch `claude/serene-haibt-50c3c9`, HEAD `220b9a3`

---

## Executive Summary

ASTRA's workspace view is a confident, disciplined three-panel layout with a restrained teal accent system and strong information architecture around the edges. Its central Kanban — the product's primary surface — underperforms the surrounding chrome for three structural reasons:

1. **The column system mixes two layouts in one row.** Active and Queued render as stacked half-rails while Drafts / Open / Done are full columns. This is the single most confusing element on the screen.
2. **Two columns are semantic grab-bags.** "Active" bundles `running` (agent owns it) with `pendingUser` (user owns it) — near-opposite experiences. "Open" bundles four terminal outcomes (completed / failed / cancelled / budgetExceeded) under a word that sounds like *"not started."*
3. **Workspace plugins appear in two surfaces that agree on scope but disagree on counts.** The bottom strip says "4 Skills"; the right panel says "1 active" — a filter-predicate bug that exposes an underlying presentation duplication.

Two secondary issues are worth addressing in the same pass: empty-state inconsistency across Kanban columns, and long identifiers truncating mid-string in both cards and sidebar.

This document proposes concrete fixes for each, grounded in the current data model so the team can scope engineering effort alongside design work.

---

## 1. Methodology

- Visual critique against the provided workspace screenshot (Bigquery Analyst workspace).
- Code review of state transitions, data bindings, and view composition — cited inline with file paths and line numbers so engineering can verify.
- Git log review (last ~30 commits) to distinguish intentional design choices from accreted duplication.
- No live user-testing data informed this pass; findings are heuristic and should be validated with a short moderated session on the Kanban specifically (see §10).

---

## 2. What Works — Preserve

| Pattern | Why it works |
|---|---|
| **Restrained teal accent** | Used sparingly (primary CTA, active toggles, running indicator). Earns attention because nothing else competes. |
| **Right-panel IA** (`WorkspaceRightRailView.swift`) | Progression Plug-ins → Context → Instructions → Access → Schedules reads left-to-right from *capability* to *governance*. Sensible. |
| **Segmented tabs** (Configure / Usage / Logs) | Crisp, obviously toggleable, icons reinforce labels. |
| **Schedules sidebar entry** | "Daily at 09:00 · Jira-Support-Tickets" packs status + cadence + scope in one line. A model to emulate elsewhere. |
| **Sidebar tree structure** | Pinned → Workspaces → Schedules gives a clear mental model with minimal nesting. |
| **`isDone` separation from `status`** (`AgentTask.swift:65`) | User completion decoupled from agent outcome is a strong schema decision — the issue is presentation, not the model. |

---

## 3. Findings by Severity

### 🔴 Critical

**C1 — Kanban column hierarchy is internally inconsistent**
Active and Queued render as stacked half-rails inside one column (`KanbanBoardView.swift:155-161`) while Drafts / Open / Done are full columns. Two competing layouts in one horizontal row. "Active" — arguably the most important state — looks the least important.
*Root cause:* see §5 (state model).

---

### 🟡 Moderate

**M1 — "Active" conflates two opposite user states**
`KanbanBoardView.swift:196-199`: the Active filter is `status == .running || status == .pendingUser`. But `running` means *hands off — agent is working*, while `pendingUser` means *hands on — agent is blocked on you*. These have near-opposite user experiences.

**M2 — "Open" is a terminal-outcomes grab bag**
`KanbanBoardView.swift:208-211`: Open filters on `{completed, failed, cancelled, budgetExceeded}` — four outcomes, one column. Users cannot tell if they're looking at successes awaiting review or failures awaiting retriage. The label "Open" is also a false cognate for *unstarted*.

**M3 — Drop semantics don't match column semantics**
`KanbanBoardView.swift:232-233`: dropping a task onto "Active" sets `status = .pendingUser` — not `.running`. So the column is "running *or* pending" but the drop target is "pending only." Internally inconsistent and hard to explain.

**M4 — Empty states speak three different languages**
Active/Queued: `• 0`. Drafts: icon + "No drafts tasks". Discard: "Drop to remove". Three patterns in one row.

**M5 — Task titles truncate mid-identifier**
Example: `project-alpha-prod-eu.table_long_identifier_notes_archive`. Backticks imply code, but clipping makes IDs unreadable. Sidebar exhibits the same problem.

**M6 — Workspace plugins appear in two surfaces with divergent counts**
Bottom strip shows "4 Skills" (`WorkspaceHomeView.swift:356`); right panel shows "1 active" — both reading the same workspace. Filter predicates differ subtly between the two implementations. See §6.

**M7 — Discard has no non-drag path**
The dashed "Discard" column is drag-only. No hover affordance on cards, no keyboard path. Discoverability is poor; accessibility is worse.

---

### 🟢 Minor

**m1** — "Bigquery Analyst" title repeats three times (sidebar selection, canvas header, right-panel header). Consider a breadcrumb or a differentiated right-panel label ("Workspace settings").
**m2** — Column status dots are too small to read as signals but too present to ignore. Document meaning, scale up, or remove.
**m3** — Toolbar controls "Show All Columns" + "Hide Empty" + filter icon sit together without a clear relationship. Group under a single "View" menu.
**m4** — Folder icon weight differs between canvas title (filled teal) and right-panel header (outlined). Pick one.
**m5** — Capability counts ("9 capabilities", "8 capabilities") share type size with their row label. Demote to secondary.
**m6** — Toggle switches have no adjacent on/off label.
**m7** — Count-badge pattern inconsistent across Pinned ("2"), columns ("0"/"2"), right panel ("1 active"). Unify.

---

## 4. Accessibility

| Area | Observation | Action |
|---|---|---|
| **Color contrast** | Muted gray for "No instructions set", "Updated Apr 16…", timestamps, helper text — borderline vs. WCAG AA 4.5:1 | Audit against off-white background; darken if needed |
| **Color-only signaling** | Column status dots likely fail colorblind users if they encode state | Pair with text label or shape |
| **Touch / click targets** | Sidebar rows appear <32pt vertically; inline `+ Add tools` / `+ Add templates` links are small | Raise to ≥32pt |
| **Keyboard navigation** | Discard is drag-only (`KanbanBoardView.swift:232-245`). Keyboard users cannot move cards between columns | Add keyboard affordance; running tasks already guard against moves (`L228`) — keep |

---

## 5. Deep Dive — Proposed Task State Model

### What the code says

A task's position is determined by **two** fields:
- `status: TaskStatus` (8 cases, agent-owned) — `AgentTask.swift:4-13`: `draft`, `queued`, `running`, `pendingUser`, `completed`, `failed`, `cancelled`, `budgetExceeded`.
- `isDone: Bool` (user-owned, added 2026-04-17 in `58022a8`) — `AgentTask.swift:65`.

Current column filters (`KanbanBoardView.swift:193-217`):

| Column | Filter | Issue |
|---|---|---|
| Active | `!isDone && status ∈ {running, pendingUser}` | M1 — two opposite states |
| Queued | `!isDone && status == queued` | Clean |
| Drafts | `!isDone && status == draft` | Clean |
| Open | `!isDone && status ∈ {completed, failed, cancelled, budgetExceeded}` | M2 — four outcomes bundled |
| Done | `isDone == true` | Clean |

There is **no Discard state in code** — the dashed "Discard" zone is a UI-only drag-delete affordance. This is worth calling out as intentionally different from the columns.

### Proposed model — "One column, one blocker"

Reframe every column around the single question: *"Who is this task blocked on?"*

| # | Column | Blocked on | Agent state(s) | `isDone` |
|---|---|---|---|---|
| 1 | **Drafts** | You — to write | `draft` | false |
| 2 | **Queued** | Agent — to pick up | `queued` | false |
| 3 | **Running** | Nothing — in flight | `running` | false |
| 4 | **Needs Review** | You — to approve/reject | `pendingUser` | false |
| 5 | **Finished** | You — to file or rerun | `completed`, `failed`, `cancelled`, `budgetExceeded` | false |
| 6 | **Done** | Nothing — filed | any | true |

**Why this resolves C1/M1/M2/M3:**
- Running gets its own column. PendingUser gets its own. The two opposite experiences stop sharing real estate.
- Drop semantics become unambiguous: each column has one target status.
- Terminal outcomes are grouped under an action-oriented label ("Finished" = *this needs filing*) with per-card outcome chips (✅ success, ⚠️ failed, ✋ cancelled, 💸 budget) for at-a-glance differentiation.
- Left-to-right flow (Drafts → Queued → Running → Needs Review → Finished → Done) alternates ownership (you → agent → — → you → you → —), telling the task lifecycle as a single story.

### Migration — minimal code changes, no schema changes

1. Split `KanbanCategory.active` into `.running` + `.needsReview`; rename `.open` → `.finished` (`KanbanBoardView.swift:6-34`).
2. Update `tasksFor(_:)` (`L193`) to split the Active filter by `.running` vs. `.pendingUser`.
3. Update drop handler (`L231`): running column rejects drops; review column sets `pendingUser`; finished column clears `isDone` only.
4. Add an outcome-chip modifier on task cards in the Finished column (driven off existing `status`).
5. Extend `collapsibleLifecycleCategories` (`L159`) from `[active, queued, drafts]` to `[drafts, queued, running, needsReview]`.

**No changes to `TaskStatus` or `isDone`** — the schema is already expressive. This is purely a presentation change.

### Fallback if 6 columns feels too wide

Keep 5 columns but split Active into two stacked sub-lanes *within one column* with their own headers, counts, and drop targets. Preserves footprint; fixes M1 and M2. Does not fully fix M3.

### Discard

Promote out of the board entirely. Either a hover-revealed "Archive" action on each card, or a persistent toolbar trash button that accepts drops. Remove the dashed column — it implies a *state* that doesn't exist.

---

## 6. Deep Dive — Bottom Plugins Strip vs. Right Panel

### What the code says

Both surfaces are **workspace-scoped**, not task-scoped. The initial hypothesis (bottom = task, right = workspace) is falsified by the schema — `Skill` and `Connector` attach to `Workspace` only (`Workspace.swift:22-26`).

Both read from the same `workspace` binding and the same `@Query` over global entities:

| | Bottom strip — `activeSetup` | Right panel — PLUG-INS |
|---|---|---|
| File | `WorkspaceHomeView.swift:350` | `WorkspaceRightRailView.swift:85` |
| Skills collection | `workspace.skills.filter(!isBuiltIn) + enabledGlobalSkills` | `workspaceSkills + enabledGlobalSkills` (deduped, built-ins filtered from globals) |
| Editable? | No — navigation buttons only | Yes — inline toggles |

### Why counts diverge ("4 Skills" vs. "1 active")

Filter predicates differ slightly:

| Filter | Bottom | Right |
|---|---|---|
| Local filtered by | `!isBuiltIn` | `!isGlobal` |
| Globals filtered by | *(none)* | `!isBuiltIn` |
| Dedup | No | Yes |

This is a **bug**, not intent. A skill present both locally and as an enabled global double-counts in the bottom strip. A built-in enabled globally counts in the bottom but not the right panel.

### Recommendation

**Option A (recommended):** hide the bottom strip when the right panel is open. The duplication is only a problem on-screen simultaneously. The strip earns its keep as a quick summary when the inspector is closed.

**Option B:** remove the bottom strip entirely. The inspector is one toggle away.

**Option C:** keep both, re-role the bottom strip as "Workspace capabilities" — drop its "Configure" button (right panel owns editing), keep "Catalog" as the one cross-link, visually demote to secondary.

**In all three:** extract a shared `WorkspaceCapabilities` value type so both surfaces derive their lists from one source of truth. Counts become impossible to disagree.

Recommend **A + the shared helper.** Smallest change that removes on-screen duplication, preserves the strip's value when the inspector is closed, and fixes the count bug as a side effect.

---

## 7. Empty-State, Truncation, and Consistency Fixes

### Empty states (M4)

One pattern across all columns: **icon + short label + optional faint helper text.**

| Column | Current | Proposed |
|---|---|---|
| Running | `• 0` | 🏃 "Nothing running" |
| Needs Review | `• 0` | 👁 "Nothing to review" |
| Drafts | icon + "No drafts tasks" | ✏️ "No drafts" — drop the grammatically awkward "tasks" |
| Finished | — | ✅ "Nothing finished yet" |
| Done | — | 📦 "Nothing filed" |

### Truncation (M5)

Two changes:

1. **Middle-ellipsis** for identifier-like strings: `project-…-archive`. Preserves both the recognizable prefix and the meaningful suffix.
2. **Separate intent from dataset** in task titles. Today the title field is a grab-bag. Move table/dataset identifiers to a secondary chip beneath the title so the primary text reads as a human sentence.

### Count-badge unification (m7)

Pick one pattern and apply across sidebar, Kanban columns, right panel. Recommend: **subtle numeric badge with light background** — what Pinned already uses. Replace inline "0" / "2" in column headers and "1 active" text.

---

## 8. Prioritized Recommendations

| # | Action | Severity | Impact | Effort | Ref |
|---|---|---|---|---|---|
| 1 | Restructure Kanban to one-column-one-state (§5) | 🔴 | High | Medium | C1, M1, M2, M3 |
| 2 | Unify empty-state pattern across all columns | 🟡 | Medium | Low | M4 |
| 3 | Middle-ellipsis + separate intent from dataset on task cards | 🟡 | Medium | Low | M5 |
| 4 | Hide bottom plugin strip when right panel is open; extract `WorkspaceCapabilities` helper | 🟡 | Medium | Low | M6 |
| 5 | Add non-drag path to Discard (hover action + keyboard) | 🟡 | Medium | Low | M7 |
| 6 | Accessibility pass — contrast, color-only signaling, target sizes, keyboard nav | 🟡 | High (compliance) | Medium | §4 |
| 7 | Standardize count badges | 🟡 | Low | Low | m7 |
| 8 | Minor polish bundle — dots, icon weights, toolbar grouping, toggle labels, title repetition | 🟢 | Low | Low | m1-m6 |

**Suggested sequencing:**
- **Sprint 1 (high-impact):** items 1, 4, 5.
- **Sprint 2 (polish + a11y):** items 2, 3, 6, 7.
- **Sprint 3 (cleanup):** item 8, bundled.

---

## 9. Open Questions for the Team

1. **Do Active and Queued semantically belong on the board, or above it?** Some teams prefer the Kanban to show only user-actionable states and push "in flight" tasks to a persistent status bar. If that's aligned with ASTRA's vision, Option B in §5 becomes: 4 columns (Drafts, Needs Review, Finished, Done) + a top strip for Running/Queued counts.
2. **Is the Discard drop-zone a column, an affordance, or both?** Current code treats it as UI-only with no backing state. The design debt comes from letting it look like a column.
3. **Should `pendingUser` tasks send a notification?** They're the only state where the agent is actively blocked on the user. Today there's no UI signal outside the Kanban.
4. **Is the bottom plugin strip still earning its keep on the home view?** Worth a look at product analytics on whether users actually interact with it.
5. **What is the intended right-panel visibility default?** If it opens by default for most users, the bottom strip is almost always redundant.

---

## 10. Suggested Next Steps

1. Team review of this document; resolve open questions (§9) before spec'ing engineering work.
2. One round of **moderated usability testing** on the Kanban specifically (5–7 users, 30-min sessions). Focus task: "Show me a task that needs your attention." If users struggle to distinguish Active/Open/Done, the state model is the proximate cause.
3. Eng to verify the four cited files and line ranges against their current local branch (this review was against `claude/serene-haibt-50c3c9` at HEAD `220b9a3`).
4. Design to produce a revised Kanban mock using the proposed 6-column model; run it past the team before implementation.
5. Schedule a **focused a11y audit pass** (contrast, keyboard nav, color-only signaling) — likely needed for compliance regardless of the above.
6. Post-implementation: re-review the Kanban and plugins surfaces; confirm count bug is gone and column semantics are legible to new users.

---

## Appendix — File Reference Index

| Concern | File | Key lines |
|---|---|---|
| Task state enum | `Astra/Models/AgentTask.swift` | 4-13, 65 |
| Kanban filter logic | `Astra/Views/Components/KanbanBoardView.swift` | 193-217 |
| Kanban drop handler | `Astra/Views/Components/KanbanBoardView.swift` | 219-252 |
| Kanban collapsible categories | `Astra/Views/Components/KanbanBoardView.swift` | 155-161 |
| Bottom plugins strip | `Astra/Views/WorkspaceHomeView.swift` | 23-47, 350-417 |
| Right panel plug-ins section | `Astra/Views/WorkspaceRightRailView.swift` | 85-122, 249-267 |
| Workspace ↔ Skill/Connector relationships | `Astra/Models/Workspace.swift` | 22-26 |

---

*Reviewer: Claude · Document v1 · 2026-04-18*
