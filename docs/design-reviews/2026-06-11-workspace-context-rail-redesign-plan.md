# Workspace context rail redesign — implementation plan

Date: 2026-06-11
Status: Proposed (Phases 0–3 ready to execute; Phase 4 items are individual decisions)
Source: UX/UI review session — three-pass critique, two mockups, and a code parity audit of
`WorkspaceRightRailView.swift`, `WorkspaceGitSectionView.swift`, `WorkspaceGitViewModel.swift`.

## 1. Goal

Restyle the right rail ("Workspace Context") around four rules, with **zero functionality loss**:

1. **One row component** — every card renders the same row anatomy (icon / title + pill /
   one-line subtitle / trailing action / chevron), instead of three per-card builders.
2. **One verb per meaning** — "Add" currently appears 4+ times meaning different things.
3. **Nouns as titles** — "Folders", "GitHub" lead; counts and status become metadata
   (today: "Configured items", "1 ready capability").
4. **Accent = interactive** — actions and only actions render in `Stanford.lagunita`;
   state and actions are visually distinct (buttons for verbs, rows for state).

Everything behind the rows — popovers, sheets, drawers, polling, audit events — is untouched.

## 2. Hard constraints

- **Architecture fitness budgets** (`Tests/ArchitectureFitnessTests.swift:292`):
  `WorkspaceRightRailView.swift` 3,390 / 3,500 · `WorkspaceGitSectionView.swift` 2,520 / 2,650.
  The redesign cannot be edited in place; Phase 0 extracts first.
- **Presentation-contract test** (`ArchitectureFitnessTests.swift:241`): presentation enums must
  stay out of `WorkspaceRightRailView.swift`. New copy goes in
  `WorkspaceRightRailPresentation.swift` (or sibling presentation files).
- **@AppStorage ratchet ≤ 129** (`ArchitectureFitnessTests.swift:331`): any persisted
  collapse state must use the existing settings/persistence patterns, not new `@AppStorage`.
- **Known trap**: never combine selectable `Text` with `.firstTextBaseline` HStacks
  (app live-lock). New rows use `.center` / `.top` alignment only.

## 3. Functional parity inventory (must all survive)

### Repository card (`WorkspaceGitSectionView.swift`)

| # | Behavior | Anchor today |
|---|---|---|
| R1 | Repository picker popover; "Workspace default / Draft task / Pinned task" scope; row disabled when task pinned, with help text | `repositoryRow` :409, `RepositoryPickerPopoverView` :1709 |
| R2 | Branch popover: search, local list, checkmark, **create & checkout inline form** | `branchRow` :457, `BranchPickerPopoverView` :1805 |
| R3 | Checkout popover: Root + worktrees, switch; **Manage worktrees sheet**: create (new branch off HEAD), switch, remove with force-confirm; pinning rules | `workingLocationRow` :490, `WorktreeLocationPopoverView` :1964, `WorktreeSheet` :2334 |
| R4 | Changes badge (Clean / +a −d / n changed) + **drawer**: stage/unstage per file & all, conflict warning, A/M/D/R/C/? badges, context menu (View Diff / Open in Files Shelf / Copy Path / Reveal in Finder / Open in Default App) | `changesRow` :570, `changesDrawer` :625, `fileRow` :1131 |
| R5 | Diff sheet: colored hunks, per-hunk stage/unstage, copy diff, open file, expand width | `ChangedFileDiffSheet` :1247 |
| R6 | Commit sheet: AI message when blank, include-unstaged toggle, Commit (⌘↩), Commit & push (⌘⇧↩), Push; ahead/behind badges ↑n ↑↑n ↓n | `commitOrPushRow` :528, `CommitSheet` :2084 |
| R7 | Create PR: readiness gating with reason strings ("Commit first", "Push first", "Publish first", conflicts, no remote); AI draft sheet; `gh pr create` with web-compare fallback | `createPullRequestRow` :726, `PRDraftSheet` :2236 |
| R8 | Existing-PR row: "#N" link, Draft badge, checks bubble (60s poll), comments bubble (count + new badge, popover: View PR / Refresh / Mark read / Address in Chat), context menu Copy PR URL / Address in Chat | `pullRequestLinkRow` :787, `PullRequestCommentsPopover` :997 |
| R9 | Header refresh (manual rescan, spinner) + 30s auto-poll paused when hidden/background | `refreshButton` :192, view model :90–154 |
| R10 | Summary ↔ details modes ("main · Root · Clean", Show all / Hide) | `repositorySummaryRow` :285, `collapseDetailsButton` :350 |
| R11 | Error banner (dismissible), audit events for every git action | `errorBanner` :225, view model throughout |

