# Runtime cancellation and recovery acceptance

Base: PR #542, merged as `8a3ff4fec905c4622792e1b2088f3c29ef5b2445`.
This work applies the same proof gate to all six adapters, every stop reason,
explicit follow-ups, Retry, automatic recovery and restart reconciliation.

## Signals and their limits

| Runtime tested | Activity / input | Completion evidence | What never grants release |
| --- | --- | --- | --- |
| Claude Code 2.1.310 | Typed text/thinking stream; ASTRA interactive asks persist waiting state | Native `result`, complete EOF, reaped child and empty process group | Tool/permission/subagent activity, nonzero server-tool counters, unknown frames |
| Codex CLI 0.164.0 | `thread.started`, `turn.started`, typed message/reasoning items | Native `turn.completed` plus the shared OS/EOF proof | Command/tool items, unfamiliar items, another provider's result |
| Antigravity CLI 1.4.7 | Typed `step_update` states; interactive asks | Native `result.status` plus the shared OS/EOF proof | Tool steps, unknown states, silence |
| Copilot CLI 1.0.103 | Native assistant/model lifecycle frames; interactive asks | Native `result` with session and exit code plus the shared OS/EOF proof | Usage, stats, shutdown, model-call completion, hidden tool requests |
| Cursor CLI 2026.10.22-27dcf5f | Typed assistant/thinking events; interactive asks | Native `result` plus the shared OS/EOF proof | Tool blocks, unknown subtypes, readable text alone |
| OpenCode CLI 1.19.4 | Session-bound text, reasoning and step events | Last `step_finish(reason=stop)` **and natural zero exit and full EOF**, then shared ownership proof | Step finish alone, cancellation whose handler returns zero, tool-calls finish, later activity, incomplete pipe drain |

The installed OpenCode CLI does not emit its internal session-idle event. Its
per-step finish is provisional until process completion. Usage is accumulated
per session/part, including cache and reasoning, with duplicate/correction
handling. Both streaming and utility consumers receive the same projection.
Invalid accounting cannot authorize a successful completion or replenish limits.

None of these CLI stdout transports provides a generic reattach operation after
ASTRA loses the pipe. ASTRA keeps an existing connection when it owns it, inspects
the exact OS process identity after restart, and continues a saved native session
only after cleanup is proved. A live orphan is protected, not relaunched.
Provider-native permission errors are not assumed to be an answerable ASTRA ask.

Tool responses and local exit do not attest that detached or remote work stopped.
Such tasks retain their reservation even if their result is visible. This also
applies to arbitrary validation commands. There is no time-based release, model
override or unchecked Retry escape. Historical releases already persisted by an
older version remain historical decisions; unresolved legacy work stays fenced.

## Automated coverage

Production runner tests cover natural OpenCode completion, cancellation returning
zero, lost finish, invalid final partial usage and utility accounting. Real local
child/pipe tests distinguish natural reaping from late cancellation and incomplete
EOF. Provider contract tests use strictly projected, synthetic-text envelopes
captured from installed CLIs; Copilot's capture is a quota failure, not a successful
provider task. No credentials, user text, real session IDs or personal history are
included in fixtures.

All six adapters are parameterized through durable ownership, disk reopen,
competing admission, cross-provider workspace claims, independent workspaces and
continuation accounting tests. Tests additionally cover unverified non-user stops,
legacy interrupted preparations, full cleanup before new user turns, and saturated
usage across supervision, previous attempts and follow-ups.

## Native acceptance

Development-channel build, separate bundle identity and private App Support store;
synthetic workspaces and private provider homes. Only existing authentication is
used. A test transport launches the real installed CLI, relays authentic events,
and holds the transport after provider exit. A separate scenario deliberately
omits the terminal frame. These faults exercise ASTRA's production queue, process
runner and durable owner; they do not fabricate a stop receipt.

Access probes succeeded for Claude, Codex, Antigravity and Cursor. Copilot returned
HTTP 402 (monthly quota exhausted). OpenCode had no configured provider credentials;
its advertised free endpoint returned HTTP 403. Those two providers cannot receive
a successful real-task acceptance claim with the available access.

