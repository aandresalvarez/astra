# Homogeneous Ask Experience — Implementation Plan

**Goal:** make "Ask mode" mean the same thing — *ASTRA, not the provider, decides whether a risky action runs* — across all six runtimes, to the maximum degree each provider physically allows, and label the remaining gaps honestly instead of implying parity.

**Why this is needed (the bug, in one table).** The same prompt ("run `git status` with Bash") got four different treatments in prod because four different authorities were consulted:

| Provider | Authority consulted | Result |
|---|---|---|
| Claude | ASTRA policy (stdio control protocol) | Live approval card ✅ |
| Codex | its own `workspace-write` sandbox | self-approved, no ask |
| Cursor | its own `--sandbox enabled` | self-approved, ran it |
| Copilot | its own `--no-ask-user` allowlist | worked around it silently |

Only Claude asks ASTRA. The strategy below makes ASTRA the authority everywhere it can be, with a kernel-level floor underneath for everywhere it can't.

---

## Architecture: two tiers + a floor

Three layers, in dependency order:

1. **Containment floor (all six, kernel-enforced).** macOS Seatbelt wrapping with deny-by-default for ask-first actions. The *only* guarantee that doesn't depend on a vendor ask channel. Covers shell, file writes, and network — but coarse (can't read command arguments).
2. **Native live-approval bridge (per provider, where the channel is machine-answerable).** Reuse the Claude `InFlightPermissionCenter` bridge to answer a provider's own structured permission request. Asks at the provider's *real* decision point, so it covers absolute paths, in-process edits, and network that a PATH shim can't name. **Claude = done. OpenCode = next. Codex/Cursor = pending upstream verification. Copilot/Antigravity = not feasible (TTY-only).**
3. **Honest coverage labels.** A per-task badge that tells the user which tier they're actually on.

