# Capabilities Remediation Plan

**Date:** 2026-06-11
**Scope:** Every issue surfaced by the 2026-06-11 deep review of the capabilities subsystem (`Astra/Services/Capabilities/`, `ASTRACore/PluginPackage.swift`, runtime projection, catalog UI, tests).
**Baseline:** capability test suite green at 350 tests / 50 suites.

The review verdict: the core pipeline (skills, connectors, local tools, templates) works end-to-end and is well tested, but the subsystem ships four structural problems — MCP servers are advertised but never delivered, a dead legacy install path is what part of the test suite actually exercises, the Ed25519 signing module is unused while the disk-load path trusts self-declared governance, and several lifecycle operations are non-atomic with silently-swallowed errors. This plan removes, fixes, or finishes each of them in six phases ordered by risk-to-users and prerequisite structure.

---

## 1. Up-front decisions

Three findings are decision-shaped. The plan assumes the recommended option for each; the alternative is scoped so a different call only swaps one workstream, not the plan.

### D1 — MCP servers: deliver or remove?
**Recommendation: deliver for Claude Code first (Phase 2), with honest per-runtime badges elsewhere.**
ASTRA's value proposition is orchestrating agent runtimes, MCP is the standard tool-delivery mechanism, and the format/validation/UI work is already done — only the last mile (materialization at launch) is missing. The fallback (strip `mcpServers` from the format and UI until a delivery story exists) is ~1 day instead of ~1.5 weeks; if chosen, replace Phase 2 with Phase 2-alt (§4.3).

### D2 — Package signing: enforce or delete?
**Recommendation: delete `PluginSigning.swift` and the `signature` field; make the SHA-256 digest approval record the single integrity mechanism, and close the disk-load normalization gap (Phase 1.4).**
There is no distribution channel that produces signatures, no key-management story, and `PluginSigning.verify` has zero production callers. The digest-bound approval store already provides tamper-evidence at the point that matters (approval → enable). Keeping dead crypto around implies guarantees the app doesn't make. If a signed remote catalog ships later, signing can return as part of that feature with a key-distribution design.

### D3 — Dormant role/visibility governance: keep or strip?
**Recommendation: keep the policy machinery, but centralize context construction and document single-user semantics (Phase 5.4).**
Every production call site passes `isAdmin: true` (PluginCatalogView.swift:92, ConfigureView.swift:74, WorkspaceRightRailView.swift:188, CapabilityPackageCreationService.swift:79/125, WorkspaceImportOrchestrator.swift:68). The roles/tags model is plausible future multi-user groundwork and is cheap to keep, but five scattered hardcoded `isAdmin: true` literals are how a future "non-admin mode" ships half-broken. One factory makes the semantics explicit and greppable.

---

## 2. Phase 0 — Dead code removal and truth-in-UI (~1 day)

Low-risk deletions that shrink the surface every later phase touches. Do this first so Phases 1–2 don't have to keep dead code compiling.

### 0.1 Delete the legacy `PluginCatalog` install path
**Problem:** `PluginCatalog.install()/update()/isInstalled()/hasUpdate()/availableUpdates()` (PluginCatalog.swift:54-305) have zero production callers — the live path is `CapabilityCatalogActionService → CapabilityInstaller`. The dead path has drifted (no approval-store integration, no global-resource dedup, no MCP handling, nondeterministic connector→skill link via `createdSkills.values.first` at PluginCatalog.swift:152, MCP-blind `hasNoInstallablePayload` heuristic at PluginCatalog.swift:65-70).
**Change:**
- Remove the five methods and supporting private helpers from `PluginCatalog`, reducing it to: `loadCatalog()` (verify still needed — it reads `~/.astra/plugins`; if `loadApprovedCapabilities()` has fully replaced it, remove it too and migrate `seedBuiltInPlugins()` deprecation cleanup), `loadApprovedCapabilities()`, `seedBuiltInPlugins()`, `categories`, and the built-in package definitions.
- Rewrite the install/isInstalled portions of `Tests/PluginCatalogTests.swift` against `CapabilityInstaller.enable()` / `CapabilityCatalogActionService` so the behaviors the old tests pinned (name dedup, template creation, version recording) stay pinned on the live path. Keep seed/load tests as-is.
**Acceptance:** `grep -rn "catalog\.install\|catalog\.update\|catalog\.isInstalled\|catalog\.hasUpdate" Astra/ Tests/` returns nothing; suite green; `PluginCatalog.swift` shrinks by ~250 lines (helps the architecture-fitness line budgets).

