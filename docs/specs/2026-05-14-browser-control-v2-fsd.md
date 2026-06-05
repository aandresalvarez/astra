# Browser Control V2 Functional Specification

**Status:** Proposed functional specification  
**Date:** 2026-05-14  
**Scope:** ASTRA Shelf browser bridge, `astra-browser` CLI, page analysis, accessibility snapshots, browser adapters, action preflight, outcome verification, vision fallback, and supervision traces

## Summary

Browser Control V2 upgrades ASTRA from a DOM-first browser bridge into a structured, accessibility-first browser control system with deterministic action references, live safety checks, adapter-specific semantics, optional vision fallback, and benchmarkable outcomes.

The product rule remains:

> ASTRA determines what can be done. The agent chooses what should be done. ASTRA verifies whether it is safe and whether it worked.

This is not a screenshot-first control system. Screenshots are a fallback and supervision artifact, not the default action contract.

## Current System

ASTRA already has the foundation:

- `ShelfBrowserSession` owns the embedded and controlled browser bridge.
- `ControlledBrowserController` owns controlled Chromium launch and Chrome DevTools Protocol input.
- `BrowserAutomationScripts` extracts live rendered page text, controls, labels, selectors, roles, bounds, and focused element data.
- `BrowserAnalysis` builds cached `analysisID` and `controlID` maps with risk, valid actions, confidence, and preflight checks.
- `Tools/AstraBrowserTool/main.swift` exposes the provider-neutral `astra-browser` command.
- `BrowserSiteAdapters` supports capability-gated browser adapters, currently including Google Drive semantics.
- `ShelfBrowserBridgeRegistry` injects the browser endpoint and safe usage instructions into task prompts.

The main gap is that ASTRA still treats DOM selectors as the strongest control reference. V2 should treat accessibility references and semantic control context as the primary contract, with selectors as one execution strategy.

## Goals

1. Make browser action selection more accurate on real authenticated web apps.
2. Reduce wrong clicks, repeated loops, stale actions, and ambiguous control selection.
3. Make browser actions easier for users to supervise and audit.
4. Keep dangerous browser actions gated by explicit user confirmation.
5. Prefer APIs and capability adapters over fragile browser clicks when reliable APIs exist.
6. Add optional vision fallback for pages where structured page data is insufficient.
7. Build a benchmark harness so regressions are visible.

## Non-Goals

- Do not replace the current bridge with a screenshot-only agent.
- Do not allow agents to type passwords, MFA codes, OAuth secrets, or private keys.
- Do not bypass user confirmation for send, submit, delete, approval, payment, purchase, or externally visible changes.
- Do not expose authenticated screenshots to remote vision models without explicit user or workspace policy.
- Do not require production users to adopt V2 until it has passed shadow and development-channel validation.

## Recommended Decisions

### Browser Adapters

ASTRA should continue using capability-gated adapters.

Pattern:

```text
Capability enabled
    -> browser adapter ID active
    -> analyzer adds site-specific semantics
    -> bridge exposes helper actions
    -> preflight and outcome verifier enforce the adapter contract
```

Google Drive remains the reference adapter. The next adapter should be GitHub because it is lower-risk, API-rich, easy to test, and useful for developer workflows. Jira should follow. Mail and REDCap should come later because they carry higher privacy and external-action risk.

### Vision Fallback

ASTRA should use a structured-first, vision-fallback policy.

Default behavior:

- Use accessibility and DOM analysis first.
- Use vision only when confidence is low or the page surface is not structurally inspectable.
- Prefer local vision when available.
- Allow provider vision only behind an explicit policy such as "Allow visual page snapshots."
- Send cropped or annotated screenshots when possible, not full authenticated pages.

Vision fallback should never override safety preflight. It may propose a target, but ASTRA must still resolve, preflight, and execute through the bridge.

### Feature Flag

V2 should ship behind a feature flag.

Recommended rollout:

1. Shadow mode in development: generate V2 analysis but continue using V1 actions.
2. Compare V1 and V2 selected controls in logs.
3. Enable V2 actions in the development channel.
4. Add per-workspace opt-in for production.
5. Promote V2 to default only after benchmark success and safety metrics improve.

