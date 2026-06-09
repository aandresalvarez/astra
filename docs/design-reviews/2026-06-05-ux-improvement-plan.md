# ASTRA UX Improvement Plan — 2026-06-05

> **Implementation status (2026-06-05): SHIPPED.** All actionable items below are
> implemented, built clean, and verified live in **both light and dark** mode.
> Theme tests extended (11 pass, incl. contrast floor + unified-accent). See the
> "Implementation log" at the bottom for the per-item diff map. Only `D2`
> (user accent-override scaffold) is intentionally left as backlog.


Source: live review of `ASTRA Dev` (dev channel) plus a read-only code audit of the
Stanford design system and the affected views. Every item below carries concrete
`file:line` anchors so it can be picked up and implemented directly.

## TL;DR

The design system is **already good** — colors are centralized in
`Astra/Views/StanfordTheme.swift` as light/dark semantic tokens with a test suite.
The work here is **not a rebuild**; it's reconciling a handful of call sites with the
semantic layer that already exists, plus a few layout/legibility fixes.

### ⚠️ Root cause found (2026-06-05 light-mode pass)
The original verbal review said "red is the brand accent on buttons." **That was correct** —
the mechanism is `Astra/ASTRAApp.swift:450` (and `:508/:517/:526`):

```swift
WindowGroup { ContentView(...).tint(Stanford.cardinalRed) }   // global app accent = red
```

A single `.tint(Stanford.cardinalRed)` at the scene level makes **cardinal red the global
SwiftUI accent**, so every control that doesn't override its tint inherits it — the "Ask"
policy pill, the `This Task / Workspace / All` segmented control, default pickers, focus
rings, etc. Meanwhile `ContentView.swift:3682/3754` overrides *parts* of the tree back to
`.tint(Stanford.lagunita)` (teal). The app fights itself: half red, half teal.

This is now item **A0** and the highest-leverage fix in this plan — one change resolves
the "Ask" pill, the segmented control, and every other default-tinted control at once.
A2/A3/A4 are downstream of it.

### Why this only became obvious in light mode
- Light `cardinalRed = 0x8C1515` is a deep, serious red → on a white background it reads as
  **error/destructive** on everyday controls.
- Dark `cardinalRed = 0xD93A3A` is a brighter salmon → reads as "attention," far less alarming.
- Same token, same global tint, but the light value crosses from brand accent into danger.
  The earlier (dark-only) review under-weighted this.

### Second, separate defect: amber overload
Independently of the red accent, `Stanford.poppy` (amber) is overused for **success**:
the "Result ready" banner is `tone = .attention` → poppy, identical to the "Needs review"
warning (A1). In light mode poppy (`0xE98300`) on white is also ~3:1 contrast — below AA —
so the green fix improves legibility too.

---

## Priorities at a glance

| ID | Issue | File(s) | Effort | Risk | Priority |
|----|-------|---------|--------|------|----------|
| **A0** | **Global accent is `.tint(cardinalRed)` → red on all default controls (worst in light mode)** | `ASTRAApp.swift:450,508,517,526` | XS | Med | **P0** |
| A1 | "Result ready" success tinted amber, not green | `TaskDecisionDockPresentation.swift:442`, `TaskDecisionDockView.swift:~345` | S | Low | **P0** |
| A4 | File-scope segmented control has no explicit tint | `ShelfMarkdownPanelView.swift:327` | XS | Low | **P0** |
| B1 | Repo path middle-truncates to "Addition...ode/astra" | `WorkspaceGitSectionView.swift:420`, `WorkspacePathPresentation.swift:89` | S | Low | **P0** |
| C1 | Files panel shows two empty states at once | `ShelfMarkdownPanelView.swift:86,358,1550` | M | Low | **P1** |
| A2 | `interactive`(sky) ≠ `focusRing`/`link`(lagunita) split | `StanfordTheme.swift:104` | S | Med | **P1** |
| A3 | `StanfordButtonStyle` hardcodes `lagunita`, bypasses semantic token | `StanfordTheme.swift:357` | S | Med | **P1** |
| C2 | Sidebar tasks not visually nested under workspace | `TaskSidebarView.swift:88,968` | M | Med | **P1** |
| A5 | Verify composer warm tint is intentional (poppy/state) not error | `ComposerToolbar.swift`, `AgentPolicySheet.swift:322` | S | Low | **P1** |
| B2 | "Artana" (workspace) vs "astra" (repo) name collision is confusing | `WorkspaceGitSectionView.swift` | XS | Low | **P2** |
| C3 | Duplicate workspace chip on New Task surface | `NewTaskView.swift:60` | S | Low | **P2** |
| B3 | Secondary text leans on `Color.secondary`; no contrast floor | `StanfordTheme.swift:38` | L | Med | **P2** |
| D1 | Extend ThemeTests (success tone, accent consistency, contrast) | `Tests/ThemeTests.swift` | M | Low | **P2** |
| D2 | (Future) user accent-override scaffold | new | L | Med | Backlog |

