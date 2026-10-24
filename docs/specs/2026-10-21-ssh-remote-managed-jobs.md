# Managed jobs for SSH remote workspaces

## Problem

Agents on SSH remote workspaces spend whole provider turns babysitting long VM
jobs. In prod task 7900335C (Antigravity) and task 788C3646 (Copilot) the agent
started 20-minute SAS scans, BigQuery loads and GCS syncs with
`ssh <alias> '<command>'`, then polled every 10–30 seconds from inside the turn.
That burns tokens. Turn limits cut the jobs off: Antigravity's 10-minute
`--print-timeout`, the run's wall-clock ceiling, and Antigravity killing its own
background tasks when the turn ends. Then the user has to keep asking "what is
the current status?".

Docker workspaces already avoid this. `workspace_job_start` runs the command
detached inside the container, and the monitor reads the job's heartbeat and
result files. While a job is active it suppresses the silence watchdogs and
leaves job time off the run clock (`managed_job_excluded_seconds`). SSH
workspaces have nothing like it, and the prompt's "long-running remote command
contract" can only tell the agent to roll its own `nohup` and stop.

## Decision

ASTRA adds a remote job helper, `astra-workspace-job`, for SSH workspaces.
`start` launches a command detached on the host and records it in the task
folder. `status` and `tail` read it back with one bounded SSH call each. The
agent ends its turn after `start`. A later slice has ASTRA watch the job and
resume the agent's native session when the job finishes.

### Relationship to the July helper protocol

`2026-07-17-remote-workspace-job-helper-protocol.md` refused to put
provider-supplied remote commands behind ASTRA. It required a separately
installed helper with a trusted launcher and a pinned digest. Its V1 wire
contract never got a client, and #397 removed it.

That spec assumed remote commands would have to go through host control. Since
#530, an SSH workspace whose route is `native_shell` already runs any
provider-supplied remote command: the agent types `ssh <alias> '<command>'` in
its own shell, through the task's SSH wrapper. The helper runs the same command
on the same route, with the same authority. What it adds is detachment and a
record. Nothing new reaches the host, so the trusted-launcher and digest
machinery has nothing left to protect. Three things carry over from the July
design:

- a fixed, ASTRA-owned job layout on the host;
- reboot-safe process identity (boot id plus process start marker), so a reused
  PID is never mistaken for the job;
- bounded, one-shot observation, with scheduling owned by ASTRA and never by a
  polling call.

## Authority

The helper may never do what the `ssh <target> '<command>'` it stands for could
not.

- It is offered only when `RemoteWorkspaceSSHRoute` resolves `native_shell`, and
  only for the targets that route lists. Those targets are already filtered by
  the policy guard's disposition for `ssh <target> true`. Docker workspaces,
  Locked, a policy that denies the shell or `ssh`, and a sandbox without network
  all get no helper.
- It runs inside the provider's shell, so the provider's sandbox and permission
  rules apply to it as to any other command. It is not on ASTRA's list of local
  work, so Ask and Custom ask before it runs, just as they ask before `ssh`.
  Auto runs it unasked, as it runs `ssh`.
- The policy guard treats `astra-workspace-job start … -- <command>` as
  `ssh <target> <command>` for denials. A rule that would deny the ssh form also
  denies the job, so a deny pattern cannot be dodged by wrapping the command in
  the helper.
- The helper runs the task's SSH wrapper (`.runtime-bin/ssh`, task-scoped
  `known_hosts`) with `BatchMode=yes`, so it can never stop to prompt.
- The connection list it reads comes from the shim ASTRA writes at launch. It
  holds no credentials, only the `ssh` arguments the agent would type.

## Tool shape

The helper is a shell command, not an MCP tool. The route it extends is a shell
route, and three of the runtimes on it (Antigravity, Cursor, OpenCode) cannot be
handed an MCP server at all. The subcommands mirror the Docker tool names.

| Docker MCP tool | SSH helper |
| --- | --- |
| `workspace_job_start` | `astra-workspace-job start --connection <target> [--label <text>] [--timeout <seconds>] -- '<command>'` |
| `workspace_job_status` | `astra-workspace-job status <job_id>` |
| `workspace_job_tail` | `astra-workspace-job tail <job_id> [--stream stdout\|stderr] [--lines N]` |
| `workspace_job_cancel` | not in slice 1 (the status output gives the remote pid) |
| `workspace_job_wait` | deliberately absent |

- `--connection` takes exactly what follows `ssh` for that connection in the run
  line, such as its config alias. It is optional when the run offers one target.
  Everything after `--` is joined with spaces and run by the host's login shell,
  exactly as `ssh` joins its trailing arguments.
- There is no `wait`. A wait inside the turn is the behaviour this replaces.
  Waiting belongs to ASTRA's watcher.
- Output is `key: value` lines, like the Docker tool. The job key is
  `remote_job_id`, not `job_id`, on purpose. The process monitor reads `job_id`
  plus `status` from tool results as an in-turn managed job. It suppresses the
  watchdogs for it and leaves its time off the run clock. A remote job is meant
  to outlive the turn, so the run's ordinary bounds still apply to an agent that
  keeps polling anyway.
