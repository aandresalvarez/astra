# ASTRA Security Boundaries

This note captures the local security boundaries that should be exercised before
release validation. Normal security testing should use the development channel:
`ASTRA Dev.app`, `com.coral.ASTRA.dev`, `~/Library/Application Support/AstraDev`,
and `~/Documents/Astra Dev/Workspaces`.

## Assets

- Keychain-backed connector and skill secrets.
- Workspace files and imported workspace metadata.
- App Support stores, logs, task events, and exported workspace config.
- Agent runtime policy manifests and provider stream output.
- Installed capability package JSON and local tool definitions.
- Capability approval records and package digests.
- First-class MCP server declarations and runtime MCP manifests.
- Sparkle update metadata and public EdDSA key in production bundles.
- Authenticated browser content exposed through the Shelf browser bridge.

## Trust Boundaries

- The feedback V1 contract is a privacy and interoperability boundary. All
  report text, filenames, runtime summaries, and remote status metadata are
  untrusted inert data. Evidence disclosure classes fail closed, payload and
  artifact sizes are bounded before transport, sensitive and explicit-opt-in
  evidence requires item-level review, and only canonical post-redaction bytes
  may be hashed. The language-neutral schema and golden bytes live under
  `docs/contracts/feedback/v1`; downstream tracks consume the authoritative
  `ASTRACore/Feedback` types rather than redeclaring them.

- User-selected files and folders enter through workspace import discovery and
  must not traverse or symlink into unrelated locations.
- Imported workspace configs are untrusted. The selected config folder is the
  authority for the workspace primary path, and imported connector/tool
  definitions must pass the same safety gates as installed capabilities.
- Agent runtimes can report tool use, file paths, shell commands, and network
  destinations; ASTRA's policy guard must enforce the run manifest across every
  observed URL, not just the first URL in a shell command.
- A run's filesystem authority is one value, `RunBoundary`, read by both the OS
  sandbox and the brokered stream guard. Those tiers are inversely activated, so
  a root granted by one and unknown to the other becomes a boundary the provider
  was never told about and is then punished for crossing. Out-of-boundary writes
  stay terminal; out-of-boundary reads are approvable, because ASTRA never
  declares a read boundary to the provider and the read has already completed by
  the time the stream is parsed. A permission approval may only add authority —
  it must not demote a run's policy level or switch its enforcement tier. See
  `docs/architecture/run-boundary.md`.
- A provider's own sandbox only counts as a file-write boundary if it covers
  the provider's file-write tool. Codex and Cursor sandbox writes themselves and
  run unwrapped below Auto; Antigravity's `--sandbox` restricts only its
  terminal, so ASTRA wraps it in Seatbelt at every level. Without that wrap a
  write outside the workspace through its file tool happened first and was only
  reported afterwards. See `ExecutionSandboxSettings.defaultWrappedRuntimes`.
  Because that wrap is all that makes Ask mean anything for Antigravity, a run
  below Auto is blocked, not run unconfined, when the wrap cannot be applied
  (workspace too broad, `sandbox-exec` missing) even under best-effort. Auto is
  exempt and the other wrapped runtimes still fall back with an audit line.
- Capability packages can define skills, connectors, and local tools; package
  IDs, tool commands, default arguments, connector URLs, and browser adapters
  must be treated as untrusted input.
- Capability packages can also define MCP servers. Stdio MCP commands and
  arguments must pass the same local command safety policy as local tools.
  Remote MCP endpoints must use HTTPS, except loopback HTTP for local
  development.
- Catalog policy is a security boundary. A package must be visible, installable,
  enableable, and runnable for the current workspace context before it can
  affect a task. Approval, risk, visibility, dependency, conflict, unsafe local
  tool, unsafe connector, unsafe MCP, and digest-mismatch decisions must stay in
  the centralized policy evaluator.
- Local approval records are durable channel-specific state, separate from
  package JSON. They are keyed by package ID, version, and canonical source
  digest. A package content change must invalidate the prior approval and force
  re-review before enablement or runtime launch.
- Generated skills, connectors, local tools, and templates must carry origin
  metadata. Disable and uninstall flows should remove package-owned resources by
  origin first so a package cannot claim or delete another package's resources by
  name alone.
