# ASTRA Lean UI Design System

This document captures the design language that emerged from the Workspace
Context right-rail redesign. It is a reusable system for ASTRA product surfaces,
not a rule that every screen must look exactly like the right rail.

Use this guide when designing or refactoring SwiftUI views, especially dense
operator surfaces where users need to scan state, open details, and act without
feeling buried in controls.

## Product Intent

ASTRA is a supervision tool for delegated agent work. The interface should feel
like a quiet operational console: clear enough for first-time users, dense enough
for repeated work, and restrained enough that the user can tell what needs
attention without reading every line.

The lean system optimizes for:

- Fast scanning before reading.
- Progressive disclosure before expanded configuration.
- State and actions wearing different chrome: state reads as rows, the things
  the user *does* read as buttons.
- Nouns leading; counts and status sitting behind them as metadata.
- One verb per meaning, in the accent color, and never anywhere else.
- Minimal borders and repeated chrome.
- Semantic grouping instead of repeated per-row labels.
- Editing in place only when the user has chosen to expand a row.

## When To Use This System

Use this system for:

- Right rails, inspectors, setup panels, and workspace context panels.
- Operational summaries with a short list of items.
- Panels that combine status, details, and configuration.
- Repeated rows where each row can expand to edit or inspect.
- Dense admin views where users revisit the same surface often.

Do not force this system onto every surface.

Use a different pattern for:

- Long-form reading surfaces such as task responses or generated reports.
- Main work canvases where the user needs broad spatial context.
- Tables that require precise comparison across many columns.
- Forms where every field is already the primary task.
- Marketing, onboarding, or explanation-first screens.

## Core Principles

### 1. One Card, One Boundary

A card may group a coherent concept, but do not put a second framed card around
the same rows. The outer card is the boundary. Inside it, use spacing, section
labels, and subtle dividers.

Preferred:

- Outer card for `Capabilities`.
- Group labels like `Action needed`, `Ready`, `Drafts`.
- Full-width rows inside the card.

Avoid:

- Card inside card.
- Rounded list containers inside a rounded panel.
- Repeating borders around every row.

### 2. Group Status, Do Not Repeat It

If several rows share status, put that status in the group heading. Do not repeat
`Configured`, `Missing`, `Ready`, or `Needs setup` on every collapsed row.

Preferred:

- `Needs setup` group containing Instructions and Remote access.
- `Configured` group containing Memory and Folders.
- Row-level pills only for exceptional item-specific state such as a Jira
  capability that needs setup.
- A single quiet dot on the leading icon of a configured item is acceptable: it
  is one glyph reinforcing the group, not scattered status text.

Avoid:

- A header summary plus per-row status dots plus per-row status text.
- The same warning message appearing in three places.

### 2a. Nouns Are Titles; Counts Are Metadata

Lead every summary with the thing the user recognizes, not a generic count.
The eye scans for nouns it knows, so the noun is the title and the count or
status is the subtitle or a pill.

Preferred:

- Title `GitHub`, subtitle `Ready · 1`.
- Title `Folders`, subtitle `Primary ~/.../astra`, a green configured dot.
- A collapsed `Configured` summary titled with the item names, subtitled with
  the count.

Avoid:

- Title `1 ready capability`, subtitle `GitHub`.
- Title `Configured items` when the item names would fit.

### 3. Collapsed Rows Are Summaries

Collapsed rows should communicate only:

- Icon.
- Strong title.
- Concise subtitle.
- Optional single action.
- Disclosure affordance.

Keep editing controls, secondary buttons, removal actions, and dense metadata
inside the expanded state.

### 4. Expand In Place

When a row needs configuration, expand it inside the same card. This keeps the
user oriented and avoids sending them to another screen for small changes.

Expanded state may contain:

- Text editors.
- Editable memory rows.
- Copy and remove controls.
- Add controls.
- Short validation or help text.

Expanded state should still avoid nested card chrome unless the content is a
real form control that needs its own boundary.

### 4a. Disclosures Name Their Payload

A collapse control should be honest about what it hides. Count it, and never
collapse a single item behind a summary.

- Render the disclosure verb with its count: `Show all (3)`, not `Show all`.
- Apply the N >= 2 rule: a lone item renders expanded, never behind
  `Show all (1)`, which hides nothing worth hiding.