## Functional Requirements

### FR1: Accessibility Snapshot V2

ASTRA must add a new page snapshot layer that can return:

- URL, title, viewport, focused element, frame context, and modal/dialog state.
- Accessibility tree nodes with role, name, value, description, disabled state, selected state, expanded state, checked state, editable state, and bounding boxes when available.
- DOM selectors and attributes as fallback evidence.
- Frame and shadow-root context.
- Optional text slices with untrusted-content labels.

Controlled Chromium should use Chrome DevTools Protocol accessibility and DOM APIs where possible. Embedded WebKit should continue using injected JavaScript and ARIA/DOM heuristics.

### FR2: Semantic Control References

V2 analysis must generate `controlRef` values that are stronger than selectors.

A `controlRef` should include:

- Stable ID.
- Backend source: `accessibility`, `dom`, `adapter`, or `vision`.
- Role and accessible name.
- State and valid actions.
- Parent/context labels.
- Frame path.
- Bounds bucket.
- Selector fallback.
- Risk class.
- Confidence score.
- Evidence summary.

Selectors remain useful, but they should not be the only identity contract.

### FR3: V2 Analyze Output

`astra-browser analyze` must continue to work. V2 may add fields without breaking V1 clients.

New output should include:

- `analysisVersion`.
- `controlRefs`.
- `sourceBreakdown`.
- `lowConfidenceReason` when relevant.
- `visionFallbackAvailable`.
- `adapterRecommendations`.
- `untrustedPageText` or equivalent labeling for text read from the web page.

Default output should stay compact. Full output remains available through `--full --debug`.

### FR4: Live Preflight V2

Every mutating V2 action must run live preflight immediately before execution.

Preflight must verify:

- Analysis exists and is fresh.
- Live page fingerprint is compatible.
- Control still resolves.
- Action is supported by the control.
- Target is visible, enabled, in viewport, and unobscured.
- Frame context is still valid.
- Risk class does not require confirmation, or confirmation has been granted.
- Credential and MFA entry remains blocked.
- Adapter-specific assumptions still hold.

If any check fails, ASTRA returns a structured stop reason and does not silently fall back to a click.

### FR5: Outcome Verification V2

ASTRA must distinguish command execution from task success.

Every mutating action should report:

- `executed`.
- `expectedOutcome`.
- `observedOutcome`.
- `goalSatisfied`.
- `outcomeVerified`.
- `outcomeReason`.
- `suggestedNextActions`.

Outcome checks should support:

- URL change.
- Title change.
- Text appears or disappears.
- Field value changed.
- Focus/selection changed.
- Save state reached.
- File/editor opened.
- Record ID or confirmation message appeared.
- Adapter-specific success signals.

`ok: true` must continue to mean the command ran, not that the user's goal was completed.

### FR6: Browser Site Adapters

Adapters must stay capability-gated.

Adapter responsibilities:

- Detect active site/page type.
- Add semantic actions to analysis.
- Prefer API or site-specific helpers over raw clicks.
- Define expected outcomes.
- Provide preflight requirements.
- Provide safe next-action suggestions.

Initial adapter priority:

1. Google Drive: keep and harden existing behavior.
2. GitHub: add API/browser hybrid semantics for repository, issue, PR, file, and action pages.
3. Jira: add issue search/open/update semantics after GitHub.
4. Mail and REDCap: defer until stronger privacy, approval, and audit controls are in place.

### FR7: Vision Fallback

Vision fallback must be explicit and bounded.

Trigger conditions:

- Accessibility and DOM analysis return low confidence.
- The target appears to be canvas-rendered.
- Controls are visually present but structurally unavailable.
- The page is image-heavy or custom-rendered.
- Preflight reports repeated obstruction or unresolved target.

Vision fallback must return suggested targets as evidence, not execute directly.

Requirements:

- User/workspace policy controls provider vision.
- Full-page screenshots are avoided when cropped target regions are enough.
- Screenshots are labeled as sensitive browser data.
- Vision suggestions still pass through `controlRef` resolution or coordinate preflight.
- Dangerous actions still require explicit confirmation.