- Credentialed connectors must use HTTPS for remote services. Loopback HTTP is
  allowed only for local development or localhost services.
- Connectors are credential and configuration profiles, not execution surfaces.
  Execution must happen through ASTRA platform tools, local tools, browser
  bridge actions, or catalog-approved MCP servers.
- The Shelf browser bridge listens only on `127.0.0.1`, but localhost is still a
  shared machine boundary. Bridge requests require a per-session token.
- Browser control remains an ASTRA-owned platform capability. Package
  `browserAdapters` are catalog-gated site-specific helpers and must not bypass
  the task-bound Shelf browser bridge token.
- Development and production channels must keep app support, workspace roots,
  Keychain namespaces, and update behavior separate.
- Channel storage boundaries are defined by `AppChannel`: production,
  development, and beta use separate App Support directories, Documents
  workspace roots, worktree roots, and Keychain prefixes.
- Workspace records live in SwiftData. `.astra-workspace.json` is the durable
  recovery and sharing export, not a credential store. Secrets belong in
  channel-scoped Keychain records.
- Workspace support files live under `.astra/`, including
  `.astra/tasks/<task-id-prefix>/` and `.astra/ssh-connections.json`. Legacy
  `tasks/<task-id-prefix>/` folders may be migrated into `.astra/tasks`.
- A workspace's `activeWorkingPath` controls where new chats run. Existing
  tasks may keep an `executionRootPath` snapshot so later workspace focus
  changes do not move the thread into a different checkout.
- A task started in a new worktree is bound to it by its newest
  `task.worktree.prepared` event whose worktree is still the task's pin
  (`TaskWorktreeBinding`). The binding is accepted only when its source
  repository belongs to the configured workspace and registers the pinned
  checkout; matching paths in an imported event are not authority. Retargeted
  pins must name that repository or one of its registered worktrees. Invalid
  bindings block launch before template hooks or provider setup can write.
  Launch grants the worktree as the only writable
  copy of its repository: configured folders that contain the source checkout
  are granted read-only, nested Git checkouts keep their own paths, and an
  unreadable binding grants no workspace paths at all. The shared Git
  directory is granted (read-only for shared-access runs) only when it is
  derived from the recorded source repository, is a real Git directory, and
  lists the worktree as a linked worktree. It is never derived from the
  worktree's own `.git` file, which the task can rewrite. ASTRA's Seatbelt
  receives it for both the agent and validation commands, so Git works in the
  worktree as in a normal checkout, hooks and config included. Docker workspace
  commands mount the verified Git directory at its original absolute path,
  while saved source-checkout mounts become read-only or are replaced by the
  task worktree. Read-only workspace ancestors remain mounted at noncolliding
  container paths and participate in host-to-container path mapping. Execution
  and planning prompts retain their original workspace labels and mark them
  read-only; shared workspace admission claims serialize writers against these
  reads, including for legacy requests. Every
  worktree Git grant has a matching admission claim, independent of Git prompt
  intent, including legacy requests. That claim is shared, whatever the run's
  workspace access: Git locks refs, the index, and config per operation, so
  sibling worktree tasks of one repository run together, while a writer of the
  main checkout holds the directory exclusively and waits for them. Template
  hooks are injected and restored at the same captured code checkout that
  admission claims. Provider-native sandboxes do not receive the Git directory:
  Codex keeps `.git` read-only by design, and a writable
  root over the shared Git directory would undo that. Derived tasks
  (chained, corrective, fork, and template) and recovery-mirror imports copy
  the binding, so they never fall back to the source checkout. A prepared
  worktree supersedes legacy branch/copy isolation, and runtime cleanup never
  treats the bound checkout as a disposable copy. Failed initial
  submissions save and export draft adoption and temporary-task deletion
  together; recovery save failures are surfaced rather than reported as success.
  Automatic cleanup records an atomic intent in the channel's App Support
  `WorktreeCleanup/` outbox before deleting the draft, outside provider-writable
  workspace paths. Workspace deletion and replacement record the same intents
  for unexecuted drafts. Removal runs only after deletion and any replacement
  bindings are saved. Failed saves preserve the workspace and UI selection. Startup retries
  interrupted cleanup and reads committed task references through a fresh
  context, so a failed deletion save cannot authorize removal. An interrupted
  branch deletion can finish even after its worktree was removed. Intent write,
  reference-read, and Git failures are logged; retryable failures retain the
  intent until removal or a terminal preservation decision. Every cleanup
  attempt rechecks local ownership; a missing, unreadable, or changed creation
  record keeps the checkout. Exclusive cleanup reservations compare resolved
  paths, including symlink aliases and overlapping ancestors or descendants,
  and a competing removal retries without replacing the first reservation.
  Fetch, creation, submodule setup, removal, and branch deletion acquire
  shared Git-common-directory and metadata workspace claims from the
  runtime queue's existing lease owner, so they run beside sibling worktree
  tasks but never beside a main-checkout writer; cleanup also claims the
  checkout exclusively, and concurrent creations on one repository are
  serialized in-process. Busy creation fails visibly before mutation, while
  busy cleanup retains its intent. Leases release on success or failure and survive queue cancellation
  until the lifecycle operation finishes.
  Cleanup keeps any
  worktree that has changes, ignored files, or new
  commits, including commits retained only in its branch or HEAD reflog;
  that another task or workspace default references; or whose
  references cannot be read.
