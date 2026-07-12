# Host-Control Block Remediation Plan (task 9FA6AF3D incident)

**Date:** 2026-07-10
**Source incident:** Diagnostics report 2026-07-10 19:06 (+ follow-up window to 22:53), task `9FA6AF3D`, workspace `95DFEB3A`
**Status:** PROPOSED — Phase 0 is diagnosis; Phase 2 has a product decision gate (D1)

---

## 1. Incident summary

Task `9FA6AF3D` (uses the `github-workflow` capability → requires ASTRA's host-control MCP
route for `github`) was blocked twice in one day on `cursor_cli`, with two different block
reasons, through two different code paths:

| Time (PDT) | Event | Binary | Code path |
| --- | --- | --- | --- |
| 18:09:17 | `worker.blocked reason=host_control_plane_unsupported_runtime required_host_control_tools=github` | **Stale** (pre-2026-07-04 field shapes) | Legacy block recorder (dead on HEAD) |
| 18:09:24 | User retry → queued | same | — |
| 18:29:02 | `runtime_compatibility_reroute from_runtime=cursor_cli to_runtime=codex_cli` (old field format) | same stale binary | Legacy reroute path |
| ~22:42 | Codex run completes fine | new build (e17caf79, built 18:51) | — |
| 22:46:15 | User explicitly switches task runtime → `cursor_cli` (`task_runtime_changed`, trace `ui-e1bf6d12`) | new | UI |
| 22:49:33 | Resume launches on cursor; **no reroute event**; resolver keeps cursor | new | `AgentRuntimeLaunchRuntimeResolver` |
| 22:49:34 | `runtime.command_planned diagnostics_blocked=1` → `worker.blocked reason=policy_blocked` → task `pending_user` | new | Policy render diagnostics gate |

Cursor CLI genuinely cannot deliver the host-control MCP server: `MCPRuntimeSupportMatrix.profile(for:)`
(`Astra/Services/Capabilities/MCPRuntimeSupportMatrix.swift:52-72`) returns `unsupportedProfile`
for every runtime except Claude Code / Codex CLI (Copilot conditionally), and
`AgentRuntimeCapabilityProfile.canDeliverHostControlPlaneMCP`
(`Astra/Services/Runtime/AgentRuntimeCapabilityProfile.swift:29`) derives from that same matrix.
Blocking Cursor for GitHub host-control work is **intended** (ASTRA refuses to fall back to
handing `gh`/git credentials to the provider process — see
`Tests/AgentPolicyGitHubRoutingTests.swift:147` which pins this exact scenario). What is *not*
intended is everything below.

## 2. Root causes

### RC1 — Stale-binary confusion (18:09 block): RESOLVED BY FORENSICS, cleanup only

The 18:09 block and 18:29 reroute logs use field shapes (`required_host_control_tools` on both;
reroute without `selected_runtime_evidence`) that exist **only** in pre-`2821eb6a`
("feat: apply runtime compatibility before launch", 2026-07-04) code:

- Sole emitter of `worker.blocked` + `required_host_control_tools`:
  `AgentRuntimeCapabilityBlockRecorder.apply(_: AgentRuntimeCapabilityCompatibilityPolicy.LaunchBlock, ...)`
  (`Astra/Services/Runtime/AgentRuntimeCapabilityBlockRecorder.swift:8-40`) — **zero production
  callers on HEAD** (verified by grep; only `AgentRuntimeCapabilityCompatibilityPolicy.swift:5`
  defines the type, nothing calls the overload).
- HEAD's reroute log (`AgentRuntimeLaunchRuntimeResolver.apply`,
  `Astra/Services/Runtime/AgentRuntimeLaunchRuntimeResolver.swift:113-121`) emits
  `required_capabilities`/`missing_capabilities`/`selected_runtime_evidence` — the format seen in
  the *successful* midday reroutes (12:54, 13:00), whose build (`ec92c58`) provably contains
  `2821eb6a` (`git merge-base --is-ancestor` verified).