### FR8: Prompt Injection Hardening

ASTRA must treat browser page content as untrusted.

Requirements:

- Mark page text as untrusted in snapshots and prompt context.
- Keep system, user, ASTRA policy, and page content separated in task prompts.
- Add warning metadata when page text contains likely agent instructions, credential requests, or tool-use manipulation.
- Build approval prompts from ASTRA action metadata, not from page text alone.
- Add tests where malicious page content attempts to override browser safety rules.

### FR9: Supervision Traces

Browser actions should produce compact trace artifacts for task supervision.

Trace fields:

- Action name.
- Analysis version.
- `analysisID` and `controlRef`.
- Selected role/name/selector/bounds.
- Risk class.
- Preflight result.
- Before/after URL and title.
- Before/after fingerprint.
- Outcome result.
- Optional screenshot thumbnail or crop when enabled.
- Console or network summary when available.

Default UI should show concise summaries. Debug views may show full trace JSON.

### FR10: Benchmark Harness

ASTRA must add a repeatable browser control benchmark before broad rollout.

Metrics:

- Task success rate.
- Wrong-click rate.
- Stale-analysis rate.
- Ambiguous-control rate.
- Loop detection count.
- Step count.
- Time to completion.
- Safety block correctness.
- Confirmation false positives and false negatives.

The first benchmark suite should include local fixtures plus a small set of live or semi-live workflows that ASTRA users actually need.

## CLI Changes

The existing `astra-browser` commands should remain stable.

Proposed additions:

```bash
astra-browser analyze --v2
astra-browser analyze --source accessibility
astra-browser analyze --vision-fallback
astra-browser trace --last
astra-browser benchmark --suite browser-v2-smoke
```

Existing control-ID commands should accept V2 references:

```bash
astra-browser click --analysis ana_... --control ctl_...
astra-browser open --analysis ana_... --control ctl_...
astra-browser fill --analysis ana_... --control ctl_... --text "value"
```

If V2 is enabled, these commands may resolve through `controlRef` internally while preserving the CLI contract.

## UI Changes

### Settings

Add browser-control settings in the relevant workspace or capability surface:

- Browser Analysis V2: off, shadow, on.
- Vision fallback: off, local only, provider allowed.
- Visual page snapshots: explicit policy toggle when provider vision is allowed.
- Browser trace capture: compact, full debug.

### Task Log

Browser action events should show:

- What ASTRA targeted.
- Why it believed the target was valid.
- Whether preflight passed.
- Whether the outcome satisfied the goal.
- What ASTRA recommends next if the action did not satisfy the goal.

### Capability Catalog

Browser-capable packages should show:

- Adapter ID.
- Supported hosts.
- Helper actions.
- Whether API-first behavior is available.
- Privacy/safety notes.

## Technical Design

### New Or Updated Types

Likely new types near browser services:

- `BrowserAnalysisVersion`.
- `BrowserAccessibilitySnapshot`.
- `BrowserAccessibilityNode`.
- `BrowserControlRef`.
- `BrowserControlSource`.
- `BrowserFrameRef`.
- `BrowserVisionObservation`.
- `BrowserTraceRecord`.
- `BrowserBenchmarkSuite`.
- `BrowserBenchmarkResult`.

Existing types to extend:

- `BrowserAnalysis`.
- `BrowserControl`.
- `BrowserPageFingerprint`.
- `BrowserActionOutcomeVerifier`.
- `BrowserSiteAdapterDescriptor`.
- `BrowserPreflightResult`.

### Module Changes

Expected files:

- `Astra/Services/Browser/ShelfBrowserSession.swift`: route V2 analysis, preflight, trace capture, and rollout mode.
- `Astra/Services/Browser/ControlledBrowserController.swift`: add CDP accessibility snapshot support.
- `Astra/Services/Browser/BrowserAutomationScripts.swift`: improve frame, shadow DOM, and actionability extraction.
- `Astra/Services/Browser/BrowserAnalysis.swift`: add V2 control references, source breakdown, and stronger matching.
- `Astra/Services/Browser/BrowserSiteAdapters.swift`: formalize adapter contract and add GitHub adapter.
- `Astra/Services/Browser/ShelfBrowserBridgeRegistry.swift`: update task prompt instructions for V2 and untrusted page content.
- `Tools/AstraBrowserTool/main.swift`: add CLI flags while preserving existing commands.
- `Tests/BrowserAnalysisTests.swift`: add V2 unit coverage.
- `Tests/AgentRuntimeWorkerTests.swift`: verify prompt exposure and safety instructions.