- Remember the choice (see State Model): the panel should not forget what the
  user expanded every session.

### 5. Actions Should Be Close To Meaning

Place actions where they belong:

- Card-level `Add` for adding from a library.
- Row-level verb for the specific row.
- Expanded-row remove/copy controls next to the item they affect.

Avoid separating a plus icon far from its label. If an icon and label are not
visually connected, remove the icon.

### 5a. State Is A Row; A Verb Is A Button

A row describes what something is; a button causes a change. Do not render them
with the same chrome. When a card mixes read-only facts with the operations the
user performs on them, the facts stay as quiet key-value rows and the verbs move
to a button footer at the foot of the card.

Preferred (the Repository card):

- `Branch`, `Checkout`, `Changes` as quiet key-value rows.
- A footer with a prominent primary button and a secondary button:
  `Commit & push` and `Create PR`.
- A blocking-state line above the buttons when an action is gated
  (`3 ahead, 2 behind — pull first`), and a readiness caption when a verb is
  unavailable.

Avoid:

- A verb rendered as a tappable row that looks identical to a state row.
- Cramming a status badge (ahead/behind counts) onto an action so it reads as
  neither state nor action.

### 5b. One Verb Per Meaning

When the same word labels several different operations, nothing is evident.
Reserve `Add` for appending to a list. Use a descriptive verb for first-time
configuration so the eye can tell "you must do this" from "you may extend this".

Preferred:

- Instructions: `Write` (then `Edit` once set).
- Remote access: `Connect`.
- Folders: `Choose…` (then `Add` for another path).
- Capabilities header: `Add` (list-append from the library).

Avoid:

- `Add` appearing four times in one panel meaning four different things.

### 6. Visual Weight Follows Importance

Use stronger visual weight for what users should scan first:

- Card title.
- Group heading.
- Row title.
- Exceptional row badge.

Use lower visual weight for supporting metadata:

- Subtitle.
- Helper copy.
- Secondary details.
- Copy/remove icons.

## Layout Grammar

### Card

Cards should use the shared rail section shape:

- Rounded rectangle at the outer section.
- Subtle fill.
- Subtle 1px stroke.
- No nested group stroke unless the nested group is a distinct object.

In code, prefer existing rail tokens in `StanfordTheme.swift`:

- `Stanford.railSectionSpacing`
- `Stanford.railPanelSpacing`
- `Stanford.railSectionContentSpacing`
- `Stanford.railContentPadding`
- `Stanford.railCardCornerRadius`
- `Stanford.railCompactCardCornerRadius`
- `Stanford.radiusSmall`
- `Stanford.radiusMedium`
- `Stanford.radiusLarge`

### Header

Header shape:

- Left: section title, `Stanford.ui(15, weight: .semibold)` in a
  docked desktop rail.
- Right: optional compact action.
- Keep secondary header copy out of the default docked state. Use help text or
  a tooltip before stacking a second action line.
- Avoid summary pills unless they add new information not shown by groups.

Example:

```text
Capabilities                                      Add
```

### Group Heading

Group headings should be quiet:

- Small semibold label.
- Secondary color by default.
- Warning tint only when the group heading itself is the only warning signal.

Example:

```text
Action needed
Ready
Drafts
Needs setup
Configured
```

### Summary Row

Use the same scan pattern for comparable rows:

```text
[icon]  Title                         Optional action  >
        Concise subtitle
```

Recommended proportions:

- Leading icon frame: about 30pt.
- Icon size: about 16pt. A real brand mark fills more of its box than an SF
  Symbol, so render it a touch smaller to match optical weight (see Icons).
- Title: `Stanford.ui(14, weight: .semibold)` for docked inspector rows.
- Subtitle: `Stanford.caption(12)`, one line, truncated, with the full text in a
  `.help` tooltip. Single-line subtitles keep row height predictable and stop a
  setup block from reading as a wall of text.
- Row minimum height: about 44-48pt for one-line operational controls and 52pt
  for setup and summary rows.
- Trailing chevron: secondary, about 11pt.

Rows should be full-width with no inner rounded border in collapsed state. The
whole row body is the tap target; the trailing verb is a separate target.

The rail should stay visually subordinate to the work canvas. Do not size rail
section headers or row titles at or above the task conversation body unless the
rail is presented as the primary surface.

### Dividers

Use dividers sparingly:

- Between rows in the same group.
- Start divider after the icon column, not at the card edge.
- Keep opacity low.

Avoid divider stacks that make the panel look like a table unless the content is
actually tabular.

### Badges And Pills

Use badges only when they reduce ambiguity:

- A capability row with `Needs setup`.
- A count pill in a section header when not otherwise represented.

Avoid badges for information already encoded by grouping.

## State Model

Collapsed state:

- Shows what the item is and whether there is something useful inside.
- Hides configuration controls.
- Uses group placement to convey broad status.

Expanded state:

- Shows configuration.
- Exposes edit, remove, copy, and add controls.
- Preserves the row's card context.

Repository is the deliberate exception to summary-first disclosure: show it
expanded by default when Git repositories exist, because the panel only appears
when source control is actionable workspace context. Its state (repository,
branch, checkout, changes) reads as quiet key-value rows; its verbs live in a
button footer (see 5a). Offer `Hide` to compress to a one-line summary, and put
the changes count and any ahead/behind in that summary so the collapsed line is
still truthful about whether there is uncommitted or unpushed work.

Persisted state:

- Remember each section's expand/collapse choice per workspace, so the panel
  reopens the way the user left it. Back this with a small `UserDefaults` store,
  not new `@AppStorage` reads.
- Persist the layout-level choices (which groups are open, repository summary vs
  details). Keep momentary state ephemeral (the changes drawer, an in-progress
  composer).

Adaptive order:

- Order sections by where the user has invested. While setup is still pending,
  keep it directly under the repository so onboarding is not buried. Once setup
  is complete, let the capabilities the workspace actually uses rise above the
  now-compact configured-setup summary.

Empty state:

- Use short, concrete copy.
- Offer the relevant action near the empty state.
- Avoid explanatory paragraphs inside dense panels.

## Interaction Rules

- Make the row body toggle expansion.
- Keep the row-level verb as a separate click target.
- Keep destructive actions inside expanded state, and confirm before acting: a
  remove control names exactly what it will delete and runs only on an explicit
  second tap. Reassure when the data survives (removing a folder unlinks it; it
  does not delete the folder).
- Use tooltips for icon-only controls such as copy and remove.
- Preserve keyboard and accessibility semantics by using real `Button`,
  `TextField`, and `TextEditor` controls rather than gesture-only views.

## Typography

Use existing Stanford typography helpers:

- `Stanford.ui(...)` for interface text.
- `Stanford.caption(...)` for supporting details.
- `Stanford.mono(...)` for paths, commands, IDs, or code-like values.
- `Stanford.heading(...)` for larger page-level headings, not compact rail rows.

Do not add negative letter spacing. `Stanford.bodyTracking(for:)` intentionally
returns `0`.

## Color

Default to semantic foreground styles:

- `.primary` for row titles.
- `.secondary` for subtitles and group labels.
- `.tertiary` for helper text and quiet icon controls.

Use brand colors deliberately:

- `Stanford.lagunita` for interactive accents — and only interactive things. If
  text is in the accent color, it must be tappable. Counts, status, and metadata
  are never accent-colored.
- `Stanford.poppy` for warnings and needs-setup emphasis.
- `Stanford.paloAltoGreen` for healthy/configured state when explicitly shown,
  such as the configured dot.
- `Stanford.errorRed` for destructive or error states.

Make state legible without the accent. A blocking sync state (behind, diverged)
drops to the info tint rather than the "ready" accent, so it never implies an
action is safe when it is not.

Avoid large surfaces dominated by one accent color. The lean system should read
as neutral with meaningful highlights.

## Icons

Icons support scanning; they should not become decoration.

Rules:

- Use one leading semantic icon per row.
- Lead with the real brand mark when a row represents a recognizable third-party
  service; fall back to an SF Symbol for everything generic. A code-brackets
  stand-in for GitHub or a cloud for Google Cloud throws away free recognition.
- Use SF Symbols already common in the app for non-brand rows.
- Keep icon color consistent in a panel unless an exceptional state needs tint.
- Do not repeat an icon and a text label if the label alone is clearer.

Examples:

- Capabilities with a brand: GitHub, Jira, Google Cloud, Google Drive marks.
- Capabilities without one: terminal, eye, cylinder, lock.shield.
- Workspace setup: text quote, memory/checkmark, folder, network/globe.

