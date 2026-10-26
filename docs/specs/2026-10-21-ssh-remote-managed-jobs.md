# Managed jobs for SSH remote workspaces

## Scope and guarantees

This change adds `start`, `status`, `tail`, cancellation and app monitoring for
native-shell SSH routes. It builds on the single persistent execution owner and
resource protection merged in #550. It does not automatically continue a
provider when a remote job finishes.

The existing run permission manifest remains the authority for SSH. The helper
runs the initial SSH command in the provider's sandbox; the app's broker only
registers it. Explicit `--connection` is required so a denied destination or
remote command cannot disappear from policy evaluation. Quoted executable paths
and every helper invocation in compound commands are checked. An ambiguous
helper invocation is denied. Ask and Auto keep their existing behavior.
Cursor's `shellToolCall` is classified by the shared tool semantics as a shell
request, so SSH deny rules and exact command approvals also apply to its native
frames. Runtimes without live approval need a new run after an Ask checkpoint;
approval alone cannot bypass the previous owner's stop-proof requirements.

Packaged apps resolve the helper from their own resource bundle and refuse a
missing bundled helper rather than falling back to a stale shared executable.
The launch grants read-only access to that exact helper and owner receipt.
An isolated development App Support override also isolates installed tool
copies; production ignores that override.

## One owner and one launch intent

After `RuntimeExecutionOwner.prepareLaunch` assigns the final execution ID,
ASTRA prepares a broker and configuration bound to that exact task, run, owner,
and execution. A live helper must match the shipped executable and descend from
the recorded provider. File-drop transport uses the existing broker's per-run
token and helper ancestry checks; it does not create another execution owner.

The app stores registrations outside provider-writable workspaces, next to the
owner journal under `remote-jobs/<task>/<execution>/`. A stable hash of the
owner, connection and command intent is serialized under a kernel file lock.
The registration is fsynced before replying to the helper. Only the first
admission can launch SSH. An interrupted registration or lost launch reply may
leave an unstarted job, but repeating it never creates another launch. A
cancelled, expired or replaced owner cannot admit new jobs. Remaining limits
are captured from the owner, never reset from edited task settings.

## Remote execution and cancellation

The host requires Python 3.9 or later, `clock_gettime(CLOCK_MONOTONIC)`, and a usable POSIX process table. It creates
`~/.astra/jobs/<uuid>` exclusively, binds metadata to a fresh nonce, and starts
an outer supervisor plus an anchored process group. The supervisor tracks the
command and ordinary children even when the original shell exits first.

Cancellation is saved locally before SSH. The probe writes a nonce-bound cancel
request in the admitted job directory. Only the original live scope signals its
own process group: TERM first, then KILL after a grace interval even if children
ignore TERM. ASTRA never signals PIDs taken from mutable remote metadata.
Disconnected cancellation stays pending and is delivered on subsequent checks,
including after an ASTRA restart. Before deleting a task, ASTRA must also save
a cancellation delivery receipt and a private copy of the original public
known-host keys. Delivery and startup reconciliation use this receipt even
when the SwiftData task or its folder no longer exists. A failed save blocks
deletion; the receipt can only cancel/probe its original owner and execution.
Whole-task cancellation is retained even if registration is still in flight
and the job journal is empty. Later registrations receive that saved stop;
cancelling one job never widens the request to other jobs. Local worker
finalization updates its owner journal without reading or recreating deleted
SwiftData task/run models.

ASTRA obtains a fixed SSH observation of the host's boot identity and monotonic
clock. Only after the reply arrives does it calculate the local remaining
allowance and add that allowance to the earlier remote monotonic instant.
Transit can only shorten the job. The first registration keeps that deadline;
repeated starts never recalibrate it. Before `Popen`, the supervisor requires
the same boot identity and a positive monotonic allowance. Missing/invalid
clock evidence refuses launch. No comparison of the two hosts' wall clocks
is used, and uncertainty never grants release or restart authority.
The admitted deadline also remains fixed across process creation and log I/O.
The clock domain is persisted explicitly and sampled with protocol version 2.
Python 3.9 on macOS gives `time.monotonic()` a process-relative epoch
([Python time documentation](https://docs.python.org/3/library/time.html#time.monotonic)), so both
the sampler and supervisor instead use the same explicit POSIX clock. Missing
or incompatible clock domains refuse command launch; existing jobs can still
be observed and cancelled, and their intents are never recalibrated.

A process group is not containment. A command can detach with a new session,
submit work elsewhere, or mutate its own metadata. Consequently every SSH job
has `cleanupVerified == false`: a reported result, empty local process group,
model judgment, timeout or lost connection NEVER sets `toolsStopped`,
`remoteWorkExcluded`, or releases the execution owner's reservation. Retry and
competing work remain subject to #550's existing proof requirements.

## Observations and app behavior

Version 2 probes require a complete framed response, job ID, nonce, boot identity,
explicit liveness fields, and successful SSH/script exit. Partial output and
nonzero exits are unreachable observations, not proof of absence. PID start
markers must match. A missing final result, missing directory, reboot, or late
launch is unverified and continues to be checked. Terminal observations are
also rechecked. A probe is dated before SSH starts so a slow old response cannot
overwrite a newer observation.

The app uses `/usr/bin/ssh` directly with the task's explicit host-key options;
it never executes an agent-editable wrapper. It revalidates the saved connection
against the workspace before contacting the host. A changed connection blocks
observation/cancellation and explains how to restore the original connection.
The initial SSH shim and app observations share the same quoted known-host file
argument, preserving spaces, quotes, and backslashes through OpenSSH's separate
filename-list parser.

A queue-store-owned monitor refreshes asynchronously every 15 seconds. Its
only side effects are observations and delivery of saved cancellation intent.
The task's Remote jobs panel shows the observed status, last successful check,
connection errors, cancellation pending, bounded output and why the workspace
remains reserved. Check now, Read output and Cancel job use the same service.
Stopping the task also requests cancellation of registered remote jobs.

Every admission/status/cancellation transition is kept in a durable outbox in
the protected job record. The monitor reconciles it to typed task events with a
stable event ID, then acknowledges it. A crash between these stores cannot
lose or duplicate published history. A deleted task is checked for liveness
before and after asynchronous SSH work and cannot be recreated by monitoring.

## Verification

Automated suites cover normal outcomes/logs, rechecking terminal observations,
unreachable hosts, lost finals, late starts, nonce framing, explicit targets,
quoted/compound policy checks, persistent duplicate admission, cancellation
across reconnect, an ignoring child after parent exit, expired admissions,
final execution binding and crash-safe event reconciliation. The script-level
fixtures run real processes through a fake SSH transport; they are not native
app or real-SSH acceptance evidence.

Native acceptance uses a separately identified development app, separate
Application Support storage, synthetic workspaces and a real loopback OpenSSH
server with temporary keys and an isolated remote HOME. Record final native
outcomes and limitations separately from unit tests, full suite, hooks and CI.
