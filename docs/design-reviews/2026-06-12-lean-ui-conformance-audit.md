# Lean UI conformance audit (app-wide)

Date: 2026-06-12
Method: multi-agent review — every SwiftUI view (52 files) classified in/out of scope,
21 in-scope surfaces deep-reviewed against every principle in
[`lean-ui-system.md`](../design-system/lean-ui-system.md), findings adversarially
verified (verification partially rate-limited; findings below come from the full
review pass). 107 findings across 21 surfaces.

## Verdict

The rail we just shipped is the **conformant reference**: `WorkspaceRightRailView`,
`ContextRailRows`, and `WorkspaceGitSectionView` all grade **strong**, and
`ContextRailRows.CapabilitySummaryRow` is the row grammar the rest of the app should
adopt. The gap is everything that predates the lean system — above all the
**capability / connector / skills / workspace config-manager family**, which diverges
hard.

The good news: the 107 findings collapse into **six repeatable patterns**. Fixing them
is mostly mechanical adoption of the shared vocabulary, not bespoke design work.

## The six cross-cutting patterns (by frequency)

| # | Pattern | Principle | Count | Where it bites hardest |
|---|---------|-----------|-------|------------------------|
| 1 | **Accent color on non-tappable elements** — `Stanford.lagunita`/brand tints on status icons, counts, progress, decorative dots | COL | 23 | nearly every manager + a few rail polish gaps |
| 2 | **Per-row status repeated** instead of carried by the group heading | P2 / P6 | 18 | Connectors, Skills, Plugin catalog, Settings, MacOS permissions |
| 3 | **Destructive action with no confirmation** — delete/detach fires on first tap | STA | 5 (all high) | WorkspaceDetail, Connectors, Skills, Tools, PluginCatalog (Disable) |
| 4 | **Card-in-card nesting** — framed rows inside framed `GroupBox`es | P1 | 6 | WorkspaceDetail, MacOS permissions, Connectors, Skills |
| 5 | **Shared row grammar not adopted** — bespoke rows miss single-line subtitle, `.help`, semibold title, noun-first | SUB / P2a / P3 | 24 | Skills, WorkspaceHome, Connectors, Usage, MissionControl |
| 6 | **Brand marks not adopted** — stand-in SF Symbols where GitHub/Jira/Google/Copilot marks exist | ICO | 10 | Connectors, Skills, Settings, and the git PR row |

Two more, lower-frequency: **state-vs-action not separated** (P5a, 6) and **`Add`
overloaded** across many operations (P5b, 6) — concentrated in the same manager views.

## Priority 1 — Safety: confirm before destroying (do first, small, high value)

Five surfaces delete or detach on the first tap with no confirmation — exactly the gap
we just closed in the rail with `PendingRailDeletion` + `.confirmationDialog`. Port that
pattern:

- `WorkspaceDetailView.swift:126-133` — folder removal.
- `ConnectorsManagerView.swift:615-620, 465-472, 354-365, 308-318` — multiple deletes.
- `SkillsManagerView.swift:172-179, 921-926` — Delete Skill; `:422-431, 523-532` — detach.
- `ToolsManagerView.swift:277-282` — Delete Tool.
- `PluginCatalogView.swift:746-771` — Disable on the collapsed row (also a P3/P5a issue).

## Priority 2 — The manager family (the biggest inconsistency)

Three surfaces grade **weak** and share all six patterns. They are the highest-leverage
targets because one adoption pass fixes many findings each:

- **`SkillsManagerView.swift`** (10 findings) — adopt `CapabilitySummaryRow` grammar
  (noun-first title, single-line `.help` subtitle, semibold), group status in headings,
  brand marks for connectors, drop nested card chrome, confirm deletes.
- **`ConnectorsManagerView.swift`** (9) — same, plus stop overloading `Add`
  (`:333, 383, 493, 505, 757`) with descriptive verbs.
- **`WorkspaceDetailView.swift`** (9) — flatten the card-in-card `GroupBox` chrome,
  separate read-only stats from verbs (P5a), confirm folder removal.

Then the **mixed** managers: `ConfigureView` (collapsed cards crowd Duplicate +
Enable/Disable + chevron; accent on counts), `PluginCatalogView` (per-row status repeats
the group; Disable on collapsed row), `SettingsView` (provider row encodes status three
ways; Copilot/Claude Code SF Symbols where marks exist; expand state not persisted).

## Priority 3 — Color-discipline sweep

The single most common violation (23). One focused pass: anywhere `Stanford.lagunita`,
`paloAltoGreen`, `poppy`, or a brand tint sits on text/icon that is **not tappable**,
move it to `.secondary`/`.tertiary` or the info/warn tint. Hot spots: `MacOSPermissions`
(per-row tinted backgrounds), `MissionControl` (running borrows the ready accent),
`Usage` (progress gauge in accent), `AgentPolicySheet:112`, `SkillsManager`,
`ConnectorsManager:77`, `WorkspaceDetail:244-250`.

