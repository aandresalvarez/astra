# Explicit provider coordination isolation for tests

Provider reservations outlive kernel locks. A fixture can intentionally leave an
unverified journal after its fake provider exits. Before test namespace isolation,
that fixture could publish a pointer in the user's shared coordination directory.
Removing the fixture workspace did not remove its separate in-memory-store
journal or shared pointer. Physical-file identity migration correctly preserves
these unresolved legacy reservations conservatively across profiles.

The empty-retry headless scenario reproduces this: a synthetic prior receipt is
followed by an empty fake CLI exit. Local settlement can finish while the provider
stream still has no complete terminal/tool evidence. `settlementToolsStopped`
describes ASTRA's settlement children; it does not override
`stopProof.toolsStopped`. An absent PID is not a tool-stop receipt.

## Namespace ownership

`ProviderSharedStateNamespace` replaces process-name inference:

- The existing test-bundle load-time constructor declares isolation before any
  suite, singleton gate or ownership handoff runs, including direct `swift test`.
- The test wrapper generates a fresh `ASTRA_TEST_PROVIDER_NAMESPACE_ID` UUID for
  every invocation. Helpers inherit that identity independently of their name.
- A UUID selects a private directory under `/private/tmp`; it cannot select an
  arbitrary app coordination path. Malformed or missing inheritance after bundle
  registration fails closed.
- Each physical test profile belongs to `fixtures/<fixture-UUID>/` under its
  run. Its locks and pointers live in the sibling `coordination/<fixture-UUID>/`
  and survive workspace cleanup. Overrides for that profile must identify the
  same directory. Other runs and ordinary app processes cannot claim it.
- A temporary path or inherited `TMPDIR` alone grants no access. The reserved
  temp parent is identified by device and inode, including its APFS Data-volume
  alias. Lock and pointer operations keep the directory descriptor across waits
  and callbacks and check that the directory is still in place before publishing.
- App processes without a test declaration use the existing shared namespace for app profiles.
  Legacy compatibility, journal authority and release criteria are unchanged.

## Recovery boundary and limits

`ProviderFixtureRecoveryService` is test-only. It creates a new isolated namespace
and captures provenance while constructing a synthetic legacy reservation. It
cannot attach to an existing app coordination directory. The rehearsal requires
exact reference/journal bytes, matching task/owner/execution identities, absent
process identities, a complete bound stop proof, finished settlement, no retained
uncertainty, and both kernel/task leases. It syncs an immutable audit containing
the original pointer and journal before unlinking only the matching pointer.
Retries are idempotent. No journal fields or stop flags are rewritten.

This is not a production repair command. Existing leaked fixtures without
captured provenance or complete tool-stop evidence remain reserved. Do not
weaken legacy conflicts, infer completion from temporary paths, promote settlement
flags into provider proof, or delete locks/journals to bypass admission. Recovering
such an old object requires independently verifiable evidence of its fixture
identity and all execution/tool termination, retained locally for audit.

## Continuing past an unverifiable reservation (2026-11-12)

The boundary above left production with no way forward. 1,002 fixture pointers
leaked into the user's shared coordination directory on Oct 26–29, and their
journal folders under `$TMPDIR` were later purged. Admission reads every legacy
pointer before a file-backed launch, so each Antigravity launch in the
production app failed with `provider_shared_state_blocked` from Nov 4 onward,
and "Check again" could never succeed.

Admission is unchanged: it stays read-only and fails closed on a pointer it
cannot verify. What changed is what the person is shown and may decide. A
reservation block now presents as a warning, "Earlier run may be active", whose
primary action, "Continue…", runs `ProviderReservationReview`:

- Inspecting is read-only and sorts every legacy pointer by what is observed on
  disk and from the kernel while its own lock is held. Nothing is inferred from
  where a journal used to live.
- A pointer whose journal root no longer exists can never be settled. It is
  offered to the person, with the evidence stated: whether it was last written
  before this Mac's most recent restart, which ended every local process from
  that time, or since, in which case an earlier process may still be running
  here. Either way the warning says work on another machine cannot be ruled out,
  and that continuing means both runs would use the same settings file.
