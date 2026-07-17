# Guided First-Install Design QA

- Source visual truth: `/Users/alvaro1/.codex/generated_images/019f6d39-c6af-7661-9cb8-4fb87e628f8e/exec-44d9acec-09c4-481b-935e-c737b8efd17f.png`
- Implementation screenshot: `/Users/alvaro1/.codex/visualizations/2026/07/16/019f6d39-c6af-7661-9cb8-4fb87e628f8e/04-guided-installer-final.png`
- Viewport: native macOS window, 720 x 520 point content area plus system title bar
- State: existing ASTRA 0.1.28 detected; local 0.1.30 build ready to replace it

## Full-View Comparison Evidence

The final native window preserves the selected design's centered ASTRA icon,
single install heading, two-line explanation, explicit existing-version row,
one cardinal-red primary action, quiet cancel action, and trust footer. Native
AppKit title-bar rendering and the live build version are expected platform and
test-data differences.

## Focused Comparison Evidence

The status and action region was inspected separately because it owns the
critical clarity contract. The final capture shows the full replacement copy
without truncation, the old and new versions before action, and the complete
primary label. No separate asset crop was needed: the only non-system asset is
the supplied production ASTRA icon, which is clearly readable at full-view
scale and comes directly from `Astra/Resources/AppIcon.icns`.

## Required Fidelity Surfaces

- Fonts and typography: ASTRA's registered Source Sans 3 UI face is used with
  native fallbacks, semibold/bold hierarchy, neutral tracking, and no clipped
  or truncated text.
- Spacing and layout rhythm: the final pass matches the source's narrow status
  group and CTA, centered vertical flow, generous whitespace, and fully visible
  footer.
- Colors and visual tokens: the production cardinal-red icon and CTA, warm
  neutral surface, charcoal reading text, and secondary gray copy match the
  selected direction and ASTRA tokens.
- Image quality and asset fidelity: the real 1024 px ASTRA icon is rendered by
  `NSImage`; SF Symbols are used only for standard native status/lock icons.
- Copy and content: destination, replacement, both versions, automatic open,
  cancel, progress, failure, and completion states are explicit. The source's
  unconditional “Signed and notarized” footer was intentionally replaced with
  “Installs in Applications · Opens automatically” because ASTRA also supports
  internal ad-hoc releases where a notarization claim would be false.

## Comparison History

1. Initial implementation capture:
   `/Users/alvaro1/.codex/visualizations/2026/07/16/019f6d39-c6af-7661-9cb8-4fb87e628f8e/02-guided-installer-implementation.png`
   - P2: status/button groups were materially wider than the selected design,
     and the footer sat too close to the bottom edge.
   - Fix: narrowed the message, status row, and primary button; tightened
     vertical gaps and status-row padding.
2. Refined capture:
   `/Users/alvaro1/.codex/visualizations/2026/07/16/019f6d39-c6af-7661-9cb8-4fb87e628f8e/03-guided-installer-refined.png`
   - P1: the version replacement sentence truncated at the most important
     information.
   - Fix: gave the status copy layout priority and a single-line adaptive text
     treatment at the existing ASTRA caption size.
3. Final capture:
   `/Users/alvaro1/.codex/visualizations/2026/07/16/019f6d39-c6af-7661-9cb8-4fb87e628f8e/04-guided-installer-final.png`
   - The earlier P1/P2 findings are resolved. No actionable P0-P2 visual issue
     remains.

## Interaction Verification

- The native window and its primary/cancel controls were exposed through the
  macOS accessibility tree.
- Cancel was exercised and terminated the installer-only process without
  changing the installed application.
- The copy, first-install, existing-copy replacement, failed-source
  preservation, verification, and relaunch command paths were exercised in a
  disposable filesystem by the focused regression suite.
- The live primary button was intentionally not clicked against the user's real
  `/Applications/ASTRA.app`; the same operation is covered by the disposable
  integration tests.

## Findings

No actionable P0, P1, or P2 mismatch remains.

## Follow-up Polish

- P3: the inactive traffic-light appearance is controlled by macOS focus state
  and can vary by OS version; no product fix is warranted.

final result: passed