### Workspace setup card (`WorkspaceRightRailView.swift`)

| # | Behavior | Anchor today |
|---|---|---|
| S1 | Instructions: inline TextEditor (live-bound), Add/Edit action, Clear when non-empty | :1659, :1830 |
| S2 | Memory: composer (↩ or + to add, x to cancel), editable list, per-item delete | :1675, :1878–2042 |
| S3 | Remote access: SSH add/edit via callbacks, list ≤4 with test-result colors, "Show X more" | :1713, :1931, `SSHConnectionManager` |
| S4 | Folders: NSOpenPanel add, duplicate check, primary immutable, copy path, remove additional | :1694, :1895, :2044–2104 |
| S5 | Routines row in Configured when `workspace.schedules` non-empty | `workspaceSetupState` :1641 |
| S6 | Needs setup ↔ Configured computed classification; groups auto-hide when empty; Configured collapses to summary | :1537–1582 |

### Capabilities card

| # | Behavior | Anchor today |
|---|---|---|
| C1 | Three groups: **Action needed** (always expanded, red indicator), **Ready** and **Drafts** (collapsible) | `capabilityList` :496 |
| C2 | Row: icon, name, composition subtitle ("Built-in · 1 skill, …"), status (Ready / Needs setup / Disabled / Available), open package config | `capabilityRow` :796, `CapabilityRailRow` :3067 |
| C3 | Add → capability library; empty-state prompt; async prerequisite health checks | :472, :1349–1381 |

### Panel chrome

Header title + workspace name + info + close button; Repository card conditional on
`hasGitRepositories`; SSH/capability refresh on appear and path change.

## 4. Target design spec

### Row grammar (tokens in `CapabilityRailLayout`, values mostly unchanged)

- Leading icon: 16pt glyph in 30pt frame (unchanged). Status dot badge (8pt, green) on the
  icon corner for configured setup items.
- Title: `Stanford.ui(14, .semibold)` (unchanged), with optional inline `StatusPill`.
- Subtitle: `Stanford.caption(12)`, **`lineLimit(1)`** (today 2), `.truncationMode(.tail)`,
  full text moves to `.help`. Token: `rowSubtitleLineLimit = 1`.
- Trailing action: `Stanford.caption(12, .medium)` in `Stanford.lagunita` (unchanged) —
  but only ever a verb; counts/status never render in accent.
- Row min heights: `setupRowMinHeight` 56 → 52, `summaryRowMinHeight` 58 → 52
  (single-line subtitles reclaim the space). One-token change, revisit visually.
- Pills: reuse `Astra/Views/Components/StatusPill.swift` (Ready = green, Needs setup = red,
  Draft/Available = secondary). Keep its 4pt radius — app consistency beats the mockup's pill shape.
- Whole row is the tap target (`contentShape(Rectangle())`, already the pattern); add
  `.background` hover highlight via the standard hover-state pattern.

### Copy table (exact string changes)