- A pointer whose journal still reads belongs to its own task. Unreleased, it
  is named in the warning with "Open Task" and is never offered; released, it
  is ignored. The journal stays the only release authority while it exists.
- A pointer that is in use (its lock is held), unsafe, malformed, missing its
  lock, or pointing at a journal under `/Volumes` (possibly unmounted) is
  reported as unexamined and never offered.
- "Continue" examines each offered pointer again under its lock and requires
  the exact bytes the person reviewed. The pointer is moved, not deleted or
  rewritten, into `released-<review-UUID>/` inside the coordination directory,
  after a `review.json` manifest naming the evidence, the restart time and the
  requesting task is durable. Locks and journals are never touched. The task
  then retries through ordinary admission.
- The requesting task records the decision as a timeline event and the app log
  as `worker.provider_reservations_released`. With nothing reviewable in the
  way, "Continue…" is a plain retry.

The person's decision stands in for proof that cannot exist; nothing else does.
A journal that exists but has lost its record, and a modern `file-v1-` pointer,
remain outside this path.

### The workspace behind it

Continuing past the reservation only exposed the next fence. The retry then
waited for a workspace that a task finished on Nov 6 still held, because its
tool effects were never confirmed stopped. The explicit workspace decision
("Continue this workspace?") existed for exactly that holder, but only a first
instruction, or a new message after a completed turn, could receive it. A task
whose only attempt never launched had no way forward at all.

`RuntimeWorkspaceContinuation.followsUnlaunchedAttempt` closes that gap without
widening the decision itself. The person's own Retry, or their new message, may
receive it when the task's saved execution ended with an explicit zero provider
launches for its latest, failed run, spent nothing, was not cancelled, and
carries no earlier execution of its own. Nothing of that task ran, so the
request is the instruction still waiting to start, not recovery of unverified
work. Schedules, chains, plan steps, relabelled requests, and any attempt that
launched or spent anything stay excluded. The holder's journal is untouched and
the decision still certifies nothing about it. The prompt also offers to open
the holding task.

A task from before the execution journal had the same dead end. It has runs
but no receipt, so it was neither a first instruction nor a task with a
completed, journaled turn, and "Review workspace" answered with a message about
an active execution on a task idle for weeks.
`RuntimeWorkspaceContinuation.followsLegacySettlement` lets the person's new
message there receive the decision on exactly the basis ordinary admission
already uses to start such a task: `RuntimeRecoveryLegacyReconciliation`'s
record that every earlier run ended on this host before the app started. A task
the journal ever tracked is not legacy and stays blocked without its receipt; a
retry replays an instruction that may have run and stays excluded. The prompt
now names this rule when it refuses, instead of three unrelated possibilities.

## Validation

Regression coverage includes bootstrap registration, inherited UUIDs, malformed
inheritance, shared-root aliases, non-temporary provider resources, failed
handoffs, cancellation, the original empty-retry scenario, audited/idempotent
retirement, live processes, incomplete tools/groups/remote evidence, active task
leases, missing/changed provenance and journals, audit failure, and neighboring
unverified reservations. Wrapper tests exercise renamed helpers, failures and
process-group cancellation. Provider scenarios use synthetic homes/configuration
and fake executables; they do not establish live Antigravity authentication or
real-provider success.

The timed worker fixtures use their own capabilities and zero user approval
records. They assert that admission does not read the user's approval store
while measuring the complete worker, including its real process and cleanup.

For the opt-in account-backed Swift tests, set `REAL_PROVIDER_ANTIGRAVITY_HOME`
to an authenticated QA profile inside the active run's `fixtures/<fixture-UUID>/`.
The worker and slash-command utility validate the same path. The wrapper exports
`ASTRA_TEST_PROVIDER_NAMESPACE_ID` before starting its child so an explicit
setup command can prepare that run's QA profile. Native app QA instead starts
the development app with its own store, ordinary coordination and an existing
QA provider profile.
