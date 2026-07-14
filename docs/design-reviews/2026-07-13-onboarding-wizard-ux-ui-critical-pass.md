# ASTRA Onboarding Wizard — Critical UX/UI Pass

**Date:** 2026-07-13

**Status:** Analysis and proposal; no product code changed

**Visual evidence:** User-provided 1602 × 1214 Retina screenshot of the Welcome step

**Codebase snapshot:** detached HEAD `b7b4f2bc1334`

**Code scope:** The five-step first-run flow, replay behavior, shared setup components,
theme tokens, and current tests

**Primary files reviewed:**
`Astra/Views/OnboardingWizardView.swift`,
`Astra/Views/Components/RuntimeSetupSection.swift`,
`Astra/Views/MacOSPermissionsSectionView.swift`,
`Astra/Views/ContentView.swift`,
`Astra/Views/StanfordTheme.swift`, and
`Tests/OnboardingWizardTests.swift`

## Executive verdict

The user's sense that this screen is disconnected from the rest of ASTRA is
correct, but the root cause is not the font family or one bad spacing value.
The wizard already uses ASTRA's Source Serif heading, Source Sans interface type,
semantic backgrounds, teal interaction color, and shared primary button. At the
token level it is mostly on-brand.

The disconnection is structural and semantic:

1. **The screenshot is a replay of a first-run flow.** The visible `Close` button
   only appears when onboarding is replayed. ASTRA is therefore saying “Welcome”
   and asking for a “First Workspace” over an already configured app. Settings
   promises an environment check and catalog overview, but actually reopens the
   entire first-run flow.
2. **The Welcome step does not earn a separate click.** It collects no input,
   asks for no decision, and describes ASTRA's internal taxonomy instead of the
   setup task the user is about to perform.
3. **The shell looks like a web onboarding component inside a macOS operator
   app.** A full-width labeled stepper, a marketing-style hero, three decorative
   accent systems, a large blue callout, and a distant generic `Next` action do
   not follow ASTRA's otherwise quiet, action-led composition.
4. **The language is being distorted by layout constraints.** The step that
   creates a workspace, guidance, and capabilities is called `Folder` because a
   test limits progress labels to eight characters. The final state is called
   `Done` in one place and `You're Ready` in another.
5. **Actions do not state their consequences.** `Next` eventually creates
   durable workspace state. In replay mode, runtime choices save immediately,
   while an in-progress workspace draft can be discarded by `Close` without a
   warning.
6. **The implementation owns several parallel presentation systems.** Visible
   titles are hard-coded in each page, `Step.title` is separately tested but not
   rendered, the footer has one generic action, and embedded settings components
   render their own headers inside the wizard's headers.

The first-principles recommendation is therefore:

- create distinct **first-run setup** and **review setup** experiences;
- reduce first-run setup to four meaningful steps:
  `Runtime → Access → Workspace → Ready`;
- replace the five-label tracker with a compact, semantic progress treatment;
- give every primary action an honest verb;
- derive titles, copy, progress, actions, and accessibility descriptions from
  one testable presentation model; and
- keep the existing domain owners rather than duplicating runtime, access, or
  workspace state in a new view layer.

This is not a proposal to make onboarding look like the dense right rail. The
lean design guide explicitly exempts onboarding from that exact pattern. It is a
proposal to bring onboarding back to ASTRA's shared principles: restrained
chrome, accurate nouns, explicit actions, one meaningful accent, and state that
can be trusted.

## 1. Audit scope and evidence limits

### Visual scope

Only Step 1, Welcome, was visually captured in the supplied screenshot. The
remaining steps were reviewed in source, not visually audited. Any statement
about their rendered density or behavior is marked as a source-derived risk and
must be verified in ASTRA Dev before implementation is accepted.

### Experience under review

The user goal is:

> Understand what setup will do, satisfy the minimum requirements, create or
> review the relevant configuration with confidence, and arrive in ASTRA ready
> for a real task.

The current source flow is:

| Step | Progress label | Visible page title | Main behavior | Evidence health |
| --- | --- | --- | --- | --- |
| 1 | Welcome | Welcome to ASTRA | Product explanation only | **Needs structural revision** — screenshot and source reviewed |
| 2 | Runtime | Choose an AI Runtime | Select, install, sign in, and verify a runtime | Visual state not captured; source structure reviewed |
| 3 | Access | macOS Access | Check Keychain and workspace storage; defer browser access | Visual state not captured; duplicate-header risk confirmed in source |
| 4 | Folder | Create Your First Workspace | Name workspace, add guidance, select and validate capabilities, then create it | Visual state not captured; action-semantic risk confirmed in source |
| 5 | Done | You're Ready | Summarize and open the workspace | Visual state not captured; truthfulness risk confirmed in source |

### What cannot be concluded from the screenshot alone

- VoiceOver reading order and announcements.
- Full keyboard tab order and focus-ring visibility.
- Whether users attempt to click the passive progress stages.
- Dark-mode contrast.
- Layout behavior at ASTRA UI scales 0.7 and 1.5.
- Scroll position when moving backward and forward.
- Whether users understand which replay changes save immediately.

This document identifies accessibility risks; it does not claim WCAG
conformance or non-conformance.

## 2. What works and should be preserved

The redesign should not discard the parts that already belong to ASTRA.

| Current strength | Why it should stay |
| --- | --- |
| Serif page heading plus sans-serif UI copy | Matches ASTRA's brand typography and the `New Workspace` sheet. The type choice is not the source of disconnection. |
| One obvious primary action | The footer makes the forward path easy to find. The label needs to change by step, not the hierarchy. |
| Stable header/body/footer shell | Runtime and workspace setup can become tall. A stable shell avoids disruptive sheet resizing. The short Welcome composition is the problem. |
| Real SwiftUI buttons and fields | Preserves native keyboard and accessibility behavior. |
| Return and Escape shortcuts | The default action and replay-only close action already have useful keyboard paths. |
| Reduce Motion support | Step transitions already honor the system setting. |
| Runtime readiness gate | Users cannot advance until the selected runtime is usable. That is a meaningful, trustworthy gate. |
| Workspace validation and warning path | Blocking issues and bypassable warnings are differentiated. The final summary must reflect the actual result. |
| Semantic, adaptive color tokens | The theme already supports light and dark appearances. The fix is to apply the roles more carefully. |

Relevant precedents already in the app:

- `NewWorkspaceSheet` uses one 24-point gutter around header, body, and footer
  (`ContentView.swift:3454-3553`).
- `WorkspaceEmptyStateView` uses the same serif/sans hierarchy with plain,
  outcome-led actions (`WorkspaceEmptyStateView.swift:3-50`).
- `CapabilityMCPInstallReviewSheet` uses one consistent 18-point rail across
  header, body, and footer (`CapabilityMCPInstallReviewSheet.swift:35-70`).
- `AstraAboutInfo` already contains stronger, stable product language than the
  Welcome page (`AstraAboutInfo.swift:4-18`).
- `AstraAppIconTile` and `AstraReticleMark` already provide the real product
  identity (`AstraBrandIdentity.swift:134-170`).

## 3. The most important root cause: first-run and replay are different jobs

The screenshot contains `Close`. In the implementation, `Close` only renders
when `allowsDismiss` is true (`OnboardingWizardView.swift:392-397`). `ContentView`
sets that only for a replay (`ContentView.swift:1127-1141`). The screenshot is
therefore not a first launch; it is an existing user reviewing setup.

That matters more than any radius or margin:

- `Welcome to ASTRA` is wrong for someone already using ASTRA.
- `Create Your First Workspace` is wrong when workspaces already exist.
- forcing the user through product orientation is wrong when Settings promised
  “Re-run the environment check and catalog overview”
  (`SettingsView.swift:341-355`).
- a first-run completion page is not the same as a configuration health review.

One Boolean currently changes only dismissal behavior. It does not change the
information architecture, copy, required steps, or success definition. That is
the primary product-level source of the disconnected feeling.

### Proposed mode A: first-run setup

**Goal:** get a new user to a usable first workspace and first task.

Recommended flow:

1. Runtime
2. Access
3. Workspace
4. Ready

This mode may remain non-dismissible because the app needs one usable runtime
and workspace to deliver its core experience.

### Proposed mode B: review setup

**Goal:** inspect and repair the current environment without pretending the app
is new.