- Every output ends with a `next:` line that states the one sensible next step:
  end the turn and check back, or read the tail.
- Exit codes: `0` when the request was carried out, even if the job itself
  failed, `1` when it was not (launch refused, unknown job, host unreachable on
  `start`), `2` for usage errors.

## Host-side wrapper

One `ssh <target> sh -s` call per operation. The script travels on stdin, so no
command text is ever re-quoted into an `ssh` argument. Each job lives in a fixed
directory derived from its job id, which is a lowercase UUID validated before
use:

```text
$HOME/.astra/jobs/<job_id>/      (mode 0700; $HOME/.astra and jobs also 0700)
  command.sh                      the agent's command, verbatim
  launcher.sh                     ASTRA's supervisor
  stdout.log, stderr.log
  process                         launch evidence, written atomically
  result.json                     terminal outcome, written atomically
  timed_out                       marker, only when --timeout fired
```

`start`:

1. `mkdir` the job directory without `-p`. An existing directory refuses the
   start, so a retried or replayed start can never run a command twice.
2. Write `command.sh` and `launcher.sh` through quoted heredocs. Each delimiter
   is random and checked against the content.
3. Detach: `nohup setsid sh launcher.sh </dev/null >/dev/null 2>&1 &`. Plain
   `nohup` is the fallback where `setsid` is missing, and the evidence records
   which one ran. Every descriptor is redirected, so the SSH session can close.
4. Wait up to 10 s, in 0.1 s steps, for the `process` file, then print it with
   the host's boot id.

`launcher.sh` runs the command with the session's login shell
(`${SHELL:-/bin/sh} command.sh`), in `$HOME`. That shell, and the environment it
inherits from the SSH session, match what `ssh <target> '<command>'` would have
used. The command gets its own process group (`setsid`) where available, so a
later cancel or timeout can signal the whole tree. The launcher writes
`process`:

```text
pid=<command pid>            supervisor_pid=<launcher pid>
start_marker=<ps -o lstart=> boot_id=</proc/sys/kernel/random/boot_id or kern.boottime>
started_at=<UTC ISO-8601>    isolation=setsid|nohup   shell=<path>
```

It then waits for the command. Last, it writes
`result.json` (`status`, `exit_code`, `completed_at`) through a temporary file
and `mv`. `--timeout` arms a TERM, then KILL, against the command's group and
leaves the `timed_out` marker.

`status` is one probe that prints the boot id, the evidence, whether each pid is
alive and its current start marker, `result.json`, and the size and mtime of
both logs. The pids are checked before the result is read, so a job that
finishes mid-probe is never reported lost. `tail` is `tail -n` on one log, capped
at 500 lines and 64 KiB on the host and capped again locally.

### Deriving status

| What the probe saw | Status |
| --- | --- |
| `result.json` | its status: `succeeded`, `failed`, or `timed_out` (exit 124) |
| No evidence yet, job less than 60 s old | `starting` |
| No evidence, older | `lost`: the launcher never ran |
| Boot id differs from the evidence | `lost`: the host rebooted under the job |
| Command pid alive, start marker matches | `running` |
| Command gone, supervisor alive | `running` (writing its result) |
| Command and supervisor gone, no result | `lost`: killed without a trace (OOM, `kill -9`, host cleanup) |
| Job directory missing, launch never confirmed | `starting` for the first 60 s (a start still in flight), then `lost`: the launch never reached the host |
| Job directory missing after a confirmed launch | `lost`: deleted, or a different host answered |
| SSH failed (exit 255, timeout) | unchanged; the observation is `unreachable` |

`lost` is terminal. An unreachable host never changes the status. It records an
unreachable observation with the error and keeps the last verified status and
its time, so the agent and the UI can always tell "running as of 14:02" from
"running now".

## Persistence

The task folder owns which remote jobs exist and what ASTRA last verified about
them. The host owns whether the job is alive and how it ended. Nothing else
keeps a copy.

```text
<task folder>/remote-jobs/<job_id>.json
```

The record holds:

- schema version, job id, task id, run id;
- connection id, name and target (display only, see below);
- command, label, timeout, created time;
- launch evidence;
- status, exit code, completed time;
- last verified time;
- last observation: time, `reachable` or `unreachable`, and the error;
- log sizes and last output time;
- message.

Writes go through `RemoteWorkspaceJobStore`: an exclusive `flock` on a sibling
lock file, read, merge, then an atomic replace. The merge is monotonic. A
terminal status is never replaced by a non-terminal one, and an older
observation never overwrites a newer one. The helper and the later watcher can
therefore both write without a second owner. A run starts with its `start`
record written before the launch is confirmed (`starting`), so a crash
mid-launch leaves a record that the next probe resolves to `running` or `lost`.

## Watcher, UI and events (slice 2)

`RemoteWorkspaceJobMonitor` is an app service with an explicit lifecycle. It
starts at app launch and when a run settles, and it stops when no task has a
non-terminal record.