### 0.2 Delete dead signing infrastructure (per D2)
**Problem:** `PluginSigning.swift` (Ed25519) and `PluginPackage.signature` are never verified in production; `isTrusted` is decoded-as-false and never read.
**Change:**
- Delete `ASTRACore/PluginSigning.swift`; remove `signature` and `isTrusted` from `PluginPackage` (decode side: drop the keys — `decodeIfPresent` means old JSON with a `signature` field still decodes; add a decode test proving that).
- Migrate/retire `Tests/PluginShareabilityTests.swift` signing cases; keep any cases that actually test share/export semantics.
**Acceptance:** no `PluginSigning` references anywhere; legacy package JSON containing `signature`/`isTrusted` keys still decodes (regression test).

### 0.3 Interim MCP honesty in the catalog (until Phase 2 lands)
**Problem:** the catalog detail view (PluginCatalogView.swift:1291-1306), content summary (PluginPackage.contentParts), and run activity panel (RunActivityPresentation.swift:247) present MCP servers as a working resource kind.
**Change:** add a "Not yet delivered to runtimes" caption/badge on the MCP section of the package detail view and in the install sheet summary (PluginCatalogView.swift:1867). Remove the badge in Phase 2 when delivery ships for Claude (it then becomes the per-runtime support badge of 2.3).
**Acceptance:** an MCP-bearing package's detail view states the limitation; copy reviewed once in the PR.

---

## 3. Phase 1 — Lifecycle correctness and trust hardening (~2–3 days)

The "sharp edges": non-atomic operations, destructive-order bugs, swallowed errors, and the disk-load trust gap. All items here are behavior fixes with tests; none changes the data model.

