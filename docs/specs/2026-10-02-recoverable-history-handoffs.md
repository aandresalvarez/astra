# Recoverable history and runtime handoffs

Addresses the evidence-retention and context-continuity parts of [#369](https://github.com/aandresalvarez/astra/issues/369).

## Durable evidence and bounded presentation

`TaskEvent` rows remain the source of original event evidence. `AgentEventCompactor`
now updates one derived navigation summary instead of deleting conversation or
tool events. It queries at most 250 source rows, summarizes a sample of at most
200 older rows, and leaves IDs, timestamps, run links, agent identity, and payloads
intact. A repeated settlement with unchanged inputs reuses its summary. Existing
deletion summaries are preserved because they may be the only remaining record
of details that an older version discarded. Previously deleted events cannot be
reconstructed by this change. Settled private recovery envelopes keep their
existing cleanup policy.

Transcript pages still come from storage through `TaskThreadHistoryReader` and
`TaskThreadHistoryStore`. A backdated summary invalidates the loaded projection;
refresh includes growth since the previous count so it does not discard the
oldest rows of a transcript the user already expanded.

## Launch continuity

A runtime's ability to resume a provider session does not prove that this launch
will resume one. Fresh follow-ups default to the extended transcript window and
context budget. The worker selects the standard window only after its existing
session, prior-run, safety, and launch-signature checks return a native session
ID. Model, runtime, policy, or resource changes that invalidate continuation
therefore receive the wider rebuilt context. Budget enforcement and context
diagnostics apply to the final prompt sent to the provider.

Rejected preflight attempts do not record a provider launch signature or inherit
a provider session ID. After admission, the worker pairs the signature with the
native session selected for that launch; a fresh launch receives its new session
ID from the provider's start event. Raising the budget after a rejected model or
policy change therefore cannot make the old session appear compatible. A failed
fresh launch that never reports a session likewise cannot replace the old
session's recorded settings.

The capsule reserves room for current objective, newest user instructions,
constraints, acceptance criteria, unfinished work, and verification before
optional historical sections. Instructions are labeled newest first; omitted
detail is disclosed and canonical state pointers retain reserved space. This is
a prompt projection policy, not a second owner of task intent.

## Original-event retrieval

The run-scoped authenticated host-control broker offers a read-only `history`
tool. Its reader is bound to the durable model container and task ID before a
detached execution task reaches a provider, and the binding is removed when that
launch finishes. Each call creates a fresh read-only context on the broker's
connection queue; no managed model or context crosses that boundary.

- No arguments: newest 10 readable events, with payload previews of at most
  1,000 characters. `next_before_id` selects an older page; timestamp/UUID order
  handles ties without offsets into a changing list.
- `event_id` and optional `offset`: an original payload chunk of at most 4,000
  characters, with `next_offset` until complete. Offsets count Swift characters,
  preserving Unicode payloads. Event/run IDs, timestamps, category, and agent
  identity accompany each chunk.
- CLI relay: `astra-host-control history --before-id UUID`, or
  `astra-host-control history --event-id UUID --offset N`.

Caller-selected task IDs, paths, mutation operations, malformed cursors, and
private result-capture/outcome-preparation envelopes are rejected. MCP and CLI
use the same request validation and broker reader. History is offered when a
transport can deliver it; it does not by itself require rerouting, withdraw native
shell, or block a run. A missing reader returns an explicit unavailable error.
Provider guidance requires newer user direction to take precedence over old
evidence and treats retrieval failure as an evidence gap.

## Validation scope

Regression coverage exercises repeated summarization and runtime switches,
reopening an on-disk store, exact Unicode payload reconstruction with metadata,
legacy summaries, cross-task/private-envelope denial, CLI transport, actual
fresh/native/model-change worker launches, crowded capsule budgets, expanded
transcript refresh, and bounded pages over 5,000 events. The existing large-task
reader and presentation suites remain part of validation. This scope does not
establish interactive scrolling performance at arbitrary event volumes or
restore evidence deleted by earlier releases.