Conclusion: the 18:09 app instance was an older ASTRA Dev build (multiple parallel worktree
dist builds run on this machine). Not a live bug. Remediation = dead-code deletion so the legacy
signature can never mislead log forensics again (Phase 4).

### RC2 — Live divergence: reroute resolver and policy gate disagree (22:49): REAL, ON HEAD

On the **current** binary, the same resume produced *neither* a reroute *nor* a
`runtime_capability_incompatible` launch block — the compatibility resolver judged Cursor
acceptable — yet one second later the policy render raised the `.blocked` diagnostic
`cursor_cli.host-control-plane-unsupported` (`Astra/Services/Runtime/AgentPolicyAdapters.swift:1238-1252`)
for the very requirement the resolver failed to see, and `shouldStartProvider`
(`Astra/Services/Runtime/AgentRuntimeWorker.swift:1618-1662`) stopped the run as `policy_blocked`.

Both sides *nominally* funnel into the same predicate
(`HostControlPlaneMCPProjection.requiredToolNames(capabilityScope:)`,
`Astra/Services/Runtime/HostControlPlaneMCPProjection.swift:31-40`), but they call it on
**independently captured capability snapshots**:

- Resolver: `AgentRuntimeLaunchRuntimeResolver.resolve` captures its own snapshot
  (`AgentRuntimeLaunchRuntimeResolver.swift:49-53`) — without `exposeAllConnectorCredentials`.
- Worker/policy render: `executeRuntimeSession` captures a second snapshot ~1s later
  (`AgentRuntimeWorker.swift:553-559`) — with `exposeAllConnectorCredentials: policy == .autonomous`
  — and the policy adapter derives `hostControlTools` from *that* scope via `enabledToolNames`
  (`AgentPolicyAdapters.swift:1210-1215`).

The 22:49 outcome proves the two derivations can disagree in production (empty vs `[github]`).
Exact mechanism not yet pinned — candidates:

- **H1:** this resume sub-path (`continuation_mode=pending_launch_signature`, `mode=fresh_follow_up`)
  reaches provider launch without passing through `executeRuntimeSession`'s resolve/apply at all
  (a `continueSession` short-circuit), so no reroute is ever attempted on it.
- **H2:** snapshot divergence — the two `TaskCapabilityResolutionSnapshot.capture` calls differ in
  arguments/pruning inputs (`TaskCapabilityResolver.makePromptScope` prunes `enabledPackageIDs`
  by matching included skills / task text, `TaskCapabilityResolver.swift:445-456`), so
  `githubCapabilityIsInScope` (`HostControlPlaneMCPProjection.swift:332-342`) answers differently.

(Ruled out: capability-profile disagreement — both sides read `MCPRuntimeSupportMatrix`; and
"no usable fallback" — that path would emit a `runtime_capability_incompatible` block, which did
not appear.)

### RC3 — Misleading / missing remediation UI: REAL

The system computes a precise, correct remediation string —
`HostControlPlaneRuntimeLaunchGuard.unsupportedRuntimeDetail/Remediation`
(`Astra/Services/Runtime/CopilotRuntimeLaunchSupport.swift:200-214`): *"Switch to Codex CLI,
Claude Code, or a Copilot CLI build with MCP config support…"* — but the user never sees it:

- The decision dock shows a hardcoded generic banner for **every** `policyBlocked` dismissal:
  *"Retry with broader policy permissions"* (`Astra/Services/Tasks/TaskDecisionDockPresentation.swift:337`,
  duplicated at `Astra/Views/TaskMainView.swift:4217`). Actively wrong here: policy is already
  `autonomous` (the broadest); retrying cannot succeed; the fix is switching runtime.
- `RunActivityPresentation.looksPolicyBlocked` (`Astra/Views/RunActivityPresentation.swift:83-89`)
  classifies by phrase-matching four strings; the host-control block text matches none, so the
  transcript shows generic "Run stopped" instead of "Policy blocked this run".
- The correct text is only visible in `AgentPolicySheet.diagnosticRow`
  (`Astra/Views/Components/AgentPolicySheet.swift:759-772`), which users rarely open.