Recommended shape: one status-first review sheet, not the first-run wizard.

| Review row | Summary | Contextual action |
| --- | --- | --- |
| AI runtime | Selected runtime plus readiness | Review runtime / Re-check |
| Local access | Keychain, workspace storage, deferred feature access | Re-check / Review details |
| Workspace location | Current root and workspace count | Open workspace settings |
| Capabilities | Ready and needs-attention counts | Open capability catalog |

Header:

> **Review ASTRA setup**
>
> Check the runtime, local access, and workspace defaults ASTRA uses now.

Footer actions:

- Secondary: `Close`
- Primary when a check is stale or failed: `Re-check`
- Primary when everything is current: `Done`

This review surface can use ASTRA's quieter status-row grammar because the user
is now operating the product, not learning it.

## 4. Why the standalone Welcome step should be removed

The Welcome page collects no input, requests no permission, and makes no
meaningful choice. Its primary contribution is a taxonomy lesson:

- “Workspaces, tasks, capabilities, and automation”
- “capability packages”
- “task shelves”
- “plans, text, query, and browser work when relevant”

Those phrases require the user to understand ASTRA before ASTRA has shown how
the concepts help. The step also introduces an optional GitHub dependency before
the user has chosen GitHub.

Removing the page improves the experience in four ways at once:

- the first screen immediately contains a real task;
- the short, top-heavy page and its empty lower half disappear;
- progress reduces from five steps to four; and
- the product promise can be stated contextually in two lines on Runtime.

Recommended Runtime opening copy:

> **Choose an AI runtime**
>
> ASTRA runs tasks through a supported agent tool on this Mac. Choose one to
> begin; you can switch later in Settings.

Quiet orientation line:

> Next, you'll review local access and create your first workspace.

This is a first-principles removal of a non-decision step, not a cosmetic
compression.

## 5. Screenshot findings — Welcome step

### P0 — The screen explains the product, not the setup task

The subtitle is a list of nouns, while the bullets mix architecture vocabulary
and implementation surfaces. The user still cannot answer three basic setup
questions:

1. What will ASTRA ask me to do?
2. What is required?
3. Can I change these choices later?

**Direction:** either remove Welcome, as recommended, or rewrite it as a setup
overview using plain outcomes.

### P0 — The primary action hides future side effects

The screenshot's `Next` label is merely vague on Welcome. The same generic label
becomes materially misleading on Workspace: `goNext()` calls
`createFirstWorkspaceAndAdvance()`, which creates durable state
(`OnboardingWizardView.swift:781-825`).

ASTRA's normal New Workspace sheet correctly says `Create`
(`ContentView.swift:3526-3551`). Onboarding should be equally honest.

**Direction:** derive the footer label and accessibility description from the
current step:

- Runtime: `Review access`
- Access: `Set up workspace`
- Workspace: `Create workspace`
- Ready: `Open {workspace name}`

### P1 — The progress component is dictating inaccurate language

The tracker reads `Welcome / Runtime / Access / Folder / Done`. `Folder` is not
the job performed on that page, and `Done` is not parallel to the other topic
labels. Tests intentionally require every label to remain at most eight
characters so the component does not wrap (`OnboardingWizardTests.swift:46-56`).

The layout constraint is now controlling the product vocabulary.

**Direction:** replace the full label rail with:

> `Setup · Step 1 of 4` plus a thin progress indicator

The current page title belongs in the body. The progress component should not
need abbreviated duplicate titles.

If the labeled tracker is retained, the minimum truthful set is:

> `Runtime / Access / Workspace / Ready`

The component must adapt to `Workspace`; the word must not adapt to the
component.

### P1 — The tracker looks interactive but is passive

Numbered stages, connected lines, teal text, and a current-state fill resemble
clickable step navigation. In source, each item is an `HStack`, not a `Button`
(`OnboardingWizardView.swift:431-483`).

**Direction:** make the progress visibly passive and compact. If product later
wants step navigation, allow only valid completed steps and give the control
real button semantics. Do not keep a tab-like appearance without navigation.

### P1 — Three accent systems compete

The screenshot has:

- a cardinal-red hand in a pink tile;
- teal progress, bullets, and primary action; and
- a sky-blue filled and bordered callout.

