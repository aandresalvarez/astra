# Workspace Creation UX/UI Audit and Unified Proposal

## Scope

This review covers the two ways a person creates a workspace:

1. Step 3 of first-run setup.
2. The regular New Workspace sheet opened from the sidebar or File menu.

The goal is a single, lean mental model and interaction flow, with extra explanation only where first-run onboarding genuinely needs it.

## User Goal

A person should be able to answer three questions quickly:

1. What is a workspace in ASTRA?
2. What belongs together in one workspace?
3. What must I decide now, and what can wait until later?

## Root Cause

The product did not have two independent forms. Both entry points already rendered `WorkspaceSetupForm`, but its onboarding mode changed the hierarchy:

- capability configuration expanded automatically;
- the optional guidance editor became taller;
- capability setup received a tinted, dominant container;
- labels and descriptions diverged between onboarding and standard creation;
- the onboarding form stretched across a much wider content region;
- the empty name appeared as a red error before the user interacted.

The resulting problem was presentation drift inside a shared component. Fixing only margins or font sizes would leave the two mental models free to diverge again.

## Audit Findings

### 1. Onboarding did not explain the workspace model

The heading listed setup operations—name, guidance, connect systems—but did not explain the organizing idea. A new user could complete the form without learning whether a workspace represents a project, a client, a team, a repository, or a recurring process.

### 2. Secondary setup dominated the primary decision

The capability editor consumed most of the onboarding viewport and exposed four integrations before the user had named the workspace. This inverted the intended hierarchy: identity and purpose are required; capabilities are optional and reversible.

### 3. The two entry points taught different language

`Quick-start capabilities` and `Workspace capabilities` referred to the same durable setting. Guidance descriptions and examples also changed by entry point. That made onboarding feel like a separate product path instead of the first use of the normal creation flow.

### 4. The wizard felt squeezed despite being wide

The issue was vertical density, not a lack of horizontal pixels. Wide fields, a taller editor, and an expanded integration list produced long lines and a large scrollable stack. More window size would have amplified the hierarchy problem.

### 5. Initial validation felt punitive

The red warning `Name your first workspace before continuing` appeared on untouched content. Empty required state should explain what is needed; red should be reserved for failed validation or an actual problem.

## First-Principles Design

### One semantic owner

`WorkspaceCreationPresentation` now owns the shared vocabulary and defaults for both entry points. The SwiftUI form remains the single interaction implementation.

### One scan path

Both flows now present:

1. Purpose.
2. Workspace name.
3. Shared guidance.
4. Optional capabilities.
5. Folder location.
6. Create action.

### Progressive disclosure

Capabilities start collapsed everywhere. The summary explains the outcome and reversibility; expanding it reveals existing setup, validation, and copy-from-workspace behavior without removing capability depth.

### Onboarding adds concept, not a second form

The wizard adds one compact primer:

> Keep one body of work together

It explains that tasks belong together when they share a goal and way of working, then gives concrete examples. Everything below that primer is the same creation experience used later in the app.

### Neutral requirements, semantic errors

An empty name now shows `Enter a workspace name to continue.` in the neutral footer style. Capability or validation failures still use warning and error semantics.

## Implemented Details

- Shared header sentence: `A focused place for related tasks, shared guidance, and system access.`
- Shared guidance explanation and example.
- Shared `Capabilities` label and summary.
- Collapsed capabilities in onboarding and standard creation.
- Consistent 86-point guidance editor minimum height.
- Neutral capability card in both flows.
- 720-point maximum reading width for the onboarding workspace step.
- Explicit accessibility labels and hints for name and guidance fields.
- Distinct validation trace sources remain intact for diagnostics.

## Accessibility Review

The running app exposes a coherent accessibility order from heading through primer, name, guidance, capabilities, location, and footer. The fields have explicit labels; capability toggles retain service-specific labels; the disabled primary action exposes what creation will do.

The screenshot audit alone could not prove color contrast ratios, VoiceOver phrasing quality, or high-zoom reflow. Live accessibility-tree inspection and keyboard focus behavior were verified, but a dedicated VoiceOver and contrast pass would still be the right gate if formal WCAG evidence is required.

## Acceptance Criteria

- [x] A first-time user can explain a workspace after reading one compact block.
- [x] The wizard and standard sheet use the same vocabulary and field order.
- [x] Required identity remains visually ahead of optional capability setup.
- [x] Optional setup is available without dominating the default state.
- [x] The wizard fits the production setup viewport without clipped content.
- [x] The standard sheet remains lean.
- [x] Initial empty state is instructive rather than punitive.
- [x] Presentation rules are protected by focused regression tests.
- [x] Both surfaces and the capability disclosure were verified in ASTRA Dev.
