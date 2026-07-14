# Workspace Creation Design QA

## Verification setup

- Visual baseline: the onboarding and standard-sheet screenshots supplied with the workspace-creation review.
- Verification build: the development-channel bundle produced by `./script/build_and_run.sh --verify` at `dist/ASTRA Dev.app`.
- Onboarding viewport: 920 × 640 macOS setup sheet, step 3 of 4
- Standard state: New Workspace sheet with name focused and capabilities collapsed
- Durable review rationale: [`docs/design-reviews/2026-07-13-workspace-creation-unification.md`](docs/design-reviews/2026-07-13-workspace-creation-unification.md)

The visual captures were inspected during the manual QA pass. This repository
record keeps the reproducible build command, viewport, state, findings, and
acceptance result instead of linking to machine-local screenshot paths.

## Findings

No actionable P0, P1, or P2 issues remain.

- Hierarchy: both entry points now follow the same scan path—purpose, name, shared guidance, optional capabilities, folder location, action.
- Density: optional capability configuration is collapsed by default in both flows. The four integration rows remain available through the disclosure and were verified in the running app.
- Understanding: onboarding adds one compact primer explaining when work belongs together; the standard sheet communicates the same model in one header sentence.
- Consistency: wording, field sizes, disclosure styling, capability summary, and folder location come from the same shared presentation contract.
- Validation: the empty required name is expressed as a neutral instruction in onboarding, not a red error before interaction.
- Accessibility: the live accessibility tree exposes labels for Workspace name, Workspace guidance, Capabilities, each capability toggle, and the disabled primary action with its consequence. Keyboard focus begins in the name field.
- Reflow: the onboarding form is constrained to a 720-point reading width inside the 920-point sheet, with no clipped fields or hidden primary action at the captured state.

## Interaction Checks

- [x] Onboarding advances from runtime to access to workspace setup.
- [x] Onboarding initial capability disclosure is collapsed.
- [x] Standard New Workspace initial capability disclosure is collapsed.
- [x] Capability disclosure expands to Jira, GitHub, Google Cloud, and REDCap rows inside a scrollable form.
- [x] The neutral name requirement and disabled Create workspace action are visible together.
- [x] Closing replay restores `astra.hasCompletedOnboarding = 1` and `astra.onboardingReplayRequested.v1 = 0`.
- [x] ASTRA Dev is running from the verified development-channel bundle.

## Follow-up Polish

No P3 follow-up is required for acceptance.

final result: passed