The theme reserves cardinal red for the brand mark and genuine errors, and teal
as the canonical interaction accent (`StanfordTheme.swift:126-135`). The hand is
not ASTRA's brand mark; the teal bullets are not interactive; and the blue note
is not an urgent status.

**Direction:**

- use the real `AstraAppIconTile` or `AstraReticleMark` when brand identity is
  needed;
- use neutral icons for explanatory rows;
- reserve teal for the primary action, focus, and actual interaction; and
- reserve tinted panels for actionable warning, error, or success states.

### P1 — The waving hand communicates the wrong personality

The hand feels friendly, but it reads like consumer onboarding and can also
resemble a stop gesture. ASTRA's product identity is calm supervision, durable
work, and precise control. A generic greeting glyph does not connect those
ideas.

**Direction:** use the real ASTRA mark at 36–42 points, or remove the badge
entirely. Do not create a new decorative onboarding mark.

### P1 — The info callout is visually stronger than its importance

The pale blue panel is the largest bounded object after the sheet itself. Its
content is non-urgent, partly optional, and belongs closer to the relevant
choice. It therefore reads more like a warning or system status than supporting
help.

The GitHub CLI (`gh`) requirement is only relevant when GitHub capabilities are
selected. `WorkspaceSetupForm` already knows whether GitHub is selected and can
surface missing authentication.

**Direction:** move the GitHub requirement beside the GitHub capability:

> Requires the GitHub CLI (`gh`) signed in on this Mac.

On first-run Runtime, keep only the universal requirement: one supported AI
runtime.

### P1 — The vertical composition creates a visual canyon

The source fixes the sheet to a minimum 760 × 560 points, caps padded content at
620 points, and pins a roughly 70-point footer to the bottom
(`OnboardingWizardView.swift:387-413`, `:748-796`). In the supplied screenshot,
the Welcome content ends around the middle of the body, leaving roughly 150
points of unused vertical space before the footer.

That space is not inherently bad. The problem is that it has no compositional
purpose and separates the explanation from its action.

**Direction:** removing Welcome is preferred. Do not add filler or merely center
the same marketing copy. If Welcome is retained, either:

- use a content-fitting 680–720 × 500–520 point introduction before entering
  the stable operational shell; or
- turn the body into a real setup overview whose rows and action occupy the
  available stage deliberately.

### P2 — Header, bullets, callout, and footer use different alignment rails

The progress strip uses a 24-point outer inset, body content uses 28-point
padding inside a centered 620-point column, and the footer uses a 20-point outer
inset. Inside the body, the hero uses a 44-point icon frame, bullets use 22
points, and the callout uses 20 points. Their text does not begin on one
repeatable axis.

Each region is reasonable alone; the sheet lacks one governing composition.

**Direction:** one shell rail and one repeated-row grammar:

- 24-point outer sheet gutter;
- 560–600-point readable content measure;
- 28–32-point explanatory icon frame;
- 12-point icon-to-copy gap;
- 8–10 points within a row;
- 16 points between repeated rows; and
- 24 points between major groups.

These values should live in a small `SetupLayout` token type and respect
`Stanford.density`, not be scattered through step views.

### P2 — Dismissal does not explain what is kept

In replay mode, runtime selection and install/sign-in work can persist
immediately. The workspace draft is local `@State`. Closing after editing that
draft discards it without a warning.

The setup experience cannot honestly behave like one atomic transaction because
installation, authentication, and macOS settings changes cannot be rolled back.

**Direction:** make setup explicitly resumable:

- committed runtime and access actions remain committed;
- persist the workspace draft until creation, or warn before discarding it;
- if the draft is dirty, show `Discard setup progress?` with `Keep editing` and
  `Discard`; and
- do not imply that `Close` reverses completed setup work.

## 6. Cross-flow source findings

These were not visually captured, but they should shape the redesign.

### Access renders a header inside a header

The wizard adds a `macOS Access` step header, embeds
`MacOSPermissionsSectionView`, which adds `Grant macOS Access` with another
shield tile and explanatory subtitle, then adds a separate `Why this matters`
callout (`OnboardingWizardView.swift:541-562` and
`MacOSPermissionsSectionView.swift:238-317`).

