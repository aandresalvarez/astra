# Remote Workspace Job Helper Protocol V1

## Decision

ASTRA will not add provider-supplied SSH command execution to host control. Remote durable jobs require a separately reviewed helper and a narrow ASTRA-owned capability. The first prerequisite is a versioned wire contract that can be reviewed independently from SSH transport, deployment, scheduling, and UI.

The V1 contract lives in `WorkspaceToolSupport` so Docker and a future SSH backend can share job semantics without moving remote command authority into the model runtime.

## Root cause

ASTRA's current managed-job implementation is durable inside Docker because `docker exec -d` owns detachment and the job store owns heartbeat, logs, result, and process metadata. That mechanism is not a safe SSH backend:

- a live SSH shell is not a durable job owner;
- `nohup ... &` returning zero does not prove the job survived session teardown;
- a PID alone is unsafe after process reuse or remote reboot;
- accepting command text or paths in helper CLI arguments creates quoting and path-traversal attack surfaces;
- host control intentionally rejects arbitrary remote commands.

## Contract boundaries

The helper protocol accepts only these operations:

- `handshake`
- `start`
- `status`
- `tail`
- `cancel`

Requests carry a protocol version and unique operation ID. Every job operation uses a lowercase path-free job ID and durable generation UUID, preventing a reused ID from returning another generation's status or output. `start` binds an already-staged `command.sh` to:

- a stable job generation UUID for idempotency;
- a lowercase SHA-256 command digest;
- an optional bounded timeout.

The protocol never carries command text, a working directory, an absolute path, an SSH alias, credentials, environment variables, or a signal number.

## Durable layout

The helper owns a fixed file layout below an ASTRA-private job root:

```text
<private job root>/<job id>/
  job.json
  command.sh
  stdout.log
  stderr.log
  heartbeat.json
  result.json
  process.json
```

Responses cannot override those names. The future installer must create the helper and state roots outside the workspace repository, owned by the remote user, mode `0700`, and must reject symlinks throughout the helper and job directory chains. Command and metadata files are owner-only.

## Crash-safety evidence

A `start` response is not sufficient merely because the transport exited zero. Before ASTRA may persist the job as running, the response must bind to:

- the exact request operation ID;
- the expected installed-helper SHA-256;
- the requested job ID and generation;
- a process-group leader PID;
- the remote boot ID;
- the kernel process start marker;
- a durable acceptance timestamp and fixed file set.

The process identity prevents a later cancellation from signaling an unrelated process after PID reuse or reboot. A future helper implementation must atomically persist that identity before acknowledging `running`.

## Bounded observation

`tail` requires an explicit stream and is capped at both the caller's requested line count (up to 500) and 64 KiB. Request envelopes are capped at 16 KiB and response envelopes at 96 KiB before JSON parsing. Timestamps use fractional epoch seconds so durable observations do not lose sub-second precision during a wire round trip. Status and tail are one-shot operations; the protocol contains no polling interval or sleep operation. Scheduling and wake-up ownership remain in ASTRA.

## Fail-closed rules

- Unknown top-level fields are rejected.
- Oversized envelopes are rejected before JSON parsing.
- Tail responses that exceed the caller's requested line count are rejected even when they remain below the byte ceiling.
- Unsupported protocol versions are rejected.
- Non-finite, zero, negative, or over-30-day timeouts are rejected.
- Running snapshots without reboot-safe process identity are rejected.
- Terminal states without completion timestamps are rejected.
- Response operation IDs, helper digests, job IDs, and generations must match the request; status and tail cannot cross job generations.
- Cancellation requires the durable generation and will later require the helper to verify its stored process identity before signaling the process group.
- Decoded deployment manifests must exactly match the security-owned version, digest rules, install paths, modes, and symlink policy.

## Non-goals of this prerequisite PR

This contract does not:

- expose SSH remote commands through host control;
- deploy a helper to any remote machine;
- launch or cancel a real remote process;
- add a `BackgroundJob` SwiftData entity;
- add monitoring schedules, leases, notifications, or UI;
- change the existing Docker managed-job backend.

These exclusions are intentional. A later PR must implement and independently review the helper artifact and atomic installer against this contract. Only after that artifact has adversarial tests for session loss, app exit, Mac reboot, remote reboot, PID reuse, symlink attacks, partial writes, duplicate starts, and cancellation may an SSH backend consume it.

## Review sequence

1. V1 protocol and validation (this PR).
2. Helper artifact plus atomic digest-pinned installer and crash/adversarial tests.
3. Narrow SSH workspace capability using the installed helper; no raw provider commands.
4. Durable ASTRA `BackgroundJob` ownership, task/run/context revision links, manual check, and handoff assembly.
5. Scheduler, leases, restart reconciliation, completion validation, and notifications.

This order keeps authority and lifecycle ownership explicit: the model may propose work, but ASTRA owns staging, deployment, launch acceptance, persistence, observation, cancellation, and recovery.