Brand marks, in practice:

- The app ships no asset catalog and the custom bundling step makes one fragile,
  so brand marks are rendered from their vector path data into a SwiftUI `Path`
  (`SVGPathParser` + `BrandMark` in `Astra/Views/Components`). Resolution is by
  capability id/name, with a graceful SF Symbol fallback when there is no mark.
- Marks are monochrome and inherit the row's foreground, so they read in both
  light and dark mode and sit at the same weight as the SF Symbols beside them.
- Use the official single-color mark (the Simple Icons CC0 glyphs); a brand's
  trademark is used only to identify the integration, never decoratively.

## Editing In The Lean System

Inline editing is appropriate when the edit is small and local to the card:

- Workspace instructions.
- Workspace memories.
- Workspace folders.
- Remote server preview with a handoff to a deeper editor.

Inline editing should:

- Appear only after row expansion.
- Use light input boundaries.
- Keep add/remove controls next to the affected item.
- Persist through the same model path as the full configuration screen.

If editing requires a long multi-section form, use the expanded row as a preview
and route to the dedicated editor.

## Implementation Guidance

When building a lean panel in SwiftUI:

1. Start with the semantic model: section, groups, rows, details.
2. Build the collapsed state first.
3. Add expansion after the collapsed scan path is clear.
4. Put status in group headings before adding row badges.
5. Reuse existing theme tokens from `StanfordTheme.swift` and the shared row
   vocabulary in `Astra/Views/Components/ContextRailRows.swift` rather than
   building a fourth bespoke row.
6. Keep presentation copy and ordering in a presentation type (e.g.
   `WorkspaceRightRailPresentation`), out of the view, so a test can pin it.
7. Add a focused presentation test for the design rule being protected.
8. Verify in `ASTRA Dev.app` with realistic data.

For right-rail work, the canonical example lives in:

- `Astra/Views/WorkspaceRightRailView.swift` — the panel and its adaptive order.
- `Astra/Views/WorkspaceGitSectionView.swift` — the state-rows + button-footer
  Repository card.
- `Astra/Views/Components/ContextRailRows.swift` — the shared row, badge, and
  summary-row vocabulary.
- `Astra/Views/Components/BrandMark.swift` + `SVGPathParser.swift` — brand marks.
- `Astra/Services/Settings/RailDisclosureStore.swift` — persisted disclosure.
- `Tests/CapabilityRailPresentationTests.swift`,
  `Tests/BrandMarkTests.swift`, `Tests/RailDisclosureStoreTests.swift`.

## Anti-Patterns

Avoid:

- Double-border designs around one conceptual list.
- Summary counts repeated in row badges.
- Scattered status text and dots when a group label can carry the state.
- A generic count as a title when the noun would fit (`1 ready capability`).
- The same verb (`Add`) meaning several different operations in one panel.
- A verb styled as a state row, or a state badge crammed onto an action.
- Accent-colored text that is not tappable.
- `Show all` with no count, or collapsing a single item behind `Show all (1)`.
- Forgetting the user's expand/collapse choices on every relaunch.
- A destructive icon that deletes on the first tap with no confirmation.
- A stand-in icon where a recognizable brand mark exists.
- Toolbars or action rows that float far from the item they affect.
- Buttons with text squeezed into tiny fixed widths.
- Decorative cards that do not frame a real repeated item, modal, or tool.
- Dense controls visible before the user expands a row.
- Large explanatory text inside operational panels.

## Review Checklist

Before shipping a UI change, ask:

- Can a user understand the card in five seconds?
- Does the collapsed state show only the essential scan path?
- Is each repeated item using the same row grammar?
- Do nouns lead, with counts and status as metadata?
- Do state and actions wear different chrome (rows vs buttons)?
- Does each verb mean one thing, and is the accent color only on tappable text?
- Are groups carrying shared status instead of each row repeating it?
- Do disclosures name their count, and is a lone item shown expanded?
- Are controls hidden until the user asks to edit, and do destructive ones
  confirm first?
- Are expand/collapse choices remembered across sessions?
- Does a recognizable integration show its real brand mark?
- Is there only one border around one conceptual group?
- Does the layout still work with real workspace data, in light and dark?
- Did a focused presentation test encode the rule?
- Was the change visually checked in `ASTRA Dev.app`?