- **Polling.** It probes each non-terminal job with the same probe and store as
  the helper. The interval is 60 s for the first 30 minutes, then 5 minutes,
  jittered. A connection's jobs share one SSH call. It never probes a job while
  that task has a run in flight, because the agent owns the turn.
- **Records are untrusted input.** They sit in an agent-writable folder. The
  monitor never takes `ssh` arguments from a record: it resolves the connection
  by id from the workspace's SSH connections and drops the record if none
  matches. It derives the remote directory from the validated job id, and it
  only adopts a job whose `remote_job_id` appears in a tool result captured from
  the record's own run.
- **Typed events.** Each transition goes through a service and becomes a task
  event: `remote_job.registered`, `remote_job.finished`, `remote_job.lost` and
  `remote_job.unreachable`. The unreachable event is recorded once per outage,
  not once per poll. Each event carries the job id, connection name, status,
  exit code and the times.
- **UI.** The task view gets one "Remote jobs" group, following the lean UI
  system. A row shows label, connection, status, elapsed time, and when it was
  last verified. Expanding it shows the log tail. "Check now" runs one
  observation through the service.

## Resume policy (slice 3)

When the monitor first observes a terminal status (`succeeded`, `failed`,
`timed_out`, `lost`), it submits a continuation through
`ExecutionRequestSubmissionService`. The submission key
`remote-job:<job_id>:<status>` makes a repeat observation a no-op. The
continuation resumes the provider's native session when the runtime supports
it, the same way a permission continuation does. Its prompt is a typed payload,
not free text: job id, label, connection, status, exit code, duration, and the
last 40 lines of stdout and stderr, all inside an untrusted-data block.

- Jobs that finish within one poll go into one continuation.
- No resume when the task is cancelled, closed or superseded, when a newer user
  message has already started a run, or when the job was started with
  `--no-resume`. The UI still shows the result.
- A run in flight is never interrupted. The continuation queues behind it like
  any other submission.
- Resuming never waives permissions. Under Ask, whatever the resumed turn does
  still asks.
- Never on unknown: an unreachable host produces no continuation. After 24
  hours unreachable, the task shows "Remote job unverified" with Check now and
  Dismiss, and stays put.

## Failure modes

- **SSH down, or the IAP tunnel dropped.** The job keeps running; it never
  depended on the session. Observation is `unreachable`, the status is
  unchanged, and the monitor backs off. `start` against an unreachable host
  exits 1 and says the job may or may not have started. Its record stays
  `starting`, so its id is never lost, and the next `status` settles it.
- **Host reboot.** The boot id changes, there is no `result.json`, so the job is
  `lost` with "the host rebooted after the job started". It is never retried
  automatically, because the command may not be idempotent.
- **Job orphaned or killed.** Command and supervisor both gone with no result
  means `lost`. If only the supervisor died, its `pid` file still names the live
  command, which stays `running` until it exits. Then it becomes `lost`, because
  no one recorded the exit code.
- **PID reuse.** A live pid whose start marker differs from the evidence is not
  the job.
- **Launch not confirmed in 10 s.** The record stays `starting`. The next probe
  settles it from the host's evidence, so a slow host is never misreported as a
  failure.
- **Mac asleep or ASTRA quit.** Nothing runs locally. On the next launch, the
  monitor reconciles every non-terminal record from the host.
- **Duplicate start.** The exclusive `mkdir` refuses it, and job ids are fresh
  UUIDs.
- **Huge or binary logs.** Tail reads a bounded suffix, decoded as lossy UTF-8.
- **Corrupt or forged record.** The helper reports it unreadable. The monitor
  ignores it, records why, and never builds an `ssh` call from it.
- **Remote disk full.** The launcher cannot write its evidence, so the job ends
  as `lost` with the probe's stderr in its message.

## Slices

1. This spec, plus the helper: `start`, `status` and `tail`, the record store,
   the host scripts, the launch shim on the native-shell route, the run line and
   prompt contract, the guard's ssh-equivalent denial, and tests. The prompt
   promises nothing slice 1 does not do. It says ASTRA keeps the record, and that
   a later turn checks the job with one `status` call.
2. `RemoteWorkspaceJobMonitor`, typed events, the Remote jobs UI, and `cancel`.
3. The resume continuation, plus `--no-resume`.
4. An MCP projection of the same library as `workspace_job_*` for runtimes that
   take MCP, so Claude, Codex and Copilot see one tool family on both workspace
   kinds.

## Verification for slice 1

The tests drive the real helper through a fake `ssh` that drops the destination
arguments and runs the script locally with `/bin/sh`. Real detached processes
start, finish, fail, time out and are killed. Coverage:

- launch and result round trip;
- exit codes;
- refusing a duplicate job directory;
- unreachable observation keeping the last verified status;
- boot id change, a killed job, and a missing directory each becoming `lost`;
- the monotonic merge;
- bounded tail;
- CLI argument parsing and output;
- shim written only on the native-shell route, and only for its targets;
- run-line wording;
- guard denial equivalence.