## Quick wins — including our own rail

The rail grades strong but isn't perfect; these are small and worth folding in:

- `WorkspaceGitSectionView.swift:663-667` — the **ahead/ready-to-push sync line still
  wears `lagunita`** (COL). We fixed the diverged/behind case to the info tint; the
  ahead-only case should not wear the interactive accent either.
- `WorkspaceGitSectionView.swift:319` — the Repository summary→details toggle says a
  bare **"Show all"** with no count (P4a) — we added "Show all (N)" everywhere else.
- `WorkspaceGitSectionView.swift:863` — the **GitHub PR row uses an SF Symbol** where
  `BrandMark.github` is now available (ICO).
- `WorkspaceGitSectionView.swift:309` — truncated summary subtitle lacks `.help` (SUB).
- `WorkspaceRightRailView.swift:2654-2672` — the **memory-composer icon-only Add/Cancel
  buttons lack `.help` + `accessibilityLabel`** (INT); every sibling control has them.
- `WorkspaceRightRailView.swift` — a body of **dead legacy helper code** (old
  connector/skills/paths/inspector sections) no longer rendered but still in the file;
  worth deleting so it isn't mistaken for live UI.
- `MissionControlPanelView.swift:114` — assertion list silently capped at 4 with no
  "Show all (N)" (P4a).
- `WorkspaceHomeView.swift:738-766` — capabilities summary leads with a generic count,
  not the noun (P2a, high); `:826-866` bespoke 2-line summary row vs the shared grammar.

## Per-surface scorecard

| Grade | # | Surface | Principles touched |
|------:|--:|---------|--------------------|
| weak | 10 | SkillsManagerView | COL ICO INT P1 P2 P2a P5b STA |
| weak | 9 | WorkspaceDetailView | COL P1 P2 P3 P5a P5b P6 STA |
| weak | 9 | ConnectorsManagerView | COL ICO P1 P2 P2a P5a P5b P6 STA |
| mixed | 7 | ConfigureView | COL ICO INT P2 P2a P3 STA |
| mixed | 6 | SettingsView (Providers / Roles) | COL ICO INT P2 STA SUB |
| mixed | 6 | PluginCatalogView | COL ICO P2 P3 P4a P5a |
| mixed | 6 | ToolsManagerView | COL P1 P5a P6 STA SUB |
| mixed | 5 | MacOSPermissionsSectionView | COL ICO P1 P2 P6 |
| mixed | 5 | MissionControlPanelView | COL P2 P4a SUB |
| mixed | 5 | TaskCheckpointBrowserView | COL P2a P5a SUB |
| mixed | 5 | WorkspaceHomeView | P2a P5b STA SUB |
| mixed | 4 | TaskDecisionDockView | COL P3 P4 SUB |
| mixed | 4 | UsageDashboardView | COL ICO P3 SUB |
| mixed | 3 | AgentPolicySheet | COL P2 |
| mixed | 3 | RuntimeSetupSection | P1 P2 P6 |
| strong | 4 | ContextRailRows | (minor, caller-side) |
| strong | 4 | WorkspaceGitSectionView | COL ICO P4a SUB (quick wins) |
| strong | 4 | ComposerToolbar | COL ICO P5a (toolbar, mostly N/A) |
| strong | 3 | WorkspaceRightRailView | INT P2a P3 (quick wins) |
| strong | 3 | TaskSidebarView | COL P2 STA (mostly nav-exempt) |
| strong | 2 | LogViewerView | COL P5b (mostly table-exempt) |

## Scope

28 files were correctly classified **out of scope** and are not findings: the main
canvas and shell (`TaskMainView`, `ContentView`, `ChatPanelView`, `KanbanBoardView`,
`WorkspaceCanvasPanelView`, `TaskDetailView`), reading surfaces (`Shelf*PanelView`,
`PromptContextPreviewView`), forms where every field is the task (`NewTaskView`,
`ScheduleEditorView`), onboarding (`OnboardingWizardView`), and token/identity/utility
files. Two surfaces were initially mis-scoped and pulled back in for review
(`SettingsView`, `WorkspaceHomeView`) — both turned out to contain governed
manager/context elements with real violations.

## Recommendation

Sequence as separate follow-up PRs (not on the rail PR #54):

1. **Safety PR** — confirm-before-destroy across the five surfaces (Priority 1). Small,
   self-contained, ships the most user-protective change first.
2. **Rail polish** — the quick wins in our own rail (accent on sync line, "Show all (N)",
   PR brand mark, memory-composer tooltips, delete dead code). Small, closes our own loop.
3. **Manager-family adoption** — `SkillsManagerView`, `ConnectorsManagerView`,
   `WorkspaceDetailView` adopt the shared `CapabilitySummaryRow` grammar, group-status,
   brand marks, and single-boundary cards. Largest, highest-impact for consistency.
4. **Color-discipline sweep** — mechanical accent-on-non-tappable cleanup, can ride along
   with #3 or stand alone.
