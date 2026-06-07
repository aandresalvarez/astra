# ASTRA Seatbelt Execution Sandbox

Date created: 2026-06-06
Last reviewed: 2026-06-06

Tracking issue: [#9 — Implement robust local sandboxing for execution tasks
using macOS Seatbelt](https://github.com/aandresalvarez/astra/issues/9)

## Status (2026-06-06)

All phases implemented and tested.

- **Phase 1 — done.** `Astra/Services/Runtime/ExecutionSandbox.swift`: enforcement
  enum, settings, path canonicalization, writable-root derivation, parameterized
  Seatbelt profile, `sandbox-exec` argument assembly, and the `decide(...)`
  decision. `Tests/ExecutionSandboxTests.swift` covers profile shape, param
  escaping, canonicalization, decision rules, and a real `sandbox-exec`
  integration test proving in-workspace writes succeed while outside-workspace
  writes are blocked by the kernel.
- **Hardening pass (2026-06-06).** Closed the highest-value gaps from an
  adversarial coverage audit (22 sandbox tests total):
  - **Over-broad-root guard (bug fix).** `decide(...)` now refuses a workspace
    that canonicalizes to `/` or a top-level system root
    (`ExecutionSandbox.isOverlyBroadRoot`), returning `unsafe_execution_path`
    (fail-closed under strict, fallback under best-effort). Previously such a
    path would emit `.applied` with `ROOT_0=/` — a no-op sandbox that still
    reported "OS Sandboxed". `writableRoots(...)` additionally drops *any*
    overly-broad root (`forbiddenWritableRoots`) from the allowlist regardless of
    source, so a misconfigured `providerHomeDirectory` / `TMPDIR` / dir-to-create
    of `/` can never widen the allowlist (the shared `/private/tmp` root is
    deliberately retained).
  - **Failure-path decision coverage.** `sandbox_exec_missing` (via an injected
    `FileManager` stub) and the full `strict→failClosed` / `bestEffort→fallback`
    mapping for every unavailable reason are now tested.
  - **Runner mapping.** The decision→launch mapping is extracted to the pure,
    testable `AgentRuntimeProcessRunner.sandboxOutcome(for:originalPlan:)`, with
    a test asserting `failClosed` always blocks (exit -1,
    `runtimeStopReason: sandbox_unavailable`) and never runs unconfined.
  - **Kernel boundary, hardened.** New real-`sandbox-exec` tests prove the
    boundary holds for a workspace path containing spaces/quotes/parens, blocks a
    symlink-traversal escape, blocks `unlink`/`chmod` of outside files, and
    confirms the offline profile blocks a real loopback connection the online
    profile allows.
- **Full gap-closure pass (2026-06-06).** Closed the remaining audit findings
  (medium/low). Sandbox coverage totals 47 tests: `ExecutionSandboxTests` (38),
  `ExecutionSandboxRunnerTests` (5), and 4 manifest OS-sandbox-tier tests.
  - **`canonicalize` hardened.** Now rejects relative paths (no leading `/`
    after symlink resolution) and paths with interior newlines, so a meaningless
    or dangerous value can never become a `-D` writable root. Tests cover
    relative/newline rejection, `..` collapse, trailing-slash stripping, and the
    `/var/folders` (real TMPDIR) firmlink normalization.
  - **Manifest no longer over-promises.** The `osSandboxed` tier is appended only
    when `ExecutionSandbox.willLikelyApply(workspacePath:settings:)` holds
    (enforcement on, usable non-broad workspace, `sandbox-exec` present), so a
    best-effort run that will fall back to unconfined no longer shows "OS
    Sandboxed". Tests cover the layering-on case (Codex gets the tier), the
    `permissionPolicyOverride` path, and the omit-when-it-won't-apply case.
  - **Runner wiring tested end-to-end.** `sandboxedPlan` (now internal) is
    exercised with a fake adapter for the applied / blocked-fail-closed / skipped
    branches; the four audit emissions are asserted (isolated by task id); and a
    `runRuntimeProcess` test proves the shared-state gate is released even when a
    strict run is blocked.
  - **Settings coverage + no-drift guard.** Full 5×3 `shouldWrap` matrix,
    strict-under-autonomous no-op, `allowNetwork` explicit/​corrupt-non-Bool
    (fail-open) resolution, layering-only isolation, and a single source of truth
    for defaults (`ExecutionSandboxSettings.default*`) shared by `current(...)`
    and the `SettingsView` `@AppStorage` declarations, pinned by a drift test.
  - The `@AppStorage` architecture-fitness ratchet was bumped 125 → 129 for the
    three new sandbox settings (user-facing toggles following the existing
    pattern).
- **Multi-path workspace support (2026-06-06).** A workspace can span multiple
  paths (`Workspace.additionalPaths`) plus input directories; the agent is
  granted these via `--add-dir`, told about them in the prompt, and the in-band
  `AgentRuntimePolicyGuard` already treats `[workspacePath] + additionalPaths` as
  write roots. The sandbox now mirrors that: `decide(...)` /  `writableRoots(...)`
  take `additionalWritablePaths`, and `AgentRuntimeProcessRunner.sandboxedPlan`
  passes `runtimeAdditionalPaths(for:)` (the same set fed to providers), so the
  kernel boundary no longer blocks legitimate writes outside the primary path.
  Overly-broad entries are still dropped by `forbiddenWritableRoots`.
- **Phase 2 — done.** `AgentRuntimeProcessRunner.sandboxedPlan(...)` wraps the
  launch plan at the single chokepoint, audits every decision
  (`sandbox.applied` / `skipped` / `fallback` / `failed`), and defaults to
  best-effort for Claude Code + Copilot.
- **Phase 3 — done.** `AppStorageKeys.sandboxEnforcement` + segmented
  "Execution Sandbox" control in Settings → Runtime Guardrails; strict mode
  fails the run closed; `autonomous` runs auto-escalate to strict.
  `AgentPolicyManifestService.recordPreflightManifest` now appends
  `PolicyEnforcementTier.osSandboxed` to the run manifest's enforcement tiers
  when the run will be wrapped, so the permissions UI (`AgentPolicySheet`,
  `RunActivityPresentation`) shows "OS Sandboxed".
- **Phase 4 — done.** Offline mode (`AppStorageKeys.sandboxAllowNetwork`,
  default on) drives a `(deny network*)` profile; opt-in layering over
  self-sandboxing providers (`AppStorageKeys.sandboxLayerNativeProviders`,
  default off) extends the wrapped-runtime set to Codex/Cursor/Antigravity.
  Both are surfaced as toggles in Settings → Runtime Guardrails and resolved in
  `ExecutionSandboxSettings.current(...)`.

## Summary

Add an ASTRA-owned, OS-level execution sandbox that wraps every provider CLI
process in a macOS Seatbelt (`sandbox-exec`) profile. The profile confines
filesystem **writes** to an allowlist anchored on the task's execution
directory, while leaving reads broad and network outbound open so the agent can
still reach its model API. This gives Astra a kernel-enforced boundary that is
independent of, and stronger than, the in-band brokered permission layer it
relies on today.

This work fills an enforcement tier that the data model already anticipates but
no code path ever produces: `PolicyEnforcementTier.osSandboxed`
(`ASTRACore/AgentPolicyTypes.swift`).

## Motivation

Astra currently delegates all process-level sandboxing to provider-native
flags:

- Codex → `--sandbox workspace-write` / `read-only`
  (`Astra/Services/Runtime/CodexCLIRuntime.swift`,
  `codexPermissionArguments(policy:)`).
- Cursor → `--sandbox enabled`, Antigravity → `--sandbox`.
- **Claude Code and Copilot CLI have no OS-level confinement at all.** Their
  only boundary is `AgentRuntimePolicyGuard`, which *observes* the provider's
  reported tool-use stream and reacts after the fact.

The brokered layer is valuable for policy/audit, but it is an advisory boundary
parsed from provider stdout, not a kernel boundary. A misbehaving, buggy, or
prompt-injected agent that writes outside the workspace through a path the
provider does not report (or reports only after the write) is not stopped.

The issue asks for exactly the missing piece: an Astra-controlled Seatbelt
profile restricting agent file access to the workspace, applied uniformly and
independent of provider cooperation.

### Non-goals

- Replacing the brokered permission layer (`AgentRuntimePolicyGuard`,
  `PermissionBroker`) or the provider-native sandbox flags. Those stay.
- Per-domain network allowlisting. Seatbelt network filtering is coarse; URL
  policy remains with the brokered/provider layer. The OS sandbox owns
  **filesystem write-scoping**.
- Linux/Bubblewrap support. Astra is Apple-Silicon macOS only
  (`Package.swift`, `platforms: [.macOS(.v14)]`).

## Current architecture (grounding)

Two facts make this tractable.

### 1. One execution chokepoint

All task execution converges on a single process-construction site:

```
AgentRuntimeWorker.runRuntimeProcess (Astra/Services/Runtime/AgentRuntimeWorker.swift:616)
  -> AgentRuntimeProcessRunner.runRuntimeProcess
  -> AgentRuntimeProcessRunner.runProcess
  -> AgentExecutionScopedProcess(executablePath:arguments:currentDirectory:environment:)
     (Astra/Services/Runtime/AgentRuntimeProcessRunner.swift:142)
```

Every provider produces a uniform `AgentRuntimeProcessLaunchPlan`
(`Astra/Services/Runtime/AgentRuntimeAdapter.swift:688`) via
`makeProcessLaunchPlan(context:)`. The plan already carries everything a profile
needs:

- `executablePath`, `arguments`
- `currentDirectory` — the isolated execution path from `IsolationService`
- `environment`
- `directoriesToCreate` — task folder, `.runtime-bin` shim dir
- the worker also passes `homeDirectory` (the provider's writable HOME) into the
  runner separately.

Wrapping at this one seam confines **all five providers** with no per-adapter
changes.

### 2. The app is not App-Sandboxed

`script/ASTRA.entitlements` declares only
`com.apple.security.automation.apple-events`. There is no
`com.apple.security.app-sandbox` key, so the process can invoke
`/usr/bin/sandbox-exec` to confine its children. (You cannot nest Seatbelt
inside the App Sandbox; we are clear.) `sandbox-exec` is the same mechanism
Chromium, Bazel, and Codex itself use.

### Process-group compatibility

`AgentExecutionScopedProcess` (`Astra/Services/Runtime/AgentProcessSupport.swift`)
uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP` and signals the whole group on
cancel/timeout. `sandbox-exec` applies the profile and then `execvp`s the target
**in the same pid**, so the existing process-group cancellation logic keeps
working unchanged. No changes needed to `AgentExecutionScopedProcess` itself.

## Design

### Wrapping seam

Insert a single transform between plan creation and process construction in
`AgentRuntimeProcessRunner.runProcess`, just before
`Astra/Services/Runtime/AgentRuntimeProcessRunner.swift:142`:

```swift
let launchPlan = ExecutionSandbox.wrap(
    plan: plan,
    task: task,
    providerHomeDirectory: providerHomeDirectory,
    settings: sandboxSettings
)
let process = AgentExecutionScopedProcess(
    executablePath: launchPlan.executablePath,   // -> /usr/bin/sandbox-exec
    arguments:      launchPlan.arguments,         // -> ["-D","WORKSPACE=…", …, "-f", profilePath, realExe] + realArgs
    currentDirectory: launchPlan.currentDirectory,
    environment:    launchPlan.environment
)
```

`providerHomeDirectory` must be threaded from
`runRuntimeProcess` into `runProcess` (it already arrives as `homeDirectory` in
`AgentRuntimeProcessLaunchContext`; pass it down or attach it to the plan).

When the sandbox is disabled, unsupported, or the runtime is excluded,
`ExecutionSandbox.wrap` returns the original plan unchanged.

### The Seatbelt profile (the hard part)

The difficulty is not wiring; it is writing a profile that confines writes
**without breaking the agent**. A naïve "allow only the workspace" profile fails
every run. Three concerns, deliberately separated:

**Reads — broad.** Agents read system libraries, `/usr`, `/bin`, the resolved
CLI and its dependency tree (Node/Python/Homebrew). Use `(allow file-read*)`.

**Writes — scoped allowlist (the security boundary).**

- The execution path (`plan.currentDirectory`). With `.copy` or `.gitBranch`
  isolation this is already a per-task directory.
- The task folder and `.runtime-bin` shim dir (`plan.directoriesToCreate`).
- **The provider's writable state** — `~/.claude`, `~/.codex`, `~/.config`,
  `~/.cache`, npm/node and tool caches, plus `$TMPDIR` /
  `/private/var/folders`. **This is the most common cause of a broken naïve
  implementation:** omit these and the CLI cannot persist its session/cache and
  dies on launch. `providerHomeDirectory` exists for exactly this.
- `/dev/null`, `/dev/tty`, `/dev/dtracehelper`.

**Network — allow outbound by default.** Critical subtlety: Astra wraps the
*entire provider CLI*, and the CLI itself makes the LLM-API HTTPS calls. Denying
network at the OS layer kills the agent. The OS sandbox's job here is filesystem
write-scoping (precisely the issue's "restrict to the workspace folder"); which
URLs a tool may reach stays with the brokered/provider layer. A stricter
`(deny network*)` variant is offered only for an explicit offline/locked mode.

Profile sketch (parameterized — see below):

```scheme
(version 1)
(deny default)
(allow process-fork)
(allow process-exec*)          ; agent spawns bash / git / build tools
(allow file-read*)             ; broad read
(allow file-write*
    (subpath (param "WORKSPACE"))
    (subpath (param "TASK_FOLDER"))
    (subpath (param "PROVIDER_HOME"))
    (subpath (param "TMPDIR")))
(allow file-write-data (literal "/dev/null") (literal "/dev/tty"))
(allow mach-lookup)            ; DNS + system services
(allow network-outbound)      ; LLM API + agent network tools (toggle for offline)
(allow sysctl-read)
(allow signal (target same-sandbox))
```

**Parameterization, not interpolation.** Generate the profile with
`(param "WORKSPACE")` placeholders and pass values via `sandbox-exec -D
WORKSPACE=/abs/path`. Do **not** string-interpolate paths into the `.sb` text —
a path containing a quote, paren, or backslash would otherwise break the profile
or escape its scope. Resolve every path to its canonical real path first
(`realpath`) before passing it; the security-boundaries doc already flags
`..`/symlink import escapes, and Seatbelt matches on resolved paths.

### Policy and enforcement integration

- **Settings toggle** (`AppStorageKeys.sandboxEnforcement`), three modes:
  - `off` — never wrap.
  - `bestEffort` — wrap when possible; if `sandbox-exec` is missing or fails to
    launch, log a diagnostic and run unwrapped.
  - `strict` — wrap always; if it cannot be applied, **fail the run closed**
    (never silently run unconfined).
- **Default per policy level:** enforce for `autonomous` (the broad-permission
  mode, `AgentPolicyLevel.isBroadPermissionMode`); `bestEffort` elsewhere.
- **Produce `PolicyEnforcementTier.osSandboxed`** in the run manifest /
  `ProviderPolicyRender` so the existing permissions UI surfaces "OS Sandboxed"
  — wiring up a tier that has been dead since it was defined.
- **Avoid double-confinement.** Default the Astra Seatbelt to providers
  *without* a native sandbox: **Claude Code and Copilot**. For
  Codex/Cursor/Antigravity, default to skipping (they self-sandbox → tier
  `providerNative`); offer opt-in layering as defense-in-depth → tier `mixed`.
  Layering Seatbelt over Codex's own sandbox can break it, so this is explicit,
  not default.
- **Isolation coupling.** `task.isolationStrategy` (`.copy` / `.gitBranch` /
  `.sameDirectory`, `Astra/Services/Runtime/IsolationService.swift`) determines
  the writable scope. `.copy` yields the tightest, truest confinement; document
  that `.sameDirectory` confines to the live workspace.

### Where the code lives

- New `Astra/Services/Runtime/ExecutionSandbox.swift`:
  - `ExecutionSandbox.wrap(plan:task:providerHomeDirectory:settings:) -> AgentRuntimeProcessLaunchPlan`
  - profile generation (template string or bundled resource)
  - `sandbox-exec` availability + macOS guard
  - canonical-path resolution and `-D` argument assembly
- Audit events mirroring `IsolationService`'s use of `AppLogger.audit`:
  `sandbox_applied`, `sandbox_fallback`, `sandbox_failed`, with task id and
  enforcement mode — per `AGENTS.md` ("explicit service boundary and durable
  events," not hidden background behavior).
- Settings surface alongside existing runtime/policy settings.

## Implementation phases

### Phase 1 — Profile generator + boundary tests (no app wiring)

- `ExecutionSandbox` profile builder and `-D` argument assembly.
- Unit tests: golden-string assertions that writable subpaths appear, that
  arbitrary paths do not, and that `-D` values are passed (not interpolated).
- **Integration test (the proof):** invoke `/usr/bin/sandbox-exec` with a
  generated profile around `/bin/sh -c '…'` and assert:
  - write **inside** `$WORKSPACE` succeeds,
  - write to `$HOME/escape` and `/tmp/escape` (outside scope) **fails with
    EPERM**,
  - read outside scope succeeds.
  This proves the kernel boundary end-to-end and runs in `swift test` on macOS
  CI.

### Phase 2 — Wrap the execution seam

- Thread `providerHomeDirectory` into `runProcess`.
- Apply `ExecutionSandbox.wrap` for Claude Code + Copilot, `bestEffort` default.
- Audit events on apply / fallback.
- Regression: existing runtime tests still pass; a wrapped Claude/Copilot run
  completes and writes its output inside the workspace.

### Phase 3 — Settings, strict mode, enforcement tier

- `AppStorageKeys.sandboxEnforcement` + Settings UI.
- Strict mode fails the run closed when the sandbox cannot be applied (test:
  simulated missing `sandbox-exec` → run fails, audited).
- Emit `PolicyEnforcementTier.osSandboxed` in the manifest; surface in the
  permissions UI.

### Phase 4 — Layering + offline variant

- Opt-in Seatbelt layering for self-sandboxing providers (tier `mixed`).
- Offline `(deny network*)` profile variant for a locked/no-network mode.
- Extend `script/security_hunt.sh` red-team checks with outside-workspace write
  attempts under each enforcement mode, per the security-boundaries doc.

## Testing

- Unit: profile generation, param escaping, runtime inclusion/exclusion rules,
  enforcement-mode resolution, the over-broad-root guard, the
  `sandbox_exec_missing` branch (injected `FileManager`), the strict/best-effort
  mapping for every unavailable reason, and the runner's decision→launch outcome
  mapping (`sandboxOutcome`).
- Integration: real `sandbox-exec` boundary tests — clean write boundary,
  special-character workspace paths, symlink-traversal escape, `unlink`/`chmod`
  of outside files, and offline `(deny network*)` blocking a real loopback
  connection (with an online control); a real wrapped provider run if a provider
  CLI is available in CI.
- Regression: `swift test --filter` on the runtime suites first
  (`AgentRuntime*`, `CodexCLIRuntime`, `CursorCLIRuntime`), then broaden.
- Manual red-team on `ASTRA Dev.app` only, per
  `docs/security/security-boundaries.md`: seed `ASTRA_TEST_SECRET_123`, attempt
  `..`/symlink escapes and outside-workspace writes, confirm the kernel blocks
  them and no secret leaks into events/diagnostics/logs.

## Risks and open questions

- **Provider state paths.** The biggest functional risk is an incomplete
  writable allowlist breaking a provider on launch. Mitigate by starting from
  `providerHomeDirectory` + `$TMPDIR` + known per-provider config/cache dirs,
  and by running Phase 2 in `bestEffort` so a miss degrades to unconfined +
  audited rather than a hard failure during rollout.
- **`sandbox-exec` is deprecated** by Apple (still fully functional, widely
  used). Acceptable and matches the issue's Codex reference; long-term hardening
  could move to an Endpoint Security helper. Documented, not blocking.
- **Subprocess depth.** Confirm agents that spawn build tools / language
  runtimes inherit the profile correctly (they do — Seatbelt is inherited across
  `exec`/`fork`), and that `(allow process-exec*)` plus broad read cover the
  toolchain.
- **Decisions to confirm** (recommended defaults in bold):
  - Layer over Codex/Cursor/Antigravity, or skip? → **Skip by default, opt-in
    layer.**
  - Default enforcement mode? → **`bestEffort` globally, `strict` for
    `autonomous`.**
  - Ship the offline/no-network variant now or later? → **Phase 4;** default
    network-allow so agents function.