**Direction:** shared settings-grade components need an embedded presentation
mode that can omit their outer header and card when the wizard already owns the
page hierarchy.

### Ready can overstate the result

Access does not gate progression. Capabilities are always passed to the final
row as visually ready. The user can bypass capability warnings, and workspace
creation can report credential-save issues, yet the final page still says
`You're Ready` (`OnboardingWizardView.swift:584-608`, `:839-847`). Access is not
included in the final summary at all.

**Direction:** derive the final state from the actual outcome:

- `Ready to open {workspace}` only when required setup is ready;
- `Workspace created — follow-up needed` when optional access or capabilities
  need attention; and
- include Runtime, Local access, Workspace, and Capabilities in the summary with
  truthful status symbols and actions.

Warnings may remain non-blocking, but the success screen must not erase them.

### General workspace setup is owned by onboarding files

`OnboardingCapabilityConfiguration` and `OnboardingCapabilitySetup` live in the
872-line wizard file, while the shared `WorkspaceSetupForm` is a large
independent surface embedded inside `ContentView.swift`. Standard workspace
creation therefore depends on types owned by onboarding, while onboarding
depends on a form owned by the app shell.

**Direction:** move workspace setup models and presentation into dedicated
files, then keep onboarding as a consumer. This is an ownership repair, not a
visual refactor for its own sake.

### Current tests protect implementation constraints, not visible truth

The wizard tests protect enum order, raw values, maximum label character count,
and a `Step.title` value that is not rendered. They do not assert the visible
page title, primary action, replay policy, accessibility progress description,
or workspace-creation semantics.

**Direction:** test the presentation and navigation policy users actually see.

## 7. Proposed first-run design

### Shell

Keep the stable sheet, but simplify its structure:

| Region | Proposed treatment |
| --- | --- |
| Header | `Setup` and `Step n of 4` in small AA-safe secondary text; thin progress bar beneath; replay controls do not appear in first-run mode |
| Body | One readable 560–600-point rail; one page header; no nested page header; scroll only when content needs it |
| Footer | Back on the left, one truthful primary action on the right, blocker or warning adjacent to the action it affects |
| Accent | Teal for interaction/focus; semantic status colors only for real state; real ASTRA mark only where brand identity is useful |
| Type | Preserve Source Serif for the page heading and Source Sans for UI/body copy |

### Recommended copy deck

| Step | Title | Subtitle / orientation | Primary action |
| --- | --- | --- | --- |
| Runtime | Choose an AI runtime | ASTRA runs tasks through a supported agent tool on this Mac. Choose one to begin; you can switch later in Settings. Quiet follow-up: Next, you'll review local access and create your first workspace. | Review access |
| Access | Check local access | ASTRA checks Keychain and workspace storage now. Browser and capability-specific access are requested only when used. | Set up workspace |
| Workspace | Create your first workspace | Name it, add persistent guidance, and choose optional capabilities. | Create workspace |
| Ready | Your workspace is ready | Open {workspace name} and start your first task. If follow-up is needed, say so here instead. | Open {workspace name} |

Use sentence case. Keep `Back` for reverse navigation. Do not add `Continue`
where a more specific destination or effect is available.

### Progress semantics

The visible compact form should be paired with one accessibility element:

> `Setup, step 1 of 4, Choose an AI runtime, current step.`

Completed and upcoming state must not rely on color alone. If individual stages
remain visible, expose `completed`, `current`, or `upcoming` in their labels and
hide decorative connectors from assistive technology.

## 8. Retained-Welcome fallback

If product stakeholders require a separate orientation page, it should preview
the setup—not market ASTRA's internal model.

### Copy

> **Get ASTRA ready for your first task**
>
> Choose a runtime, review local access, and create your first workspace. You
> can change these choices later.

Three setup rows:

| Row | Explanation |
| --- | --- |
| AI runtime | Choose the local agent tool ASTRA will use to run tasks. |
| Local access | Review secure storage and workspace access. Feature-specific permissions are requested only when used. |
| First workspace | Create a focused home for tasks, context, and capabilities. |

Quiet requirement note:

> **Required to continue:** one supported AI runtime. You'll choose it next.

Primary action:

> `Choose runtime`

If product value must be included, use outcomes rather than internal terms:

- Keep each project's tasks, instructions, and history in its own workspace.
- Give each workspace only the tools and services it needs.
- Keep plans, documents, data, and browser work attached to the task.

Do not restore the GitHub CLI callout here.

## 9. Component and ownership proposal

The visual change should not become another one-off view rewrite.

### Derived presentation

Introduce a small immutable `SetupStepPresentation` value containing:

- semantic step ID;
- page title and subtitle;
- position and total count;
- primary action label and accessibility label;
- optional secondary action;
- icon or real brand asset choice;
- state summary; and
- progress accessibility description.

Build it from the mode and existing state. Do not persist it and do not make it
a second mutable owner.

### Flow policy

Introduce an `OnboardingNavigationPolicy` or similarly focused coordinator for:

- valid transitions;
- blockers and bypassable warnings;
- the typed primary effect for each step;
- first-run versus review behavior; and
- dirty-draft dismissal policy.

Do not use enum `rawValue` arithmetic as the behavioral contract. Step order can
be explicit without making raw integer stability a product requirement.

### Small composition components

- `SetupShell`: one alignment rail, progress, body, footer, and keyboard policy.
- `SetupStepHeader`: generalized from the existing New Workspace header.
- `SetupSummaryRow`: icon, noun-led title, concise description or status, and
  optional action.
- `SetupNote`: neutral supporting information; tint only for meaningful status.
- Embedded modes for `RuntimeSetupSection` and
  `MacOSPermissionsSectionView` that omit duplicate outer chrome.

### File ownership

Split responsibilities rather than moving the monolith:

- Wizard shell and navigation policy in onboarding-specific files.
- Each step view in a small focused file.
- Workspace draft, capability setup presentation, and `WorkspaceSetupForm` in
  dedicated workspace-setup files.
- Runtime and access state stay with their current models/services.
- Durable workspace creation remains behind the existing creation service or
  callback boundary.

## 10. Accessibility requirements

### Confirmed strengths

- Primary and secondary actions are real buttons.
- Return invokes the default action.
- Escape closes replay mode.
- Scroll containers are present for larger content.
- Step motion respects Reduce Motion.
- Progress uses number/checkmark differences in addition to color.

### Risks to address

1. Replace small `Stanford.coolGrey` copy with the theme's AA-targeted
   `Stanford.textSecondary` or `Stanford.textTertiary` tokens. The theme defines
   them specifically because system secondary colors can be too pale at 10–12
   points (`StanfordTheme.swift:46-60`).
2. Combine each decorative icon-and-text row into one meaningful accessibility
   element, or hide purely decorative icons.
3. Give progress an explicit current/completed/upcoming semantic description.
4. Test the fixed shell at UI scale 1.5. Fonts scale, while several frames,
   gutters, and the minimum window size are fixed literals.
5. Verify focus order follows header → body controls → blocker/warning → footer.
6. Keep a visible focus ring on all interactive custom rows.
7. Do not use pale fills or accent color as the only state signal.
8. Confirm dirty replay dismissal communicates what is kept and what is lost.

### Required manual verification

- Light and dark appearance.
- UI scale 0.7, 1.0, and 1.5.
- VoiceOver announcements for progress, status, errors, and primary actions.
- Keyboard-only completion, including Return, Escape, backward navigation, and
  focus restoration after alerts.
- Long workspace name, long provider status, and warning/error copy.
- First-run and review modes with both healthy and needs-attention states.

## 11. Implementation sequence

Keep behavior changes reviewable and avoid mixing a large visual rewrite with
unrelated setup mechanics.

### Phase 1 — Repair the product model and presentation source

- Add explicit `firstRun` and `reviewSetup` modes.
- Define the first-run four-step order and the review summary content.
- Create `SetupStepPresentation` and typed primary actions.
- Remove dead duplicate titles and the eight-character product-language test.
- Add presentation and navigation-policy tests before changing the view.

**Exit gate:** every visible title, subtitle, progress description, and primary
action comes from one tested presentation source.

### Phase 2 — Build the shared shell and first-run composition

- Replace the labeled tracker with compact progress.
- Establish one horizontal rail.
- Use the shared step header and neutral note/summary rows.
- Remove the standalone Welcome step.
- Add embedded modes to eliminate duplicate Runtime/Access chrome.
- Apply AA-safe secondary text tokens.

