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
- One primary action per row.
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

Avoid:

- A header summary plus per-row status dots plus per-row status text.
- The same warning message appearing in three places.

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

### 5. Actions Should Be Close To Meaning

Place actions where they belong:

- Card-level `Add` for adding from a library.
- Row-level `Add` or `Edit` for the specific row.
- Expanded-row remove/copy controls next to the item they affect.

Avoid separating a plus icon far from its label. If an icon and label are not
visually connected, remove the icon.

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
- Icon size: about 16pt.
- Title: `Stanford.ui(14, weight: .semibold)` for docked inspector rows.
- Subtitle: `Stanford.caption(12)`, 1-2 lines.
- Row minimum height: about 44-48pt for one-line operational controls, 56pt
  for two-line setup rows, and 58pt for summary rows.
- Trailing chevron: secondary, about 11pt.

Rows should be full-width with no inner rounded border in collapsed state.

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
when source control is actionable workspace context. Keep its rows at rail
density and offer `Hide` to compress the controls after the user has seen them.

Empty state:

- Use short, concrete copy.
- Offer the relevant action near the empty state.
- Avoid explanatory paragraphs inside dense panels.

## Interaction Rules

- Make the row body toggle expansion.
- Keep row-level `Add` or `Edit` as a separate click target.
- Keep destructive actions inside expanded state.
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

- `Stanford.lagunita` for interactive accents and neutral capability icons.
- `Stanford.poppy` for warnings and needs-setup emphasis.
- `Stanford.paloAltoGreen` for healthy/configured state when explicitly shown.
- `Stanford.errorRed` for destructive or error states.

Avoid large surfaces dominated by one accent color. The lean system should read
as neutral with meaningful highlights.

## Icons

Icons support scanning; they should not become decoration.

Rules:

- Use one leading semantic icon per row.
- Use SF Symbols already common in the app.
- Keep icon color consistent in a panel unless an exceptional state needs tint.
- Do not repeat an icon and a text label if the label alone is clearer.

Examples:

- Capabilities: cloud, doc, terminal, eye, cylinder.
- Workspace setup: text quote, memory/checkmark, folder, network/globe.

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
5. Reuse existing theme tokens from `StanfordTheme.swift`.
6. Add a focused presentation test for the design rule being protected.
7. Verify in `ASTRA Dev.app` with realistic data.

For right-rail work, the canonical example lives in:

- `Astra/Views/WorkspaceRightRailView.swift`
- `Tests/CapabilityRailPresentationTests.swift`

## Anti-Patterns

Avoid:

- Double-border designs around one conceptual list.
- Summary counts repeated in row badges.
- Per-row status dots when group labels can carry the state.
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
- Are groups carrying shared status instead of each row repeating it?
- Are controls hidden until the user asks to edit?
- Is there only one border around one conceptual group?
- Does the layout still work with real workspace data?
- Did a focused presentation test encode the rule?
- Was the change visually checked in `ASTRA Dev.app`?