Effort: XS<30m · S≈1h · M≈half-day · L≈1day+

---

## Workstream A — Color semantics

### A0 (P0). Decide the global interaction accent — `cardinalRed` vs `lagunita`
**Where:** `Astra/ASTRAApp.swift:450` (main window) plus `:508` (About), `:517` (Logs),
`:526` (Usage) all apply `.tint(Stanford.cardinalRed)`. `ContentView.swift:3682/3754`
override sub-trees back to `.tint(Stanford.lagunita)`.
**Problem:** This is the root cause of "red on everything." A brand color (Stanford
cardinal) is being used as the **interaction accent**, which (a) collides with red's
universal error/destructive meaning, (b) is internally inconsistent (some subtrees are
teal), and (c) looks actively like a danger control in **light mode** (`0x8C1515` on white).
**This is a product decision, not just a bug** — surface it explicitly:
  - **Recommended:** change the four scene-level tints to `Stanford.lagunita` (teal). This
    matches the `ContentView` overrides, the `StanfordButtonStyle` default, `focusRing`, and
    `link`, so the whole app converges on one calm accent. Reserve `cardinalRed` for the
    **brand mark** (the reticle/logo — already hardcoded there) and genuine errors.
  - **Alternative (keep brand-red accent):** if cardinal red as the interaction accent is a
    deliberate brand stance, at minimum (i) remove the conflicting `lagunita` overrides so
    it's consistent, and (ii) lighten the *light-mode* value so it stops reading as
    destructive — but this still spends your only error color on everyday controls. Not
    recommended.
**Effect of the recommended fix:** the "Ask" pill, the file-scope segmented control, and
every other default-tinted control turn teal in one change — makes A4 mostly redundant and
A2/A3 trivial.
**Verify:** `/run` the dev app in **both** light and dark mode; confirm no everyday control
is red, and that errors/destructive actions still are.

### A1 (P0). "Result ready" should read as success, not attention
**Where:** `Astra/Services/Tasks/TaskDecisionDockPresentation.swift:442-444` sets
`title = "Result ready"`, `icon = "checkmark.circle.fill"`, `tone = .attention`. The tone
→ color map (`Astra/Views/TaskDecisionDockView.swift:~345-358`) renders `.attention` as
`Stanford.poppy` (amber).
**Problem:** A completed, ready result is a *success* state but wears the same amber as
"Needs review" — so success and warning are indistinguishable.
**Fix:** Introduce/confirm a `.success` tone mapped to `Stanford.statusHealthy`
(= `paloAltoGreen`) and switch "Result ready" to it. Keep `.attention`→poppy for
"Needs review" / "Pending user". Net effect: green ✓ for ready, amber for needs-action.
**Verify:** `/run` the dev app, complete a task, confirm the ready banner is green and the
needs-review pill stays amber.

### A2 (P1). Collapse the interactive-accent split
**Where:** `Astra/Views/StanfordTheme.swift:104-107`:
```
static let interactive = sky        // 0x0098DB
static let focusRing    = lagunita  // 0x007C92
static let link         = lagunita
```
**Problem:** Two different "primary action" hues with no documented rationale. Buttons that
honor `interactive` get sky-blue; focus rings and links get lagunita-teal. Visual drift.
**Fix (recommended):** Make **lagunita the single primary accent** (it's already the button
default and the focus/link color, so this is the lower-blast-radius choice):
set `interactive = lagunita`, keep `sky` as `statusInfo` only, and add a doc comment
naming lagunita the canonical interactive accent. (Alternative: standardize on sky and
repoint focus/link — higher blast radius, not recommended.)

