# RunBroker lifecycle and security boundary

## Root cause

A long-running operation cannot be owned by the ASTRA app process if it must
survive app closure or replacement. A process, an app bundle path, and SwiftUI
memory are all ephemeral. Durable execution truth belongs in RunLedger; process
supervision belongs in a per-user service whose executable and control paths do
not live inside the replaceable app bundle.

RunBroker is therefore a per-channel LaunchAgent. The app ships a broker payload
as a signed resource, then installs an immutable copy under channel-specific
Application Support. `launchd` references only stable paths outside the app. An
atomic `Current` selector chooses a versioned payload, so an already-running
version remains valid while an update is staged and a failed health check can
restore the previous selector and launch state.

## Ownership

- RunLedger is the only durable owner of operation identity, authority,
  idempotency, monitor deadlines, and outcomes.
- RunBroker owns process supervision and an in-memory projection used only to
  arm the next one-shot deadline.
- The ASTRA app is a client. Closing or replacing it must not terminate the
  broker or rewrite active execution truth.
- No in-memory production fallback may claim durable scheduling, cancellation,
  or idempotency when RunLedger is unavailable. Mutating commands fail closed.

Production and development have different LaunchAgent labels, Application
Support roots, Unix sockets, installation IDs, and capability secrets. The
current implementation intentionally does not map the unsupported beta channel.

## Local protocol

The Unix-socket protocol uses a four-byte big-endian length prefix and rejects
oversized lengths before allocating the payload. JSON is canonical, bounded,
and strict: unknown fields are rejected. Every request carries a protocol
version, request ID, idempotency key, channel, installation ID, timestamp,
nonce, command, and HMAC. Negotiation exchanges supported min/max versions and
security floors; there is no silent downgrade.

Monitor deadlines include operation identity, authority and epoch, generation,
attempt, future due time, and the stable audit `recordedAt` time. Dates are
canonicalized to milliseconds. Attempt completion is a durable compare-and-set
against the full expected deadline. A stale completion cannot overwrite a
newer upsert, removal, or authority transfer.

## Authentication boundary and limitations

Each channel installation has a random 256-bit capability secret stored in a
regular user-owned `0600` file. Requests use HMAC-SHA256 with a bounded nonce
replay cache. The server obtains peer UID and PID from Darwin where available;
UID mismatch fails closed. A code-identity-verifier seam exists, and deployments
that require it fail closed when a complete verifier is unavailable. ASTRA does
not treat a partial code-signature lookup as security.

This boundary isolates channels and rejects accidental, stale, or differently
installed clients. It does **not** protect against arbitrary malicious code
already executing as the same macOS user: such code can generally read the
user-owned capability file and control that user's LaunchAgents. Defending that
threat requires a stronger OS identity boundary (for example a separately
entitled service and complete code-requirement validation), not stronger claims
about a `0600` file.

Socket and authentication directories reject symlinks, wrong ownership, and
unexpected modes. Socket cleanup records the bound device/inode and never
unlinks a path that has since been replaced. Secrets, nonces, MACs, and request
payloads are excluded from diagnostics.

## Scheduling

Scheduling is event/deadline driven. RunBroker recovers deadlines from RunLedger
after restart, arms one one-shot timer for the deterministic earliest deadline,
and uses bounded exponential backoff with injected clock/random sources. It does
not sleep-poll. Duplicate ledger rows, stale generations, and write failures fail
closed. If a durable retry cannot be recorded, the scheduler becomes explicitly
degraded, emits an external diagnostic, and does not invent a memory-only retry
that could imply ownership.