- `current_state.json`, `current_state.md`, `session_history.md`, diagnostics,
  turn outputs, and runtime-bin folders are ASTRA-owned task state. Agents may
  read them for context when prompted, but they must not be treated as
  user-facing deliverables or writable completion targets.
- Runtime adapters are a trust boundary for provider output. Provider-reported
  stream events, file paths, permission prompts, usage, diagnostics, and
  inferred file changes must still pass ASTRA recording, policy, validation,
  and artifact reconciliation layers before affecting task completion.
- Runtime readiness, diagnostics, and logs may receive credential-looking
  provider output and must avoid persisting secret values.
- Runtime permission manifests may list environment key names, credential
  labels, and MCP server IDs, but must not persist credential values or MCP
  environment values.

## Permission Levels

A level decides whether ASTRA asks; it never widens a sandbox or credential
boundary. The full inventory is in
`docs/specs/2026-10-07-permission-levels-harmonization.md`.

- **Ask** asks before changing files, running commands, and acting outside
  ASTRA. Reading files stays free; web reads still ask. Destructive and
  publishing commands (`rm`, `chmod`, `chown`, `git push`, `deploy`,
  `publish`) are asked about, not refused; `sudo` stays denied because it
  cannot prompt in a non-interactive run. Local tools are never pre-granted,
  on any runtime.
- **Auto** asks nothing. Connector credentials are allowed for the task (the
  launch stops if that grant cannot be saved; a connector the agent reached for
  mid-run is allowed only after a clean finish and a durable save, and offered
  otherwise; an Auto launch answers an offer still open). A staged Jira write
  and a requested GitHub review are still reviewed in the sheet in Auto for
  now: ASTRA learns of them only after the run, so sending them without asking
  would mean sending after the turn; they will be sent when the agent asks
  (spec decision 15). Every action outside ASTRA leaves a record in the chat,
  derived from its receipt. A command the agent ran itself that
  is not known local work — exactly what Ask would have asked about — is
  recorded with an **Agent** pill as the command it ran; a call that is one
  `git push` or `gh` write gets that action's title. The next turn's prompt
  lists these records too.
- **Custom** applies the saved per-item tool, shell, and network rules (an
  enabled local tool becomes a grant only when those rules allow Bash, on
  every runtime) to local work only. A shell command runs on a rule alone
  only when every command in it is known local work
  (`LocalShellCommands`); anything else asks as Ask does, unless the
  approval its request yields was already given. ASTRA does not try to read
  whether a command acts outside the machine — a variable, `eval`, an alias,
  a runner or one more option changes what runs — so the list answers the
  opposite question, and a command it cannot read is not local. Being wrong
  costs a question, never an unasked action.
