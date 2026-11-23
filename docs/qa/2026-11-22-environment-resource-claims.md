# Docker mounts, remote folders and local SSH state in admission

Base: main `c20995d9`. Tracks #480 (Docker environment mounts, remote
workspaces) and #479 (hook isolation, Git grants for a launch with no request,
versioned claims).

## Behavior

**Docker environment mounts.** A host folder a Docker environment projects
into the container (`WorkspaceExecutionEnvironment.mounts` and its credential
projections) is now claimed by admission, one claim per folder: a read-write
mount exclusively, a read-only mount shared. There is no per-environment lock.
Two tasks on one environment run together unless one of them can write a
folder the other mounts.

- The access comes from `DockerExecutionPlanner.mountPlan`, the function the
  launch builds its `--volume` arguments from. A read-only run gets its mounts
  read-only, so it claims them shared.
- A writable mount also competes with any task that holds that folder, or one
  containing it or inside it, as a workspace folder. A read-only mount does not
  wait for workspace writers.
- The task's own folder, its worktree's Git metadata and mounts inside folders
  the task already holds as workspace claims are left to those claims.
- If the launch would mount a folder read-write that its admitted lease does
  not hold as a writer, the run stops with the workspace-drift error instead of
  starting.

**Remote folders.** A task in a workspace with SSH connections claims each
connection's remote folder: host and port, then the folder, normalized without
contacting the host. The claim follows the run's workspace access, so a
write-capable run is a writer and a run declared read-only is a reader.

- Different hosts, and separate folders on one host, run together.
- The same folder, a folder containing it and a folder inside it conflict when
  either run is a writer. Readers share.
- Where two folders cannot be compared locally (`~/app` against `/srv/app`, or
  a path that climbs out of a home), they are treated as overlapping.

This is new waiting a person can notice: write-capable tasks in separate local
worktrees, or separate workspaces, that point at the same remote folder now run
one after another. "Review workspace" covers these waits as it does local
folders.

**Local SSH state. The decision is a concurrency contract, not a claim and not
a narrower grant.** A remote-workspace run is still granted read-write
`~/.ssh/known_hosts*`, write on `~/.ssh`, and read-write on the gcloud config
folder when a ProxyCommand uses gcloud. No admission claim covers them. The
contract:

1. ASTRA writes none of that state. It copies `~/.ssh/known_hosts` once into
   the task folder and reads the rest.
2. Every `ssh` a run finds through its `PATH` is ASTRA's wrapper, which pins
   `UserKnownHostsFile` to the task's own copy, sets
   `GlobalKnownHostsFile=/dev/null` and `UpdateHostKeys=no`. Two runs therefore
   never share a known-hosts file on that route.
3. What can still reach the shared files is a tool that runs `/usr/bin/ssh` by
   absolute path, and gcloud refreshing its own tokens. Both are the
   program's own writes to its own store, exactly as when a person uses two
   terminals. ASTRA adds no writer and does not serialize them.

A claim on `~/.ssh` would have serialized every remote-workspace task, which is
the blanket lock this work is meant to avoid.

**Template hooks.** Hooks are injected into `.claude/settings.local.json` only
for a runtime that reads it, and only while the run holds its checkout
exclusively. A task on Codex CLI, Copilot CLI, Cursor CLI, Antigravity CLI or
OpenCode CLI no longer gets the file written and no longer claims its checkout
exclusively because of hooks.

**Git writes without a request.** A launch with no durable request used to
keep every Git metadata path the launch detected as writable. It now projects
the claims it is admitted under, like any other launch, so Git metadata nobody
claimed is read-only.

**Versioned claims.** A request's frozen claims are written as
`{"version":1,"claims":[…]}`. The bare array written before still reads, as
version 0. A version this build does not know is unreadable, which admission
and the runtime already treat as fail-closed.

## Automated coverage

- `TaskExecutionEnvironmentClaimTests`: read-write and read-only mounts,
  unrelated mounts, a mount against a workspace folder, a read-only run, claim
  and launch agreement across mount plans, and the drift stop; remote folder
  overlap, readers, hosts, unknown relations and sandboxing Off; the SSH
  wrapper giving each task its own known-hosts file.
- `RemoteDirectoryClaimKeyTests`: path normalization and the overlap rule.
- `TaskExecutionResourceClaimCoverageTests`: no kind is left as an unclaimed
  gap; the browser and account kinds are recorded as contracts with their
  documents and tests.
- `RuntimeWorkspaceReviewTests`: a holder of a remote folder or a mounted
  folder is reviewed, and released, like a holder of a local one.
- `TemplateHookInjectionPolicyTests`, `TaskExecutionResourceClaimSetTests`,
  and the direct-launch cases in `TaskWorktreeResourceScopeTests` and
  `ExecutionSandboxRunnerTests`.

## Real app QA

None. No container, SSH connection or provider was started for this change.

## Review and limitations

- **OpenSSH and gcloud behaviour is relied on, not verified here.** Item 3 of
  the SSH contract describes those programs from general knowledge of how they
  work: OpenSSH appends a new host key as one line and replaces the file
  through a temporary file, and gcloud keeps its credentials in its own
  database. Nothing in this change ran either program concurrently. The worst
  outcome known for known-hosts is a newly learned key that is not recorded,
  which leads to the host being checked again, never to a host being trusted
  that was not.
- Narrowing the grant was considered and not done. With the wrapper in place
  the host known-hosts files are not needed for `ssh` found through `PATH`.
  They are still needed by tools that call `/usr/bin/ssh` directly (`scp`,
  `sftp`) and when the wrapper cannot be written. The grant was added for a
  reason this change cannot re-test, so it stays.
- Remote folders are compared by spelling. A symlink on the host, or one
  machine reached under two names (an SSH alias here, its host name there), is
  not recognized as the same folder.
- A read-only remote claim is a declaration. ASTRA's sandbox limits what a run
  writes on this Mac, not what it does over SSH.
- A credential projection ASTRA adds at launch (gcloud application-default
  credentials, read-only) is mounted after admission, so its shared claim is
  not held for that first run.
- A legacy pinned worktree with Git intent still holds its repository's Git
  directory exclusively for the turn. Giving it the shared claim prepared
  worktrees have needs the same narrowed metadata grants, and those grants
  come from a different source for legacy pins; see the pull request.
- Run-scoped hooks through Claude Code's `--settings` argument were evaluated
  and not adopted; see the provider-state document.

## Validation

Focused suites and the architecture checks are recorded in the pull request.
The full suite runs in CI.