### 1.1 Make install→enable transactional
**Problem:** `CapabilityInstaller.install()` (CapabilityInstaller.swift:38-92) writes the library JSON, then runs `enable()`; if `enable()` throws (policy blocker raced, SwiftData failure), the package file is orphaned in the library and surfaces in the catalog as installed-but-never-enabled.
**Change:** compensate on failure — wrap `enable()` so a throw triggers `library.removePackage(id:)` for a package that was *not previously installed* (don't delete a pre-existing version on a failed re-enable). Prefer compensation over reordering: writing the file last would let `enable()` succeed against a package the matcher can't find on disk (`CapabilityRuntimeResourceMatcher.enabledPackages` reads the library).
**Tests:** extend `CapabilityPackageRoundTripE2ETests` (it already asserts approval-record rollback at line 264-304): new-install enable failure leaves no library file; failed re-enable of an upgrade leaves the previous version's file intact.

### 1.2 Keychain cleanup ordering in disable/uninstall
**Problem:** `CapabilityActivationDisabler.disable()` and `CapabilityUninstaller.remove()` call `cleanupKeychain()` on connectors/skills before the SwiftData deletes are saved (CapabilityActivationDisabler.swift:71,79; equivalents in the uninstaller). A save failure after the wipe loses credentials while the records survive — the user's connector looks configured but is empty.
**Change:** two-phase teardown: (1) collect keychain entity IDs from resources being deleted, (2) perform SwiftData deletes and **save**, (3) only then delete keychain items, logging (not throwing) individual keychain failures via `CapabilityAudit`. Apply the same ordering in both services.
**Tests:** disabler/uninstaller tests with a failing-save model context (in-memory container + induced failure or protocol seam): assert keychain untouched when save fails; assert keychain cleared when save succeeds (use the existing `MockSecretStore`).

### 1.3 Stop swallowing fetch/save errors in destructive paths
**Problem:** `(try? modelContext.fetch(...)) ?? []` in `CapabilityUninstaller.remove()` (lines 39-48) and the dedup fetch in `CapabilityInstaller.enable()` (line ~467) turn database errors into "nothing matched", so an uninstall can silently skip cleanup and an enable can create duplicate globals. `CapabilityActivationDisabler` returns `Result` but drops sub-step errors.
**Change:** in destructive/mutating paths, propagate fetch errors (`throws`) instead of defaulting to empty; in the disabler, accumulate sub-step failures into the returned `Result` failure case. Read-only display paths may keep the lenient pattern.
**Tests:** failing-fetch seam → uninstall throws and leaves library file in place (no partial deletion); enable throws rather than duplicating a global connector.

### 1.4 Normalize governance at library load (close the disk-drop gap)
**Problem:** the import flow normalizes self-declared governance to draft (CapabilityPackageValidator.swift:148-190), but `CapabilityLibrary.installedPackages()` (CapabilityLibrary.swift:39-63) decodes whatever sits in App Support verbatim. A JSON hand-placed there claiming `approvalStatus: approved` / `requiresAdminApproval: false` (or `sourceMetadata.trustLevel: "remote-approved"`, which `CapabilityGovernance.defaultGovernance` auto-approves) is honored — `CapabilityCatalogPolicy.effectiveGovernance` only upgrades from approval records, never downgrades disk claims. Local file-write access is the same trust domain as the app, so this is defense-in-depth, but it's also the gap the dead signing module pretended to cover.
**Change:** in `installedPackages()`, after decode: trust `built-in`/`remote-approved` governance **only** for package IDs present in `PluginCatalog.builtInPackages` (pass the approved-ID set in, or expose it via `ApprovedCapabilityBundle`); for everything else, clamp through the same normalizer the import validator uses (extract `normalizeForLocalImport`'s governance reset into a shared `CapabilityGovernanceNormalizer` so the two paths can't drift). Approval records then re-upgrade legitimately approved local packages via the existing digest mechanism — no behavior change for honest packages.
**Tests:** forged file fixtures — fake `built-in` kind with unknown ID, fake `remote-approved` trust level, self-declared `approved` status — each loads as draft/admin-gated; a legitimately approved local package (digest-matching record) still resolves to approved through policy.

### 1.5 Repair `recordInstalledPlugin` parallel-array desync
**Problem:** `Workspace.recordInstalledPlugin` (Workspace.swift:90-100) silently no-ops the version write when `installedPluginIDs`/`installedPluginVersions` are out of sync, freezing the recorded version forever.
**Change:** when `idx >= installedPluginVersions.count`, pad the versions array to match before assignment; one audit log when repair occurs. (Longer-term: fold both arrays into a single `[InstalledPluginRecord]` codable attribute — only if a SwiftData migration is already planned; not worth one alone.)
**Tests:** unit test with deliberately desynced arrays → version recorded, arrays consistent after.

### 1.6 Silent-skip visibility in `CapabilityResourceOrigin.stamp`
**Problem:** when a resource is already owned by a different package, `stamp` silently declines (CapabilityResourceOrigin.swift:171-174), leaving ownership ambiguous for later uninstalls.
**Change:** keep the behavior (correct), add a `CapabilityAudit` entry naming both package IDs so support/debugging can see contested ownership.
**Tests:** assert audit field emission on contested stamp.

---

## 4. Phase 2 — MCP delivery (per D1) (~1–1.5 weeks)

The feature that turns the format's `mcpServers` into something real. Claude Code first; other runtimes get explicit "unsupported" surfacing rather than silent omission.

### 2.1 Materialize MCP config at launch (Claude Code)
**Change:**
- New `MCPRuntimeProjection` (in `Astra/Services/Capabilities/`) that takes `TaskCapabilityResolver.enabledMCPServerManifests` (TaskCapabilityResolver.swift:276-310) and produces Claude's MCP config JSON: stdio → `command`/`args`/`env`; http/sse → `url`. Resolve `environmentKeys` and `connectorBindings` through `ConnectorRuntimeProjection` so Keychain-backed credentials reach server env blocks without ever being written into the prompt or logs.
- Write the rendered config to a per-run file alongside the existing `.claude/settings.local.json` render (AgentPolicyAdapters.swift:106 area), and pass `--mcp-config <path>` (plus `--strict-mcp-config` so a repo's own `.mcp.json` doesn't smuggle servers past ASTRA's governance) in the Claude command builder (`AgentRuntimeAdapter.swift`, Claude runtime around line 993+).
- **Secrets on disk caveat:** if a bound connector credential must appear in the env block of the config file, write the file `0600` inside the run's private support dir and delete it in run teardown; prefer env-var indirection (`"env": {"KEY": "${KEY}"}` resolved from the process environment ASTRA already injects) where Claude supports it, so the file carries no secret material at all. Decide during implementation; the no-secrets-in-file option is preferred.
- Honor `allowedTools`/`excludedTools` from `PluginMCPServer` by emitting `mcp__<serverID>__<tool>` entries into the existing allow/deny lists in the settings render.
**Acceptance:** a package with a stdio MCP server, enabled in a workspace, yields a Claude run where the agent can call that server's tools; disabling the package removes them on the next run.

### 2.2 Gate MCP by governance and integrity
**Change:**
- `CapabilityRuntimeIntegrityService` already content-matches MCP servers (CapabilityRuntimeIntegrityService.swift:229, 450); extend launch preflight (`AgentRuntimeLaunchPreflight`) to verify stdio commands resolve to an executable (reuse `CapabilityToolDetector`) and fail the launch with a remediation message when missing.
- `trustLevel: .restricted` servers require the package's approval record (already implied by enable-gating; add an explicit policy test so the invariant is pinned).
**Tests:** preflight blocks launch for missing stdio binary with actionable message; restricted-trust server in a draft package cannot reach a run.

### 2.3 Per-runtime support surfacing
**Change:**
- Add `supportsMCP` to the runtime descriptor (the per-runtime metadata in `AgentRuntimeAdapter.swift`); true for Claude Code initially.
- Package detail + install sheet: replace Phase 0.3's interim badge with per-runtime support chips ("MCP: Claude Code ✓ · others not yet").
- Run manifest/activity (RunActivityPresentation.swift:247): when the selected runtime lacks MCP support and the task's capability set includes MCP servers, show "N MCP servers skipped (runtime doesn't support MCP)" instead of listing them as if active.
- **Fitness-budget note:** `PluginCatalogView.swift` is 2,649 lines and the repo enforces per-file line caps in precommit/CI — land the badge UI as an extracted subview file (e.g. `Views/CapabilityRuntimeSupportBadge.swift`), not as growth in the catalog view.
**Acceptance:** OpenCode/Codex/Copilot runs with MCP-bearing capabilities visibly report the skip; no runtime silently drops servers.

### 2.4 MCP-only package lifecycle parity
**Problem:** with the legacy heuristic deleted in 0.1, verify the live path treats MCP-only packages correctly end-to-end: `CapabilityPackageState.readiness()`, `CapabilityLifecycleResolver`, rail presentation, and `CapabilityRuntimeIntegrityService.scopedResourcePresence` (line 501 already counts `mcpServers` — good).
**Tests:** MCP-only package: enable → shows enabled in rail and catalog; disable → cleanly removed; integrity service treats it as having installable payload.

### 2.5 Integration test with a stub MCP server
**Change:** add a tiny deterministic stdio MCP stub (a Swift executable target or checked-in script in `Tools/`, responding to `initialize` + one `tools/list`/`tools/call`) and an integration test that renders the config, spawns the stub, and asserts the handshake — no network, CI-safe. A full Claude-CLI smoke belongs in the existing `RealProviderSmokeTests` pattern (manual/env-gated), not CI.
**Acceptance:** CI exercises config render → spawn → handshake without external dependencies.

### 4.3 Phase 2-alt (if D1 = remove)
Strip `mcpServers` from `PluginPackage` (keep decode-tolerance for old JSON), delete validator/policy/integrity MCP branches, remove the catalog UI sections and `RunPermissionManifest.mcpServers`, drop `PluginPackageMCPTests`. ~1 day. Re-introduce later behind a real delivery design.

---

## 5. Phase 3 — Runtime projection robustness (~2–3 days, parallelizable with Phase 2)

### 3.1 Generic connector preflight + credential-failure audit
**Problem:** only Jira gets launch preflight (ConnectorPreflightService.swift:20-23); `ConnectorRuntimeProjection` silently skips missing/empty credentials (ConnectorRuntimeProjection.swift:196-198), so a broken connector just shows "NOT configured" in the prompt with no audit trail.
**Change:**
- Add a service-agnostic preflight tier: for every connector projected into a run, check "all declared credential keys load non-empty from Keychain". Failures become launch warnings surfaced in the run activity view (not hard blocks — the agent may legitimately not need that connector), plus a `CapabilityAudit` entry per missing key (key name only, never values).
- Keep the Jira-specific auth probe as the first pluggable `ConnectorAuthTester`; document the protocol so REDCap/GitHub testers can follow.
**Tests:** missing-credential connector → audit entry + run warning; fully-configured connector → no noise.

### 3.2 Bound detached-snapshot lifetime
**Problem:** snapshots of deleted skills keep injecting behavior instructions into all future runs of a task indefinitely (TaskCapabilityResolver.swift:438-451), invisible to the user.
**Change (product decision, recommended):** detached snapshots remain valid only for **resuming the run that captured them**; a *new* run of the task re-resolves live capabilities and drops detached snapshots, logging an audit entry ("skill X removed since last run"). UI: task detail shows a "from deleted skill" tag when a run is using a detached snapshot.
**Tests:** delete skill mid-task → resume keeps snapshot; next fresh run drops it and audits.

### 3.3 Deprecate legacy bare env-var fallback
**Problem:** single-connector services also expose bare legacy env names (ConnectorRuntimeProjection.swift:64-70); adding a second connector of the same service later silently changes which credentials the bare name resolves to.
**Change:** keep the fallback (built-in skill prompts still reference projected names) but emit a deprecation audit when a bare name is actually injected, and add the alias-name form to all built-in skill instructions (PluginCatalog built-ins already mostly say "use the projected env names" — finish the sweep). Schedule fallback removal in a release note, gated on zero audit hits.
**Tests:** two same-service connectors → no bare names; one connector → bare names present + audit emitted.

### 3.4 Validate browser-bridge env injection
**Problem:** `ShelfBrowserBridgeRegistry.environmentVariables(for:)` output merges into the task env unvalidated (AgentRuntimeProcessRunner.swift:748-751).
**Change:** assert/filter that injected keys match an `ASTRA_BROWSER_`/known-prefix allowlist; log and drop anything else. Cheap invariant against a future bridge change clobbering `PATH`/`HOME`/connector vars.
**Tests:** registry returning a hostile key (`PATH`) → dropped + audited.

### 3.5 Cache `enabledPackages` reads (perf, minor)
**Problem:** `WorkspaceCapabilities` computed properties call `CapabilityRuntimeResourceMatcher.enabledPackages(for:)` (WorkspaceCapabilities.swift:97-99) which reads library JSON from disk; catalog body rebuilds hit this repeatedly (telemetry threshold 15 ms at PluginCatalogView.swift:111-136).
**Change:** the matcher already has an `NSLock`-guarded cache — verify it caches *decoded packages by directory mtime* (not per-call decode); if not, add mtime-keyed invalidation. No API change.
**Tests:** unit test that two consecutive `enabledPackages` calls hit the cache (decode-count seam); telemetry threshold unchanged.

---

## 6. Phase 4 — Test debt (~3–5 days, parallelizable)

Targets from the review's coverage map. All new tests follow the house pattern: in-memory SwiftData containers, UUID-isolated temp dirs, `MockSecretStore`, no network.

| Workstream | Today | Add |
|---|---|---|
| 4.1 `CapabilityUninstaller` | 1 test | multi-workspace removal; shared-resource preservation via origin precedence; legacy name-match boundaries (similarly-named resource survives); fetch-failure throws (pairs with 1.3); keychain ordering (pairs with 1.2) |
| 4.2 `CapabilityActivationDisabler` | 1 test | global-resource disable keeps other package's claim; workspace-scoped connector/skill deletion; failure accumulation in `Result` |
| 4.3 `CapabilityHealthService` / `CapabilityLifecycleResolver` / `CapabilityToolDetector` | 2 / 1 / 3 tests | credential-presence health; MCP executable health (Phase 2.2); lifecycle matrix (draft/approved/blocked/deprecated × enabled/disabled × prereq ok/missing); PATH-resolution edge cases |
| 4.4 Zero-coverage services | none | `ApprovedCapabilityBundle` (bundle decode, malformed-resource fallback to `fallbackBuiltInPackages`); `CapabilityLibrary.syncApprovedPackages` edge cases (fake built-in removal — pins 1.4 behavior); `BundledToolInstaller`; `CapabilitySetupCopier` (cross-workspace copy, permission failure); `CapabilityAudit` (governance field redaction — assert no secret values in fields); `MailTaskIntent` |
| 4.5 First-party integrations | none | pure-logic tests only: `JiraConnectorAuthTester` response classification (401 vs project-visibility vs network); `CardinalKeyClientCertificateProvider` subject-filter predicate; `StanfordOutlookMail` registry JSON round-trip; `GoogleDocsDocumentAPI` request construction. No live endpoints in CI. |
| 4.6 Fitness rules | 3 capability rules | add: installer/uninstaller resource-kind parity (every resource kind `CapabilityInstaller.enable` materializes must appear in `CapabilityUninstaller`/`CapabilityActivationDisabler` handling — a compile-time-ish list assertion so the next resource kind can't ship install-only, which is exactly how the MCP gap happened) |

**Acceptance:** every service in `Astra/Services/Capabilities/` is named in at least one test file; destructive paths have failure-mode tests; suite stays deterministic and fast (<10 s warm).

---

## 7. Phase 5 — Product completeness (backlog, schedule independently)

### 5.1 Package update flow
Built-ins already refresh via `CapabilityDefinitionRepairService` at startup; local/imported packages have version machinery (`SemanticVersion`, `CapabilityLibrary.hasUpdate` at CapabilityLibrary.swift:73) but no UI and no user-facing flow. Add: catalog "Update available" badge when a newer-version import/source is offered, diff summary (resource adds/removes/changes), and an update action that re-runs `CapabilityInstaller.enable` with the new definition + re-stamps origins + invalidates the approval record (digest changes ⇒ re-approval required — that's correct and should be shown, not silently bypassed). Covers all resource kinds, unlike the deleted legacy `update()` which only did skills/templates.

### 5.2 Export from the catalog
`CapabilityPackageSourceExporter` works (used by the creation wizard via ConfigureView.swift:443,868). Add an "Export…" action on library (non-built-in) packages in the catalog detail view. Small; respects the fitness budget by reusing the wizard's save panel helper.

### 5.3 Prerequisite cache freshness
`PreflightCache` results persist until manual re-check. Add a TTL (e.g., re-probe on sheet open if older than 10 minutes) and an automatic re-check after the user clicks an install-hint link. Keep the manual button.

### 5.4 Governance context factory (per D3)
Replace the five hardcoded `isAdmin: true` constructions with `CapabilityCatalogPolicyContext.currentUser(workspace:approvalRecords:)` whose doc comment states the single-user assumption and is the only place a future multi-user mode must change. Add a fitness rule banning inline `isAdmin:` literals outside the factory and tests.

### 5.5 UI niceties from the review (explicitly deferred, not planned)
Bulk enable/disable, dependency visualization. No current user demand; record as backlog only.

---

## 8. Findings → plan traceability

| # | Review finding | Plan item |
|---|---|---|
| F1 | MCP declared/validated/displayed but never delivered to any runtime (AgentRuntimeProcessRunner.swift:463 filters MCP tools; no `--mcp-config` anywhere) | 2.1–2.5 (or 2-alt) |
| F2 | `isInstalled` "no payload" heuristic ignores MCP-only packages | 0.1 (dead code deleted), 2.4 (live-path parity) |
| F3 | Legacy `PluginCatalog.install/update` path: drifted, nondeterministic skill link, no approvals | 0.1 |
| F4 | `PluginCatalogTests` pins dead code (misleading green coverage) | 0.1 |
| F5 | `PluginSigning`/`signature`/`isTrusted` dead infrastructure | 0.2 (D2) |
| F6 | Disk-load honors self-declared approved/built-in governance (`defaultGovernance` trusts `remote-approved` claim) | 1.4 |
| F7 | `isAdmin: true` hardcoded at all 5 production sites; role/visibility model dormant | 5.4 (D3) |
| F8 | No update/upgrade flow for non-built-in packages despite version machinery | 5.1 |
| F9 | Export infrastructure without catalog UI | 5.2 |
| F10 | Install→enable non-transactional (orphaned library file) | 1.1 |
| F11 | Keychain wiped before SwiftData save commits (credential loss on failure) | 1.2 |
| F12 | Silent `try?` fetch fallbacks in uninstaller/installer dedup | 1.3 |
| F13 | Detached snapshots of deleted skills run forever, invisibly | 3.2 |
| F14 | Launch preflight covers Jira only | 3.1 |
| F15 | Missing connector credentials skipped silently, no audit | 3.1 |
| F16 | Legacy bare env-name fallback can silently rebind when a second connector appears | 3.3 |
| F17 | Browser-bridge env injection unvalidated | 3.4 |
| F18 | Destructive ops under-tested (uninstaller 1, disabler 1, lifecycle 1, health 2) | 4.1–4.3 |
| F19 | Zero-coverage files (bundle, audit, copier, Stanford/Google/CardinalKey, MailTaskIntent) | 4.4–4.5 |
| F20 | Nothing integration-level touches a real runtime/MCP spawn | 2.5 |
| F21 | `recordInstalledPlugin` parallel-array desync silently no-ops | 1.5 |
| F22 | Prerequisite cache staleness (manual re-check only) | 5.3 |
| F23 | Legacy `update()` handled only skills/templates (connectors/tools drift on update) | 0.1 deletes it; 5.1 replaces with full-kind update |
| F24 | `WorkspaceCapabilities` computed props → disk-backed package reads on every render | 3.5 |
| F25 | Contested `CapabilityResourceOrigin.stamp` silently skipped | 1.6 |
| F26 | Run activity lists MCP servers as if active on non-supporting runtimes | 0.3 interim, 2.3 final |

---

## 9. Sequencing, PR slicing, and estimates

```
Phase 0 (1d) ──► Phase 1 (2–3d) ──► Phase 2 (1–1.5w, D1)
                      │                   │
                      └──► Phase 3 (2–3d, parallel with 2)
                      └──► Phase 4 (3–5d, parallel; 4.1/4.2 pair with 1.2/1.3)
Phase 5: backlog, independent
```

Suggested PRs (kept small for the architecture-fitness line budgets; each lands green independently):

1. **PR-1:** 0.1 + 0.2 + 0.3 (deletions + interim badge + test repointing)
2. **PR-2:** 1.1 + 1.3 + 1.5 + 1.6 (installer/uninstaller correctness + tests)
3. **PR-3:** 1.2 + 4.1 + 4.2 (keychain ordering with its destructive-op test suites)
4. **PR-4:** 1.4 + 4.4(sync tests) (governance normalization + forged-fixture tests)
5. **PR-5:** 2.1 + 2.2 (MCP projection + preflight, Claude only, no UI)
6. **PR-6:** 2.3 + 2.4 + 0.3 removal (runtime badges, MCP-only lifecycle parity)
7. **PR-7:** 2.5 + 4.6 (MCP stub integration test + parity fitness rule)
8. **PR-8:** 3.1–3.5 (projection robustness; can split 3.1/3.2 from 3.3–3.5)
9. **PR-9:** 4.3 + 4.5 (remaining test debt)
10. **Backlog PRs:** 5.1–5.4 as scheduled

## 10. Risks and constraints

- **Architecture-fitness line budgets** (precommit/CI enforced): `PluginCatalogView.swift` (2,649) and `AgentPolicyAdapters.swift` are near their caps — all UI additions land as new extracted files; policy-adapter changes should extend via the existing render helpers, not inline growth.
- **Claude resume coupling:** run launch signatures already include `mcpServerIDs` (AgentRuntimeWorker.swift:1780), so enabling/disabling MCP mid-task changes the signature and (per the chat-coherence review) breaks Claude-native resume. Phase 2 must document this in the run-restart UX and must not alter signature fields for runs without MCP (no signature churn for existing users).
- **Secrets in MCP config files:** 2.1's preferred design keeps secrets out of the rendered file entirely (env indirection); if Claude's config requires literal values for some transport, the 0600-plus-teardown fallback applies and the file path must be excluded from diagnostics bundles (`runtime.failure_diagnostic` captures stderr tails — verify config paths never echo).
- **Decode compatibility:** 0.2 removes Codable fields — old JSON must keep decoding (covered by explicit regression tests); never reorder/rename surviving keys (approval digests are computed over sorted-keys canonical JSON; any key change invalidates existing approval records — call this out in PR-4's release note since 1.4 + digest interplay is the subtle part).
- **Single-user semantics:** several fixes (3.1 warnings, 3.2 snapshot drops) surface new UI copy; keep them quiet-by-default (activity view, not modal) to avoid alert fatigue in a single-user app.

## 11. Verification

- Full capability suite green after every PR (350+ tests; expect ~+60–80 new tests by Phase 4 completion).
- Architecture fitness suite green (line budgets, view→action-service boundary, new parity rule).
- Phase 2 exit: manual smoke via the `RealProviderSmokeTests` pattern — one Claude run with a real MCP server (e.g., a filesystem server) exercising a tool call; recorded in the PR description.
- Phase 1 exit: forged-fixture security checks (1.4) added to `SECURITY_REVIEW.md` checklist so the next review re-verifies them.