- **Known local work** is a fixed list: file, text and process tools; Git's
  local verbs (no push, no `-c`, no configuration writes, no `rebase -x`,
  `submodule foreach` or `bisect run`); `gh` reads (`view`, `list`,
  `status`, `checks`, `diff`, a `gh api` GET or a GraphQL query without
  `mutation`); `curl`/`wget` with fetch-only options and a GET or HEAD;
  `docker` with no global option, push, login, or `DOCKER_*` assignment;
  package managers' install/run/test (never publish, login, `npx`, `exec`);
  build, test and format tools; and an interpreter running a script file.
  A shell's `-c` string, a runner's command (`env`, `xargs`, `timeout`,
  `find -exec`), and each `$(…)`, backtick or `<(…)` body are judged the
  same way; an assignment to a variable that steers a tool (`PATH`, `HOME`,
  `GIT_*`, `DOCKER_*`, `NODE_OPTIONS`, proxies) is not local. The list judges
  the command, not the program it runs: `make`, `swift test`, `npm run build`,
  `python3 scripts/report.py` and `docker run` execute project code or an
  image, and what that code does is the project's. So every operand that
  chooses which code runs stays in the project: an interpreter's script,
  `awk -f`, `make -f`, a loader, and every path a build, test, lint or
  package tool is given (`--package-path`, `--manifest-path`, a test file,
  `-project`, a toolchain file, a linter's config or formatter, `git -C`),
  as well as the directory it runs in after a `cd`. A tool is "local with
  any arguments" only when no argument can make it run code: `sed` is read
  command by command (GNU `e`), and a header or cookie curl reads from a
  file (`-H @file`) is not local. A variable set for a program, or exported, is that
  program's environment and is local only when it is on the list of ones
  that only tune a local program (`NODE_ENV`, `LC_*`). A user's own tool
  configuration (`~/.curlrc`, Git hooks, the Docker CLI's current context,
  a provider home's Docker config, a capability's `DOCKER_HOST`) is the
  user's: it decides where a command the list accepts goes, and the command
  does not express it.
- **What the list is not.** It decides whether a command *expresses* an
  action outside ASTRA (`git push`, `gh pr create`, `curl -d`, `npm
  publish`, `ssh`), so that the action asks in Ask and Custom and is recorded
  in Auto. It is not a boundary against code that hides an action: running
  the project's code is local by design, so `printf 'curl -d …' > x.sh &&
  bash x.sh` is two local commands, and an option, variable or setting that
  names a program to run (`rg --pre`, `make --eval`, `cargo --config
  build.rustc-wrapper`, `npm --script-shell`, `GOFLAGS=-toolexec`) is the same
  capability as that script. The list rejects such forms it knows about,
  because doing so costs nothing, but a new one is a known limit rather than a
  hole. Code that hides an action is contained by the operating-system
  boundary (the Seatbelt sandbox, its network policy, and the credentials a
  launch is given), never by reading shell text.
- **An approval** of a shell command is the set of grants its request yields,
  one per command in it (the program and its first words, as the prompt
  shows). The command runs unasked once all of them were granted, so a
  host-scoped read does not approve a write to that host and a push does not
  approve a force. Anything but a read also yields a grant naming its whole
  content (`content-sha256-…`, ASTRA's gate only; providers replay by the
  pattern), so approving one comment or body does not approve another, and a
  `curl`/`wget` write keeps its method, so a POST does not approve a DELETE.
  A command one of whose parts yields no grant (inline code,
  `$CMD`) cannot be approved for replay, and the run stops with that reason.
  The browser MCP tool is judged and approved as the `astra-browser` command
  it runs, and the Docker workspace's shell tools are gated like Bash.
- `ExternalActionPolicy` is the only owner of "does this level ask before an
  external action". It reads the user-facing level of the run that produced
  the action, so a proposal composed under Ask is still reviewed after the task
  switches to Auto.
- Prompts that are not action approvals stay in every level: widening the
  Seatbelt sandbox after a denial and the sensitive-data runtime-switch
  acknowledgement.

## Repeatable Checks

Run the security hunt script for a focused pass:

```bash
./script/security_hunt.sh
```

For manual red-team checks, use only the development app. Seed fake values such
as `ASTRA_TEST_SECRET_123`, attempt workspace escapes via `..` and symlinks,
exercise restricted agent runs that try `rm`, `sudo`, outside-workspace writes,
multi-URL `curl` commands, denied URL patterns, imported unsafe local tools,
credentialed HTTP connector URLs, unsafe MCP commands, digest-mismatched
approval records, origin-collision package resources, blocked governance status,
unknown browser adapter IDs, and unexpected network destinations, then
verify ASTRA blocks the action without leaking the fake secret in task events,
diagnostics, or app logs.
