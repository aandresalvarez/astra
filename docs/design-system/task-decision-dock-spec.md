# Task Decision Dock Specification

This specification defines the compact task decision surface shown at the bottom
of a task conversation. It translates the HTML mockup in
`docs/design-system/task-decision-placement-mockup.html` into ASTRA's SwiftUI
implementation rules.

> Amendment (2026-07-10): the dock's `Details` popover is now the single run
> inspector for the latest finished run. It hosts the full run-activity
> sections (permissions, issues, progress, tools, files, policy, technical
> output, stats — injected by `TaskMainView`) plus an `Open Diagnostics`
> footer, and the thread suppresses its own run-details disclosure for that
> run (`TaskRunNoticePresentationRules.detailsLiveInDock`). Older runs and
> live runs keep their inline disclosures. This inverts the original
> "suppress the dock Details when the thread shows run details" rule — the
> no-duplication goal is unchanged; ownership moved to the dock.

The dock is not a replacement for the conversation, run details, Mission
Control, artifact cards, or task state evidence. It is the final decision
surface for the current task state.

## Goal

Make the bottom task surface lean, predictable, and easy to scan:

- The conversation thread carries user/agent meaning.
- Artifact cards in the thread open artifacts.
- Run detail rows in the thread carry execution evidence.
- Mission Control/task state details remain available in the existing detail
  surfaces.
- The bottom dock carries only the current decision and non-duplicated decision
  helpers.

The user should be able to answer one question in less than five seconds:

```text
What happened, and what can I do next?
```

## Non-Goals

- Do not move run logs, tool calls, policy data, or raw output into the decision
  dock.
- Do not duplicate artifact-open controls already shown in the conversation.
- Do not duplicate task status/run details already shown above the composer.
- Do not make a second Mission Control card inside the dock.
- Do not add hard-coded colors, fonts, radii, shadows, or ad hoc spacing in the
  SwiftUI view.

## Design-System Requirement

The ASTRA implementation must use the Stanford design system already defined in
the app.

Required style sources:

- Typography: `Stanford.ui(...)`, `Stanford.caption(...)`, `Stanford.body(...)`
  as appropriate.
- Semantic colors: `Stanford.lagunita`, `Stanford.poppy`,
  `Stanford.paloAltoGreen`, `Stanford.failed`, `Stanford.coolGrey`,
  `Stanford.black`, `Stanford.fog`, and system semantic styles such as
  `.primary`, `.secondary`, and `.tertiary`.
- Shape/radius tokens: `Stanford.radiusSmall`, `Stanford.radiusMedium`,
  `Stanford.railCompactCardCornerRadius`, and existing composer presentation
  constants.
- Button styling: existing `StanfordButtonStyle` or local button helpers that
  derive exclusively from Stanford tokens and presentation constants.
- Layout constants: `TaskComposerPresentation` or a similarly named
  presentation-constant type. Any new spacing/height/radius value must be added
  there first, with a presentation regression test.

Forbidden in production SwiftUI:

- Raw hex colors.
- Raw `Color(red:green:blue:)` values.
- Hard-coded custom font names or `Font.system` replacements where Stanford
  helpers exist.
- One-off shadows, radii, or opacity values in `TaskDecisionDockView` unless
  they are backed by named design-system or presentation constants.
- Inline magic spacing values scattered through the view.

The standalone HTML mockup may use literal CSS values because it is a prototype.
The SwiftUI implementation must not copy those values directly.

## Placement

The dock remains at the bottom of `TaskMainView`, directly above the composer
input area.

It should appear only when `TaskDecisionDockPresentation.build(...)` returns a
presentation. It should remain visually attached to the composer, not presented
as a separate large card.

Recommended hierarchy:

```text
Task conversation
  agent/user messages
  artifact card(s)
  run meta row
  run details disclosure

Bottom composer region
  task decision dock
  composer input
  composer toolbar
```

The dock should share the composer region boundary. Avoid adding a full
secondary card boundary around the dock.

## Information Architecture

### What Belongs In The Conversation

The following belong in the chat thread or per-run details, not in the decision
dock:

- Agent response prose.
- Artifact cards and artifact open controls.
- Run finished/cancelled/stopped metadata.
- Tool count, file count, duration, token usage, exit code.
- Policy details.
- Tool activity.
- Raw technical output.
- Mission Control detail lists.

### What Belongs In The Dock

The dock contains:

- A semantic status icon.
- A short decision title.
- Optional short utility action if it is not duplicated elsewhere.
- Secondary decision actions.
- One primary decision action.

Examples:

```text
! Partial result found        Add verification      Close anyway  Revise  Retry
✓ Result ready for review                         Send back       Close task
x Blocked by policy                              Abandon         Revise request
```

### What Does Not Belong In The Dock

Remove these from the default visible dock row:

- `Task status` / `Details` button, when it duplicates the run detail row in the
  conversation.
- `Open artifact`, when an artifact card is visible in the conversation.
- Long summary sentences.
- Metric pills.
- Mission Control sections.

If the artifact card is not visible for a future layout variant, `Open artifact`
may be restored as a utility action, but only under an explicit presentation
condition that proves there is no visible duplicate.

## Visible Row Contract

The default dock row should be one line at normal desktop widths.

Visible content:

```text
[status icon] [decision title] [optional utility action] [decision actions]
```

The row must not visibly show a long explanation sentence. The presentation may
still carry a `summary` string, but the view should expose it through help,
accessibility, or a details surface rather than placing it in the compact row.

For example:

- Visible title: `Partial result found`
- Help/accessibility summary: `Found index.html; expected artifact check failed.`

## Tooltip And Accessibility

The summary should be available without consuming layout space.

SwiftUI behavior:

- Apply `.help(presentation.summary)` to the title/status cluster.
- Provide an accessibility label that includes title and summary.
- Keep the visible title line-limited to one line.
- Do not rely on hover alone; VoiceOver should be able to read the summary.

Recommended accessibility shape:

```text
Accessibility label: Partial result found.
Accessibility value: Found index.html; expected artifact check failed.
```

The status cluster should be keyboard reachable only if it has an action or
popover. If it is informational only, it should be part of the dock's combined
accessibility element rather than a fake button.

## Action Model

### Decision Actions

Decision actions change the task state or execution path.

Examples:

- `Retry`
- `Revise`
- `Close task`
- `Close anyway`
- `Approve`
- `Approve next step`
- `Run task`
- `Resume`
- `Abandon`

Rules:

- At most one primary action.
- Primary action is right-most.
- Primary action uses the presentation tone color.
- Secondary destructive or low-confidence actions may be quiet text buttons.
- Action labels must not truncate into ambiguity. If space is insufficient,
  wrap the action group as a group before overlapping.

### Utility Actions

Utility actions support the decision but do not directly advance the task.

Allowed visible utility action in the current compact dock:

- `Add verification`, when no validation contract exists and ASTRA can infer a
  useful validation check from the current artifact.

Excluded by default:

- `Open artifact`, because the artifact card in the conversation already owns
  that action.
- `Task status` / `Details`, because run details already appear in the thread.

`TaskDecisionDockPresentation.utilityActions` should therefore be filtered by
visibility context, not only by action kind. The presentation layer should know
whether a utility action is duplicated by the visible thread.

## Layout Behavior

Use SwiftUI layout primitives that prevent overlap:

- Use `ViewThatFits(in: .horizontal)` for compact vs wrapped variants.
- Give the status/title cluster layout priority over optional utility actions.
- Keep decision actions in a fixed-size group so buttons do not compress into
  each other.
- Allow utility actions to drop before decision actions do.
- Allow the entire action group to wrap below the title only on narrow widths.
- Never allow text to overlap action buttons.

Preferred layout order:

1. One-line row: status/title, utility action, spacer, decision actions.
2. Two-line compact row: status/title and utility action on first line, decision
   actions on second line.
3. Narrow mobile row: status/title, utility action, then vertically stacked or
   wrapped decision actions.

The current mockup's final target for desktop is one line. The SwiftUI
implementation must verify this with real ASTRA window widths, not only unit
tests.

## State Mapping

### Partial Result

Condition:

- A run produced at least one visible artifact, but validation failed, was not
  available, or the task remains review-needed.

Visible dock:

```text
Partial result found        Add verification        Close anyway  Revise  Retry
```

Summary/help:

```text
Found index.html; expected artifact check failed.
```

If no verification can be inferred, omit `Add verification`.

### Result Ready

Condition:

- A result exists and there is no blocking failure.

Visible dock:

```text
Result ready for review                         Send back  Close task
```

If validation passed, tone is verified. If there is no automated validation,
the title may still be ready/review, but the help text should say no automated
check was available.

### No Usable Result

Condition:

- The run completed or stopped without a usable artifact.

Visible dock:

```text
No usable result                                Close anyway  Revise  Retry
```

No artifact-open action should be shown.

### Blocked By Policy Or Provider

Condition:

- ASTRA stopped or blocked the run before it could create a result.

Visible dock:

```text
Blocked by policy                               Abandon  Revise request
```

The summary/help should name the blocker in plain language. Technical output
remains in run details.

### Goal Mode Approval

Condition:

- A goal-plan step awaits approval.

Visible dock:

```text
Approve next step                               Open plan  Approve next step
```

`Open plan` can remain because the plan is not otherwise always visible in the
thread at the decision point. If it is visible, presentation should suppress the
duplicate.

## Presentation Model Changes

The current owner path is:

