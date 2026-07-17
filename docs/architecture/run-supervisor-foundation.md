# Run Supervisor Foundation

Status: implemented as a provider-neutral leaf library and executable. ASTRA
runtime adapters do not launch it yet; broker integration belongs to the later
migration PR.

## Root cause and ownership

Long-running work cannot inherit the lifecycle of the ASTRA UI process. App
termination, update replacement, or runtime switching can otherwise orphan a
provider, lose its completion signal, or kill work that should continue. PID
liveness cannot repair that ambiguity because a PID is reusable and carries no
execution identity or launch authority.

Each execution therefore has exactly one supervisor below the future broker.
The broker may disappear without affecting the supervisor. The supervisor is
the only owner of its provider process group; if the supervisor is killed, a
kernel lifetime pipe wakes the existing process-group watchdog, which performs
bounded TERM-to-KILL cleanup. No code adopts an already-running PID.

## Trust and bootstrap boundary

The broker passes two pre-opened file descriptors:

- a bounded, one-shot pipe containing the bootstrap payload and capability;
- a private `0700`, current-user-owned root directory.

The executable accepts only those descriptor numbers. It validates the complete
identity, authority epoch, manifest digest, executable, argument digest/count,
environment names, and protocol range before creating a run directory or
launching a provider. Secrets never appear in arguments, environment variables,
discovery records, descriptions, or debug descriptions. The supervisor closes
the inherited descriptors, creates a new session, and redirects standard I/O
before starting the service.

The trusted root descriptor is the filesystem authority. Payload paths and
diagnostic PIDs are never authority. Run directories and files are opened
relative to that descriptor with owner, mode, type, and no-symlink checks.

## Discovery and control

Discovery is a secret-free, atomically replaced `0600` record. It contains the
execution identity, authority, protocol range, launch authenticator, capability
digest, socket name, and diagnostic PIDs. A duplicate exact launch is accepted
only after an authenticated handshake with the live socket. An exact record
without a live authenticated socket is `in doubt`; the system does not start a
second provider or adopt a PID.

Control uses a per-run `0600` Unix socket. Every bounded frame has a strict
schema and protocol version. Requests bind the execution ID, peer UID, timestamp,
nonce, action, and HMAC. Nonces are single-use within a bounded replay window.
Socket creation refuses any pre-existing entry, and shutdown unlinks only the
same socket inode that the server bound. Connection slots and I/O deadlines
bound unauthenticated same-user resource consumption.

## Events, replay, and backpressure

The append-only spool owns durable supervisor observations. Events have monotonic
sequences and IDs. Frames use a length, digest, and commit marker. On recovery,
only an incomplete final frame may be quarantined and truncated; corruption of
a committed frame fails closed. Acknowledgement is monotonic and compaction is
an atomic file replacement. Its integrity-checked watermark is separate metadata,
not a replay-visible event, so replay-to-ledger-to-ack pumps always converge.

Output is read with POSIX streaming reads and is never treated as EOF after a
read error. Output backpressures before it consumes the critical reserve. The
reserve itself has a terminal sub-reserve so control chatter cannot prevent
`providerExited` or cancellation evidence from being persisted. Terminal
persistence failures are surfaced rather than silently reported as success.

## Cancellation semantics

Graceful cancellation is capability-driven. An unsupported provider records
`cancellationUnsupported` and keeps running. Immediate termination is a separate,
explicit action. `cancellationConfirmed` is recorded only when this supervisor
actually issued termination and wait status supplies authoritative signal
evidence. If a natural exit wins the race, the run is completed or failed from
its exit status and is not mislabeled as cancelled.

Standard input is deliberately transient. `stdin_accepted` and `stdin_closed`
mean the local provider pipe operation succeeded; a missing process, EPIPE, or
close failure is returned as indeterminate/error and never receives durable
acceptance evidence. Input contents are not written to the spool.

## Compatibility and migration

Discovery and control advertise minimum and maximum protocol versions so an app
update can reconnect only when ranges overlap. Changed payloads, stale authority,
unknown fields, and incompatible versions fail before effects. This PR extracts
the existing containment algorithm into a reusable target and packages the
supervisor, but deliberately leaves SwiftData, UI, provider adapter, updater,
and current runtime launch paths unchanged until the broker migration is ready.
