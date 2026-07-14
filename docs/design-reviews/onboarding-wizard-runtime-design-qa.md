# Onboarding Wizard Runtime Design QA

This report archives the completed runtime-step visual QA that previously lived
at the repository root before the workspace-creation follow-up replaced it.

## Verification setup

- Visual baseline: the selected runtime-step direction supplied with the onboarding review.
- Verification build: the development-channel bundle produced by `./script/build_and_run.sh --verify` at `dist/ASTRA Dev.app`.
- Viewport: 920 × 640 macOS sheet
- State: ASTRA Dev, light appearance, first-run step 1 of 4, Cursor CLI selected from the live runtime registry, primary action hovered
- Durable review rationale: [`2026-07-13-onboarding-wizard-ux-ui-critical-pass.md`](2026-07-13-onboarding-wizard-ux-ui-critical-pass.md)

The visual captures were inspected during the manual QA pass. This archive
records the reproducible build command, viewport, state, findings, and
acceptance result without depending on one contributor's local filesystem.

## Findings

No actionable P0, P1, or P2 differences remain.

- Typography, spacing, color, assets, copy, and interaction hierarchy use ASTRA's production design tokens and match the selected runtime direction.
- The footer explains the next operation at rest and increases emphasis on pointer hover or keyboard focus.
- First run has no Close action; explicit replay from Settings or the File menu does.

## Acceptance

- [x] Replace the disconnected welcome page with an actionable runtime decision.
- [x] Reduce setup to four explicit steps with compact progress.
- [x] Use a single grouped runtime surface with progressive disclosure.
- [x] Name and explain the next operation.
- [x] Keep automatic first run non-dismissible and explicit replay dismissible.
- [x] Verify the production ASTRA Dev build.

final result: passed
