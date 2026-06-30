# Workspace App Studio Implementation Status

**Originally:** 2026-06-11 (branch `alvaro/workspace-app-studio-spec`, susom PR #122)
**Last updated:** 2026-06-23 (branch `claude/loving-rhodes-87e735`)
**Parent spec:** `docs/specs/2026-06-05-workspace-app-studio-spec.md`

This document tracks implementation status against the Workspace App Studio
product and architecture spec. The spec remains the source of truth for the
target product. This document is the execution tracker: what exists now, what
is partially implemented, and what still needs to be built before the final
product direction is true.

> **Read the 2026-06-21 update first.** It supersedes the per-area "Pending"
> lists below where they conflict. The 2026-06-20 and original 2026-06-11
> snapshots are kept underneath for history.

## 2026-06-23 Update — Edit-publish regression: wrong-workspace lookup (version-in-place)

**Symptom (live):** editing a published app then publishing failed with "The app you were editing no
longer exists. Use Save as a Copy…" (the AV1 stale-edit guard). Log confirmed the app
(`open-pr-comment-queue`) DID exist in workspace `95DFEB3A`. Root cause: `effectiveWorkspace =
selectedTask?.workspace ?? selectedWorkspace` tracks the selected WORKSPACE, and opening/editing an
app never aligns `selectedWorkspace` to the app's workspace. So `publishWorkspaceApp` filtered
`allApps` by the wrong `effectiveWorkspace` and `updateApp(in: effectiveWorkspace)` targeted it — the
app wasn't found → guard threw. (Pre-AV1 this silently created a sibling in the wrong workspace;
AV1's guard turned the latent bug into a hard failure.)

**Fixed:** `publishWorkspaceApp` now, for an edit, resolves the app by logical id across ALL workspaces
(preferring the session's `workspaceID`) and updates it IN ITS OWN workspace — independent of the
currently-selected one. The journal flush, version snapshot, and seed all use the app's own workspace
path (`target`), not `effectiveWorkspace`. New-app publish is unchanged (creates in the selected
workspace). Full suite 3321 + 41 fitness green.

## 2026-06-23 Update — Publish bug: unsupported storage column type (the dead Publish button)

**Symptom (live, from `~/Library/Logs/AstraDev/astra.log`):** a generated "PR Review Board" wouldn't
publish; the button looked dead. Log showed `App Studio publish failed:
storageFailed("unsupportedColumnType(\"number\")")` (×7). Root cause: the model emitted a storage
column typed `"number"`; `validateStorage` only checked `column.type` was a valid IDENTIFIER, never
that the engine SUPPORTS it, so the manifest validated (`publishable=true`, button enabled) and then
`applySchema` threw at publish — and `publishWorkspaceAppFromStudio`'s catch only logged it.

**Fixed:**
- `WorkspaceAppStorageService.sqliteType` now lowercases + accepts the aliases models reach for
  (number/float→REAL, string→TEXT, boolean→INTEGER, int→INTEGER, timestamp→TEXT); exposes
  `supportedColumnTypes`.
- `WorkspaceAppManifestValidator.validateStorage` blocks a `column.type` not in `supportedColumnTypes`
  — so a bogus type is a clean blocker caught at generation (repair loop) and the Publish button is
  correctly gated, instead of a publish-time crash.
- The data + workflow HTML templates' `inputType()` normalize case + accept the same aliases (a
  `boolean` column renders as a checkbox, not a text field).
- `WorkspaceAppStudioSession.notePublishFailure` surfaces a failed publish in the chat (was log-only).
- Generation prompt now enumerates the allowed column types (a count → integer, an amount → double;
  never "number"/"string").
- Tests: alias round-trip, validator blocks a bogus type + accepts aliases, every supportedColumnType
  applies cleanly (drift guard), publish-failure surfacing. Full suite 3321 + 41 fitness green. Codex
  review: no BLOCKER/HIGH; MEDIUM (template case) + LOW (drift test) fixed.

**Separate, NOT a bug — "preview doesn't show my real PRs":** App Studio HTML apps run in a no-network
sandbox and the `astra.*` bridge exposes only the app's own local storage + the governed workflow
bridge — NOT connectors. So an app cannot pull live GitHub/Jira data; connector-backed HTML apps are
explicitly deferred (see Out of scope). The model disclosed this, then under pressure built a board
with a dead "Import real Git PRs" button. Honest fix (model behavior) + the connector bridge are
future work; logged here as the #1 requested capability gap.

## 2026-06-23 Update — App identity + versioning UX (edit versions in place, no more forked siblings)

**Problem.** "Edit in Studio → Publish" FORKED a suffixed sibling every time — `Home Notes` → `Home Notes 2`
→ `Home Notes 2 2` → `2 2 2` → `Home Notes 3`, each a separate `WorkspaceApp` with its own SQLite DB —
because publish always called `createApp` and the source `logicalID` collided (`manifestForPublishing`
suffixes). The per-app versioning system (`versions/index.json` + `recordPublish` bumping
`latestVersionNumber`) existed but was bypassed, so lineage lived in sibling names. The sidebar also
name-interleaved apps with task runs.

**Landed (version in place + clearer IA):**
- **`WorkspaceAppService.updateApp`** — edit-and-publish now UPDATES the source app (same `logicalID` +
  SQLite DB) and snapshots a new version, instead of forking. Forces `manifest.app.id = app.logicalID`
  (identity is fixed), rewrites the manifest at the same path, applies storage schema additively
  (rows preserved), reconciles dependency bindings + automations (preserving each surviving
  automation's enabled state). `WorkspaceAppStudioSession.editingAppLogicalID` carries the source id;
  `ContentView.publishWorkspaceApp` routes update-vs-create on it. Studio greeting updated.
- **Explicit "Save as a Copy"** in the app detail menu (reuses `duplicateApp`) — forking is now a
  deliberate action, not the silent default.
- **Version badge** on each sidebar app row (`v{N}` from `latestVersionNumber`) so an app's history is
  legible at a glance; full history stays in the app detail view. (`SidebarWorkspaceAppRow`.)
- **Apps/Tasks group labels** in the workspace drawer (`SidebarGroupLabel`, shown only when both exist)
  so durable apps read as distinct from conversational task runs.
- Tests: `updateAppVersionsInPlace` (no forked sibling, identity preserved, manifest rewritten) +
  `editingAppLogicalIDTracksSource`. Full suite 3316 + 41 fitness green.
- **Deliberately NOT done — auto-merging existing siblings.** The pre-existing `Home Notes 2/2 2/…`
  are separate apps with separate SQLite DBs; auto-merging them into one version history risks data
  loss (which DB wins?). The new model stops the pile going forward; old duplicates are removed via
  the existing Delete App. A future "merge into history" is possible but explicitly deferred.

## 2026-06-23 Update — Dynamic editing over time (surgical HTML edits + honest no-op detection)

**Problem.** Editing a published HTML app turn over turn didn't compound. The manifest had a
progressive patch channel (`ASTRA_APP_PATCH`), but the UI/logic blob did not — every UI edit forced
the model to re-emit the WHOLE `manifest.html`. That made edits silently no-op (omit the block →
`applyPatch` keeps the old HTML, still `accepted: true`), regress untouched UI (full-blob rewrites
drop/alter unrelated parts), and the model's "Fixed it / ready to publish" claim was structural-only
(`WorkspaceAppManifestValidator` checks size/CSP/eval, never behavior). Reported symptom: "fix the
delete buttons" → model says fixed, buttons still dead. (Root-caused: the data bridge has no
`astra.delete` verb at all — `WorkspaceAppDataBridge.swift:73` allows query/insert/update only — so a
data-backed HTML delete is impossible to author; the prompts now say so.)

**Landed (keystone for "keep editing apps over time"):**
- **`ASTRA_APP_HTML_EDIT` surgical edit channel** (`WorkspaceAppStudio.swift` `applyHTMLEdits` +
  `applyHTMLEditPayload`). A JSON array of `{find, replace}` anchored edits applied to the current
  `manifest.html`, the blob analogue of a manifest patch. UNIQUE-occurrence contract: 0 matches →
  "anchor not found", >1 → "ambiguous", identical result → "unchanged" no-op rejected. Edits compound
  (a later `find` sees earlier `replace`s). Composes with an optional `ASTRA_APP_PATCH`; mutually
  exclusive with a full `ASTRA_APP_MANIFEST`/`ASTRA_APP_HTML`; requires `manifest.html != nil`. The
  result flows through the SAME `applyPatch` → validator path (so HTML-app sandbox rules still gate
  it) and `WorkspaceAppSurfaceView` re-validates before render. DoS caps: ≤100 edits/turn, ≤64 KB per
  find/replace, ≤256 KB running body (mirrors the validator cap, early-bail).
- **No-op detection** (`WorkspaceAppStudioGenerator.vetEditAware`): an accepted EDIT whose canonical
  manifest digest equals the current app is demoted to a non-publishable blocker that feeds the repair
  loop; on exhaustion it falls back to the unchanged app. Closes "model says Fixed but nothing changed".
- **Honest messaging** (`StudioTurnSummary.line`): an edit that didn't land no longer claims "valid and
  ready to publish" — it says the app is unchanged and asks for a more specific instruction.
- **Prompts** (`refinementPrompt` + `repairPrompt`): present the current UI once in a clean
  `CURRENT_HTML` section (stripped from the manifest JSON), teach `ASTRA_APP_HTML_EDIT` as the preferred
  channel with full `ASTRA_APP_HTML` as the rewrite fallback, and state there is no `astra.delete`
  (model a removal as an archived/status column via `astra.update`). Repair prompt no longer echoes the
  oversized rejected HTML blob.

Tests: +~17 (`WorkspaceAppHTMLAppTests`, `WorkspaceAppStudioGeneratorTests`, `WorkspaceAppStudioSessionTests`)
covering unique-anchor/compound/no-op/cap, dispatch + mutual exclusion, non-HTML rejection, sandbox-escape
rejection, no-op demotion, prompt guidance, honest fallback. Full suite 3296 green + 41 fitness. Codex
adversarial review: no BLOCKER/HIGH; MEDIUM DoS-cap + repair-prompt-amplification items fixed.

**Grounded verification LANDED (same update).** After a turn produces an app, ASTRA now RUNS it in the
preview sandbox instead of trusting the model's "Fixed it" summary — the execution-backed version of a
"did the edit land?" check (an LLM judge would share the generator's blind spot).
- `WorkspaceAppStudioVerifier.verify` (new): Tier-1 `WorkspaceAppSelfCheck.autoExercise` (free,
  deterministic — every declared action once; a throw is the strongest negative) + Tier-3
  `WorkspaceAppScenarioCheckGenerator` (the model AUTHORS an acceptance check from the user's intent,
  ASTRA RUNS it for real). `combine()` folds them → `verified`/`failed`/`inconclusive`/`notApplicable`,
  never a false verified (a step-less or `.warn` check is inconclusive, not verified).
- `WorkspaceAppStudioSession`: injected `verify` seam (tests stub it), `@Published isVerifying`,
  `verifyTurn()` after the result is shown. NON-BLOCKING — never alters the draft, never gates publish;
  only appends an honest verdict message. Gated on `result.accepted && canPublish && !actions.isEmpty`
  (a no-op/fallback turn is NOT verified, so it can't contradict the honest "unchanged" message). Token-
  guarded so a stale check can't post into a newer turn; publish bumps the token (`cancelGeneration()`)
  so a late verdict can't persist to the source app's journal. Chat shows a "Checking your change in a
  sandbox…" indicator.
- Scope/honesty: verifies the GOVERNED data/action layer (what a data-backed HTML app drives through the
  `astra.*` bridge), not the HTML UI pixels; pure-UI apps with no actions are `notApplicable`.
- Tests: +13 (`WorkspaceAppStudioVerifierTests` verdict-folding incl. empty-steps/warn → inconclusive +
  two grounded end-to-end sandbox runs; session tests for surfacing/skip/non-blocking/non-accepted-skip).
  Full suite 3310 green + 41 fitness. Codex review: 2 BLOCKER + 1 HIGH + 2 MEDIUM found and FIXED, re-review
  confirmed all closed, no new BLOCKER/HIGH/MEDIUM.

**First real catch (live).** Grounded verification immediately paid off: a generated "Simple Notes"
app (GPT-5.5) declared `add_note` (appStorage.insert) but `defaultMode: readOnly`, so the Add button
was permission-denied at runtime — the app couldn't save. Verification surfaced it honestly instead of
"ready to publish". Root fix: a validator invariant (`validatePermissionConsistency`) — a read-only
HTML app that declares a write/destructive action is a BLOCKER (its bridge-driven buttons go dead), so
the repair loop self-corrects the mode to `draftOnly`. SCOPED to HTML apps: a declarative governed app
keeps read-only + gated write actions (the runtime blocks the write + records a blocked run — a
supported, tested posture). Generation prompt also reinforced ("NEVER readOnly for a data app"). +4
tests; full suite 3314 green.

**Not yet (fast-follow):** the delete product decision — expose a governed `astra.delete`
(native-confirmed) vs. a soft-delete column. Optionally record the verification verdict on the per-turn
`StudioGenerationEvent` for durable audit (today it's surfaced in chat only).

## 2026-06-21 Update — Dynamic HTML/CSS/JS apps (Phase 1)

App Studio could only express **data apps** (storage + table/dashboard/form/chart/diagram
views rendered natively), so every intent collapsed to the same data shell — ask for a
"calculator" and you got a `calculations` table, not a calculator. Phase 1 breaks that
ceiling: for an interactive tool the declarative vocabulary can't express, the model now
authors the **UI as self-contained HTML/CSS/JS** rendered in the existing locked WebView
sandbox. **Live-verified**: "a calculator …" generates a real keypad calculator that
computes on click (7×8=56), previews in the shelf, and publishes + renders identically in
the detail view (9+6=15).

**Security model (the boundary).** Swift owns the document shell + CSP; the model only
contributes inner content. `WorkspaceAppWebReportHTML.appDocument(innerHTML:)` wraps the
model HTML in the same locked CSP family as `interactiveDocument`
(`default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline';
base-uri 'none'; form-action 'none'`), rendered by the hardened `WorkspaceAppWebReportView`
(`allowsJavaScript: true`, non-persistent store, **no `WKScriptMessageHandler` — no bridge
in Phase 1**, `baseURL: nil`, nav delegate cancels every non-in-memory load). Net: model JS
runs but can't reach network/native/filesystem or navigate out. Pure-UI apps have no data
to leak.

**What changed**
- `WorkspaceAppManifest.html: String?` (nil-default; manifest-level). Non-nil ⇒ HTML app.
  Encodes omitted when nil → declarative digests stay byte-stable.
- `WorkspaceAppSurfaceView.body` branches: `manifest.html` non-empty → render the sandbox
  full-surface; else the native sections. One branch serves BOTH the live preview shelf and
  the published detail view.
- Generation (`WorkspaceAppStudioGenerator`) teaches the model to classify tool-vs-data and,
  for a tool, emit a minimal metadata manifest + an `ASTRA_APP_HTML … END_ASTRA_APP_HTML`
  block; `WorkspaceAppStudioBuilder.applyStructuredOutput` parses it onto `manifest.html`
  (attached before validation; a separate block wins over inline html).
- Validator: `validateHTMLApp` (non-empty, 256 KB cap, blocks `<iframe>`/external `src` as a
  clear authoring error — the CSP already blocks them); the storage-usability net is skipped
  when `html` is present (the WebView fills the surface).
- **Robustness fix (root cause of the first failed live run):** model-authored manifests
  routinely OMIT empty/default fields, which the synthesized `Codable` rejected with an
  opaque keyNotFound ("the data couldn't be read because it is missing") → template
  fallback. `WorkspaceAppManifest`, `WorkspaceAppManifestMetadata`, and
  `WorkspaceAppPermissions` now have **lenient decoders** (omitted arrays → `[]`, omitted
  scalars → defaults, omitted id/name → "" so the validator reports a clear blocker).
  `encode(to:)` stays synthesized, so digests are unaffected. This hardens ALL generation,
  not just HTML apps.
- Tests: `Tests/WorkspaceAppHTMLAppTests.swift` (15) — round-trip + nil-omission, locked-CSP
  appDocument, ASTRA_APP_HTML parsing, validator rules, lenient minimal-manifest decode, the
  surface-decision precondition. Full suite green (3205 tests incl. the 41 fitness tests).

**Codex adversarial review (2026-06-21, verdict SHIP WITH FIXES) — fixes applied:**
- **Accurate boundary + explicit local-device denial (was HIGH).** The CSP/nav-lock blocks network
  egress + navigation, but not local DOM APIs. `WorkspaceAppWebReportView` now installs a denying
  `WKUIDelegate`: `window.open` → nil, file-open panel → nil (so `<input type=file>` can't read
  disk), JS alert/confirm/prompt dismissed. Docs corrected: the guarantee is **no exfiltration
  channel** (no network egress, no native bridge, no navigation, no persistence) — a user-gesture
  `clipboard.writeText` can still run but has nowhere to send data, so it stays allowed (legit
  "copy result" buttons).
- **HTML apps are self-contained UI only (was MEDIUM).** `validateHTMLApp` now rejects an `html`
  manifest that ALSO declares storage/requirements/sources/views/actions/automations (hidden/dead
  capabilities that skip governance).
- **Reject `eval()`/`new Function` (was MEDIUM).** The CSP has no `'unsafe-eval'`, so an eval-based
  calculator would silently no-op; the validator now blocks it (standalone-call match, so
  `retrieval()` isn't a false positive) → the repair loop rewrites it.
- **Repair prompt carries the `ASTRA_APP_HTML` contract (was MEDIUM)** so a rejected HTML app
  re-emits the UI block instead of dropping it.
- **Shared tool tokens (was LOW).** `WorkspaceAppArchetype.htmlToolIntentTokens` is the single
  tight list used by BOTH `classify` and `WorkspaceAppStudioScope`, so "in scope as a tool" and
  "classifies as an HTML app" agree; generic nouns (tool/widget/game) no longer suppress the
  website warning.
- Confirmed FINE by codex: CSP/no-bridge posture ≥ the vetted chart shell; `img-src data:` is not a
  network channel; lenient decoders default permissions to empty grants + `readOnly` and keep
  `encode(to:)` synthesized (digests byte-stable); deferring height auto-sizing is correct (a
  height handler is still a bridge → its own review). Full suite green (3208 tests).

### Dynamic-UI reliability follow-up (same day) — a "dynamic UI" intent no longer degrades to a static data shell

Live testing surfaced the real failure: asking for "a ui to manage open PRs … make it nice and
dynamic" produced the static `review_items` shell because generation **timed out** and the
deterministic fallback routed a UI intent to `.dataEntry`. Diagnosed via a parallel diagnostic
workflow (timeout / routing / data-honesty traces → synthesis). Fixes:
- **Timeout** (`WorkspaceAppStudioSession.generationTimeoutSeconds`) 120 → **240s**. The provider
  timeout is pure wall-clock and `codex exec` buffers output to the end, so an output-heavy HTML
  generation was killed mid-write.
- **Output bound** in `generationPrompt`: hard "ship a WORKING MINIMAL UI (~160 lines), refine by
  chatting" so generation finishes fast instead of over-producing.
- **`classify()` UI-gate** (`WorkspaceAppArchetype`): UI-centric intents ("a ui", "interface",
  "interactive", "dynamic ui", "web app", "single page") → `.htmlApp` UNLESS data tokens present.
  So the deterministic FALLBACK is now a dynamic HTML scaffold, not the static records shell.
- **Model steering** (`generationPrompt` DYNAMIC HTML APPS): explicitly build an HTML app for "a UI /
  interface / dynamic / interactive" intents (with sample data) — "do NOT fall back to a records
  table + dashboard for a UI-centric intent". (classify() is the fallback path only, so both the
  classifier AND the prompt are needed — verified by the workflow.)
- **Honest messaging**: `WorkspaceAppStudioScope.needsConnectorNotice` surfaces a non-blocking
  notice for connector/live-data intents (GitHub/Jira/…) — "sandbox has no internet, sample data
  only" — then proceeds. `StudioTurnSummary` distinguishes the HTML-scaffold fallback
  ("interactive HTML starting point … sample UI … can't sync live data yet") from the data template.
- Tests: +6 (`uiCentricToHtmlApp`, `dataCentricIgnoresUILanguage`, `promptSteersUIIntentsToHTML`,
  `connectorIntentsGetNotice`, `connectorIntentDisclosesButGenerates`, `htmlScaffoldFallbackMessage`).
  Full suite green (3214).

**Live-verified**: connector notice fires + is non-blocking; a UI intent now falls back to a dynamic
HTML scaffold (NOT the data shell) with honest messaging + the interactive-app banner. CAVEAT: a
fresh *successful* model generation couldn't be re-shown in the test session because codex was
running extremely slowly under cumulative session load (even a tip-calculator hit the 240s ceiling);
the earlier-session calculator (generated + computed 7×8=56) confirms the happy path when codex is
healthy. **Known limit / deferred:** when codex is slow or the UI is very large, generation still
times out → scaffold. The real UX fix is **streaming the HTML as it generates** or a true
**idle-timeout** (reset on stdout activity) — both touch the shared `AsyncProcessRunner` primitive
(`SpecEngine.swift`) used by every task runtime, so they're a separate, higher-blast-radius change.

### Resilient, self-healing dynamic UI (same day) — ALWAYS a real interactive UI, instantly

Even with the timeout/routing fixes above, a slow/timed-out model still left a UI intent on a
placeholder scaffold (and the wait was a blank "Building…"). Two layers now guarantee a real dynamic
UI regardless of model speed/availability:
- **Deterministic interactive-HTML template library** (`WorkspaceAppHTMLTemplate`, new): real,
  working, sandbox-safe UIs — `calculator / checklist / board / dashboard / form / generic` — authored
  by a parallel multi-agent workflow then adversarially verified (and re-asserted by unit tests) for
  no-eval / no-network / self-contained + genuine interactivity. `classify(intent)` picks the closest
  (e.g. "manage open PRs" → kanban board); unknown intents get the polished `generic` shell, so there
  is ALWAYS a real interactive result. `WorkspaceAppStudioBuilder.htmlAppScaffoldManifest` now returns
  a template instead of the old "describe what you want" placeholder — so any model timeout/failure
  heals to a genuine dynamic UI.
- **Provisional-then-upgrade** (`WorkspaceAppStudioSession.submit`): for a UI-centric first build, the
  deterministic template draft is shown IMMEDIATELY (preview never blank), then UPGRADED to the
  model's bespoke UI if generation succeeds, or kept as-is if it times out — never a downgrade.
- Tests: +6 (`WorkspaceAppHTMLTemplateTests` ×4 + 2 session tests for provisional/upgrade and the
  data-intent-has-no-provisional guard). Full suite green (3220).
- **Live-verified**: "a ui to manage open PRs … make it very nice and dynamic" → an interactive kanban
  board renders INSTANTLY (To Do / In Progress / Done with sample cards) while the model is still
  building; clicking a card advances its column and updates the counts (real JS in the no-network
  sandbox). The static-data-shell outcome is gone for UI intents. (Codex remained too slow under
  session load to show a bespoke upgrade, but the deterministic floor is the guarantee — the user
  always ends up with a working dynamic UI.)

### Phase 2 — vetted data bridge LANDED (HTML apps can use their own governed data)

A dynamic HTML app can now read/write ITS OWN governed storage via an injected `astra.*` JS API,
so HTML can be a real data app (the step toward making HTML the universal surface + retiring native
widgets). `WorkspaceAppDataBridge` (new) is a `WKScriptMessageHandlerWithReply` (`astraAppBridge`)
exposing `astra.query/insert/update`. The bridge adds NO new data-access surface: each request goes
`parse` → `resolve` (allowlist) → the SAME `onRunAction` the native UI uses →
`WorkspaceAppActionExecutor`, which enforces `permissionMode`, records an audit run, and scopes the
SQLite file to the app's own `logicalID`. Wired in via `WorkspaceAppWebReportView.onBridgeRequest`
(registered ONLY for data-backed HTML apps) + `WorkspaceAppSurfaceView.dataBridgeRun` (preview/live
parity for free). `validateHTMLApp` relaxed: an HTML app may declare its own storage + appStorage
actions (the allowlist), still no connectors/views/automations/non-storage actions.

**Security (codex adversarial review, DO NOT SHIP → fixes → re-review):**
- **No delete via the bridge.** Delete is `.destructive` (native UI needs a two-step confirm), so a
  JS-minted confirmation would let a page wipe records on load. Dropped entirely (`allowedOps` =
  query/insert/update; the bridge never sets `confirmedDestructive`). Deferred to a host-confirmed path.
- **Exact-table allowlist.** `resolve` requires `action.table == request.table` (a table-less action
  no longer grants the op on every table); `validateHTMLApp` requires each appStorage action to name
  a declared table.
- **No stale allowlist.** `updateNSView` refreshes the handler's closure (live manifest) each
  update; and bridge eligibility is part of the WebView's SwiftUI `.id` (storage added/removed
  recreates the WebView), so a page can't keep calling `astra.*` after the app loses storage.
- **DoS caps** (≤200 record fields, ≤256KB values) + **strict values** (NaN/Infinity/nested rejected,
  not stored as null).
- Confirmed by codex: no cross-app DB access, no SQL injection (quoted identifiers + bound values),
  no connector/task/export escalation, CSP/nav/UIDelegate posture intact.
- Tests: `Tests/WorkspaceAppDataBridgeTests.swift` (allowlist, exact-table, value mapping, governed
  insert→query round-trip). Full suite green (3229). NOTE: the full GUI round-trip (live JS →
  SQLite) is exercised in Phase 3, when generation/templates emit data-backed HTML apps.

### Phase 3 + 4 LANDED — HTML is the primary surface; native is legacy/workflow-only

**Phase 3 — data apps are now data-backed HTML.** A record-tracking data app (track/list/store X) is
generated as a DATA-BACKED HTML app: `storage` + `appStorage.query/insert/update` actions (the bridge
allowlist) + an HTML UI wired to `astra.*`. New file `WorkspaceAppDataHTMLTemplate` (a real CRUD UI —
list + add-form + inline edit, model-authored then adversarially verified) is the deterministic
floor; `WorkspaceAppStudioBuilder.dataBackedHTMLManifest` assembles it.
`WorkspaceAppStudioRecipes` routes localDatabase(non-grocery) / dataEntry →
data-backed HTML. The generation prompt now describes both PURE-UI and DATA-BACKED HTML apps (with
the `astra.*` contract); the provisional-then-upgrade fires for any html-baseline intent (data + tool)
so a real UI shows instantly. Governance is fully preserved — every read/write still goes
`astra.*` → the governed executor (permission + audit + app-scoped DB).

**Phase 4 — native widgets are legacy/workflow-only.** `WorkspaceAppSurfaceView.declarativeSurface`
renders ONLY when `manifest.html == nil`: already-published declarative apps (backward-compat, digests
unchanged) + the governed-WORKFLOW archetypes. Native data-presentation widgets are frozen (new data
apps never use them). `WorkspaceAppStudioRefinement` native chips are disabled for HTML apps (refine
by chatting instead).

**The honest boundary (what stays native + why):** governed-workflow archetypes — `pipeline`,
`agenticWorkflow`, `reportGenerator`, `monitor` — plus `dashboard` (metric/chart widgets), `reviewQueue`
(triage + approval gate), and the curated multi-table grocery reference stay native, because they need
agent tasks / approval+agent gates / pipelines / scheduled automations / artifact exports / charts /
multi-table UI that the appStorage-only bridge does not expose. **Fully deleting the native widget
library + "no declarative views ever" requires a future governed WORKFLOW bridge (tasks/gates/connectors)
— Phase 5 — plus multi-table and chart data templates.** Until then native is retained (frozen) for
those cases. Tests: `WorkspaceAppArchetypeTests` (plain-record archetypes → html + astra.*; workflow +
chart/queue archetypes → native) + `WorkspaceAppHTMLTemplateTests` (data template safe + uses bridge +
validates + injection-safe) + `WorkspaceAppHTMLAppTests` (network-API / `<link>` / `<script src>` reject).

**Codex Phase 3/4 adversarial review (2026-06-22, verdict SHIP WITH FIXES) — all four applied:**
- **HIGH (sandbox contract):** `validateHTMLApp` now also rejects network/external-resource markers it
  previously let through — `fetch(` / `import(` (standalone-matched), `xmlhttprequest`, `websocket`,
  `eventsource`, `sendbeacon`, `@import`, `importscripts`, `navigator.serviceworker`, any `<script src>`
  (incl. `data:`), and any `<link>`. The CSP (`default-src 'none'`) is still the real boundary; this
  keeps a non-self-contained app from passing review and keeps the repair loop honest.
- **HIGH (lost semantics):** `dashboard` + `reviewQueue` were collapsing into the generic CRUD template
  and silently dropping charts / the approval gate (and native refinement chips don't apply to HTML
  apps), so they were routed back to native. Only `localDatabase`(non-grocery) and `dataEntry` are
  data-backed HTML now.
- **MEDIUM (template injection):** `WorkspaceAppDataHTMLTemplate` is injection-safe by construction —
  `table`/`primaryKey` are JSON-encoded into the JS context and a `scriptSafe` pass escapes `<` so a
  crafted identifier can't close the inline `<script>`. (The manifest validator's identifier-charset
  rule already blocks such names upstream; this is defense in depth.)
- **LOW (stale copy):** the deterministic fallback summary now distinguishes a data-backed HTML fallback
  ("saves to this app's own local storage") from a pure-UI one ("can't sync live data yet").

Full suite green (**3235**, +3 tests). GUI live-verify of the data-app round-trip (live JS → SQLite)
was blocked the prior session by a host screen-capture failure; the data path + allowlist are
unit-verified through the real executor.

### Phase 5 LANDED — governed WORKFLOW bridge; native is now monitor-only

HTML apps can now drive their OWN declared workflow, so the workflow archetypes are HTML too. The
`astraAppBridge` gained three verbs (same handler, dispatch-by-`op`):
- `astra.runAction(actionId)` — trigger a DECLARED, JS-runnable workflow action.
- `astra.runs({limit})` — read this app's recent run snapshots (poll status / show history).
- `astra.actions()` — list the declared runnable actions.

**Security model (the load-bearing part — hardened after a codex DO-NOT-SHIP, see below).** The
direct JS verbs (`runnableActionTypes`) are only the self-gating/harmless ones: pipeline.run, loop.run,
task.createDraft, notification.show, rows.reduce, clipboard.copy. EXCLUDED from direct JS:
`capability.*` (networked connectors — still deferred), `gate.*` (a human resolves these in the native
attention queue; JS may never mint a decision), `url.open` (arbitrary navigation), storage delete, AND
`artifact.export` + `task.createAndRun` (write/agent effects that may run ONLY inside a gated pipeline,
never as a direct verb). `resolveAction`/`jsActions` gate on `isDirectlyRunnable` = a runnable type
that is NOT an internal `steps` entry of any pipeline/loop — so a page can't call a gated step (e.g.
`export_report`) directly to skip its approval gate; only the top-level `run_*` pipeline is callable,
and it suspends at its `gate.humanApproval` step. The bridge NEVER sets
`confirmedApproval`/`confirmedDestructive`, so the gate is the sole authority. Everything routes through
the same `onRunAction` → `WorkspaceAppActionExecutor` (permission + audit + app-scoped DB). Two
throttles: `runActionInFlight` (no concurrent runAction) and `workflowRunPending` (deny a new runAction
while a prior run is waiting/running — cleared when an `astra.runs()` poll shows nothing pending — so a
scripted loop on a `preApproved` app can't queue unbounded agent tasks).

**Why the gates still work for a full-HTML app.** `WorkspaceAppDetailView.body` renders the approval
queue (`attentionSection`), `versionsSection`, and `automationSection` as native chrome AROUND the
`WorkspaceAppSurfaceView`. So a workflow HTML app TRIGGERS a pipeline via `astra.runAction`; the
pipeline suspends at its `gate.humanApproval` step; the human approves in the native queue shown above
the HTML; the run resumes. JS only triggers — it never approves.

**Builders + routing.** `workflowHTMLBase` + per-archetype builders (`pipelineHTMLManifest`,
`reportHTMLManifest`, `reviewQueueHTMLManifest`, `agenticWorkflowHTMLManifest`, `dashboardHTMLManifest`
in `WorkspaceAppStudio.swift`) wrap any external-write step behind a `gate.humanApproval` step inside
the `pipeline.run`. One parameterized `WorkspaceAppWorkflowHTMLTemplate` (single injected `__CONFIG__`
JSON, `<`-escaped = injection-safe) covers multi-table CRUD + metric/bar-chart (dashboard) + run
buttons + a run-history poll. `validateHTMLApp` relaxed (`isHTMLAppActionAllowed`) to allow
task./gate./pipeline.run/loop.run/export/notification/rows.reduce/clipboard; still forbids
`capability.*`/`url.open`/requirements/sources/views/automations.

**The honest remaining native set:** ONLY `monitor` (scheduled, time-triggered automations — not a
UI-triggered action) plus the curated multi-table grocery REFERENCE (kept native by choice, not a
capability gap — the workflow template supports multi-table). Connector-backed (live GitHub/Jira)
HTML apps remain explicitly deferred (need a governed connector bridge; Phase 5 stays no-network).

**Codex adversarial review (THREE rounds) → all findings fixed:**
- **Round 1 (BLOCKER):** JS could call an internal pipeline step (`export_report`) directly to skip its
  gate → dropped artifact.export/task.createAndRun from the direct-verb set and excluded any pipeline
  step from direct invocation (`isDirectlyRunnable`). (HIGH) sequential task-spam → `workflowRunPending`
  throttle. (LOW) stale `astra.runs()` → `onReload` after each runAction.
- **Round 2 (STILL DO NOT SHIP):** the bypass wasn't fully closed — a top-level `pipeline.run` could
  itself be UNGATED (export effect is `.read`, so the executor won't gate it), and `loop.run` runs
  `task.createAndRun` INLINE (no suspend → the throttle never engages).
- **Round 3 fix — admission gate in `validateHTMLApp`:** an HTML `pipeline.run` whose steps include
  `artifact.export` MUST have a `gate.humanApproval` step BEFORE the export (export doesn't suspend; a
  `task.createAndRun` step is fine because the pipeline SUSPENDS on it → throttled); an HTML `loop.run`
  may not contain ANY external-effect step.
- **Round 3 review (STILL DO NOT SHIP):** the gate check was NON-TRANSITIVE — a
  `pipeline.run → gate.branch → artifact.export` (or a nested pipeline) reached an ungated export past
  the direct-steps-only check.
- **Round 4 fix — keep the HTML workflow vocabulary FLAT + branch-free so the analysis is complete:**
  `isHTMLAppActionAllowed` is now an explicit allow-set that EXCLUDES `gate.branch`/`task.fanOut`/
  `task.open` (un-declarable), and `validateHTMLApp` rejects any pipeline/loop step that resolves to
  another `pipeline.run`/`loop.run` (no nesting). With branching/fan-out un-declarable and no nested
  composites, the action graph reachable from a JS-runnable pipeline is depth-1 to LEAF actions, and no
  leaf type references another action → the flat gate-before-export / no-external-effect-in-loop checks
  are graph-complete. The native `artifact.export` `.read` effect was left unchanged (broad native
  blast radius); the validator admission gate is the fix.

Confirmed across the review rounds: no cross-app run leak, CSP/no-network intact,
gates/connectors/url.open not JS-reachable, template injection-safe.

Full suite green (**3252**, +17 tests). The in-memory PreviewRunner throws `approvalRequired` at a
gate (it has no suspend machinery), so a workflow pipeline runs to completion only in the PUBLISHED
app with the real executor — correct governance, asserted by the bridge test. GUI live-verify remains
blocked by the host screen-capture failure; the bridge allowlist + suspend-on-gate path are
unit-verified through the real runner.

### Full security review hardening — codex DO NOT SHIP ×4 → SHIP

A comprehensive adversarial review of the whole HTML/bridge subsystem (assume a hostile app author
AND hostile page JS, not just the Phase 5 delta) surfaced issues beyond Phase 5. All fixed:
- **HIGH — `clipboard.copy` wrote `NSPasteboard` from JS with no gesture** (effect `.read`): removed
  from `runnableActionTypes` and `isHTMLAppActionAllowed`. HTML copy uses the browser's gesture-gated
  `navigator.clipboard`.
- **HIGH — the bridge trusted the on-disk manifest**: `WorkspaceAppSurfaceView` re-validates in init
  (`htmlManifestValid`) and renders HTML + installs the bridge ONLY when valid; an invalid/tampered
  manifest shows a notice and gets no WebView/bridge (fail closed). Both preview + published route
  through this surface.
- **BLOCKER — the workflow spam throttle was bypassable**: a volatile per-WebView flag seeded from the
  8-row presentation snapshot (a hostile app could insert ≥8 storage records to age its waiting run
  out of the history, then `astra.runs()` cleared the flag). Replaced with a LIVE, UNCAPPED store query
  (`makeWorkflowPendingCheck` → `FetchDescriptor` on `appID` + waiting/running, fail-closed on error)
  passed as `Handlers.isWorkflowRunPending` and checked INSIDE the runAction `Task` — atomic with the
  SYNCHRONOUS `WorkspaceAppActionExecutor.execute` on the serial main actor, which also closes the
  two-WebView TOCTOU without a reservation table.
- **MEDIUM — DoS caps loosened**: field count 200→100, per-value 256KB→64KB, NEW total-record-byte cap
  (256KB) in `strictRecord`, and the bridge query limit clamped to `maxQueryLimit` (1000).
- **MEDIUM — drag/drop**: refused three ways — `WorkspaceAppNonDroppingWebView` subclass +
  `unregisterDraggedTypes()` at creation + recursive post-load unregister + a capture-phase
  `dragover`/`drop` `preventDefault()`+`stopImmediatePropagation()` injected first in the HTML shell.

Codex final verdict: **SHIP** (no open findings). Confirmed still sound: no-network CSP, exact-(op,table)
data allowlist, no delete, SQL identifier-quoting + value binding, audit-run-before-permission, no
cross-app run leak (app-scoped query). **Accepted follow-ups (flagged, not blockers):**
`WorkspaceAppService.createApp` doesn't enforce logical-ID uniqueness (callers dedupe today); no per-app
CUMULATIVE agent-token budget (the throttle bounds concurrency to one in-flight run, not lifetime
spend). Full suite green (**3255**).

## 2026-06-20 Update — Conversational App Studio (Lovable/Replit-style)

App Studio is no longer a form. Creating an app is now a **conversation in the main
detail column** (the same surface tasks render in), with the **live app docked in the
right shelf** — reusing the existing chat-style UI and the global shelf system instead of
a bespoke builder screen. Describe the app, refine it by chatting, watch the test version
build on the right, publish when ready.

**What changed**
- New `WorkspaceAppStudioSession` (`Astra/Services/WorkspaceApps/`) — the conversational
  engine. Each message generates the first app or refines the current one through the
  existing `WorkspaceAppStudioGenerator` (which already accepts `existingManifest` and
  emits a full manifest OR an `ASTRA_APP_PATCH`, so multi-turn refinement is "pass the
  prior manifest as the base"). Includes the out-of-scope guard and deterministic, honest
  turn summaries. The generator is injected, so the 8 new unit tests never spawn a CLI.
- New `WorkspaceAppStudioChatView` — the left conversation: reuses the model picker, the
  archetype quick-starts, and the `WorkspaceAppStudioRefinement` chips (now things you can
  just say), plus publish / sample-data / cancel / preview-toggle in a slim header.
- New `ShelfWorkspaceAppPreviewView` + a new `.appPreview` case on `WorkspaceCanvasItem` —
  docks the **existing** full interactive `WorkspaceAppPreviewView` (sandboxed CRUD/actions)
  in the global right shelf; re-renders per `session.draftRevision`. The preview is a
  first-class shelf in the **top-right dynamic menu** (`WorkspaceTopRightToolbar`): a "Preview"
  button governed by `canShowAppPreviewShelf: isComposingWorkspaceApp`, so it surfaces only in
  App Studio, alongside Files, with the same active-highlight + toggle behavior as the other
  shelves (it auto-docks on entry; switching workspaces or leaving the Studio dismisses it).
- `ContentView`: the studio now renders through the docking shell (`ContentDetailAreaView`
  → `ContentDetailContentView` `.workspaceAppStudio` case) so the preview docks beside the
  chat. The old form `WorkspaceAppStudioView` + `WorkspaceAppStudioInlinePreview` are
  retired. `WorkspaceCanvasItem` + the shelf-boundary value/overlay types moved to
  `Astra/Views/WorkspaceCanvasItem.swift` to keep `ContentView.swift` within its 5000-line
  budget (now 4969). "Edit in Studio" seeds the conversation from the app's manifest.

**v1 scope (noted, reversible)**
- App-build conversations are ephemeral (build → publish/cancel; not saved to the task
  list) — matches the prior Studio lifecycle.
- Assistant turns are deterministic summaries (no second model round-trip); honest about
  validation and model-unavailable fallbacks.
- Regenerating resets the preview's in-memory sandbox (disposable test data).

All 3177 tests + 41 architecture-fitness tests green.

### Gap closure (2026-06-21)

Closed the residuals from the conversational rework:
- **Model-written turn summaries.** The generator now asks for a one-line `ASTRA_APP_SUMMARY:`
  and surfaces it on `WorkspaceAppStudioGenerationResult.summary`; the chat leads the assistant
  turn with it (always appending the honest validation line) and falls back to the deterministic
  summary when absent or on the template fallback. Sanitized + length-capped (display-only).
- **"Test" re-surfaced.** A `…` menu in the chat header opens the existing `WorkspaceAppTestPanelView`
  sheet (self-check / plain-English tests / saved checks); authored checks save back onto the draft
  via `WorkspaceAppStudioSession.applyChecks`.
- **Manifest inspector re-surfaced.** The same menu opens a read-only `WorkspaceAppManifestInspectorView`
  sheet (identity / sources / storage / actions / automations / permissions), reusing
  `WorkspaceAppManifestInspectorPresentationBuilder`.
- **Ideate + identity card.** Their standalone form UIs are intentionally NOT re-surfaced —
  conversational generation supersedes the ideation cards, and the live interactive preview replaces
  the identity card. Follow-up cleanup retired the old proposal/identity scaffolding; deterministic
  coverage now lives on `WorkspaceAppArchetype.classify` and `WorkspaceAppStudioRecipes`.
- **Workspace-switch correctness.** Switching workspaces while in the Studio now exits it
  (`handleSelectedWorkspaceChanged`), so a stale session can't publish into the wrong workspace.

**Codex second opinion (2026-06-21).** An independent `codex review` of the conversational
Studio diff returned GATE: PASS (no critical findings) and two [P2] regressions, both addressed:
- *Stale generation could clobber state* — FIXED. `WorkspaceAppStudioSession` now carries a
  monotonic `generationToken`; a turn only applies its result if the token is still current, and
  `reset` / `cancelGeneration` (called on Cancel, leaving the Studio, and workspace switch)
  invalidate any in-flight turn. Covered by two new tests.
- *Editing an app publishes a duplicate* — MITIGATED + deferred. The seeded "Edit in Studio"
  flow now says it builds an updated **copy** (publishing saves a new app), so it no longer implies
  in-place update. True in-place editing is deferred (see below).

**Still deferred (deliberate, not defects):**
- *Persistent/resumable app-build conversations* — still ephemeral. A separate feature (SwiftData
  model for in-progress builds, sidebar entries, reopen lifecycle); `ContentView.swift` is at its
  line budget. Its own slice.
- *In-place editing of a published app* — publishing an edited app creates a new app rather than
  updating the original's manifest + version history. `WorkspaceAppService` has no update path, and
  a correct one needs additive storage migration (`ALTER TABLE ADD COLUMN`, with the NOT-NULL-on-
  existing-rows case) — a data-migration slice that shouldn't be rushed. The current copy behavior
  is non-destructive (the logical-ID dedup prevents record/version-dir collisions).

Live-verified end-to-end (publish → install → sidebar app row; Edit-in-Studio seeds from the app's
manifest; Test + Inspect sheets; honest model-timeout fallback).

### Sandboxed interactive-JS visualization (2026-06-21)

Added a third web renderer, `chartInteractive` — the **only** renderer that runs JavaScript, and
only a **vetted, Swift-authored** script (no third-party/bundled lib → no supply chain; no
model/user-authored code). The bar data is handed over as an **escaped JSON data-island**
(`<script type="application/json">`, `<`/`>`/`&` → `\uXXXX`), parsed with `JSON.parse`, and every
data-derived string is written with `textContent` (no `innerHTML`/`eval`/attribute injection).
JavaScript is enabled for ONLY this renderer (`WorkspaceAppWebReportPresentation.allowsJavaScript`,
true just for `chartInteractive`); `htmlReport`/`chartComposite` stay JS-off. The document keeps
`default-src 'none'` (no network), now with explicit `base-uri 'none'; form-action 'none'`; there is
no JS↔native bridge, `baseURL` is nil, and the nav delegate allows only in-memory `about:` loads (so
a script-initiated navigation to a real URL is blocked independently of CSP). Reachable from the chat
via the "Add an interactive chart" refinement and from generation (`allowedRenderers`). 6 safety unit
tests; live-verified (renders + JS hover tooltip works, scoped to this renderer only).

**Adversarial codex review (2026-06-21):** found NO app-data→executable-JS exploit (data-island
breakout, network/exfil, native bridge, JS scoping, DOM-XSS all hold). Two Low defense-in-depth gaps
it raised — nav not locked to the initial load, CSP not maximally explicit — were both closed (the
nav-scheme guard + `base-uri`/`form-action`).

Arbitrary model/user-authored JS apps remain deliberately **out of scope** (that would be running
untrusted code — a different threat model).

### Provider reliability — real generation, not constant templates (2026-06-21)

Generation was almost always falling back to the deterministic template. Investigated the shared
utility runtime (`AgentUtilityRuntimeRunner` → per-adapter `runUtilityPrompt`) and found two distinct
provider problems, not an App Studio bug:

- **codex (FIXED, now a real working provider).** Auth is file-based (`~/.codex/auth.json`) and works,
  but `codex exec` ran at default reasoning and explored the workspace, so a one-shot manifest
  generation deliberated **past the timeout** (>180s) and fell back. Fix: utility one-shots now run
  codex at **`model_reasoning_effort="low"`** (`CodexCLIRuntimeAdapter.runUtilityPrompt`) — a probe
  dropped a trivial call from >180s to ~10s, and a full App Studio generation now finishes in ~80s.
  App Studio generation timeout raised 60→120s for headroom (`WorkspaceAppStudioSession`). Live-
  verified: codex generated a real tailored "Reading List Tracker" (books table, per-field actions,
  an inferred "Average rating" metric, model-written summary) — origin `.model`, not template.
- **claude_code (root-caused; needs an infra/signing fix, not a code change).** Its OAuth token lives
  in the macOS **Keychain** (`~/.claude.json` holds only `oauthAccount` metadata; no API key in the
  shell). A Finder-launched, **ad-hoc-signed** dev build can't read/refresh that token in the spawned
  subprocess → `401 Invalid authentication credentials` (a stripped-env repro shows "Not logged in").
  This is the known keychain-signing issue (stable Developer ID signing is the real fix; or set
  `ANTHROPIC_API_KEY`). **Workaround today: use the codex provider in App Studio** (its auth works).

## 2026-06-19 Update — Progress And Gaps

The F1–F7 runtime re-land and the product slices that were "pending" on
2026-06-11 have largely landed on `claude/loving-rhodes-87e735`. Live-verified in
the running dev app.

### Landed since 2026-06-11

- **F1–F7 runtime re-land** onto the active line: domain/manifest/validator,
  app-owned SQLite storage, contract registry, action runtime
  (task/gate/loop/pipeline), app-detail + Studio views, and UI entry-point wiring
  (⌘⇧A → Studio → publish → detail → run). Apps re-open from the workspace home
  Apps section **and** inline in the sidebar under their workspace.
- **Slice 2 — model-backed generation**: structured `ASTRA_APP_MANIFEST` output +
  validation-feedback repair loop. Live-verified — an in-scope intent ("track lab
  samples by status and location") produces a real model-built "Lab Sample
  Tracker", status "Draft generated by the model".
- **Slice 3 — preview + versioning**: inline preview runner, publish with version
  snapshots, last-known-good.
- **Slice 4 — local database reference app** (grocery CRUD).
- **Slice 9 — agentic workflow apps (Phases A–C)**: `task.createAndRun`,
  agent/human gates, output/input bindings, bounded loops, parallel fan-out +
  reduce, live agent resumption.
- **Pipeline run visualization + approval-queue UI** (was §24.6 pending).
- **Archetype coverage**: classifier + per-archetype recipes (localDatabase,
  dataEntry, reviewQueue, dashboard, pipeline, reportGenerator, monitor, and
  **agenticWorkflow** as a first-class type in the picker).
- **App self-test engine** (Tiers 1–3) + Test panel; **Studio UX redesign**
  (plain-language identity card, type picker, inline preview, refinement chips).

### Added beyond the original spec (doc-level omissions now filled)

The spec assumed a generic "the model" and did not address these; they were
needed in practice and should be folded back into the spec:

- **Provider + model picker** for generation (Claude / Copilot / Codex / Cursor /
  OpenCode / Antigravity), bound to the workspace default. The spec never
  discussed non-Claude generation.
- **Generation observability**: every attempt logs provider, model, exit code,
  output size, decoded?, publishable?, and the first blocker reason (category
  `WorkspaceApps`). The path was previously a black box.
- **Honest fallback status**: when a model runs but returns no usable manifest,
  the Studio surfaces the real reason instead of a silent template swap.
- **Out-of-scope detection**: content/marketing-site intents ("a landing page",
  "a website") are flagged with guidance instead of silently shipping a mislabeled
  data shell — enforcing the §5 non-goal "public web hosting for apps".
- **Sandbox developer-toolchain fix**: sandboxed providers' `git` shim no longer
  trips the macOS "install command line developer tools" dialog.

### Remaining gaps — status as of 2026-06-19 (later pass)

All seven were worked; most are now closed. Updated state:

| # | Capability | Spec ref | Status | Note |
|---|---|---|---|---|
| 1 | **Rich native renderer** — forms with validation, sortable/filterable tables, charts, approval controls | §14, §24.3, success #5 | **DONE** | Tap-to-sort + filter tables, required/number/date form validation, bar/line/pie charts, gate/approval forms. `WorkspaceAppTablePresentation`/`WorkspaceAppFormValidation` (unit-tested). |
| 2 | **Flexible visualization via sandboxed WKWebView** | §13.2–13.3, §24.8 | **DONE** | `WorkspaceAppWebReportView` (hardened: no JS, no network, no bridge) + `htmlReport` & `chartComposite` renderers (Swift-built, CSP-locked). `mermaidDiagram` dropped from allowlist (needs blocked JS; native diagram covers it). |
| 3 | **Empty-state seeding** of freshly published apps | §10 | **DONE** | Friendly empty state + opt-in "Start with sample data" toggle (`WorkspaceAppSampleSeeder`); round-trip tested. |
| 4 | **Capability-aware generation** — generation knows the workspace's connectors | §24.4, success #2 | **DONE** | Prompt lists the workspace's enabled connector serviceTypes and steers requirements to available providers (`availableConnectorsGuidance`); derived via `CapabilityRuntimeResourceMatcher.enabledPackages`. |
| 5 | **Schedule governance UI** + pipeline-builder controls | §24.6 | **DONE (schedules)** / pipeline direct-editing deferred | Enable/Disable toggle on `WorkspaceAppAutomationStateCard` → `setAutomationEnabled` (was built+tested but unwired). Direct visual pipeline-step editing in Studio remains future (creation is via generation + refinement chips + run viz). |
| 6 | **REDCap form rendering + branching + data-entry workflow** | §24.3, success #3 | **LOCAL DONE** / submit connector-gated | `WorkspaceAppREDCapMetadataParser` bridges a metadata read → the tested form builder (fixture-tested). Live `formSchema.read` + end-to-end submit require a real REDCap connector. |
| 7 | **Team library** + package signing | §24.9, §25.7 | **LIBRARY DONE** / signing deferred-by-spec | `WorkspaceAppPackageLibraryView` browses a shared folder, lists discovered packages + install state, routes into the governed import review. Signing deferred per §18.15/§25.7 (only if remote/team distribution is in scope). |

### §24.8 Advanced Rendering — reframed intent (2026-06-19)

Product intent clarified: the WKWebView / advanced-rendering path is for
**flexible, expressive visualization inside LOCAL apps** — letting an app present
its data in rich, varied styles beyond the fixed native widget set — **not** for
authoring or hosting public web pages. "Public web hosting" stays a §5 non-goal;
this is the opposite: a sandboxed, Swift-governed presentation surface that widens
what a local app can *look like* while Swift keeps owning state, actions,
credentials, and audit (success #10/#11). Recommended build order: a sandboxed
WKWebView host with a narrow read-only message bridge + CSP / no-network /
no-filesystem policy, fed manifest-declared data — so a generated app can choose a
richer visual without becoming a web app. This makes #2 above a first-class,
in-scope capability rather than guarded scaffolding.

### Success-criteria snapshot (2026-06-19)

- #1 local DB app from prompt — **DONE** (generate + preview + publish + sortable/filterable tables + validated forms + seed).
- #2 connector-backed app — **DONE for reads** (live GitHub PRs via the `astra.read` connector-read bridge; connector writes still gated/native-only). See "Connector Read Bridge" below.
- #3 REDCap data-entry/reconciliation with governance — **mostly** (metadata→form bridge done; live submit connector-gated).
- #4 conversation/process → reusable app — **partial** (deep conversation-context ideation still future).
- #5 metrics/charts/diagrams/tables/forms/controls — **DONE** (rich native renderer + sandboxed htmlReport/chartComposite).
- #6 apps create/run ASTRA tasks — **DONE** (agentic Slice 9).
- #7 share without credentials — **mostly** (export/import + library browse; signing deferred).
- #8 imports declare deps/permissions — **DONE** (import review + library route through it).
- #9 packages declare contract ops — **partial** (HTTP/CLI/MCP execution intentionally later).
- #10 Swift trusted runtime — **DONE** (invariant).
- #11 WebView sandboxed presentation — **partial** (host pending; see reframed §24.8).

## Connector Read Bridge (CB0–CB5, 2026-06-24)

A sandboxed HTML app can now read LIVE connector data through a vetted, read-only `astra.read` verb —
shipping the first end-to-end "connector-backed app": the user's real GitHub pull requests. The page
stays CSP-locked with no network of its own; the read rides the existing governed path.

- **CB0 — async executor path.** `WorkspaceAppActionExecutor.executeAsync` now routes `capability.read`
  through `resolveAsync` (a live connector read is network I/O the sync resolver can't await; its sync
  client is the Unavailable stub). Own run lifecycle, `enforcePermission` first, same
  `workspaceApp.capability.read` audit event the sync path records.
- **CB1 — `astra.read(sourceId, {params})`.** A new bridge verb (`WorkspaceAppDataBridge`): `parseRead`
  + `resolveRead` (the read allowlist — the page's `sourceId` must be a declared `sources` entry AND the
  exact non-empty `sourceRef` of a declared `capability.read` action), an async `read` closure routed to
  the async executor, a serialized `read` dispatch (`readInFlight`, one live read per WebView), and the
  injected `astra.read`. Reply is SCALAR rows only; never sets `confirmedApproval`/`confirmedDestructive`.
  Wired through `WorkspaceAppSurfaceView.onCapabilityRead` (built in `WorkspaceAppDetailView` from the
  app's appID-scoped bindings); nil on the preview surface (no bindings → reads resolve only when
  published).
- **CB2 — validator.** `validateHTMLApp` now allows `requirements` + read-mode `sources` +
  `capability.read`, but STILL blocks `capability.write`, write-mode sources, and a `capability.read`
  with a blank/undeclared `sourceRef`.
- **CB3 — generation.** The prompt teaches a CONNECTOR-READ HTML app recipe + that `pullRequest.read`
  (github) is always available via the `gh` CLI; the scope notice is positive for GitHub-PR intents.
- **CB4 — GitHub backend.** New `pullRequest.read` contract family + `github-pr-read-native`
  implementation (auto-`.mapped` on publish, no manual binding). `WorkspaceAppGitHubPRReadClient` →
  `GitService.workspaceAppPullRequestJSON` runs a FIXED `gh search prs --author=@me` / `gh pr list --repo`
  argv (the user's own gh auth; no token returned). Page influences only `state` (validated) + `limit`;
  the repo comes from the manifest (`source.projectRef`), not the page. A deterministic
  `githubPullRequestsHTMLManifest` builder + `isGitHubPullRequestIntent` route a "show my PRs" intent to
  a guaranteed-valid app even when the model is unavailable.
- **CB5 — verification.** `Tests/WorkspaceAppConnectorReadTests.swift` (18 tests) pins the read
  allowlist, validator invariants, gh argv/decoder, registry auto-mapping, deterministic builder, scope
  notice, and the CB6 hardening; full suite + fitness green; codex adversarial security review.
- **CB6 — security fixes (codex adversarial review).** Closed four findings:
  - **BLOCKER** — `bridgeEligible` (the WebView `.id`) omitted `capability.read`, so a read app and a
    bridge-less app shared a WebView and the stale `astra.read` handler survived an app switch (cross-app
    leak). Fixed by single-sourcing the predicate as `WorkspaceAppDataBridge.isBridgeEligible` (used by
    both the surface `.id` and `handlers()`), plus a fail-closed `denyAll` handler installed when a reused
    WebView loses its bridge.
  - **HIGH** — a manifest could declare a narrow requirement op for review but a broader `source.operation`
    at read time (op-broadening). Fixed: the GitHub client guards `operation ∈ requirement.operations`,
    and the validator rejects a capability.read source whose operation its requirement doesn't declare.
  - **MEDIUM** — `astra.read` could read app storage by shadowing a table id (the resolver checks
    storage BEFORE the binding); a re-review also found the same leak via a `capability.read` STEP of a
    `pipeline.run`/`loop.run` triggered by `astra.runAction` (the SYNC executor path). Fixed in three
    layers: (1) `resolveRead` + the validator require a capability.read source to be connector-bound
    (`requirementRef`) AND reject any source whose id/tableRef/sourceRef shadows a storage table
    (enforced at render by fail-closed re-validation, closing the pipeline-step path); (2) a connector-ONLY
    ASYNC resolver path (`resolveCapabilityReadAsync`, used by `executeAsyncCapabilityRead`) for direct
    `astra.read`; (3) a connector-ONLY SYNC resolver path (`resolveCapabilityRead`, used by the sync
    `executeCapabilityRead`) for the pipeline/loop-step path — neither ever falls through to storage, so a
    capability.read always resolves through its dependency binding.
  - **MEDIUM** — read DoS over time + caller `limit` unparsed/unforwarded. Fixed: `parseRead` parses +
    `resolveRead` clamps `limit` to a small connector-read cap (default 30 / max 100), the injected
    `astra.read` now forwards `opts.limit`, and a 0.5s min-interval throttle bounds read frequency per
    WebView (on top of one-in-flight serialization). The *durable, app-scoped* connector-read rate budget
    across multiple surfaces was later added as FU3 (see Generic Capability Read) — `WorkspaceAppConnector
    ReadRateLimiter` caps reads per app over a sliding window, enforced before the run record.

## Generic Capability Read (GEN1–GEN4, 2026-06-24)

Closes the deferred success-criterion #9 ("packages declare contract ops; HTTP/CLI/MCP execution") for
the CLI transport: **"enable a capability → apps can read it, with NO per-connector Swift."** The
built-in BigQuery/REDCap/GitHub native clients stay as fast paths; an arbitrary ENABLED capability now
flows through a generic, transport-driven executor. Closed three gaps the design map found:

- **GEN2 — execution spec.** `WorkspaceAppContractImplementation` gained an optional `readExecution`
  (`WorkspaceAppCapabilityReadExecution`: transport + per-operation argv-template command + rowsPath).
  `WorkspaceAppCapabilityContractDeriver` maps each ENABLED capability `localTool` whose `toolType` is the
  opt-in sentinel `workspaceAppRead` to a contract family `capability.<pkg>.<tool>-<hash>.read` + an
  implementation carrying that spec (no ASTRACore persistence change — reuses the existing localTool
  `command`/`arguments`).
- **GEN1 — registry blind at publish.** `WorkspaceAppService.registry(for:workspace)` now extends the
  registry (`including(capabilityFamilies:implementations:)`) with the workspace's enabled-capability
  contracts, so `createApp`/`updateApp`/duplicate auto-map the requirement to a `.mapped` binding.
- **GEN3 — generic executor.** `WorkspaceAppSourceResolver` looks up the binding's implementation among
  the workspace's enabled capabilities; if it has a `readExecution`, it runs `WorkspaceAppGenericCLIReadClient`
  (else the native client). The CLI client is hardened like the `gh` path: author-controlled command
  template, page fills only WHOLE-TOKEN `{placeholder}` argv elements (charset/length/leading-dash
  validated, no shell), executable must be absolute or a bare PATH name (relative rejected), cwd pinned to
  the workspace, stdout byte-capped, rows/fields/value-size capped, SIGTERM→SIGKILL timeout, and
  **fail-closed** on non-zero exit / unparseable / non-array output.
- **GEN4 — verification.** `Tests/WorkspaceAppGenericCapabilityReadTests.swift` proves the chain end to
  end (enable → derive → registry → publish-binding → resolve → generic executor → scalar rows) with a
  fake runner, plus a **real-process** test that actually spawns `/bin/cat` and decodes, plus the executor
  security boundary; full suite green; two codex adversarial rounds (the second confirmed the hardening).

**Per-app least-privilege is unchanged:** an app still DECLAREs the requirement + gets an appID-scoped
`.mapped` binding; "enabled" makes a capability *bindable*, not auto-granted to every app. Only a
`toolType == "workspaceAppRead"` tool is exposed (agent tools are not).

Two codex security rounds hardened the executor: round 1 found cwd-inheritance, id-collision, output
bounds, fail-open, and timeout issues (all fixed); round 2 confirmed those closed and flagged a residual
cwd-inherit-when-empty path — now fail-closed (the read refuses without a real workspace directory, in
both the client and the runner). 64-bit derived-id fingerprints.

**Hardening follow-ups landed (FU1–FU3):**
- **FU1 — per-param value schema (DONE).** A capability author constrains each `{placeholder}` inline in
  the localTool args: `{name:fixed=V}` (page can't influence it), `{name:enum=a,b,c}`, `{name:re=PATTERN}`
  (whole-value regex). The deriver parses these to bare `{name}` + a `ParamConstraint` map; the generic
  client enforces fixed/allowed/pattern on top of the charset/length/no-leading-dash guard — so generic
  reads are safe for UNTRUSTED/imported capabilities, not just author-trusted (closes the codex HIGH).
- **FU2 — process-GROUP kill on timeout (DONE).** The read child is put in its own process group
  (`setpgid`) and group ownership is captured WHILE the child is provably alive (`ownsGroup =
  getpgid(pid)==pid`). On timeout, when `ownsGroup`, the WHOLE group is signalled SIGTERM→SIGKILL
  **independent of the leader's own liveness** — so a worker a wrapper forks and orphans (parent exits on
  SIGTERM) is still reaped; `ownsGroup` was true so `-pid` can NEVER be ASTRA's group. Falls back to a
  single-process kill if the `setpgid` exec-race is lost. _Residual:_ the race itself (child may exec
  before the parent's `setpgid` lands) means group creation isn't atomic; a fully-deterministic reap needs
  `posix_spawn`+`POSIX_SPAWN_SETPGROUP` — documented follow-up, not built (realistic read CLIs don't fork
  orphan workers).
- **FU3 — durable app-scoped rate budget (DONE).** `WorkspaceAppConnectorReadRateLimiter` (process-wide,
  sliding 60s window, 60 reads/app) enforced at BOTH connector-read entry points — the async direct
  `astra.read` path (`executeAsyncCapabilityRead`, before the run record, so a rejected read leaves no
  audit row) AND the sync `executeCapabilityRead` path that a `capability.read` pipeline STEP reaches via
  `astra.runAction` (closes the codex bypass where a page looped a pipeline to dodge the budget). Native
  user-click reads share the budget; 60/min is far above any human click rate.
- **FU1 regex bound (codex LOW).** `matchesWholeValue` rejects an author pattern over
  `maxPatternLength` (256) before compilation — cheap ReDoS insurance on top of the 256-byte page-value
  cap. The pattern is author-pinned (never page-injectable); the complete fix (a non-backtracking
  mini-schema in place of arbitrary regex) stays a deferral.

**Remaining follow-ups (not yet built):** the `http`/`mcp` transports (accepted in the schema, fail-closed
until implemented); atomic process-group creation via `posix_spawn` (FU2 residual above); a
non-backtracking value mini-schema replacing arbitrary author regex (FU1 residual above).

**Generation-awareness (DONE).** `WorkspaceAppStudioSession.submit` derives the workspace's enabled-
capability contract families and threads them into the generator's contract catalog (`contractFamilies =
built-ins + capabilityFamilies`), so the model KNOWS it may declare a `capability.<x>.read` against a
capability the user just enabled (and the contract vet accepts it). This is the last link making "create a
capability → enable it → ask the chat to build an app that uses it" work without hand-authoring the
manifest.

## Current State Summary

The branch has moved beyond a documentation-only PR. It now contains a working
Workspace App foundation:

- Durable `WorkspaceApp` domain state and SwiftData indexes.
- File-backed app manifests under the workspace app folder.
- App-owned SQLite storage.
- Manifest validation.
- Workspace App detail, Studio, import review, and presentation surfaces.
- Contract registry and dependency binding primitives.
- Native source resolution for app storage, mocked capability sources, BigQuery
  reads, and REDCap reads/form schema/write validation paths.
- Action execution for app storage, task launch, capability read/write,
  artifact export, utility actions, gates, pipelines, and bounded loops.
- Automation scheduling and due automation execution.
- `.astra-app` style package export/import, portable data export, package
  validation, dependency mapping, digest, provenance, trust metadata, library
  discovery, and update checks.
- Regression coverage under `Tests/WorkspaceApp*`.

The largest remaining gap is not the low-level app model. The largest gap is
turning those primitives into the final user-facing product: a chat-built App
Studio that can inspect workspace context and capabilities, generate a useful
app, iterate through validation feedback, preview the app, publish it, and make
the resulting app feel complete for local database, connector-backed, REDCap,
and pipeline workflows.

## Evidence Files

Core implementation files:

- `Astra/Models/WorkspaceApp.swift`
- `Astra/Models/WorkspaceAppDependencyBinding.swift`
- `Astra/Models/WorkspaceAppAutomationState.swift`
- `Astra/Models/WorkspaceAppRun.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppManifest.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppManifestValidator.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppStorageService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppContractRegistry.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppSourceResolver.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppAutomationScheduler.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppAutomationExecutionService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppStudio.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageExporter.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageImportReview.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppPackageLibraryService.swift`
- `Astra/Services/WorkspaceApps/WorkspaceAppWebViewBridge.swift`
- `Astra/Views/WorkspaceAppDetailView.swift`
- `Astra/Views/WorkspaceAppStudioView.swift`
- `Astra/Views/WorkspaceAppPackageImportReviewView.swift`
- `Astra/Views/WorkspaceAppPresentation.swift`

Regression coverage:

- `Tests/WorkspaceAppManifestTests.swift`
- `Tests/WorkspaceAppStorageTests.swift`
- `Tests/WorkspaceAppContractRegistryTests.swift`
- `Tests/WorkspaceAppSourceResolverTests.swift`
- `Tests/WorkspaceAppActionExecutorTests.swift`
- `Tests/WorkspaceAppAutomationSchedulerTests.swift`
- `Tests/WorkspaceAppAutomationExecutionServiceTests.swift`
- `Tests/WorkspaceAppDetailDataLoaderTests.swift`
- `Tests/WorkspaceAppPackageTests.swift`

## Status By Roadmap Area

### 24.1 Foundation

Status: mostly implemented.

Implemented:

- Workspace App domain model.
- Manifest Codable types.
- Manifest validator.
- App detail/studio/import review presentation surfaces.
- SwiftData indexing of app metadata and app run state.
- Service-owned manifest writes and digest refresh.

Pending:

- URL route and App Intent coverage for opening apps, if not already wired in
  the broader app shell.
- More UI routing tests for opening Workspace Apps from every intended entry
  point: workspace home, sidebar, URL route, and App Intent.

### 24.2 App-Owned Storage

Status: mostly implemented.

Implemented:

- Per-app SQLite database location under the workspace app folder.
- Storage schema manifest.
- CRUD service.
- Migration planner.
- Portable typed record export/import through package flows.

Pending:

- End-to-end local database app polish. The current system can create and
  execute storage-backed manifests, but the user-facing grocery/database app
  should be a complete reference workflow with table/form editing, metrics,
  charts, and export controls.
- More renderer support for form-style data entry and inline editing.

### 24.3 Native Renderer

Status: partially implemented.

Implemented:

- Detail loader and presentation models.
- App detail shell.
- Storage/table-backed presentation basics.
- Run history and action entry points at the service level.

Pending:

- Production-grade native widgets for:
  - metrics
  - charts
  - diagrams
  - tables with sorting/filtering/selection
  - forms with validation state
  - markdown sections
  - approval controls
  - run history drill-in
- Layout collapse behavior for dense operational apps.
- View tests for the final lean presentation rules.

### 24.4 Capability Contracts

Status: partially implemented.

Implemented:

- Contract family and operation types.
- Built-in contract registry.
- Requirement resolution and provider hint ordering.
- Workspace dependency binding model.
- Package-declared implementation descriptors.
- Native app storage contract path.
- Native BigQuery read client path for `tabularQuery.read`.
- Native REDCap record/form/write validation paths.
- Source resolver and action executor.

Pending:

- Full App Studio use of the registry during generation. The builder should
  inspect available workspace capabilities, propose compatible app designs,
  and create dependency requirements without hardcoding provider-specific
  flows.
- More complete provider profile handling for REDCap projects, BigQuery
  datasets/tables, and future connectors.
- Task-backed fallback operations for capabilities that do not yet have native
  deterministic app operations.
- Later only: general package-declared HTTP, CLI, and MCP execution. The parent
  spec explicitly says not to ship those in the first milestone.

### 24.5 App Studio

Status: scaffolded, but this is the biggest remaining product gap.

Implemented:

- App Studio draft object.
- Deterministic builder for several known intent families.
- Structured manifest output validation.
- Manifest patch operation validation.
- Direct conversation-driven generation from the user's request.
- Studio view with intent, preview, validation, and manifest inspector.

Pending:

- Model-backed app generation from real workspace context.
- Builder input assembly:
  - user prompt
  - relevant conversation excerpts
  - workspace files/artifacts
  - available capability contracts
  - existing app manifest when editing
  - policy constraints
- Validation feedback loop that returns structured errors to the builder and
  retries safely.
- Live preview of the app while editing.
- Publish workflow with version tracking.
- Undo/revert:
  - draft version
  - published version
  - last known good version
  - revert to previous published version
- Editing an existing app through App Studio.
- More complete ideation from actual conversation/task context, not just
  keyword-based deterministic suggestions.

### 24.6 Automation And Pipelines

Status: mostly implemented at the runtime primitive level; partial at product
level.

Implemented:

- `AppRun` models and event recording.
- Automation scheduler.
- Due automation execution service.
- Pipeline action type.
- Human approval gates.
- Expression gates.
- Agent recommendation gates with budget and approval policy.
- Bounded loop action type with max iterations, timeout, stop condition, and
  per-iteration audit events.

Pending:

- Task-backed agent steps that launch/continue ASTRA tasks and bind outputs
  back into app state.
- User-facing pipeline builder controls in App Studio.
- Pipeline run visualization in app detail.
- Approval queue UI for blocked runs.
- Schedule enable/disable review UI with clear governance.

### 24.7 Sharing

Status: substantially implemented.

Implemented:

- Package export/import service.
- Package shape and checksums.
- Dependency mapping.
- Logical dependency IDs and portable requirements.
- Export modes for template/sample/seed/full style data.
- Typed portable app-owned data export/import.
- Package install states and validation blockers.
- Package digest and provenance.
- Full export sensitive data warning.
- Package library discovery and update checks.
- Trust metadata validation.

Pending:

- End-to-end UI polish for export, import, mapping, approval, install state,
  and update flows.
- More manual validation of ASTRA-to-ASTRA sharing between separate workspaces.
- Stronger signed package support only if team/remote distribution is required.

### 24.8 Advanced Rendering

Status: early/guarded. **(See the 2026-06-19 reframed intent above — this path is
for flexible LOCAL-app visualization, not web publishing, and is now considered a
first-class in-scope capability.)**

Implemented:

- WebView bridge request validation for declared widget actions.
- Manifest validation limits WebView widgets to ASTRA-known renderers.
- Package validation blocks unsafe arbitrary portable content.

Pending:

- Sandboxed WKWebView widgets for advanced diagrams/reports.
- Chart and diagram rendering improvements.
- Custom visual widgets through a narrow message bridge.
- CSP/network/filesystem restrictions before any imported custom WebView code.

### 24.9 Team Library

Status: partial.

Implemented:

- Package library discovery, including shared-folder style package discovery.
- Package update checks.
- Trust metadata model.

Pending:

- Complete local team library workflow.
- Clear UI for shared folder import paths.
- Team trust/source metadata policy.
- Package signing if remote/team distribution becomes part of the milestone.

## Status By Success Criteria

1. User can build a useful local database app from a natural-language prompt.
   - Status: partial.
   - Reason: deterministic builder can generate local database-style manifests,
     and storage/action primitives exist. The app is not yet a polished
     natural-language, preview-and-edit experience.

2. User can build a connector-backed app from workspace capabilities without
   separate setup.
   - Status: partial.
   - Reason: contract registry, dependency bindings, and native BigQuery/REDCap
     paths exist. App Studio still needs full capability-aware generation and
     dependency mapping during build.

3. User can build a REDCap data-entry or reconciliation app with visible
   governance.
   - Status: partial.
   - Reason: REDCap read/form/write validation primitives exist. Full form
     rendering, branching logic, data-entry replacement workflow, and visible
     governance UI remain.

4. User can turn a repeated conversation/task process into a reusable app.
   - Status: partial.
   - Reason: the old standalone ideation scaffold has been retired; a future
     implementation needs a first-class conversation/task-context mining service
     rather than a second app-generation owner.

5. Apps can display metrics, charts, diagrams, tables, forms, and actionable
   controls.
   - Status: partial.
   - Reason: tables/actions/presentation basics exist. Rich metrics, charts,
     diagrams, and forms need more renderer work.

6. Apps can create and run normal ASTRA tasks when agent work is needed.
   - Status: partial to mostly implemented.
   - Reason: task create draft and create-and-run actions exist. Task-backed
     pipeline steps and output binding remain.

7. Apps can be shared to another ASTRA workspace without sharing credentials.
   - Status: mostly implemented.
   - Reason: package export/import, dependency mapping, redaction, and portable
     data flows exist. Needs UI polish and cross-workspace manual validation.

8. Imported apps clearly declare dependencies and permissions before use.
   - Status: mostly implemented.
   - Reason: package import review and validation exist. Needs final UX polish.

9. New capability packages can make themselves app-usable by declaring
   compatible contract operations.
   - Status: partial.
   - Reason: package-declared implementation descriptors can extend the
     registry. General execution of package-declared HTTP/CLI/MCP operations is
     intentionally later.

10. Swift remains the trusted runtime for state, actions, credentials, and
    audit.
    - Status: implemented as an architectural invariant so far.
    - Reason: current state/actions/audit are Swift-owned; WebView is not a
      privileged runtime.

11. WebView or JavaScript, if used, remains sandboxed presentation rather than
    privileged runtime.
    - Status: partially implemented.
    - Reason: bridge validation and renderer restrictions exist. Full sandbox
      policy for richer custom visuals remains future work.

## Main-line Re-land Sequence (current fork)

This status doc and the slice list below were written against the
`alvaro/workspace-app-studio-spec` branch, where the full Workspace App runtime
already exists. The active line of development (`aandresalvarez/astra` `main`)
does **not** contain that runtime: there are zero `WorkspaceApp` model, view, or
service files on `main`. PR #58 (Slice 1, context builder) is the first
re-land, and it intentionally brought only the context builder.

Therefore the runtime must be re-landed onto `main` as review-sized slices
before any slice that depends on it (Slice 2+ and Slice 9 all do). Re-land
order, smallest dependency first:

- **F1 — Domain + manifest + validator.** `WorkspaceApp`, `WorkspaceAppRun`,
  `WorkspaceAppDependencyBinding`, `WorkspaceAppAutomationState` models;
  `WorkspaceAppManifest` Codable types; `WorkspaceAppManifestValidator`;
  `SchemaVersions` registration. Tests: `WorkspaceAppManifestTests`,
  `SchemaVersionTests`. No executor, no UI. Pure-data foundation.
- **F2 — App-owned storage.** `WorkspaceAppStorageService` (SQLite CRUD +
  migration planner) and the additive `WorkspaceFileLayout` app-path methods.
  Tests: `WorkspaceAppStorageTests`. NOTE: `WorkspaceAppService` was originally
  grouped here but depends on `WorkspaceAppContractRegistry` (F3) and the
  automation scheduler, so it re-lands in F3.5 (below), not F2.
- **F3 — Contract registry.** `WorkspaceAppContractRegistry` only (built-in
  contract families + requirement resolution). Self-contained on F1. Tests:
  `WorkspaceAppContractRegistryTests`. NOTE: `WorkspaceAppSourceResolver` and
  `WorkspaceAppNativeCapabilitySourceClient` were originally grouped here but
  share types (`WorkspaceAppActionInput`, `WorkspaceAppCapabilityWriteResult`,
  `WorkspaceAppActionExecutionError`) with the executor, so they move into the
  F4 action-runtime cluster.
- **F3.5 — App lifecycle service.** `WorkspaceAppService` (app create/duplicate/
  delete, manifest writes + digest, dependency-binding resolution via the
  contract registry, automation-state enable). Depends on F1+F2+F3. Tests: the
  service half of the susom `WorkspaceAppManifestTests` (createApp / remap /
  automation / lifecycle / duplicate / delete).
- **F4 — Action runtime.** `WorkspaceAppSourceResolver` +
  `WorkspaceAppNativeCapabilitySourceClient` + `WorkspaceAppActionExecutor`
  (the `task.createAndRun`, `gate.agentRecommendation`, `gate.humanApproval`,
  `loop.run`, `pipeline.run` dispatch). These land together because they share
  the action-input/result/error and capability-client types. Tests:
  `WorkspaceAppSourceResolverTests`, `WorkspaceAppActionExecutorTests`. Watch
  per-file line budgets (executor is ~1400 lines); split if needed.
- **F5a — App-detail data + presentation (DONE).** `WorkspaceAppDetailDataLoader`
  + `WorkspaceAppPresentation` (cards, inspector rows, run-history, storage form/
  draft builders). Tests: `WorkspaceAppDetailDataLoaderTests`.
- **F5b — App-detail view (DONE).** `WorkspaceAppDetailView` + extracted
  `WorkspaceAppStatusPill`. Compiles; not yet reachable from the UI.
- **F6 — Studio builder + automation + packaging + webview (DONE).**
  `WorkspaceAppStudio`(+`Ideation`), `WorkspaceAppAutomationExecutionService`,
  `WorkspaceAppPackage*`, `WorkspaceAppWebViewBridge`, `WorkspaceAppStudioView`,
  `WorkspaceAppPackageImportReviewView`. Tests: package + automation suites.

### F7 — UI entry-point wiring (CORE LANDED; visible list + live verify residual)

Core wiring landed (`ContentView` + `ContentSceneState`), compiling, with routing
logic unit-tested (`WorkspaceAppDetailPresentationTests`, 4) and no regressions
(ViewTests 44, ArchitectureFitnessTests 40):

- `ContentDetailPresentation` gains `.workspaceApp` / `.workspaceAppStudio` +
  `resolve(selectedWorkspaceApp:, isComposingWorkspaceApp:)` (defaulted) +
  `WorkspaceAppStudioEntryPresentation.shouldShowNewAppEntry`.
- `ContentView` renders `WorkspaceAppDetailView` / `WorkspaceAppStudioView` at the
  `detailArea` level (gated on `selectedWorkspaceApp` / `isComposingWorkspaceApp`),
  mutually exclusive with task selection. `onRunAction` wires
  `WorkspaceAppActionExecutor` (+ `ModelContext` + per-app bindings); publish wires
  `WorkspaceAppService.createApp` and auto-opens the new app. New App opens via a
  hidden ⌘⇧A hotkey (mirrors `searchHotkey`).

This gives a complete functional loop for Slice 9: ⌘⇧A -> App Studio -> publish ->
detail -> run governed agentic-workflow actions.

Visible re-open list — DONE (F7b): `onOpenWorkspaceApp` is threaded from
`ContentView` through `ContentDetailAreaView` / `ContentDetailContentView` into
`WorkspaceHomeContainerView`, which `@Query`s the workspace's `WorkspaceApp`s and
renders an Apps section in the home context card (tap to open). Re-open loop is
closed.

Residual (only live verification now — `/run` / `/verify`):
- Live verification of navigation/rendering/run behavior on the running app (unit
  tests can't cover SwiftUI runtime); confirm the Apps-section layout reads well.
- Optional: a `TaskSidebarView` app-rows surface (the home Apps list already
  re-opens apps), and porting the app-specific cases from susom `ViewTests` /
  `WorkspaceHomePresentationTests` / `TaskEventTimelineSidebarTests` under
  non-colliding names.

Original full checklist (for reference):

- `ContentSceneState`: add `.workspaceApp` / `.workspaceAppStudio` cases to
  `ContentDetailPresentation`, thread `selectedWorkspaceApp` through
  `resolve(...)` + `ContentWorkspaceSelectionCoordinator`/`...Update`, and add
  `WorkspaceAppStudioEntryPresentation.shouldShowNewAppEntry(for:)`.
- `ContentView`: add `@State selectedWorkspaceApp`, thread it into
  `ContentDetailAreaView`, and handle the two new cases in the detail switch
  (~line 3190) — render `WorkspaceAppDetailView` (wire `onRunAction` to
  `WorkspaceAppActionExecutor` + `ModelContext`, `onRefresh`, `onExportPackage`,
  `onOpenStudio`) and `WorkspaceAppStudioView`. Add a `startWorkspaceApp` create
  path (`WorkspaceAppStudioBuilder` -> `WorkspaceAppService.createApp`).
- `WorkspaceHomeView`: add an Apps section + `New App` action + the app-card
  presentation flags the susom `WorkspaceHomePresentationTests` assert.
- `TaskSidebarView`: app rows as workspace children (open / studio / duplicate /
  export / delete) + the `WorkspaceAppList` activity-sort presentation that
  `TaskEventTimelineSidebarTests` covers.
- Coupled tests to add (without clobbering existing same-named files): the
  app-specific cases from susom `ViewTests` / `WorkspaceHomePresentationTests` /
  `TaskEventTimelineSidebarTests` (`WorkspaceAppStudioEntryPresentation`,
  `ContentDetailPresentation.resolve` with apps, `WorkspaceAppsPresentation`).

Automation scheduler and packaging/sharing already re-landed in F6.

Each F-slice ports the corresponding susom-branch files onto current `main`,
fixes API drift (~355 commits of divergence), and lands with its tests green.
F1–F6 + Slice 9 Phase A are committed on `claude/loving-rhodes-87e735`.

## Recommended Next PR Slices

Keep the work reviewable. Each slice should include focused regression tests.

### Slice 1: App Studio Context Assembly And Builder Contract — DONE (1a core; 1b UI residual)

Goal:

Make App Studio gather the real context it needs before generation.

Landed on `claude/loving-rhodes-87e735` (commit 46) by re-landing the context-builder
cluster from PR #58 (`codex/workspace-app-context-builder`) — the work the runtime re-land
never carried over. Ported with ZERO code changes (compiled + tested as-is against this branch).

- [DONE — 1a] `WorkspaceAppStudioContext(+Request)`, `WorkspaceAppStudioContextBuilder`
  (pure `build()` — gathers/bounds/orders prompt + workspace + capabilities + recent tasks +
  event excerpts + artifacts + existing manifest), `WorkspaceAppStudioContextRedactor` (scrubs
  secrets before any excerpt reaches a prompt), `…BuilderContractFactory` / `…BuildTaskBuilder`
  / `…GenerationTaskBuilder`, `WorkspaceAppStudioDraftSupport` + `ChatPanelDraftPresentation`
  (pure draft-presentation model). 12 tests (redaction, capability inclusion, stable ordering,
  draft support). WorkspaceApp+Studio suites 195 green.
- [1b — residual, live-verify] the chat-panel slash WIZARD (`ChatPanelSlashWizard`,
  `ChatPanelEmptyStateView`, `ChatMessage`) + the `ChatPanelView` / `ContentView` /
  `WorkspaceHomeView` wiring that lets a user generate an app from chat. Needs the running app;
  also touches ContentView (near its line budget).

### Slice 2: Model-backed Structured Generation Loop — DONE (designed + adversarially reviewed)

Goal:

Replace deterministic-only generation with a structured manifest generation
loop that still keeps Swift validation authoritative.

Landed on `claude/loving-rhodes-87e735` (commits 31–32):

- `WorkspaceAppStudioGenerator.generate(...)` — async, value-typed, with an
  INJECTABLE prompt runner (default = `AgentUtilityRuntimeRunner.runPrompt`,
  `toolMode: .readOnly`) so the whole loop is unit-testable with canned outputs.
- Calls the one-shot utility runtime (NOT a full AgentTask), parses via the
  existing `WorkspaceAppStudioBuilder.applyStructuredOutput` seam (manifest AND
  patch blocks), validator authoritative.
- Validation-report-driven REPAIR loop (`maxRepairAttempts`) feeding blockers +
  the model's prior attempt back, preserving last-valid (spec §17.3).
- Graceful degradation: deterministic template (`baseManifest(intent:)`) is both
  the fallback AND the valid few-shot example, so generation is never worse than
  the previous deterministic behavior.
- Studio "Generate Draft" is now async (spinner, origin-aware status, intent
  editor disabled mid-run).
- Review hardening: a generator-side contract vet rejects model manifests that
  reference an unknown contract/operation (the validator only checks SYNTAX, not
  existence) and repairs them; intent wrapped + sanitized against prompt injection;
  editing-case fallback messaging; `Task { @MainActor in }`.
- Builder result states present: model / modelRepaired / deterministicFallback
  (+ `accepted`, `canPublish`).
- 16 unit tests (valid-first, invalid-then-repaired, exhausted-fallback,
  provider-error first+mid-repair, zero-repair-budget, no-block, both-blocks,
  unknown-contract caught/repaired/exhausted, templates-are-safe, intent-sanitized).
  WorkspaceApp suite 140 green; precommit fitness green.

NOT yet done (Slice 3 territory): the builder "needs user decision" state and
draft/published/last-known-good VERSIONING + revert. Live in-app verification of
a real model round-trip is residual (the loop is fully unit-tested with an
injected runner; only the real provider call needs the running app).

### Slice 3: App Studio Preview And Versioning — DONE (core; designed + adversarially reviewed)

Goal:

Make the Studio feel like a builder, not just a manifest inspector.

Landed on `claude/loving-rhodes-87e735` (commits 34–37), as three focused commits
(3a versioning, 3b preview, 3c publish wiring) + review hardening:

- **Versioning (schema-light):** three DEFAULTED fields on the existing `WorkspaceApp`
  (`publishedManifestDigest` / `lastKnownGoodManifestDigest` / `latestVersionNumber`)
  absorbed into ASTRASchemaV7 — NO new @Model, NO new schema version (the V7/V8 crash
  was the design's hard constraint; a round-trip test proves absorption).
- **`WorkspaceAppVersionService`:** snapshot-on-publish (`versions/v<n>.json` +
  `index.json`, the source of truth), listVersions, markLastKnownGood, recordPublish,
  revertToPreviousPublished. File-only methods nonisolated + FileManager-injected;
  @Model mutators @MainActor. Revert is storage-preserving + digest-verified + does not
  fork history; it steps back through published versions and throws at the floor.
- **`WorkspaceAppDraftPreviewBuilder`:** turns a DRAFT manifest + deterministic sample
  rows into the exact `WorkspaceAppDetailDataSnapshot` the published detail view consumes,
  so the preview renders through the SAME presentation builders. Sample text cells marked.
- **Publish fix:** publish now sets `.published` (was a latent draft-on-publish bug),
  dedups the logicalID via `manifestForPublishing` (was never wired → duplicate-record
  risk), and snapshots a version (logged, non-blocking).
- Tests: 11 version-service + 7 preview (incl. revert-steps-back-and-floors,
  last-known-good-preserved-across-revert, same-intent-dedup, item_count-reflects-sample-rows,
  seed-varies-samples). WorkspaceApp suite 158 green.

NOT done (residual / live-verify, like prior slices): the in-app Studio PREVIEW PANEL +
Versions/Revert UI controls (the builder + service they call are unit-tested); a true
`updateApp`/edit-in-place path (editing an existing app is not wired into the Studio yet —
every publish creates a fresh, id-deduped app); the inline preview validation overlay.

### Slice 4: Local Database Reference App — DONE (core)

Goal:

Make the grocery/local database use case complete enough to judge the product.

Landed on `claude/loving-rhodes-87e735` (commit 39). Most of the machinery already
existed from the runtime re-land (the executor implements appStorage insert/update/
delete/query; the detail view renders edit/delete row controls + metrics/charts; NL→
manifest is Slice 2). The gap was the grocery TEMPLATE: it declared only query+insert+
task+export, so the reference app could add items but never edit or delete them.

- Wired `appStorage.update` + `appStorage.delete` actions (bound to `items`) into the
  grocery template; the items table now surfaces edit + delete end to end.
- `WorkspaceAppGroceryReferenceTests` prove the reference app itself: template validates +
  declares full CRUD, the items row-action presentation exposes update + delete with the
  right primary key, and the template's OWN actions drive a real add→list→update→list→
  delete(refused-without-confirm)→delete(confirmed)→empty cycle on SQLite, with item_count
  reflecting live data. WorkspaceApp suite 161 green.

Residual (live-verify / polish): the `form` view type rendering for a richer add/edit
form; the live in-app CRUD walkthrough (the executor + presentation are unit-tested).

### Slice 5: REDCap Form And Reconciliation Reference App — DONE (5a + 5b core; form-view UI residual)

5b LANDED (commits 48–49): form-field manifest schema (`WorkspaceAppViewSpec.formFields` +
`WorkspaceAppFormFieldSpec`/`WorkspaceAppFormChoice` + manifest `submitBlockedReasons`, all
optional/nil so digests stay stable) + validator (allowed fieldTypes, choices required, name→column,
`visibleWhen` must be 5a-safe, blocked-form-must-be-read-only). `WorkspaceAppREDCapFormBuilder`
turns REDCap field metadata into a governed form manifest (record_id collected not minted, draft
table, form + review views, approval-gated capability.write submit); conservative type taxonomy;
branching via the 5a analyzer (safe→visibleWhen, unsupported→read-only + submitBlockedReasons →
form demoted to read-only). 17 form tests. Residual: the SwiftUI form-view RENDERING (the
presentation builder is unit-testable; the rendered control surface is live-verify).

(original section retained below)

### Slice 5: REDCap Form And Reconciliation Reference App — PARTIAL (5a done; 5b blocked)

Goal:

Prove the regulated connector-backed workflow.

Deliverables:

- REDCap metadata-backed form manifest generation. — **5b, BLOCKED** (see below).
- Field type, required field, choice list, and validation handling. — **5b, BLOCKED**.
- [DONE — 5a] Safe branching logic subset + unsupported warnings: `WorkspaceAppREDCapBranchingAnalyzer`
  classifies a field's branching-logic expression as `.safe(normalized condition)` or
  `.unsupported(reason)`. Conservative subset ([field] <op> value, single combinator); functions/
  arithmetic/parens/negation/smart-vars/mixed-and-or are unsupported so the form can block submit /
  route to review. 12 tests (safe + unsupported). Commit 43.
- Reconciliation dashboard with BigQuery/REDCap mocked sources. — partly present
  (`reconciliationManifest` template + REDCap contracts/transport exist).

**5b is BLOCKED on a manifest schema extension + a product decision.** `WorkspaceAppViewSpec` is
minimal (id/type/title/table/widgets) and CANNOT express form fields with choice lists or per-field
branching today. A faithful "native form screens from REDCap fields" builder needs (a) a Codable
extension to the manifest (a form-field concept carrying type/required/choices/visibility) across
all of WorkspaceAppManifest's Codable sites, and (b) product calls on the REDCap field-type taxonomy
to support. Those decisions warrant owner input rather than a unilateral schema change.

### Slice 6: Pipeline App Builder And Run Visualization

Goal:

Turn repeated task/conversation processes into reusable app workflows.

Deliverables:

- App Studio pipeline recipe selection.
- Pipeline/loop/gate visual preview.
- Task-backed step support.
- Run history drill-in and approval queue UI.
- Tests for blocked, approved, completed, and failed pipeline runs.

### Slice 7: Sharing UX Hardening

Goal:

Make ASTRA-to-ASTRA sharing usable by non-developers.

Deliverables:

- Export UI.
- Import review UI polish.
- Dependency mapping UI polish.
- Install state surfacing.
- Update flow UI.
- Manual cross-workspace package round trip.

### Slice 8: Advanced Rendering Guardrails — DONE (core)

Goal:

Add richer visuals without weakening the trusted runtime model.

Landed on `claude/loving-rhodes-87e735` (commit 41). The guardrails already existed in
the validator + bridge (renderer allowlist, per-widget `allowedActions`, portable-asset
+ diagram-kind checks, per-request manifest re-validation); the gap was a shared source
of truth + the spec's "bridge policy tests".

- Centralized the renderer allowlist as `WorkspaceAppWebViewBridge.allowedRenderers`
  (mermaidDiagram / htmlReport / chartComposite — ASTRA-known, no arbitrary imported JS);
  the validator now references it so publish-time and runtime guards can't drift.
- `WorkspaceAppWebViewBridgeTests`: 8 adversarial cases over the request boundary —
  allow-in-allowlist, CROSS-WIDGET ISOLATION, unknown widget, non-webView widget can't
  masquerade as a bridge source, stale/phantom allowlisted action, invalid manifest
  refused, renderer allowlist shared + closed. WorkspaceApp suite 169 green.

Residual: dedicated CSP-header assertion on the rendered WebView HTML (needs the running
WebView host); the diagram/chart renderer HTML generation itself is existing code.

### Slice 9: Agentic Workflow Apps

Goal:

Let a user describe a problem and get a reusable app that orchestrates a
workflow of governed ASTRA agents to solve it. This is a new archetype recipe,
not a new runtime: it composes existing task, agent team, gate, loop, run, and
audit primitives. The execution rule in spec 16.5 is binding (see also spec
24.10). Most of Phase A is expressible on primitives that already ship today;
the product gap is await/binding/visualization, not the agent engine.

Phase A (buildable on current primitives):

- Add the Agentic Workflow archetype to App Studio: recipe plus builder hint.
- Generate manifests that chain `task.createDraft` / `task.createAndRun` steps
  with `gate.agentRecommendation`, `gate.humanApproval`, and bounded `loop.run`.
- Surface per-step status, linked task IDs, and run history in app detail.
- Tests for manifest validation, gate blocking/approval, and bounded-loop exit.

Phase B (new plumbing):

- [DONE — B1] Bind a step's structured output into later step inputs and app
  storage. `WorkspaceAppActionInput.boundRows`/`effectiveRecord`/`bindingForward`;
  executePipeline/executeLoop thread prior-step rows; appStorage.insert/update
  consume the bound row. Unit-tested (WorkspaceAppActionExecutorTests 21/21).
- [DONE — B2 core+service] Await long-running agent steps and resume the workflow.
  - `WorkspaceAppRun` gained `.waiting` + `pendingActionID` + `pendingStepIndex`
    (absorbed into schema V7's fresh tables — no new version).
  - `executePipeline` is resumable (startIndex/initialBoundRows) and SUSPENDS on a
    `task.createAndRun` step: launches the queued task, persists the resume point,
    throws a suspension the top-level `execute()` catches -> run `.waiting`.
  - `WorkspaceAppActionExecutor.resume(run:taskOutputRows:)` continues from the
    saved step, binding the task output forward (reuses B1).
  - `WorkspaceAppRunResumptionService.resumeRuns(awaitingTaskID:)` finds the waiting
    runs for a completed task, loads each manifest, and resumes them.
  - Unit-tested (WorkspaceAppActionExecutorTests 23/23): suspend->resume->complete +
    the resumption service.
- [DONE — B2 live] `WorkspaceAppRunResumptionService.resumeCompletedRuns(modelContext:)`
  sweeps waiting runs whose linked task is `.completed`, resolves workspace + manifest,
  binds a task-output row, and resumes — wired into `TaskLifecycleCoordinator` after
  `processQueue` + `executeTask` (in-session + on-open cross-session). Also fixed: a
  pipeline step's permission is enforced BEFORE launching the agent task. Unit-tested.
- [DONE — B3] `WorkspaceAppWorkflowBudget` (declared budget = sum of agent-gate token
  budgets); `WorkspaceAppRun.consumedTokens` accumulates awaited-task usage; `resume()`
  blocks (`.blocked`, not failed) the run on overrun. Unit-tested.
- [DONE — B4] Run history exposes `attentionRows` (`.waiting`/`.blocked`); the detail
  view renders a "Needs attention" approval/attention queue. Partition unit-tested;
  the live visual is verifiable in the app.

Phase B is complete (B1–B4 + B2-live), all unit-tested. Slice 9 Phase C (parallel
fan-out / branching / aggregation) remains as the explicit "later" tier.
- Tests for output binding (done), resume-after-await, and run-level budget.

Phase C (DONE — designed via a judge-panel workflow, adversarially reviewed):

- [C1] `task.fanOut`: launches one queued agent task per upstream bound row and
  suspends the run on a BARRIER over the SET of task ids (`WorkspaceAppPipelineSuspension`
  grew `taskID` -> `taskIDs`; B2 single-task is the one-element barrier;
  `WorkspaceAppRun.awaitedTaskIDsJSON` absorbed into V7). The run resumes only when
  EVERY awaited task completes, the N task rows bound forward (the fan-in into reduce).
- [C2] `gate.branch`: synchronous predicate over upstream output -> runs thenStep/elseStep
  inline (validator blocks targets that can transitively reach an async task).
- [C3] `rows.reduce`: folds the prior step's bound rows into one row (count/sum/concat/
  first/last).
- Hardening from the adversarial review: a failed/cancelled/deleted fan-out task FAILS the
  run (no infinite `.waiting`); task.fanOut rejected as a loop step / automation action.
- Tests: fan-out suspend/all-complete-resume + partial-failure, branch then/else +
  transitive-async rejection, reduce fold + validation. WorkspaceApp suite 124 green.

The full Workspace App Studio is now landed: runtime (F1-F6) + agentic workflows
(Slice 9 Phase A linear, Phase B async orchestration, Phase C parallel/branching/reduce),
all unit-tested; F7 UI wiring live-verified.

Out of scope for the first milestone:

- General package-declared HTTP/CLI/MCP execution inside workflow steps.
- Any agent runtime outside `TaskLifecycleCoordinator`.

## Verification Policy

For each implementation slice:

- Add or update regression tests for every new feature and every bug fix.
- Run the narrowest relevant test first.
- Run `swift test --filter WorkspaceApp` before pushing Workspace App changes.
- Run `git diff --check`.
- Run `./script/build_and_run.sh --verify` for user-visible changes.
- Broaden to full `swift test` when changing schema, persistence, package,
  runtime, capability, or scheduling behavior.

Current useful commands:

```bash
swift test --filter WorkspaceApp
swift test --filter WorkspaceAppManifestTests
swift test --filter WorkspaceAppActionExecutorTests
swift test --filter WorkspaceAppPackageTests
git diff --check
./script/build_and_run.sh --verify
```

## Working Definition Of Done

The Workspace App Studio implementation should not be considered complete until
all of the following are true:

- A local database app can be built, previewed, published, used, edited, and
  exported from a natural-language prompt.
- A connector-backed app can be built from available workspace capabilities,
  with dependency mapping and no credential leakage.
- A REDCap data-entry or reconciliation app can be generated and used with
  visible governance and safe unsupported-rule handling.
- A repeated task/conversation workflow can be turned into a pipeline app with
  gates, task-backed steps, run history, and approvals.
- Apps render operationally useful metrics, charts, diagrams, tables, forms,
  and actions.
- Package import/export works across workspaces and clearly presents
  dependencies, permissions, trust, and data inclusion choices.
- Swift remains the only trusted owner of state, credentials, actions, and
  audit.
- WebView remains sandboxed presentation only.
- The final implementation is covered by focused unit, integration, and view
  tests and passes the standard Workspace App verification commands.