| Symbol | Current | New |
|---|---|---|
| rail header text (`WorkspaceRightRailView.swift:323`) | "Workspace Context" | "Workspace context" (sentence case; **brand-voice decision**) |
| `WorkspaceSetupChecklistPresentation.configuredSummaryTitle` | "Configured items" | noun-first: `configuredPreview(names)` becomes the title; subtitle "N of M configured" |
| `configuredSummaryActionTitle` | "Show all" | "Show all (N)"; row renders expanded (no summary) when N == 1 |
| setup row `actionTitle` | "Add" ×4 | Instructions "Write" (configured: "Edit"), Memory "Add", Remote access "Connect", Folders "Choose…" |
| `CapabilityRailSectionPresentation.readySummaryTitle` | "N ready capabilities" | title = `previewList(names)`; subtitle = "Ready · N" |
| `addActionShowsPlusIcon` | `false` | `true` |
| `WorkspaceGitPanelPresentation.showDetailsActionTitle` / `hideDetailsActionTitle` | "Show all" / "Hide" text rows | retired — header chevron toggles summary ↔ details; keep `.help("Show/Hide repository controls")` |
| Checkout value "Root" | "Root" | "Repo root" (row value + worktree popover) |
| Commit/PR rows | rows with trailing badges | footer **buttons**: adaptive primary ("Commit & push" / "Push"), secondary "Create pull request" (sparkle); readiness reason as caption under buttons, reusing `pullRequestReadinessIssue` strings verbatim |
| ahead/behind badges on commit row | ↑n / ↑↑n / ↓n badges | sync status line above buttons: "n commits to push" / "n behind — pull first"; counts also appended to the collapsed summary ("astra · main · Repo root · +a −d · ↑n") |

### Section order

Unchanged in Phases 0–3 (Repository → Workspace setup → Capabilities, via
`WorkspaceRightRailPresentation.primarySectionOrder`). The steady-state reorder
(Repository → Capabilities → setup last as a quiet suggestions row) is **Phase 4 decision D4**.

## 5. Component architecture

New files (all in `Astra/Views/Components/`, following `StatusPill.swift` precedent):

1. **`ContextRailRow.swift`** — the unified row. API sketch:
   ```swift
   ContextRailRow(
     icon: .system("folder") | .asset("github-mark"),
     iconBadge: .configuredDot | nil,
     title: String, titlePill: StatusPill? = nil,
     subtitle: String? (lineLimit 1, help = full text),
     action: ContextRailRowAction? (.verb(String, () -> Void)),
     accessory: .chevronRight | .disclosure(isExpanded:) | .none,
     onTap: () -> Void, isDisabled: Bool = false, disabledReason: String? = nil
   )
   ```
   Plus `ContextRailFieldRow(label:value:icon:accessory:)` for the key-value rows
   (Repository / Branch / Checkout / Changes) — popovers stay anchored at call sites.
2. **`ContextRailCard.swift`** — card chrome: extracts `floatingContextSection` fill/stroke
   (`WorkspaceRightRailView.swift:408–430`) + header (title, optional count pill, optional
   trailing action, optional collapse chevron bound to a `Binding<Bool>`).
3. **`WorkspaceGitSheets.swift`** (in `Astra/Views/`) — pure move of `CommitSheet`,
   `PRDraftSheet`, `WorktreeSheet`, `ChangedFileDiffSheet` (~690 lines) out of
   `WorkspaceGitSectionView.swift`. Self-contained structs; promote shared helpers they use
   (e.g. status badge color mapping) into the new file or a small shared enum.
4. **`ContextRailRows.swift`** (in `Astra/Views/Components/`) — pure move of the private
   structs at the tail of the rail view (`CapabilitySummaryRow`, `CapabilityEmptyPrompt`,
   `CapabilityHierarchy*`, `CapabilityResourceScopeRow`, `CapabilityRailRow`, `CapabilityRow`,
   `CapabilityToggleRow`, `ResourceRow`, ~460 lines), `private` → `internal`.
   These collapse into `ContextRailRow` during Phases 1–3 and this file shrinks/disappears.
5. **Presentation moves** — `WorkspaceSetupChecklistPresentation` (rail view :40) and
   `WorkspaceGitPanelPresentation` (+ `WorkspaceGitDetailsMode`,
   `WorkspaceGitTransientPresentationState`, git view :11–46) into
   `WorkspaceRightRailPresentation.swift`. Matches the already-enforced extraction pattern.

Brand icon: add an octocat **template asset** to `Assets.xcassets` and map it in presentation
by package id (`"github-workflow"`), with the existing SF symbol
(`chevron.left.forwardslash.chevron.right`, `PluginCatalog.swift:639`) as fallback for
unknown packages. No catalog data migration; mapping lives in one function.

