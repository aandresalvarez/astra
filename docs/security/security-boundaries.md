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
  is sent when the agent proposes it, and a requested GitHub review is posted
  when the agent asks ASTRA to post the file it wrote; the receipt (key, link,
  or error) is the agent's tool result (spec decision 15, below). Every action
  outside ASTRA leaves a record in the chat, derived from its receipt. A
  command the agent ran itself that
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
  `docker` against the local daemon with no global option, push, or login;
  package managers' install/run/test (never publish, login, `npx`, `exec`);
  build, test and format tools; and an interpreter running a script file.
  A shell's `-c` string, a runner's command (`env`, `xargs`, `timeout`,
  `find -exec`), and each `$(…)`, backtick or `<(…)` body are judged the
  same way; an assignment to a variable that steers a tool (`PATH`, `HOME`,
  `GIT_*`, `DOCKER_*`, `NODE_OPTIONS`, proxies) is not local. The list judges
  the command, not the program it runs: `make`, `swift test`, `npm run build`,
  `python3 scripts/report.py` and `docker run` execute project code or an
  image, and what that code does is the project's. A user's own tool
  configuration (`~/.curlrc`, Git hooks, the Docker CLI's current context)
  is the user's.
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
  approve a force. A command one of whose parts yields no grant (inline code,
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

### Writes sent when the agent asks (Auto)

The host-control broker composes and stages a connector write, or reads a
review file the agent names, and then asks the app over
`BrokeredExternalActionRequesting`. The broker never sends anything and never
reads a permission level (`BrokeredConnectorFitnessTests` pins both). The app
answers through `BrokeredExternalActionHandler`, bound when the run launches
to the task, the run, and the run's own user-facing level, so a request
chooses none of them:

- **Ask and Custom**: `ExternalActionPolicy` asks, so nothing is sent or
  recorded at proposal time. The run boundary records the proposal and the
  dock offers the review sheet, exactly as before.
- **Auto**: the proposal is recorded with `authorization: .autoPolicy` and
  sent at once through the sheet's own `ConnectorMutationCoordinator.prepare`
  and `send`: the staged bytes are re-read against the digest of the bytes the
  broker wrote (never a path the agent named), the route is derived from
  ASTRA's table, the destination is re-resolved from the connector, the send
  is reserved durably before dispatch, and an ambiguous outcome is never sent
  again. Any outcome retires an Auto record, so a refused write goes back to
  the agent and is never offered for a later send. A requested review is
  posted through `GitHubReviewPublicationService.prepare` and `publish`, only
  for the file the request names while it still holds the bytes the broker
  read, and only while the user's request to post a review is open and is a
  command to post it now: a positive list — the base verb post, publish or
  submit before the review or its comments, nothing ahead of it but words
  that keep it a command, no condition after it, and no pause anywhere in the
  message ("ask me first", "hold off", "draft"), and it is the user's latest
  word — anything said after it ("actually, no", "never mind", or any other
  message) leaves the review for the sheet. Wording that falls outside
  the list still offers the sheet, so a misreading leaves a review unposted,
  never posts one. Whether a run wrote or touched a review file never makes
  it eligible.

Nothing about either send depends on how the run ends, its checks,
settlement, or crash recovery: the run boundary sends nothing at any level.
If the app cannot record the proposal, it sends nothing and the proposal waits
for review. A send still in flight when ASTRA stops leaves a record with no
outcome, which the dock shows like any other proposal, refused as already sent
when the send was claimed. The broker waits a bounded time for the answer;
past it the agent is told the outcome is not yet known and not to ask again,
while the send finishes and records its own outcome.

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