**Exit gate:** the four first-run steps render without duplicate headers,
misleading accents, or generic actions at all supported UI scales.

### Phase 3 — Build review setup and honest completion

- Replace “Show Onboarding Again” behavior with the status-first review sheet.
- Add re-check and deep-link actions.
- Add dirty-draft protection.
- Derive Ready versus follow-up-needed outcomes from actual state.

**Exit gate:** an existing user is never told “Welcome,” never forced to create
a first workspace, and never shown green readiness when a surfaced issue remains.

### Phase 4 — Visual and interaction verification

- Run focused unit and regression tests.
- Render every first-run and review state in light/dark at 0.7/1.0/1.5 UI scale.
- Complete keyboard and VoiceOver passes.
- Rebuild and inspect ASTRA Dev against the surrounding workspace and Settings
  surfaces.

## 12. Tests to add with implementation

### Unit and presentation tests

- First-run and review modes produce different titles, steps, and actions.
- First-run order is exactly Runtime, Access, Workspace, Ready.
- Progress says `step n of 4` and uses accurate page titles.
- Workspace primary action is `Create workspace` and maps to the create effect.
- Review mode never includes Welcome, First Workspace, or Ready completion copy.
- Final presentation distinguishes ready from follow-up-needed.
- GitHub CLI guidance appears only when GitHub is relevant.

### Navigation and regression tests

- Runtime blockers prevent forward navigation.
- Access warnings remain visible when non-blocking.
- Workspace warnings require the existing explicit confirmation.
- Dirty replay dismissal prompts before losing the workspace draft.
- Clean replay dismissal closes immediately.
- Back does not duplicate or undo committed external setup work.
- Review mode does not create a workspace as a completion requirement.

### Accessibility and layout tests

- Progress exposes one correct semantic label for every step.
- Visible secondary copy uses AA-targeted semantic tokens.
- Embedded Runtime and Access omit duplicate headers.
- Layout does not overlap or truncate at UI scales 0.7, 1.0, and 1.5.
- Long localized-style strings do not force inaccurate labels or collapse the
  action area.

### Manual ASTRA Dev scenarios

- First launch with no runtime installed.
- First launch with one ready runtime.
- Access needing Keychain action.
- Workspace creation with no capabilities.
- Workspace creation with a capability warning.
- Credential-save failure after workspace creation.
- Review setup in an existing multi-workspace app.
- Replay close with and without a dirty draft.

## 13. Acceptance criteria

The redesign is ready when all of the following are true:

- Existing users see `Review ASTRA setup`, not first-run onboarding.
- First-run begins with a meaningful Runtime task; no empty marketing-only step
  is required.
- No progress label sacrifices semantic accuracy to a character limit.
- The progress treatment is visibly passive unless it is implemented as real
  navigation.
- Every primary action names its destination or effect.
- The durable workspace-creation action says `Create workspace`.
- The real ASTRA mark is used for brand identity; the waving hand is removed.
- Teal is reserved for interaction/focus, with semantic colors used only for
  real status.
- Informational copy no longer receives warning-level visual weight.
- Header, body, repeated rows, and footer follow one alignment system.
- Access does not render a header inside a header.
- Final readiness reflects actual runtime, access, workspace, capability, and
  credential outcomes.
- Dirty replay dismissal protects unsaved workspace input.
- Light/dark and 0.7/1.0/1.5 UI-scale checks pass without collision or
  truncation.
- VoiceOver identifies current progress, state, blockers, and actions.
- Focused tests cover presentation, navigation effects, replay behavior, and
  the workspace creation regression.

## Final recommendation

Do not spend the next pass tuning the hand tile, moving the blue box by eight
points, or vertically centering the existing content. Those changes would make
the screenshot neater while preserving the underlying mismatch.

First separate **new-user setup** from **existing-user setup review**. Then
remove the no-decision Welcome step, make the remaining actions truthful, and
build one small setup composition layer from ASTRA's existing typography,
buttons, semantic colors, and state owners. That is the smallest solution that
addresses why the wizard feels disconnected instead of only changing how the
disconnection is decorated.