| Runtime | Automated verification | Real development-app result |
| --- | --- | --- |
| Claude Code | Native frame contract, complete/incomplete EOF, durable stop gate, competing claims, Retry/reopen and cumulative limits | Manual Stop after the authentic final frame released the reservation (`0771488B`); successor `38CD43DF` completed once. A withheld final/incomplete stream (`F1D67AD8`) retained its reservation before and after Retry and app restart. |
| Codex CLI | Native terminal versus command/tool activity, durable stop gate, competing claims, Retry/reopen and cumulative limits | Manual Stop released `EE57AC0A`; successor `A6B32F8A` completed once. Dropped `turn.completed` in `A46D217D` retained the reservation, including Retry and restart. |
| Antigravity CLI | Native result/step contract, shared configuration ownership across processes/restart, durable stop gate and cumulative/estimated limits | Confirmed terminal retirement released `31D54ACA`; successor `20D3B139` completed once. This positive case used ASTRA's terminal transport retirement, not the manual Stop button. Dropped result plus manual Stop in `311CE306` retained the reservation across Retry/restart. A different workspace sharing its provider configuration was also refused before launch. |
| GitHub Copilot CLI | Native result versus stats/usage/shutdown/tool requests, durable stop gate, competing claims, Retry/reopen and cumulative limits | Actual task `7DCFB73B` failed with HTTP 402, monthly quota exhausted. Cleanup remained protected. Successful cancellation/recovery scenarios could not be tested with this account. |
| Cursor CLI | Native terminal/thinking contract, durable stop gate, competing claims, Retry/reopen and cumulative limits | Manual Stop released `6ED00702`; successor `25384BAC` completed once. Dropped result in `5C265010` retained the reservation, including Retry and restart. |
| OpenCode CLI | Production runner natural finish, cancellation returning zero, missing final, incomplete EOF, invalid usage, deduplicated per-step accounting; shared ownership/limits matrix | Actual task `CD2DE238` stopped at account preflight: no configured credentials. A separate direct free-endpoint probe returned HTTP 403. No successful native completion or cancellation claim. |

All positive provider tasks requested a short synthetic response without tools.
The fault transport never emits a fabricated final event or stop receipt. The
manual positive cases cancel the held transport only after the real provider's
terminal frame; the negative cases deliberately remove or withhold that frame.
These results do not certify arbitrary detached or remote tools.

Cross-provider contention was observed in the app: Codex `E7BD2FF5` waited for
Claude `4F411EDE` in the same workspace, then completed with exactly one run.
Antigravity and Cursor in independent workspaces continued while Codex's missing
final retained its reservation. Independence also requires separate provider
configuration when a runtime mutates shared state; Antigravity's reserved MCP
configuration is intentionally protected across workspace boundaries.

Before/after restart snapshots compared all 16 existing owner records, including
execution IDs, run IDs, stop proofs, remaining seconds/turns and token ceilings.
They were unchanged. No additional task run or provider launch occurred in the
four protected workspaces. Each waiting successor retained zero runs. Clicking
**Check again** for each of the four uncertain executions after restart preserved
the same records and limits. An unrelated OpenCode title-generation utility was
identified separately; it was not a recovered task execution.

Native QA also exposed two presentation gaps: an uncertain task still offered a
generic approval/retry dock, and a shared-provider reservation appeared as an
internal error. Recovery now explains the saved owner, retains queued messages
and their cancellation controls, and shows **Check again**. A prelaunch shared
configuration block pauses without an automatic restart or estimated token cost.
The rebuilt app confirmed that Antigravity's new blocked attempt retained the
prior 1,304-token ledger without adding usage or launching a provider. A Codex
follow-up was saved under **Recovery blocked**, with **Cancel request** available;
cancelling that request left the original execution owner and reservation intact.
After the final dock-policy rebuild, this Retry/queued-message/cancellation flow
was repeated. All 19 owner records, every task's run count and every recorded
provider launch count were unchanged. Automated regressions also cover a stale
permission alongside the queued message and preserve live permission priority.

Settlement recovery distinguishes completed local bookkeeping from cleanup
authority. If an arbitrary validation command ran before a failed verdict save
or projection, recovery keeps its result and reservation without repeating the
command. The command's exit alone cannot authorize Retry or finalization that
may dispatch downstream work. Regression cases cover both this refusal and
successful recovery of a prepared result that launched no validation commands.

Private evidence is retained under `/private/tmp/astra-runtime-safety-20261024`:
read-only store/owner snapshots, synthetic workspace transport logs and authentic
provider streams. Raw streams and authentication copies are not committed.
