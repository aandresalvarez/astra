# Accounting across the six runtimes

Budget scope is one user request. Retry, automatic recovery, app restart, permission continuation and plan continuation keep that request's remaining allowance. A separately authored request may obtain a new allowance only after the previous execution and tools have proven termination. Conversation totals retain historical consumption.

## Evidence boundaries

Native tests use the development channel with a dedicated bundle identity (`com.coral.ASTRA.ledgerqa.20261025`), SwiftData store, workspaces and provider homes. All tasks are synthetic, with Ask permissions. Transparent launchers execute installed provider binaries; they do not fabricate responses or usage. Computer Control submits requests and inspects terminal app states. Read-only database snapshots and execution receipts corroborate usage and ownership.

The local evidence root is `/private/tmp/astra-usage-six-qa`. This directory contains screenshots, snapshots and the isolated build/launch scripts; credentials are excluded from this report and the repository.

| Runtime | Automated coverage | Real provider in ASTRA Dev |
| --- | --- | --- |
| Claude Code | Split message counters, cache counters, duplicate snapshots, absent versus explicit-zero usage, request budget, Retry and reload | Authentication unavailable at the last check. User is arranging sign-in; successful model usage is not claimed. |
| Codex CLI | Cumulative-session deltas, repeated/imported reports, incomplete estimated history, zero reports, request and recovery allowances | Multiple completed requests, including native session reuse after restart. A 25,000-token request reported 27,878 and stopped over budget; Retry did not launch again or refill its allowance. After the fix, a new request completed at 31,274/50,000 with lifetime usage 109,391, native session preserved and resources released. |
| Antigravity CLI | Cumulative epochs, cache/thinking subsets, missing/invalid/zero counters, timing metadata, continuation frame evidence | Three completed responses: 10,141, 10,495 and 14,199 tokens. The last reused the previous session after restart. A context-update frame initially kept resources reserved. Fresh final retest completed 8,976 + 10,182 + 13,545 tokens; the last two share a native session, with verified tools/group termination and resources released. |
| GitHub Copilot CLI | Per-call projection and deduplication, session baseline, final shutdown/file metrics, timestamps, cache/fallback counters, metadata and invalid values | Native HTTP 402 `quota_exceeded`. Successful accounting could not be verified. User authorized documenting this limitation and continuing. |
| Cursor CLI | Per-run usage, failure metadata, discarded empty-turn usage, missing versus explicit zero | Three completed responses: 11,025, 11,848 and 12,197 tokens. Conversation continuation after restart used rebuilt context because native session discovery returned missing; this is not evidence of native session reuse. |
| OpenCode CLI | Native accounting, deduplication, zero/missing reports, natural-exit/EOF completion and uncertainty guards | No authorized provider credentials in the isolated profile. User authorized documenting this limitation and continuing. |

One terse Codex follow-up repeated the first response marker; explicitly describing the next request as independent produced the correct new marker. This observation does not invalidate the persisted usage comparison, but no claim of perfect instruction-following is made.

Earlier failed Codex credentials were refreshed privately and tested in a separate task. Its original unresolved receipt was not removed. Likewise, the Antigravity receipt created before recognizing its context metadata remains reserved; the fix does not reinterpret old uncertain receipts into proof.

## Changes verified by regression tests

- Provider-specific normalization feeds the monitor and recorder the same counters. Claude message snapshots and Copilot API-call reports are not mistaken for interchangeable run totals.
- Explicit zero is measured usage; absence or malformed counters remain unknown. Costs, duration and turns can be retained without inventing token evidence.
- Saturating arithmetic prevents token overflow. Cache conventions remain provider-specific; Copilot premium-request multipliers are not labeled USD.
- Cumulative baselines exclude other runtimes, future runs and historical estimates that cannot establish a reset. Unconfirmed request usage is labeled in the UI.
- Persisted ownership and settlement checkpoints drive request progress, including Retry and long/paged histories. Historical conversation totals do not exhaust a separately authored request.
- New requests after a budget stop require reliable cleanup proof. Replaying the same request after restart, Retry, permissions and plan steps do not replenish its allowance.

## Native acceptance checks

1. Submit a minimal text-only request through each configured provider; inspect the final response and saved usage.
2. Submit follow-ups and restart the isolated app. Confirm prior counters persist without duplicate imports; compare provider-session identities.
3. On Codex, reduce the next request ceiling below lifetime usage. Verify the UI reports request usage, not conversation totals.
4. Exhaust that request, press Retry, and verify no additional provider execution or replenished allowance. Submit a new request with an adequate ceiling and verify it completes after cleanup proof.
5. Keep uncertain receipts intact. A provider's result text alone does not authorize releasing resources or launching a competitor.

Focused regressions, full tests, a verified development build, pre-commit/pre-push hooks and CI are required for the final PR revision. Their final results are recorded in the PR checks and description.

## Validation record before publishing

- Independent subagent review found and remediated counter-presence, Copilot fallback/invalid values, metadata retention and request-replay issues. A second pass verified the cleanup-proof boundary and the new-request/recovery distinction.
- Full serial suite before the final review fixes: 9,424 root tests passed, plus auxiliary package suites. This is an intermediate result; final-revision validation is required separately.
- Final accounting/safety focused run: 715 tests in 53 suites passed serially. A combined parallel run had eight timeout/wait failures; unchanged assertions passed in the serial rerun.
- UI/request regression run: 85 tests in six suites passed. Later diagnostics wording is covered by the mandatory hook and final suite.
- The isolated verified build passed and both native defects were retested to terminal results.
