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
  otherwise), staged Jira writes are sent
  during settlement — after the provider result is captured, so an exit
  mid-send is reconciled rather than replayed, and only for a run whose outcome,
  tests and AI check included, completed it (never after a cancel, failure,
  failed validation, timeout, or policy stop) — and a requested GitHub review
  this run wrote is posted at that same point, after validation; each through the same checks an approved
  action goes through (digest re-read, derived route, re-resolved destination,
  dispatch recorded before the network call, no resend of an ambiguous
  outcome). Every action outside ASTRA leaves a record in the chat, derived
  from its receipt, with an **Auto** pill; recognised `git`/`gh` commands the
  agent ran itself (also behind a runner or `sh -c`), and any other command the
  risk classifier calls a write outside the machine, are recorded with an
  **Agent** pill. The next turn's prompt lists these records too.
- **Custom** applies the saved per-item tool, shell, and network rules (an
  enabled local tool becomes a grant only when those rules allow Bash, on
  every runtime) and follows Ask for actions outside ASTRA: a rule that allows Bash, `git:*`,
  `curl:*`, or `gcloud:*` still asks before `git push`, a `gh` write, a `curl`
  that sends data, a cloud deploy, a remote database client, a package
  registry change, or a browser page change
  (`ShellCommandRiskClassifier.actsOutsideMachine`), unless that exact
  command was approved. A `sh -c` payload, a backtick substitution, and the
  command behind a runner such as `env -u NAME`, `nice -n 5`, or `timeout 30`
  are judged as commands of their own (so is `eval`, and the Docker
  workspace's shell tools are gated like Bash; approving a push does not
  approve a force, delete, or mirror of it). What cannot be proven local is
  asked about too: inline interpreter code (`python3 -c`, `node -e`), an
  unknown Git subcommand or alias, a Docker command whose daemon (its
  `--context`, `-H`, `DOCKER_HOST`, or the CLI's current context) is not a
  local socket, and a command still wrapped at the unwrapping limit, and the browser MCP tool is judged as the
  `astra-browser` command it runs. Local writes such as `git commit`, reads,
  and browser navigation keep the rule.
- `ExternalActionPolicy` is the only owner of "does this level ask before an
  external action". It reads the user-facing level of the run that produced
  the action, so a proposal composed under Ask is still reviewed after the task
  switches to Auto, and only proposals the Auto run itself staged are sent.
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