## Rollout Plan

### Phase 0: Baseline

Create a benchmark list of 10 to 15 browser tasks. Measure current V1 success and failure modes.

### Phase 1: V2 Shadow Mode

Add accessibility snapshots and V2 analysis behind a flag. Log V2 recommendations without executing them.

### Phase 2: Development Actions

Enable V2 execution in the development app only. Keep V1 fallback available for debugging, but do not silently fall back after a V2 safety failure.

### Phase 3: Adapter Expansion

Harden Google Drive and add the GitHub adapter. Validate adapter behavior with unit tests and browser smoke tasks.

### Phase 4: Vision Fallback

Add local-first vision fallback with provider vision behind explicit policy. Start with trace-only or suggestion-only behavior.

### Phase 5: Production Opt-In

Expose V2 per workspace in production. Keep compact traces on by default.

### Phase 6: Default

Make V2 the default only after benchmark and safety metrics beat V1.

## Safety And Privacy

Browser control can affect authenticated user accounts. V2 must keep safety centralized.

Required safeguards:

- Credential and MFA typing is blocked.
- Dangerous actions require chat confirmation.
- Page content is untrusted.
- Provider vision requires explicit policy.
- Screenshots are minimized, cropped when possible, and marked sensitive.
- API-backed adapters must respect capability permissions.
- Failed preflight must stop execution.
- Cached analysis must never authorize an action by itself.

## Testing Strategy

Unit tests:

- Accessibility node parsing.
- `controlRef` stability.
- Risk classification.
- Preflight stale/control-changed cases.
- Credential and MFA blocks.
- Adapter recommendations and outcomes.
- Prompt-injection markers.

Integration tests:

- `astra-browser analyze --v2`.
- Control ref click/fill/open.
- Iframe target resolution.
- Shadow DOM target resolution.
- Google Drive open helper.
- GitHub adapter smoke behavior.
- Vision fallback suggestion-only flow.

Regression benchmarks:

- Current V1 suite.
- V2 shadow comparison.
- Prompt-injection pages.
- Ambiguous duplicate controls.
- Canvas/custom UI page.
- Dangerous action confirmation.

Recommended commands:

```bash
swift test --filter BrowserAnalysisTests
swift test --filter BrowserToolShimTests
swift test --filter AgentRuntimeWorkerTests
swift test
```

## Acceptance Criteria

V2 is ready for production opt-in when:

- V2 analysis runs in shadow mode without crashing on the benchmark suite.
- V2 resolves equal or better targets than V1 on at least 80 percent of benchmark actions.
- Wrong-click rate is lower than V1.
- Stale-analysis and control-changed failures return actionable messages.
- Dangerous action gates remain enforced.
- Provider vision cannot run unless policy allows it.
- Browser traces are visible enough for a user to understand what ASTRA did.
- Existing `astra-browser` commands remain backward compatible.

V2 is ready to become default when:

- Benchmark task success improves materially over V1.
- Loop count decreases.
- Ambiguous-control handling improves.
- No safety regression is found in credential, MFA, destructive, payment, approval, or send flows.

## Risks

- CDP accessibility data may not map cleanly to executable DOM targets.
- WebKit may not expose enough accessibility detail, requiring JS fallback for embedded mode.
- Vision fallback may create privacy concerns if not tightly gated.
- Adapter-specific behavior can become stale when sites change.
- Stronger preflight may block legitimate actions until matching improves.
- Benchmark tasks may be too small unless they include real user workflows.

## Open Questions

- Should V2 settings live in workspace settings, browser shelf settings, or capability settings?
- What is the minimum trace artifact users need in the default task log?
- Should ASTRA store browser benchmark results in app support, task artifacts, or test fixtures only?
