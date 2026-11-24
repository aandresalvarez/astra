# Provider account and session state: what ASTRA owns and what it relies on

Base: main `c20995d9`. Tracks #480 (provider-owned authentication, cache and
session state).

## Behavior

ASTRA does not serialize a provider or an account. Two tasks on the same
runtime start together unless they share a folder, a Docker mount, a remote
folder or a native session. `TaskExecutionResourceKind.accountSession` stays
declared and is never claimed. That is now a recorded decision, not a tracked
gap: `TaskExecutionResourceClaimCoverageTests` lists it under
`kindsIsolatedWithoutAClaim`, pointing at this document.

The decision rests on separating two things that live near a provider's home.

**ASTRA-owned configuration.** Anything ASTRA writes to steer a launch is
written per launch or per task, never into the provider's home:

| What ASTRA writes | Where | Scope |
| --- | --- | --- |
| MCP server config (Claude Code, Copilot CLI) | `$TMPDIR/astra-mcp-configs/astra-mcp-<taskID>-<UUID>.json` | One file per launch |
| MCP servers, reasoning effort, sandbox mode (Codex CLI) | `-c key=value` launch arguments | The process |
| Model (Antigravity CLI) | `--model` launch argument | The process |
| Docker client config | `<task folder>/.runtime/docker-client/<run>/config.json` | One run |
| `ssh` wrapper and known-hosts copy | `<task folder>/.runtime-bin`, `.runtime-ssh` | One task |
| Provider logs ASTRA asks for | `<task folder>/diagnostics/…` | One run |

Under the six provider homes ASTRA creates directories and nothing else.

**One shared file remains, in the checkout rather than a provider home:**
`<code folder>/.claude/settings.local.json`. Every Claude Code launch with an
autonomous or restricted policy merges its sub-agent permissions into it, and
template hooks are injected into it for the length of a run.

- Hook injection is coordinated by admission. A task that injects hooks claims
  its checkout exclusively, and the launch injects only for a runtime that
  reads the file and only while it holds that claim
  (`TemplateHookInjectionPolicy`). Other runtimes no longer get the file
  written, and no longer claim for it.
- The permission merge is coordinated by the write itself. Runs that share a
  checkout are read-only runs. The file is now replaced in one step, so a
  provider starting beside a sibling launch never reads a partial file, and a
  launch whose permissions the file already carries does not rewrite it.

**Provider-owned state.** Everything else under a provider's home belongs to
the provider's CLI: credentials, session stores, caches. ASTRA makes those
folders writable to the provider process and relies on the CLI's own
behaviour when two of its processes run at once, the same thing that happens
when a person runs the CLI in two terminals.

| Runtime | State ASTRA makes writable to the provider | What ASTRA projects | Contract ASTRA relies on |
| --- | --- | --- | --- |
| Claude Code (`claude_code`) | `~/.claude`, `~/.claude.json`, `~/Library/Application Support/Claude` | Per-launch `--mcp-config` file with `--strict-mcp-config`; the checkout settings file above | Concurrent `claude` processes share one home. A resumed session ID is reserved to one run. |
| Copilot CLI (`copilot_cli`) | `~/.copilot`, `~/Library/Caches/copilot`; XDG folders under ASTRA's own Copilot folder | Per-launch `--additional-mcp-config` file; per-run `--log-dir`. `~/.copilot/config.json` and `mcp-config.json` are write-denied to the run | Concurrent `copilot` processes share `session-store.db` and `session-state/`. A resumed session ID is reserved to one run. |
| Codex CLI (`codex_cli`) | `~/.codex`, or the configured `CODEX_HOME` | `--ignore-user-config --ignore-rules` and `-c` arguments; no file | Concurrent `codex` processes share `auth.json` and `sessions/`. A resumed session ID is reserved to one run. |
| Cursor CLI (`cursor_cli`) | `~/.cursor` | Launch arguments only | Concurrent Cursor CLI processes share `cli-config.json` and `mcp.json`. A resumed session ID is reserved to one run. |
| Antigravity CLI (`antigravity_cli`) | `~/.gemini`, `~/.antigravity` | `--model` and `--log-file` arguments. ASTRA no longer rewrites `~/.gemini/antigravity-cli/settings.json` (13a18b54) | Concurrent processes share OAuth credentials and conversations. A launch still waits for a settings writer left by an older ASTRA build (`AgentRuntimeSharedStateGate`). |
| OpenCode CLI (`opencode_cli`) | `~/.config/opencode`, `~/.cache/opencode`, `~/.local/share/opencode`, `~/.local/state/opencode` | Launch arguments only | Concurrent `opencode` processes share `auth.json` and `opencode.db`. A resumed session ID is reserved to one run. |

Native session IDs are the one piece of provider state ASTRA does reserve
(#574): a run that resumes or reports a session holds
`native_session:<runtime>:<id>` exclusively, and a provider that reports a
session another run holds is stopped.

## Automated coverage

- `TaskExecutionResourceClaimCoverageTests`: the account kind is an approved
  contract, not a gap; two tasks on one runtime in separate folders are
  admitted together; every contract entry names a document and tests that
  exist.
- `TemplateHookInjectionPolicyTests`: hooks are injected, claimed and restored
  only for a runtime that reads the checkout settings; a launch that holds the
  checkout shared writes nothing.
- `ClaudeSettingsSharedWriteTests`: an unchanged permission projection leaves
  the checkout file untouched; a changed one replaces it whole; a symlinked
  settings file keeps its link.
- Existing: `RuntimeNativeSessionOwnershipTests` (session reservation),
  `ProviderSharedStateLaunchTests` and `ProviderSharedStateMigrationTests`
  (the Antigravity settings gate), `AgentRuntimeAdapterTests` (launch
  arguments and per-launch MCP config).

## Real app QA

None. No provider CLI was launched for this change, and no paid or model
session was started.

## Review and limitations

- **The right-hand column is what ASTRA relies on, not what was verified.**
  The paths come from ASTRA's own code (`AgentRuntimeHomeStateAccess`,
  `RuntimeHomeAccessPolicy`, the six adapters). How each CLI behaves when two
  of its processes refresh a token, write a session store or rotate a cache at
  the same moment was not tested, and is not documented by ASTRA. The evidence
  is indirect: ASTRA already runs tasks of one runtime in parallel, and people
  run these CLIs in several terminals.
- A token refresh that two processes attempt at once is the case most likely
  to misbehave. If a provider shows it, the fix that fits this design is a
  short claim around that one write, held by the run that performs it, not a
  provider-wide lock.
- The checkout permission merge is last-writer-wins when two read-only Claude
  Code launches in one checkout carry different permission projections. Each
  launch still passes its own tool lists on the command line and runs behind
  its own read-only boundary; what can differ is what a sub-agent reads from
  the file. Passing these settings with Claude Code's `--settings` argument
  would remove the shared file. That was not adopted: whether sub-agents honour
  settings passed that way cannot be confirmed without running the CLI.
- Copilot utility launches without a run still log to a shared folder under
  ASTRA's Copilot home.

## Validation

Focused suites and the architecture checks are recorded in the pull request.
The full suite runs in CI.