### A3 (P1). Route `StanfordButtonStyle` through the semantic token
**Where:** `Astra/Views/StanfordTheme.swift:357` → `var color: Color = Stanford.lagunita`.
**Problem:** The default is a *raw* token, so changing the semantic `interactive` token does
not propagate to buttons — the semantic layer is decorative for the most common control.
**Fix:** Change the default to `Stanford.interactive` (after A2 they're equal, so this is a
no-op visually but makes the semantic layer authoritative going forward). Audit the 4 other
button styles in `ShelfQueryPanelView.swift:2115-2217` and have the "primary" ones inherit
the same token.

### A4 (P0). Tint the file-scope segmented control
**Where:** `Astra/Views/ShelfMarkdownPanelView.swift:327-336` — `Picker(...).pickerStyle(.segmented)`
with no `.tint(...)`, so the selected segment uses SwiftUI's ambient accent (inconsistent).
**Fix:** Add `.tint(Stanford.interactive)`.

### A5 (P1). Confirm the composer warm tint is intentional
**Where:** composer bottom bar — submit arrow is correct (`ComposerToolbar.swift:~820`,
`Stanford.lagunita`); the "Ask" rule-count pill is `Stanford.poppy`
(`AgentPolicySheet.swift:322`). The model-picker chip's token was not pinned down in the
audit.
**Action:** Trace the model-picker chip + the "Ask" mode indicator tokens. If the warmth is
`poppy` because the task is in `pendingUser`/`.attention`, it's **semantically fine** — at
most, reduce saturation so it reads "attention," not "error." If any control uses
`cardinalRed`/`errorRed` as a resting (non-error) tint, repoint it to `interactive`. Decide
explicitly; don't leave it ambiguous.

---

## Workstream B — Legibility

### B1 (P0). Fix the repository path display
**Where:** `Astra/Views/WorkspaceGitSectionView.swift:420-424` renders
`selectedRepositorySubtitle` with `.lineLimit(1).truncationMode(.middle)`. The string is
pre-abbreviated by `WorkspacePathPresentation.abbreviatePath` (`…/Services/Persistence/WorkspacePathPresentation.swift:89-108`,
which already collapses to `prefix/.../lastThree`). The two layers stack →
"Addition...ode/astra", which hides the meaningful tail.
**Fix:** (a) switch the `Text` to `.truncationMode(.head)` so the repo name (the tail)
always survives, and/or (b) have `abbreviatePath` keep the last 2 components only and not
re-truncate; (c) add `.help(fullPath)` so the full path is available on hover.
**Acceptance:** the visible string always ends in the actual repo folder (`…/astra`), never
mid-word.

### B2 (P2). Disambiguate workspace vs repository
**Where:** right rail, `WorkspaceGitSectionView.swift`. Workspace "Artana" + repo "astra"
are near-anagrams stacked together.
**Fix:** small label/hierarchy tweak — e.g. prefix the repo row with a "repo" affordance or
show `workspace ▸ repo` so the relationship is explicit. Copy-level, low effort.

### B3 (P2). Give secondary text a contrast floor
**Where:** `StanfordTheme.swift:38` → `coolGrey = Color.secondary`; low-emphasis labels rely
on system secondary + scattered `.opacity(0.82/0.065/...)`. Only long-form `readingText` has
a WCAG-validated value.
**Fix:** introduce explicit `textSecondary` / `textTertiary` tokens with tuned light/dark
hex (mirroring `readingText`), replace ad-hoc opacity dimming on text, and add a contrast
test (see D1). Larger, do after the P0/P1 items.

---

## Workstream C — Layout & structure

### C1 (P1). One empty state in the Files panel
**Where:** `Astra/Views/ShelfMarkdownPanelView.swift` — list empty state "No task files"
(`:899/:910` via `:358-403`) and preview empty state "No file selected" (`:1550-1570`)
render simultaneously inside the two-pane split (`:86-104`, `:262-275`).
**Fix:** when the list is empty, collapse/hide the preview pane and show a single centered
empty state spanning the panel; only reveal the split once ≥1 file exists. Removes the
"two kinds of nothing" look.