**Why not the PATH-shim from the earlier draft?** The grounded review showed it is strictly *weaker* than what we already have on the one axis that matters most: ASTRA's existing post-hoc guard already normalizes `/usr/bin/git` → `git` for matching (`AgentRuntimePolicyGuard.swift` `segmentWithExecutableBasename`), but a PATH shim is bypassed by absolute paths, `python -c`, and builtins. The shim is dropped from the plan. The native-channel approach (owner's idea 1) is the correct target; Seatbelt is the floor; plan mode (owner's idea 2) ships as an optional power feature, not a replacement for Ask.

---

## P0 — Close the Auto-mode floor hole *(must land first)*

**Problem.** In autonomous (Auto) mode, Codex / Cursor / Antigravity run with their own sandbox **disabled** (`--dangerously-bypass-approvals-and-sandbox`, `--force --sandbox disabled`, `--dangerously-skip-permissions`) **and** are not in `defaultWrappedRuntimes` (`[.claudeCode, .copilotCLI]`). So Auto mode on those three has *no gate at all* — neither vendor nor ASTRA. Every later phase claims "there's a floor"; today that claim is hollow for half the fleet.

**Change.**
- `ExecutionSandbox.swift`: when `permissionPolicy == .autonomous` and enforcement is on, force `wrappedRuntimes` to include the native-sandbox runtimes (Codex/Cursor/Antigravity/OpenCode) regardless of the `layerNative` user toggle — Auto must never run a provider with both gates off. The escalation hook already exists at `ExecutionSandboxSettings.current` (`bestEffort` → `strict` for autonomous); add the wrapped-set union beside it.
- Verify the Seatbelt profile (`makeProfile`) actually applies when layered over a provider whose own sandbox is bypassed (the bypass flag affects the *provider's* sandbox, not our outer `sandbox-exec` wrapper — confirm with a behavioral test that a write outside the writable allowlist is denied).

**Files:** `Astra/Services/Runtime/ExecutionSandbox.swift`, `Tests/ExecutionSandboxTests.swift`.
**Test:** autonomous Codex/Cursor/Antigravity runs are wrapped; a write outside the workspace is kernel-denied; a write inside is allowed.
**Risk:** layering Seatbelt over a provider's own (now-bypassed) sandbox could interact badly — needs a real run per provider, not just unit tests. Gate behind the existing enforcement preference so it's reversible.

---

## P1 — Foundational plumbing for any second live-approval provider

Two small, provider-agnostic changes that every later live-approval phase needs. No new attack surface.

**1a. Per-request resolution in `InFlightPermissionCenter`.** Today `resolveAll(taskID:approved:)` collapses *all* concurrent pending asks for a task into one answer. With one ask in flight at a time (the Claude case) that's fine, but a second provider — or a provider that batches asks — needs per-request answers.
- Add `awaitDecision` keyed by a request id, and `resolve(taskID:requestID:approved:)` alongside the existing `resolveAll` (keep `resolveAll` for process-death cleanup).
- `PendingAsk` already carries `requestID`; thread it through.
- **Files:** `Astra/Services/Runtime/AgentInteractivePermissionChannel.swift`. **Test:** two pending asks resolve independently.

**1b. `permission.request.resolved` event.** Today only `task.approved` closes an open approval card (`TaskDecisionDockContextBuilder` / `TaskLifecycleCoordinator` derive "has open request" from the latest `permission.approval.requested` vs `task.approved` timestamps). A *denied-but-still-running* live ask (the Claude deny path, and every future provider's) leaves a stale card because no `task.approved` is emitted.
- Emit a `permission.request.resolved` event (with the request id + allow/deny) when a live ask is answered; include it in the "open request" recency check.
- **Files:** `Astra/Models/TaskEventTypes.swift`, `Astra/Services/Tasks/TaskDecisionDockContextBuilder.swift`, `Astra/Services/Tasks/TaskLifecycleCoordinator.swift`, the worker's `interactiveAskHandler` resolution branch. **Test:** deny resolves the card; the run continues.

---

## P2 — The Auto-mode auto-approve classifier *(precondition for idea 1)*

**Problem.** Owner's idea 1 says "in Auto mode, ASTRA auto-approves the provider's native asks." Done naively that is a **security regression** — it lets the *provider* define the blast radius, so `rm -rf /` self-approves. Auto must auto-approve **only what's inside ASTRA's existing policy envelope** and deny the rest (the deny-list: `rm:*`, `sudo:*`, `git push:*`, `deploy:*`, `chmod:*`…), exactly as Ask mode would for a non-interactive grant.

**Change.** A single classifier that, given a parsed permission request (tool/command/path/url) and the run's policy, returns `.autoApprove / .forwardToUser / .deny`. This is the decision function the live-approval handler calls in Auto mode instead of always prompting.
- Reuse `PermissionBroker.providerNativePromptRequest` (request shape) + `AgentRuntimePolicyGuard` (the allow/ask/deny evaluation already used post-hoc) so the classification matches what Ask mode enforces — one source of truth, no drift.
- In Auto: `.autoApprove` → answer allow; `.deny` → answer deny with a message; `.forwardToUser` collapses to `.autoApprove` *only* for the routine-work tier, else deny (Auto is "routine work auto, terminal denials still stop").
- In Ask: everything that isn't already granted → `.forwardToUser` (the live card).
- **Files:** new `Astra/Services/Runtime/AutoApprovalClassifier.swift` (thin, delegates to broker + guard); wire into `AgentRuntimeWorker.interactiveAskHandler`. **Test:** Auto auto-approves `git status`, denies `git push`/`rm -rf`, never blanket-approves; Ask forwards everything ungranted.

**This unblocks idea 1 safely** and is reusable by every provider bridge in P3.

---

## P3 — OpenCode live approvals *(the first non-Claude live provider)*

OpenCode already emits a structured `permission.asked` JSON event — the parser handles it today at `OpenCodeStreamEventParser.swift:100-101,159` but **discards the request id** and collapses it to `.permissionDenied` (no reply path). This is the one new provider where idea 1 is bounded work.

**Change.**
- Capture the request id (and tool/patterns) in `permissionEvent`; add a parsed event type that carries the id (e.g. `.permissionRequested(id:tool:reason:)`) distinct from the terminal `.permissionDenied`.
- Open a reply channel and, on the user's decision (via `InFlightPermissionCenter` + the P2 classifier), write the answer back. **⚠ Verification gate:** confirm upstream *how* OpenCode wants the permission answer — stdin control line, or a call to its local server? The probe confirmed the *request* is structured JSON; the *reply transport* is *unverified in-repo*. Spike this against the real `opencode` CLI before committing the design.
- Reuse the Claude bridge: `interactiveAskHandler`, the heartbeat keep-alive (so `AgentProcessMonitor`'s 600s idle timeout doesn't kill a run waiting on the user), and the stdin-channel plumbing in `AgentRuntimeProcessRunner`.
- Flip `PlanCheckpointPolicy.tier(for: .openCodeCLI)` → `.liveApprovals` once it works.
- **Files:** `ASTRACore/OpenCodeStreamEventParser.swift`, `Astra/Services/Runtime/OpenCodeCLIRuntime.swift` (+adapter), `Astra/Services/Runtime/AgentRuntimeProcessRunner.swift`, `Astra/Services/Tasks/PlanCheckpointPolicy.swift`. **Test:** scripted fake OpenCode emits `permission.asked`; ASTRA pauses, the card shows, approve continues the same run, deny is acknowledged.
- **Outcome:** proves the idea-1 abstraction generalizes beyond Claude on a real provider, and gives a second live-approval runtime.

---

## P4 — Coverage badge (honesty layer)

A per-task badge derived from the runtime + policy + sandbox settings:
- **Guaranteed** — Seatbelt floor on + live approvals (Claude, OpenCode).
- **Best-effort** — live approvals, floor off, or floor-only.
- **Provider-managed** — no ASTRA live ask, run-boundary + floor only (Codex/Cursor/Copilot/Antigravity).

Plus: relabel native provider prompts that ASTRA can only detect as blocking text from generic "blocked" to **"ASTRA can't answer this provider's prompt — approve in the provider, or switch runtime/mode."** This makes the heterogeneity visible instead of surprising.
- **Files:** a small presentation helper + the task header/decision dock. **Test:** badge maps correctly per (runtime, policy, sandbox) tuple.

---

## P5 (optional, later) — Codex / Cursor live approvals *(gated on upstream verification)*

**Do not start until** an upstream check confirms `codex --ask-for-approval` / `cursor-agent --mode ask` emit a *machine-answerable* request (structured, with an id, answerable over a channel we can drive) rather than a TTY `y/n` prompt. If they're TTY-only, **stop** — PTY prompt-scraping is more fragile than their current run-boundary gating, and the floor + plan mode already covers them. If verified, the build mirrors P3.

**Copilot and Antigravity are explicitly out of scope for live approvals** — TTY-only on available evidence. Their ceiling is floor + run-boundary gating + honest badge.

---

## What will never be homogeneous (state this in the UI, don't hide it)

1. **Mid-step per-action asks** exist only for Claude + OpenCode (and any future verified provider). The other four self-approve inside their sandbox; ASTRA gates *between* steps and the Seatbelt floor is the real stopper.
2. **Absolute-path / builtin commands** under live-approval providers can still slip the *pattern-granular* ask (the model chose an absolute path) — only the coarse Seatbelt floor catches those.
3. **Provider tool timeouts** while a human decides — a CLI may give up before you answer; uncontrollable.
4. **Model behavior while blocked** — Claude understands a pending ask; a non-Claude model sees a slow/hung tool and may retry or abandon. Wrapper/stderr messaging mitigates, never eliminates.

The P4 badge is the honesty mechanism for all of these. **Do not market "Ask mode = same safety everywhere"** — the code shows that's false; market "ASTRA-owned gating cadence + kernel safety floor on every provider, live per-action approvals where the provider supports it."

---

## Sequencing

```
P0 (Auto floor hole)  ──┐
P1 (per-request + resolved event) ──┬──> P2 (Auto classifier) ──> P3 (OpenCode live) ──> P4 (badge)
                                    │                                                    └──> P5 (Codex/Cursor, IF verified)
```

- **P0 and P1 are independent and ship first** (P0 is the security-critical one).
- **P2 depends on P1** (the classifier answers through the per-request channel).
- **P3 depends on P1 + P2.**
- **P4 can ship any time after P0** (it just reads state).
- **P5 is gated on external verification and may never happen.**

## First two PRs this week

1. **P0 — Auto-mode floor fix.** Smallest, highest-stakes, no new concepts. Closes a real security hole.
2. **P1 — per-request resolution + `permission.request.resolved` event.** Pure plumbing, unblocks everything downstream, also fixes the existing stale-card-on-deny papercut in the Claude path.

P2 + P3 (classifier + OpenCode spike) follow once P1 lands. Verification side-quest in parallel: check Codex/Cursor upstream CLI docs to decide whether P5 is ever on the table.

---

## Open verification items (must resolve before the dependent phase)

- **OpenCode reply transport** (blocks P3): how does `opencode` accept a permission answer — stdin line, or local-server call? Spike against the real CLI.
- **Codex/Cursor native ask shape** (blocks P5): structured-JSON-over-stdio or TTY-only? Check upstream `codex` / `cursor-agent` docs.
- **Seatbelt-over-bypassed-sandbox** (blocks P0 sign-off): does our outer `sandbox-exec` wrapper actually deny writes when the provider's own sandbox is off? Behavioral test per provider.