- Nothing warns at **selection time**: the runtime switcher happily accepts Cursor for a task
  whose capabilities Cursor cannot run (22:46 action), guaranteeing a dead-end 3 minutes later.

### RC4 — Diagnostics report can't classify these blocks: MINOR

Both incident entries surfaced as generic "Application warning — review whether it corresponds
to a recoverable condition". `worker.blocked` reasons are a small closed set; the report
generator should name them and print the known remediation.

---

## 3. Remediation phases

### Phase 0 — Pin the RC2 mechanism (diagnosis, test-first) — ~0.5 day

1. **Scenario test (expected to fail):** clone the shape of
   `Tests/HeadlessChatContinuationScenarioTests.swift:1012` ("GitHub host-control retry reroutes
   from Cursor to configured compatible runtime") but drive it through the *exact* 9FA6AF3D
   resume shape: completed task → explicit runtime change to cursor (`task.runtimeID = cursor`)
   → `task_continue_chat` follow-up under `.autonomous`, `continuation_mode=pending_launch_signature`.
   Assert: either a reroute event **or** a launch block is produced — never a provider launch that
   then dies at the policy gate. If the test passes on HEAD, iterate on the continuation admission
   preconditions until the 22:49 path is reproduced (H1); if it fails as predicted, capture which
   hypothesis held.
2. **H1 check (code trace):** map every path from `continueSession`
   (`AgentRuntimeWorker.swift:~411-429`) to provider launch; confirm whether any of them
   (admission retry, pending-launch-signature settlement) skips `executeRuntimeSession`'s
   resolve/apply block (`AgentRuntimeWorker.swift:500-534`).
3. **H2 check (determinism):** unit test asserting
   `requiredToolNames(capabilityScope:)` equality across the two capture callsites' argument
   shapes for a github-workflow task (grants override present/absent ×
   `exposeAllConnectorCredentials` true/false × identical context text).
4. **Observability (ship regardless):** add `requirements_host_control_tools=<joined>` and
   `requirement_source=launch_resolver` fields to the resolver's debug logging, and include the
   requirement set in the `runtime.command_planned` warning fields. One-line each; makes any
   future disagreement directly visible in diagnostics reports.

**Exit criteria:** a red test that reproduces "resolver silent + policy gate blocks" and a one-line
statement of the mechanism.

### Phase 1 — Single derivation of runtime requirements (structural fix) — ~1 day

**Invariant to establish:** *the reroute decision and the policy-render block diagnostic must be
computed from the same `TaskRuntimeRequirementSet`, derived once per launch.*

1. Thread `AppliedRuntimeResolution.requirements` (already returned by
   `AgentRuntimeLaunchRuntimeResolver.apply`) from `executeRuntimeSession` down into the policy
   render, and change `applyingHostControlPlaneManifestSupport`
   (`AgentPolicyAdapters.swift:1196-1215`) to accept the precomputed tool list instead of
   re-deriving via `enabledToolNames` from a second snapshot. Same for the sibling derivations at
   `AgentPolicyAdapters.swift:1311` and `:1396` (scoped local-tool commands + manifest servers) so
   all three agree by construction.
2. If Phase 0 confirms **H1** (a launch path bypasses resolve), route that path through
   `AgentRuntimeLaunchRuntimeResolver.resolve/apply` as well — the resolver is idempotent for
   compatible runtimes, so this is safe for every other resume shape.
3. If Phase 0 confirms **H2**, additionally make `executeRuntimeSession` reuse the resolver's
   snapshot instead of capturing a second one when the runtime was not rerouted (recapture only
   on reroute, where the adapter/context legitimately changes). This removes the duplicate
   `TaskCapabilityResolutionSnapshot.capture` (`AgentRuntimeWorker.swift:553-559`) in the common
   case — also a small launch-latency win.
4. Keep the `AgentRuntimeProcessRunner` guard (`AgentRuntimeProcessRunner.swift:249-256`) as
   defense-in-depth, unchanged: with 1–3 in place it becomes unreachable for this class, which is
   exactly what a last-line guard should be.

**Tests:** Phase 0's scenario test goes green; add
`Tests/TaskRuntimeCompatibilityServiceTests` case asserting resolver-vs-adapter agreement on a
github-workflow task; keep `Tests/AgentPolicyGitHubRoutingTests.swift:147-189` green (the block
must still fire when the user pins Cursor *and* D1 chooses blocking).

### Phase 2 — DECISION GATE D1, then behavior for explicit user picks — ~0.5 day after D1

At 22:46 the user *explicitly* chose Cursor; at 18:29 the same task was silently rerouted off
Cursor. Today no code distinguishes the two intents (`task_runtime_changed` is telemetry only —
verified; the resolver has no user-pinned concept). After Phase 1 the outcome becomes
deterministic, so we must pick which outcome it is:

- **Option A — always reroute (silent-but-visible).** Matches the tested reference behavior
  (`HeadlessChatContinuationScenarioTests:1012`) and ASTRA's outcome-oriented posture. The
  existing reroute chat event + a toast make it legible. Risk: overriding an explicit pick feels
  paternalistic, and model choice silently changes (composer-2.5-fast → gpt-5.5).
- **Option B — respect explicit picks: block fast, actionably.** When the runtime was set via
  `task_runtime_changed` for this task (requires persisting a `runtimeExplicitlyChosenAt` marker
  on `AgentTask`), skip reroute, block *before launch* with the real remediation text and a
  one-click "Switch to Codex CLI" action. Defaults-sourced runtimes still auto-reroute.

**Recommendation: Option B for explicit picks, A otherwise** — it honors user intent, and
Phase 3's composer warning makes the dead end visible at pick time, not 3 minutes later.
(Option A is acceptable if we'd rather avoid the new persisted field; the plan works either way.)

### Phase 3 — Truthful, actionable failure UI — ~1 day

1. **Dock banner tells the truth** (`TaskDecisionDockPresentation.pendingReviewPresentation`,
   `Astra/Services/Tasks/TaskDecisionDockPresentation.swift:331-345`): when dismissal reason is
   `.policyBlocked` and the latest failed run carries a blocked `PolicyDiagnostic` with
   `remediation`, show the diagnostic's title + remediation instead of the hardcoded "Retry with
   broader policy permissions" line; add a secondary action **"Switch runtime…"** (opens the
   composer runtime picker) when the diagnostic's `affectedCapability == "control_plane"`.
   Requires threading the blocked diagnostics (id/title/remediation) into the pending-review
   context — they are available where `shouldStartProvider` records the failure
   (`AgentRuntimeWorker.swift:1618-1662`); persist them on the run (or its terminal TaskEvent
   payload as structured JSON) rather than re-deriving in the view layer.
   Mirror the same fix at `Astra/Views/TaskMainView.swift:4217` — but keep new logic in the
   presentation service, not TaskMainView (file is at its architecture-fitness line budget).
2. **Structured classification, not phrase matching**
   (`Astra/Views/RunActivityPresentation.swift:66-89`): classify "Policy blocked this run" from
   the run's `stopReason == policy_blocked` when available; retain the string heuristic only as
   fallback for legacy events, adding the host-control phrasing ("cannot attach ASTRA's
   host-control MCP route") to it.
3. **Composer pre-flight warning:** in the runtime picker (`task_composer` path), evaluate
   `TaskRuntimeRequirementSet.derive` + `AgentRuntimeCapabilityProfileService.profile` for the
   candidate runtime and show an inline warning row when incompatible: *"This task uses GitHub
   host-control; Cursor CLI can't run it — it will be \{rerouted to Codex CLI | blocked\} (per D1)."*
   Selection stays allowed (warning, not a wall). Cheap: both inputs are already main-actor
   available; no FS scans in `body` (per the right-rail lesson — precompute in the model layer).

**Tests:** presentation unit tests for the three states (policy-blocked with/without remediation
payload; legacy event fallback); snapshot/UI test for the composer warning row.

### Phase 4 — Cleanup + report classification — ~0.5 day

1. **Delete dead legacy path:** `AgentRuntimeCapabilityCompatibilityPolicy.swift` (whole file),
   the legacy overload `AgentRuntimeCapabilityBlockRecorder.apply(_:AgentRuntimeCapabilityCompatibilityPolicy.LaunchBlock…)`
   (`AgentRuntimeCapabilityBlockRecorder.swift:8-40`), and the file's entry in
   `Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift:51`. **Keep**
   `missingHostControlMCPReason` and `HostControlPlaneRuntimeLaunchGuard` — they are live
   (process-runner guard `AgentRuntimeProcessRunner.swift:249-256`, Copilot support
   `CopilotRuntimeLaunchSupport.swift:118,186,258,270`, and two
   `TaskRuntimeCompatibilityServiceTests` assertions reference the constant).
2. **Diagnostics report classifier:** map known `worker.blocked` reasons to named issues with
   remediation text — `policy_blocked` → surface the run's blocked-diagnostic remediation;
   `host_control_plane_unsupported_runtime` *without* `source=runtime_launch_preflight` → "legacy
   log signature: app instance predates 2026-07-04 unification (2821eb6a); confirm which build
   emitted it". Add `app_git_commit` to the per-issue extract header if cheap.

---

## 4. PR slicing & order

| PR | Contents | Depends on |
| --- | --- | --- |
| PR-1 | Phase 0 items 1–4 (red scenario test may land `disabled`/`.bug`-tagged + observability fields) | — |
| PR-2 | Phase 1 (single derivation) + Phase 0 test enabled green + Phase 4.1 dead-code deletion | PR-1, D1 not required |
| PR-3 | Phase 2 (per D1) + Phase 3 UI | PR-2, **D1 answered** |
| PR-4 | Phase 4.2 report classifier | independent |

## 5. Risks & guardrails

- **Do not weaken the block itself.** Refusing to hand gh/git credentials to non-MCP runtimes is
  a security posture (four codex invariants around connector reads; `AgentPolicyGitHubRoutingTests`).
  Every phase changes *routing, determinism, and messaging* — never the refusal.
- **Don't re-flip PR #226 autonomous-floor tests** while touching `shouldStartProvider` /
  policy render: `enforcement=provider_native` + `uses_broad_provider_permissions=true` for
  autonomous Cursor are unrelated to this incident (verified: set unconditionally in
  `CursorPolicyAdapter.render`) and the two warning-level diagnostics stay as-is.
- **Line budgets:** `TaskMainView.swift` and `AgentRuntimeWorker.swift` are at/near
  architecture-fitness caps — put new logic in `TaskDecisionDockPresentation` /
  `RunActivityPresentation` / resolver files; keep worker diffs to threading parameters.
- **Worktree discipline:** all edits under the working worktree, not main-repo paths.
- **Continuation-admission trap:** any change near `continueSession` must preserve the
  `finishContinuationLaunch` revert contract (PR #70) or failed admissions strand tasks in
  `running`.

## 6. Verification matrix (end state)

| Scenario | Expected |
| --- | --- |
| New task, default runtime cursor, github capability, phase=run | Auto-reroute → codex + visible reroute event (unchanged) |
| Resume after completion, runtime still default-cursor | Auto-reroute (Phase 1 makes this unconditional across resume sub-paths) |
| Resume after **explicit** cursor pick (9FA6AF3D 22:49 shape) | Per D1: block **before launch** with real remediation + "Switch runtime…" action (B) — or visible reroute (A). Never `policy_blocked` at the render gate |
| Cursor picked in composer for a github task | Inline incompatibility warning at pick time |
| Policy-blocked dock card | Shows host-control remediation text, no "broader permissions" advice |
| Legacy `host_control_plane_unsupported_runtime` in a future report | Classified as stale-build signature with build-forensics hint |
| `swift test` full suite | Green, `--no-parallel` (known flaky pipe test excepted) |