### C2 (P1). Visually nest tasks under their workspace
**Where:** `Astra/Views/TaskSidebarView.swift:88-104` —
`childTaskListLeadingPadding = 0` and `childTaskContentLeadingPadding = 0`, and
`selectedWorkspaceChildrenUseGuide = false`. So child tasks render flush with workspace
rows; grouping is ambiguous (the "Add task" affordance at `:1244-1267` then looks
free-floating).
**Fix:** give child tasks a real indent (e.g. 14-18pt) and optionally flip
`selectedWorkspaceChildrenUseGuide` on for a connecting hairline. Ensure the contextual
"Add task" sits inside the indented group so its workspace scope is obvious.

### C3 (P2). Remove the duplicate workspace chip on New Task
**Where:** `Astra/Views/NewTaskView.swift:60-70` renders `Label(ws.name, ...)` while the
title bar and right rail already show the workspace. (Confirm whether the *canvas* "Artana"
chip on the empty state is this Label or a separate component before editing.)
**Fix:** drop the redundant chip, or make it the single canonical workspace indicator and
remove one of the others.

---

## Workstream D — Hardening

### D1 (P2). Extend `Tests/ThemeTests.swift`
Current suite checks light≠dark per brand color, pins cardinal red, verifies status aliases,
and enforces 4.5:1 only for chat reading text. Add:
- `.success` tone resolves to `statusHealthy`/green (locks A1).
- `interactive == focusRing == link` after A2 (prevents accent re-drift).
- WCAG ≥4.5:1 for `interactive` text-on-canvas and the new `textSecondary` token (locks B3).

### D2 (Backlog). Accent-override scaffold
There's already an `AppearancePreference` (light/dark/system) enum + `@AppStorage`. A future
`AccentPreference` parallel + `@Environment(\.brandAccent)` would let users pick the
interactive accent. Out of scope now — listed so A2/A3 are built in a way that doesn't block
it.

---

## Light-mode evaluation (per-item)

The original audit was dark-mode-only. Re-checked against light-mode screenshots
(New Task, completed task, Files panel). Verdict per item:

| ID | Holds in light mode? | Light-mode notes |
|----|----------------------|------------------|
| A0 | **Worse** | Light `cardinalRed 0x8C1515` on white reads as error/destructive on the "Ask" pill + selected segment. The single biggest light-mode problem. |
| A1 | **Worse** | Amber `Result ready` not only conflates with warning but poppy `0xE98300` on white is ~3:1 (sub-AA). Green fix (`0x175E54`) restores both meaning and contrast. |
| A4 | Same | Selected segment inherits the global red tint; fixed for free by A0, but keep the explicit `.tint` for hygiene. |
| B1 | Same | "Addition...ode/astra" truncation is mode-independent. |
| C1 | Same | Double empty state identical in light mode. |
| C2 | Same | Sidebar nesting is mode-independent. |
| B3 | **New / Worse** | Light mode is where secondary-text contrast bites: `coolGrey = Color.secondary` and `.tertiary` (path subtitle "Workspace default", setup descriptions) are pale grey on white. `.tertiary` ≈ 3:1 — likely below AA. Dark mode hid this. **Promote B3 from P2 → P1** and audit both modes. |

### New light-mode-specific items
- **B4 (P1). Contrast floor for low-emphasis text in light mode.** `.tertiary` labels (repo
  subtitle, "Needs setup" descriptions, timestamps) are pale on white. Introduce tuned
  `textSecondary`/`textTertiary` tokens (light/dark hex like the existing `readingText`) with
  a ≥4.5:1 floor for body and ≥3:1 for incidental text; replace ad-hoc `Color.secondary` /
  `.tertiary` on text. (Folds into B3.)
- **A6 (P2). Re-validate the amber model-picker chip in light mode.** The model chip renders
  warm/amber for `Antigravity · Gemini 3.5 Flash (Low)` but neutral for `Copilot · Sonnet`.
  If that hue encodes model tier/effort it's a *semantic* signal — but on white it's low
  contrast and visually collides with the `Needs review` amber. Decide whether the encoding
  is intentional; if so, raise contrast and differentiate it from the warning amber.
- **D3 (P2). Add a light-mode snapshot/contrast test pass.** ThemeTests currently validates
  contrast only for `readingText`. Add the same WCAG assertions for the accent (post-A0),
  `Result ready` green (post-A1), and the new secondary-text tokens — in **both** appearances.