## 6. Phases

Each phase is an independently shippable PR with no functional regressions.

### Phase 0 — Extraction (zero visual/behavioral change)
Moves #3, #4, #5 above. No string or layout changes.
- Budget result (estimates): git view 2,520 → ~1,830 (headroom ~820); rail view 3,390 → ~2,840 (headroom ~660).
- Verify: build; full test suite; `ArchitectureFitnessTests` (extraction test still passes —
  it asserts absence from the rail view); before/after screenshots identical.

### Phase 1 — Row component + Workspace setup card
- Add `ContextRailRow` / `ContextRailFieldRow` / `ContextRailCard`.
- Setup card adopts them: per-item verbs, single-line subtitles, noun-first configured summary,
  "Show all (N)" with N ≥ 2 rule, "Configured" micro-label kept (card mixes states), configured
  icon dot badge. Inline editors (S1–S4) reattach unchanged as the rows' expanded `details`.
- Parity check: S1–S6.

### Phase 2 — Repository card
- Field rows for R1–R3 (popovers/sheets untouched; pinned-task disable + help preserved).
- R4 drawer behavior unchanged; only the collapsed row restyles.
- Header gains collapse chevron (replaces Show all/Hide rows, R10) next to refresh (R9);
  collapsed summary becomes "name · branch · checkout · +a −d · ↑n".
- Footer: sync status line + adaptive buttons; PR readiness caption (R7); commit/PR sheets
  open from buttons with the same disabled logic (`canOpenCommitSheet`, `isSyncing`,
  `pullRequestReadinessIssue`, `isSuggestingPR`).
- R8 existing-PR row restyled with `StatusPill` bubbles; comments popover & menus unchanged.
- Parity check: R1–R11 + keyboard shortcuts + audit events.

### Phase 3 — Capabilities card
- Three groups kept (C1); Action-needed indicator stays; Ready/Drafts use the N ≥ 2 rule.
- Noun-first summaries via existing `previewList`; plus icon on Add; `StatusPill` statuses (C2).
- GitHub brand asset + id-mapped icon with SF fallback.
- Parity check: C1–C3, single-capability renders as a full row with no "Show all".

### Phase 4 — Net-new behaviors (one decision each; default off until approved)
- **D1 Persisted collapse state** — today all expand/collapse is ephemeral `@State`
  (`applyConfigureDefaults`, rail view :2486). Persist per workspace via the existing
  persistence patterns (not `@AppStorage` — ratchet).
- **D2 Dismissible setup suggestions** — needs `dismissedSetupItems: [String]` on the
  `Workspace` model (SwiftData migration) + a "Review" entry point to undismiss.
- **D3 Destructive-action guard** — confirm or 5s-undo for folder remove (S4) and memory
  delete (S2); both delete immediately today.
- **D4 Steady-state section order** — Repository → Capabilities → setup collapses to a quiet
  one-line suggestions row at the bottom once everything is configured.

## 7. Verification (every phase)

1. `xcodebuild` build + full test suite, including `ArchitectureFitnessTests`
   (line budgets, presentation extraction, @AppStorage ratchet).
2. Manual parity sweep using §3 tables (R1–R11, S1–S6, C1–C3) — each behavior reachable and
   identical except styling.
3. Screenshot pass, light + dark, at compact and regular rail widths.
4. Reduced-motion: disclosure animations still gate on `accessibilityReduceMotion`.

## 8. Risks

- **Type-checker pressure**: big `body` chains in these files are near the known ceiling —
  extraction reduces it; keep `ContextRailRow` concrete (enum-driven), avoid deep generic nesting
  (the one existing generic, `details:` builder, is kept).
- **Popover anchoring**: popovers must stay attached to the row views after componentization —
  rows expose plain `View` so `.popover`/`.sheet` modifiers remain at the call site.
- **Sheet helper visibility**: moved sheets reference fileprivate helpers (status colors,
  action labels) — promote into the sheets file in the same commit; no logic edits.
- **GitHub mark licensing**: use the official mark unmodified as a template image to identify
  the GitHub integration (permitted use); fallback path keeps non-GitHub packages generic.