- `Astra/Services/Tasks/TaskDecisionDockPresentation.swift`
- `Astra/Views/TaskDecisionDockView.swift`
- `Astra/Views/TaskMainView.swift`
- `Tests/TaskDecisionDockPresentationTests.swift`
- `Tests/ComposerPresentationTests.swift`

Recommended model adjustments:

1. Add explicit visible-placement context to
   `TaskDecisionDockPresentation.Context`.

   Example:

   ```swift
   var visibleThreadAffordances: Set<TaskThreadAffordance>
   ```

   Suggested enum:

   ```swift
   enum TaskThreadAffordance: Hashable {
       case artifactOpen
       case runDetails
       case missionControlDetails
       case planDetails
   }
   ```

2. Filter support/utility actions against visible thread affordances.

   Rules:

   - Suppress `.openArtifact` when `.artifactOpen` is visible.
   - Suppress details/status actions when `.runDetails` or
     `.missionControlDetails` are visible.
   - Keep `.addVerification` when it is actionable and not duplicated.

3. Treat `summary` as help/accessibility copy in compact mode.

   Do not render it as a visible second line in the default desktop dock.

4. Preserve details data in `presentation.details`.

   The compact dock may not render the details toggle, but details still matter
   for diagnostics, tests, and any explicit expanded/debug surface.

5. Keep `usesOverflowMenu == false` unless a future implementation introduces a
   tested overflow interaction.

## SwiftUI View Requirements

`TaskDecisionDockView` should render:

- Leading accent rail using tone color from `TaskDecisionDockTone`.
- Status icon using `presentation.icon`.
- Title using Stanford typography and one-line truncation.
- Summary via `.help(...)` and accessibility, not visible body text.
- Optional utility action row inline with the title.
- Decision actions right-aligned.

Implementation constraints:

- Do not use hard-coded colors in the view.
- Do not use raw numeric style values directly in the view when an existing
  token/constant can represent the value.
- Keep button visuals in helper functions that map action/tone to Stanford
  tokens.
- Use `ViewThatFits` or equivalent adaptive layout to avoid overlap.
- Keep `.fixedSize(horizontal: true, vertical: false)` on the decision action
  group or an equivalent mechanism.
- Apply `.lineLimit(1)` to visible title and action labels where appropriate.
- Ensure long localized labels wrap the group rather than overlap.

## Composer Integration

`TaskMainView` should keep the dock inside the composer region:

- Dock above the text input.
- Composer text input below.
- Toolbar at the bottom.

Do not add extra card chrome between dock and composer. The composer region is
the boundary.

When no decision dock is present, the composer should retain its normal compact
spacing.

## Testing Requirements

Every implementation change must include regression coverage.

### Presentation Tests

Add or update `TaskDecisionDockPresentationTests`:

- Artifact-visible context suppresses `.openArtifact` from
  `utilityActions`.
- Run-details-visible context suppresses details/status utility action from the
  visible dock.
- Partial-result context still exposes `.addVerification` when inference is
  available.
- Ready/verified context does not expose an empty utility row.
- No-usable-result context has no artifact-open action.
- Existing details remain in `presentation.details` even when not visible as a
  dock button.

### Composer Presentation Tests

Add or update `ComposerPresentationTests`:

- Summary copy is tooltip/accessibility-only in compact mode.
- Decision dock uses Stanford/presentation constants, not nested chrome.
- Utility actions are not duplicated when the thread already has equivalent
  affordances.
- Action overflow remains disabled unless explicitly redesigned.

### View Tests

Add or update SwiftUI/view tests where feasible:

- Compact dock renders one visible status title line.
- Summary sentence does not appear as visible text in the dock.
- `Add verification` appears for partial result when available.
- `Open artifact` does not appear in the dock when an artifact card is visible.
- `Details` or `Task status` does not appear in the dock when run details are
  visible in the thread.
- Primary action remains reachable and labeled.

### Visual QA

After implementation:

1. Build and run `ASTRA Dev.app`.
2. Open a completed artifact task.
3. Open a partial/no-usable-result task.
4. Open a Goal Mode approval task.
5. Verify the dock at normal desktop width and a narrowed window:
   - no overlapping text/buttons;
   - no duplicated artifact/status controls;
   - summary available via help/accessibility;
   - primary decision is obvious;
   - composer remains usable.

## Acceptance Criteria

The implementation is complete when:

- The dock is one compact line on normal desktop widths.
- Long explanatory status copy is not visible in the compact row.
- Hover/help/accessibility expose the explanatory summary.
- `Task status`/`Details` is not duplicated in the dock when thread details are
  present.
- `Open artifact` is not duplicated in the dock when an artifact card is visible.
- `Add verification` remains available when useful.
- Decision buttons never overlap title or utility text.
- All colors, fonts, radii, and control treatments come from Stanford tokens or
  named presentation constants.
- Focused regressions pass.
- `git diff --check` passes.