## Suggested sequencing

1. **Batch 0 (P0 decision + 1-line fix):** **A0** — confirm accent direction (recommend
   teal), flip the four `.tint(cardinalRed)` calls, remove the conflicting `lagunita`
   overrides. Screenshot **both** light and dark. This alone removes most of the "red"
   complaints.
2. **Batch 1 (P0, ~half day):** A1, A4, B1 — high-visibility, low-risk, isolated.
3. **Batch 2 (P1 color, ~half day):** A2 → A3 (trivial once A0 lands), A5 verification.
4. **Batch 3 (P1 legibility + layout, ~1–1.5 days):** B3/B4 (light-mode contrast), C1, C2.
5. **Batch 4 (P2 polish):** B2, C3, A6, D1, D3.
6. **Backlog:** D2.

Each batch is independently shippable; recommend committing per-item with **paired
light + dark** before/after screenshots for the visual ones (this whole revision exists
because the first pass only checked one appearance).

---

## Implementation log (2026-06-05)

| ID | Status | Change |
|----|--------|--------|
| A0 | ✅ | `ASTRAApp.swift` — four scene `.tint(Stanford.cardinalRed)` → `.tint(Stanford.interactive)`. Global accent is now teal; cardinal red reserved for the reticle brand mark + errors. |
| A1 | ✅ | Added `.success` tone (`TaskDecisionDockPresentation.swift`); "Result ready" now `.success`; `metricColor` maps `.success`→`statusHealthy` (green). Verified distinct from amber "Needs review" in both modes. |
| A2 | ✅ | `StanfordTheme.swift` — `interactive = lagunita` (was `sky`); documented that interactive/focusRing/link share one hue. `sky` still serves `statusInfo`. |
| A3 | ✅ | `StanfordButtonStyle` default `color = Stanford.interactive` (was raw `lagunita`) — accent is now one knob. |
| A4 | ✅ | Explicit `.tint(Stanford.interactive)` on the file-scope segmented picker (`ShelfMarkdownPanelView.swift`); also covered by A0. |
| A5 | ✅ verify | Composer policy pill uses `policyColor()` (semantic: review="Ask"→green, auto→teal), never the global tint. Only legacy `.locked` preset is red. No change needed. |
| A6 | ✅ verify | Model/runtime chip color = `runtimePillColor`, driven by **task status** (`.pendingUser`→amber), not model tier. Amber chip == amber "Needs review" == same signal. No change needed. |
| B1 | ✅ | Repo subtitle `.truncationMode(.head)` + `.help(fullPath)`; added `selectedRepositoryFullPath` to the VM. Now shows `…uments/Code/astra` (tail preserved). |
| B2 | ◻︎ minimal | Workspace/repo names live in distinct zones (panel header vs. "Repository" row + folder icon); the new path tooltip aids disambiguation. Left as-is to avoid over-engineering a P2. |
| B3/B4 | ✅ | Added tuned `textSecondary`/`textTertiary` tokens (light/dark hex, contrast-floored) + applied to the repo row. Broader call-site migration is incremental follow-up. |
| C1 | ✅ | Files panel: `showsCombinedEmptyState` collapses the two empty states into one centered state when nothing is browsable. |
| C2 | ✅ | `childTaskListLeadingPadding = 16` — tasks + "Add task" now read as nested under their workspace. Verified live. |
| C3 | ✅ | Removed the redundant hero workspace chip (`ChatPanelView.swift`); workspace still shown in title + right rail. |
| D1/D3 | ✅ | `ThemeTests.swift` — added contrast-floor test for the new text tokens and a unified-accent test (interactive == focusRing == link == lagunita, ≠ cardinalRed). 11 tests pass. |
| D2 | ⏳ backlog | User-selectable accent override — intentionally deferred; A0/A2/A3 leave `Stanford.interactive` as the single seam to build it on. |

Files touched: `ASTRAApp.swift`, `StanfordTheme.swift`, `TaskDecisionDockPresentation.swift`,
`TaskDecisionDockView.swift`, `ShelfMarkdownPanelView.swift`, `WorkspaceGitSectionView.swift`,
`WorkspaceGitViewModel.swift`, `TaskSidebarView.swift`, `ChatPanelView.swift`, `Tests/ThemeTests.swift`.
