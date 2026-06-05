# Browser Control Analysis Plan

**Status:** Proposed implementation plan  
**Date:** 2026-05-13  
**Scope:** ASTRA Shelf browser bridge, `astra-browser` CLI, deterministic page analysis, action preflight, and transparent browser control

## Goal

ASTRA should give agents better browser control without making every click depend on model judgment. The browser bridge should scan the live rendered page deterministically, produce a reusable action map, let the agent choose from known valid actions, and still enforce live safety checks immediately before execution.

The core rule:

> The deterministic scanner owns what is possible. The agent chooses what is intended. The executor enforces what is safe on the current page.

## Current Architecture

ASTRA already has the right foundation:

- `ShelfBrowserSession` owns the Shelf browser session, bridge server, request routing, and browser action helpers.
- `BrowserAutomationScripts` extracts visible text, controls, labels, selectors, roles, bounds, focused element, and actionability information from the rendered page.
- `ControlledBrowserController` supports the controlled Chromium profile through Chrome DevTools Protocol.
- `Tools/AstraBrowserTool/main.swift` exposes the provider-neutral `astra-browser` CLI to agents.
- `ShelfBrowserBridgeRegistry` injects browser context and tool guidance into task prompts.

The missing layer is a first-class analysis contract: a compact, cached, transparent map of controls and valid actions that agents can reference by stable IDs.

## Principles

1. **Deterministic first**
   - Use DOM, accessibility, page state, and current bridge evidence before asking an agent to infer page structure.
   - Agentic fallback should only help with ambiguous intent or custom surfaces that deterministic analysis cannot classify.

2. **Rendered page over source code**
   - The analyzer should inspect the live page the user sees, not minified app bundles or raw HTML alone.
   - Accessibility metadata and rendered DOM state are more reliable for action selection.

3. **Cached analysis is a hint, not authority**
   - Cached analysis reduces repeated scanning and gives agents stable control IDs.
   - Every mutating action still performs live preflight before execution.

4. **Transparent by default**
   - The user and task log should be able to see what ASTRA thought it clicked or filled.
   - Results should explain matched label, role, selector source, risk, and preflight outcome in concise language.

5. **Safety remains centralized**
   - Dangerous actions must require explicit user confirmation regardless of cached analysis.
   - Submit, send, delete, purchase, payment, approval, authorization, and sensitive credential flows stay gated.

6. **Existing helpers remain valuable**
   - Google Docs, Sheets, Slides, and Drive helpers should remain available.
   - The analyzer should recommend those helpers when page detection is confident.

## Target Flow

```text
agent asks to use browser
        |
        v
astra-browser analyze
        |
        v
deterministic action map with analysisID + controlIDs
        |
        v
agent chooses action by controlID
        |
        v
live preflight checks current page state
        |
        v
execute or return explicit blocked/stale/ambiguous reason
        |
        v
return concise result + evidence + optional post-action summary
```

## Product Decisions

### Analyze Output

Default `analyze` should return a compact ranked set of relevant actionable controls, not every discovered node.

Default behavior:

- Return page summary, page type, focused element, control counts, and the top ranked controls.
- Prefer visible, enabled, named, high-confidence controls.
- Include enough evidence for the agent to choose safely.
- Include `hiddenControlCount` or `omittedControlCount` so the agent knows the page is larger than the compact response.

Full behavior:

- `astra-browser analyze --full`
- Return all visible/scannable controls within bounded limits.
- Intended for debugging, ambiguous pages, or user-visible investigation.

Query behavior:

- `astra-browser analyze --query "save"`
- Return controls, text matches, and recommended actions relevant to the query.

### Cache Policy

Use page fingerprint compatibility as the primary validity rule, with a freshness cap.

Recommended policy:

- Cache analysis in memory per `ShelfBrowserSession`.
- Use a normal freshness cap around 30 seconds.
- Invalidate immediately on navigation, engine switch, bridge disable, major page fingerprint mismatch, modal/dialog changes, or failed preflight.
- Keep a bounded cache, such as the latest 5 to 10 analyses.
- Return explicit `stale_analysis` instead of silently falling back when the page changed.

The cache should never authorize an action by itself. It only maps `analysisID + controlID` back to the evidence ASTRA saw during analysis.

### Batch Support

`controlID` support should be first-class in `batch`, not deferred.

Batch rules:

- Each step runs live preflight immediately before execution.
- Batch stops on stale, dangerous, ambiguous, or failed preflight by default.
- Batch returns per-step results and the stop reason.
- A later advanced mode can allow `continueOnFailure`, but the safe default is stop-on-first-block.

## Proposed Data Model

Add Swift domain types near the browser session layer:

- `BrowserAnalysis`
- `BrowserAnalysisCache`
- `BrowserPageFingerprint`
- `BrowserControl`
- `BrowserControlID`
- `BrowserControlEvidence`
- `BrowserAction`
- `BrowserActionKind`
- `BrowserRisk`
- `BrowserPreflightRequest`
- `BrowserPreflightResult`
- `BrowserAnalysisStalenessReason`

Example response shape:

```json
{
  "ok": true,
  "analysisID": "ana_20260513_abc123",
  "fingerprint": "fp_7d61...",
  "url": "https://example.com/settings",
  "title": "Settings",
  "pageType": "form",
  "summary": "Settings form with account fields and save controls.",
  "controlCount": 42,
  "returnedControlCount": 12,
  "omittedControlCount": 30,
  "controls": [
    {
      "controlID": "ctl_save_9ac2",
      "label": "Save",
      "role": "button",
      "tag": "button",
      "selector": "button[data-testid=\"save\"]",
      "state": "enabled",
      "risk": "formSubmit",
      "requiresUserConfirmation": false,
      "validActions": ["click"],
      "confidence": 0.96,
      "evidence": {
        "labelSource": "aria-label",
        "selectorSource": "data-testid",
        "visible": true,
        "enabled": true,
        "covered": false
      }
    }
  ],
  "recommendedActions": [
    {
      "action": "click",
      "controlID": "ctl_save_9ac2",
      "reason": "Primary enabled save button"
    }
  ]
}
```

## Fingerprinting

The page fingerprint should be stable enough to detect meaningful state changes without treating every animation or timer update as stale.

Use inputs such as:

- URL host, path, and stable query keys
- title
- viewport size bucket
- focused element selector, role, label, and value hash
- visible control count bucket
- top control signatures
- modal/dialog presence
- first slice of visible text hash
- engine type

Avoid using:

- exact timestamps
- raw full text
- volatile animation state
- raw array ordering as the only identity

## Control IDs

Generate stable `controlID`s from normalized evidence:

- selector source and normalized selector
- role
- label/name
- tag/type
- form or dialog context
- bounds bucket
- page fingerprint prefix

Do not use simple array indexes as primary IDs. Indexes can be included for debugging but should not be the contract agents use.

## Valid Action Classification

Classify actions deterministically:

- `click`: enabled buttons, links, menu items, checkboxes, radio buttons, actionable role nodes
- `focus`: editable controls and focusable controls
- `fill`: textboxes, textareas, editable fields
- `setValue`: inputs, textareas, selects, contenteditable where reliable
- `select`: select controls, comboboxes where value options are inspectable
- `insertText`: currently focused editable element or editor surface
- `verifyText`: page text or detected editor text
- `waitFor`: text, selector, save state, navigation, or control state
- `domainHelper`: Google Docs, Sheets, Slides, Drive, or other explicit helpers

## Risk Classification

Risk should be explicit in every analysis and preflight result.

Risk classes:

- `normal`
- `navigation`
- `externalNavigation`
- `formSubmit`
- `destructive`
- `sendMessage`
- `payment`
- `purchase`
- `authorization`
- `privacySensitive`
- `credentialInput`
- `mfaInput`
- `unknownHighImpact`

Dangerous classes require explicit user confirmation in chat before execution. Cached analysis must not bypass this.

## API Plan

Add bridge capabilities:

- `GET /analyze`
- `GET /analyze?query=...`
- `GET /analyze?full=true`
- `POST /preflight`

Extend existing mutating endpoints to accept:

```json
{
  "analysisID": "ana_20260513_abc123",
  "controlID": "ctl_save_9ac2"
}
```

Supported endpoints should include:

- `/click`
- `/type`
- `/fill`
- `/setValue`
- `/replaceText` where selector/control mapping applies
- `/clickControl`
- `/act`
- `/batch`

Preflight response shape:

```json
{
  "ok": true,
  "analysisID": "ana_20260513_abc123",
  "controlID": "ctl_save_9ac2",
  "action": "click",
  "matched": true,
  "risk": "formSubmit",
  "requiresUserConfirmation": false,
  "checks": [
    {"name": "analysisFresh", "status": "passed"},
    {"name": "selectorResolved", "status": "passed"},
    {"name": "labelRoleCompatible", "status": "passed"},
    {"name": "visible", "status": "passed"},
    {"name": "enabled", "status": "passed"},
    {"name": "unobscured", "status": "passed"}
  ],
  "summary": "Ready to click Save button."
}
```

Failure codes:

- `stale_analysis`
- `control_not_found`
- `control_changed`
- `ambiguous_control`
- `target_not_visible`
- `target_disabled`
- `target_obscured`
- `unsupported_action`
- `dangerous_confirmation_required`
- `credential_input_blocked`
- `mfa_input_blocked`

## CLI Plan

Add commands:

```bash
astra-browser analyze
astra-browser analyze --query "save"
astra-browser analyze --full
astra-browser preflight --analysis ana_... --control ctl_... --action click
```

Extend commands:

```bash
astra-browser click --analysis ana_... --control ctl_...
astra-browser fill --analysis ana_... --control ctl_... --text "value"
astra-browser set-value --analysis ana_... --control ctl_... --text "value"
astra-browser batch '{"actions":[{"action":"click","analysisID":"ana_...","controlID":"ctl_..."}]}'
```

Keep existing selector, label, role, test ID, and coordinate paths for compatibility and fallback.

## User Transparency

Every action result should include a concise user-readable explanation.

Example:

```json
{
  "ok": true,
  "action": "click",
  "summary": "Clicked the Save button.",
  "matchedControl": {
    "controlID": "ctl_save_9ac2",
    "label": "Save",
    "role": "button"
  },
  "preflight": {
    "ok": true,
    "summary": "Matched by role=button and label=Save; visible, enabled, and unobscured."
  }
}
```

Debug output should include selectors, bounds, fingerprint details, and evidence. Compact output should keep this readable and avoid dumping huge snapshots.

UI/logging expectations:

- Task events should show what control was operated and why ASTRA believed it was valid.
- Dangerous-action blocks should explain exactly what confirmation is needed.
- Stale analysis should say the page changed and recommend running `astra-browser analyze` again.
- Repeated no-op loops should point to analysis/preflight instead of repeating clicks.

## Agentic Fallback

Agentic fallback is not the primary browser-control path.

Use it only when:

- deterministic scan has low confidence
- multiple controls are equally plausible
- the page uses a canvas/editor surface that DOM/accessibility cannot classify
- the user goal requires semantic reasoning, such as choosing the earliest appointment
- a deterministic action fails despite passing preflight

Even then, the fallback should propose intent or a plan. Execution should still go through deterministic preflight and safety gates.

## Implementation Steps

1. Add browser-analysis domain models and JSON serialization helpers.
2. Extend the snapshot scanner to collect richer evidence needed for analysis.
3. Implement deterministic action classification and risk classification.
4. Implement page fingerprinting and stable control ID generation.
5. Add `BrowserAnalysisCache` with bounded size, TTL, and invalidation hooks.
6. Add `/analyze` and `/preflight` bridge routes.
7. Extend mutating routes to resolve `analysisID + controlID`.
8. Extend `astra-browser` CLI command parsing and usage output.
9. Add `controlID` support to `/batch`.
10. Update prompt context in `ShelfBrowserBridgeRegistry`.
11. Add audit telemetry and concise user-facing action summaries.
12. Validate in embedded WebKit and controlled Chromium modes.

## Files Likely Touched

- `Astra/Services/Browser/ShelfBrowserSession.swift`
- `Astra/Services/Browser/BrowserAutomationScripts.swift`
- `Astra/Services/Browser/ControlledBrowserController.swift`
- `Astra/Services/Browser/ShelfBrowserBridgeRegistry.swift`
- `Tools/AstraBrowserTool/main.swift`
- `Tests/BrowserToolShimTests.swift`
- new browser-analysis tests under `Tests/`

## Testing Plan

Add unit tests for:

- ranked vs full analysis output
- query-filtered analysis
- stable control IDs across equivalent scans
- fingerprint compatibility and staleness
- cache hit, miss, TTL expiration, and invalidation
- valid-action classification
- risk classification
- preflight success
- preflight stale-analysis failure
- preflight target changed failure
- dangerous-action confirmation gating
- credential/MFA field blocking
- batch controlID execution and stop-on-first-block
- CLI argument encoding for `analyze`, `preflight`, and control-based actions

Run:

```bash
swift test --filter Browser
swift test --filter CopilotRuntimeTests
swift test --filter ContextInjectionTests
swift test
./script/build_and_run.sh --verify
```

For normal feature work, use the development app only:

```bash
./script/build_and_run.sh
```

## Rollout Plan

1. Ship analyzer and preflight behind the existing Agent control bridge surface.
2. Keep existing commands fully functional.
3. Update prompt guidance to prefer `analyze -> controlID -> action`.
4. Add telemetry to compare old selector/label paths against new controlID paths.
5. Use clear fallback errors instead of silent retries.
6. Only consider stronger enforcement after telemetry shows the analyzer is reliable across real pages.

## Success Criteria

- Agents use fewer broad snapshots before clicking or filling.
- Agents choose controls by `controlID` instead of hand-built selectors when analysis is available.
- Browser action loops decrease.
- Dangerous actions are blocked with clear explanations.
- Stale cached results do not execute.
- User-visible task logs explain browser actions in plain language.
- Existing Google Workspace workflows continue to work.

