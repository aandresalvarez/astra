# Plugins 2.0: one way to add, configure, and keep capabilities working

Status: **proposal, 2026-10-15. Nothing implemented.** Written after a
read-only review of the capability code on `main` at `19bb27e6`, a comparison
with the plugin models of Claude Cowork, Claude Code and OpenAI Codex, and a
design conversation with the repository owner. Claims marked *(verified)* were
checked against the cited lines; claims marked *(static read)* come from a
code-reading pass that executed nothing; *(unverified)* means the spec relies
on it and nobody has confirmed it yet.

## Problem

A user who wants ASTRA to work with Jira, BigQuery or Gmail meets four kinds of
thing, each with its own setup story, spread over three surfaces:

| Kind | Built-in example | What the user must do | How it is modelled today |
| --- | --- | --- | --- |
| CLI extension | `gcloud-workflow`, `github-workflow` | install a binary, sign in to that CLI | `prerequisites` with `binary`, `livenessArgs`, `authHint`, `installHint` |
| API-key connector | `jira-workflow` (`basic`), `redcap-workflow` (`api_key`) | store a credential in Keychain, approve its first use | `connectors` + `CapabilityApprovalStore` |
| Skill | every workflow package | nothing beyond enabling | `skills` |
| MCP server | `google-workspace` (Gmail, Drive, Calendar) | keep a process alive, complete OAuth | `mcpServers` |

*(verified: `Astra/Resources/Capabilities/*.json`, 12 packages.)*

Adding one takes five user steps (browse, read requirements, approve, enable
per workspace, set up credentials) where Cowork and Codex take three (browse,
install, connect). The two extra steps are the catalog review (`Approve`,
`Deprecate`, `Block` in `PluginCatalogView.swift:1521-1548`) and the
per-workspace enable; on a single-user Mac the approver is the user, so the
review adds friction without adding a boundary.

Underneath, the install/approve/enable half carries the architecture debt the
2026-10-13 review found: enablement state with several owners, a config import
that trusts the file, a startup repair that rewrites skills silently, and
caches that read deleted models (the crash fixed in
`aandresalvarez/astra#495`). `Astra/Services/Capabilities` is 72 files and
18,151 lines; `PluginCatalogView.swift` alone is 2,860 lines; 39 service files
consume `PluginPackage` on the install side; 50 test files touch capabilities.
*(verified by `wc`/`grep` on 2026-10-15.)*

## What this changes, and what it must not

There is a seam in the current code. Everything **below** it reads
`Skill`/`Connector`/`LocalTool` rows plus package definitions, and nothing
about how they were installed:

- `TaskCapabilityResolver` and the per-turn reachable/narrated scope.
- `AgentRuntimeLaunchPreflight`, `CapabilityRuntimeIntegrityService`,
  `CapabilityCatalogPolicy.decision`.
- `ExternalActionPolicy`, `AgentRuntimePolicyGuard`, the Ask/Auto levels,
  `ConnectorMutationCoordinator`.
- The host-control broker (`astra-host-control`, `HostControlToolSupport`),
  `MCPRuntimeProjection`, `ConnectorRuntimeProjection`.
- Keychain via `SecretStoreSeam`, `ExecutionSandbox`, the five provider
  adapters.

Plugins 2.0 replaces everything **above** the seam: the package format, the
install/approve/enable state machine, the catalog UI, and the enablement
state. It keeps the runtime and security layer, and at first projects the new
model *into the existing rows* so that layer does not notice the change.

Two places where the seam is not clean, and which must move into the manifest
before the old path can be deleted *(static read)*:

- Host-control routing keys on the literal package id `github-workflow`
  (`HostControlPlaneMCPProjection.swift:59`) and on substring parsing of skill
  prose (`:543-592`).
- MCP delivery exists for Claude, Codex and conditionally Copilot only
  (`MCPRuntimeSupportMatrix.swift`); Cursor, OpenCode and Antigravity get the
  shell relay, so an MCP-only plugin is inert there with no warning.

## Vocabulary

| Term | Meaning |
| --- | --- |
| **Plugin** | The unit the user adds, removes and updates. One manifest, one folder. Replaces "capability", "pack" and "package" in the UI. |
| **Component** | One thing inside a plugin: `skill`, `tool`, `connector`, `mcp`. Every component has the same setup contract. |
| **Service** | What a `connector` component points at: a static declaration of a remote service (`jira`), the auth methods it accepts and the transport it uses. Comes from the manifest. |
| **Account** | A user-created connection to a service: alias, site, chosen auth method, one Keychain credential. A service has 0..N accounts. |
| **Source** | Where plugins come from: the built-in catalog, or a git repository the user or an admin adds. |
| **check / verify / connect / repair** | The four legs of the setup contract, defined under [Health and repair](#health-and-repair). |

"Global row", "pack", "enabledCapabilityIDs" and "approval" stop being user
concepts. Packs survive as a restrict-only policy an admin can attach to a
source; they are not something a user enables.

## Manifest

One JSON file per plugin. Shape chosen to map onto the Claude plugin layout
(`.claude-plugin/plugin.json`, `skills/<name>/SKILL.md`, `.mcp.json`) so that
ecosystem plugins can be imported with a converter, while carrying the fields
ASTRA needs that those formats lack (setup contract, transport, provider
support).

```json
{
  "id": "jira-workflow",
  "name": "Jira",
  "version": "2.0.0",
  "summary": "Read issues and propose updates in Jira",
  "worksOn": { "claude": "full", "codex": "full", "copilot": "full",
               "cursor": "shell-only", "opencode": "shell-only", "antigravity": "shell-only" },
  "components": [
    { "kind": "skill", "id": "jira-agent", "path": "skills/jira-agent/SKILL.md" },
    { "kind": "connector", "id": "jira",
      "service": {
        "id": "jira",
        "authMethods": ["api_token", "oauth"],
        "transport": "brokered",
        "aliasRequiredWhenMultiple": true
      },
      "check":   { "kind": "credentialPresent" },
      "verify":  { "kind": "http", "path": "/rest/api/3/myself" },
      "connect": { "kind": "credentialForm", "fields": ["site", "email", "token"] },
      "repair":  { "kind": "connect" } }
  ]
}
```

A CLI extension declares the same contract with different legs:

```json
{ "kind": "tool", "id": "gcloud", "binary": "gcloud",
  "check":   { "kind": "exec", "args": ["auth", "list", "--format=value(account)"], "expect": "stdoutNonEmpty" },
  "connect": { "kind": "terminal", "command": "gcloud auth login" },
  "repair":  { "kind": "terminal", "command": "gcloud auth login" },
  "install": { "kind": "url", "url": "https://cloud.google.com/sdk/docs/install",
               "hint": "brew install --cask google-cloud-sdk" } }
```

An MCP server:

```json
{ "kind": "mcp", "id": "google_workspace_gmail", "path": ".mcp.json#google_workspace_gmail",
  "check":   { "kind": "processStarts" },
  "connect": { "kind": "url", "flow": "oauth" },
  "repair":  { "kind": "connect" } }
```

Rules:

- `check` never needs the user and runs on add and on every refresh.
- `verify` may hit the network; runs on demand and in launch preflight.
- `connect` needs the user; it is never run at add time.
- `repair` is what the row's button does when `check` fails after the
  component was once healthy. It is usually `connect` again.
- `worksOn` is mandatory. A plugin whose only components are `mcp` must say
  `shell-only` or `unsupported` for the three runtimes without MCP delivery;
  the UI shows it before the user adds the plugin.
- A `tool` is a transport, not an auth method. A Jira CLI is a `tool` under
  the Jira plugin with the shell policy; it is never shown as "another way to
  connect Jira". See [Cardinality](#cardinality).

## Cardinality

Today a `Connector` row is both the service and the account, there is no
uniqueness on `serviceType`, and the broker already handles several accounts:
the `jira` tool takes an `alias` that is "optional when one Jira connector is
projected and required when more than one is: ASTRA refuses the call rather
than choosing a tenant for you" (`JiraToolSchema.swift:35`, *verified*);
REDCap does the same (`REDCapHostControlPolicy.swift:56`, *verified*). What
guesses is the preflight: `rankedConnectorsForService` picks one connector
per service by keyword overlap with the task text plus "has a credential"
(`ConnectorPreflightService.swift:122-133`, *verified*).

Plugins 2.0 makes the model explicit:

- **Plugin 1 — Component N.** A plugin owns its components.
- **Connector component 1 — Service 1.** Static, from the manifest.
- **Service 1 — Account 0..N.** User-created. Each account has its own alias,
  site, auth method and Keychain credential. The auth method is a property of
  the account, chosen among the service's `authMethods`; "Stanford" by API
  token and "Personal" by OAuth coexist under one plugin.
- **Account N — Workspace N.** An account can be on in several workspaces; a
  workspace can hold two accounts of the same service.
- **Workspace 1 — default Account 0..1 per service.** When a workspace has
  more than one account of a service, it names a default. The resolver uses
  the alias named in the task text, else the default, else it asks *before
  launch*. The broker's refusal stays as the last line.
- **Alias is required and visible** as soon as a service has two accounts,
  which is the broker's rule promoted to the UI.

This needs a new schema version (account is a new entity; today it is the
`Connector` row). Follow the repository rule: add `Vn+1`, never edit a shipped
version.

## Install and enable flow

Target: three user steps, matching Cowork and Codex.

1. **Find.** Search by name, summary and component contents (`bigquery` finds
   Google Cloud because `bq` is one of its tools). Sources: built-ins plus any
   git source the user added.
2. **Add.** One review sheet shows the components, what each one will be able
   to do, and `worksOn` for the user's runtimes. One confirmation:
   - runs `check` on every component and sorts them into ready / needs setup;
   - writes the approval record automatically (digest kept; it still catches
     tampering) with `approvedBy: "user"`;
   - installs once into the library; nothing is enabled per workspace yet.
3. **Connect, lazily.** `connect` legs are never run on add. The plugin row
   shows "N steps pending"; the user runs them when they want, or the first
   task that needs the component triggers the existing first-use gate
   (`AgentRuntimeLaunchPreflight.swift:486`, *verified*).

Enabling per workspace is a switch in the plugin's expanded row
(`Workspaces (2)`), not a separate screen. The workspace rail becomes
read-only for plugins: it shows what is on and what needs a step.

What stays as a gate:

- `CapabilityCatalogPolicy.decision` still runs at add (digest, unsafe tool,
  pack rules). A pack attached to the source can still block.
- The same `canRun` decision runs **inside resolution**, not only in launch
  preflight. Today a draft, blocked or digest-mismatched enabled package
  still resolves skills unless pack policy happens to apply
  (`CapabilityRuntimeResourceMatcher.swift:237`, *static read*).
- `Approve`/`Deprecate`/`Block` move behind a managed-mode flag for team
  deployments; they leave the single-user UI.

## Health and repair

ASTRA has three disconnected pieces of this today *(verified)*:

| Piece | Today | Scope |
| --- | --- | --- |
| Detection | `PreflightCache` (TTL 30 s, `PreflightCache.swift:24`) runs `livenessArgs`; rail and catalog show "Needs setup" with the `authHint` | only while the rail or catalog is open, plus launch |
| In-app repair | `GitHubRepositoryAccessRepairCoordinator`: device code, copy, open GitHub, verify (`PluginCatalogPrereqBadge.swift:26`) | GitHub only |
| Terminal repair | `RuntimeRemediationCatalog` + `TerminalCommandLaunching` scripts `gh auth login`, `gcloud auth application-default login`, `codex login` into Terminal.app with a copy/paste fallback (`RuntimeAuthSessionCoordinator.swift:9`, `RuntimeRemediationCatalog.swift:141,175`) | consumed by runtime setup views only |
| Mid-run | runtimes detect "not logged in"; for plugin CLIs `TaskLaunchResourceResolver.swift:1652` emits a diagnostic whose `repairAction` is a string with **no consumer in `Astra/Views`** | text in a log, not a button |

The spec joins them into one loop per component: **detect → show → repair →
verify → detect**.

- **Detect** at three moments: `check` on refresh, `verify` in launch
  preflight for every connector (not only the keyword-triggered `jira`
  entry in `triggerKeywordsByServiceType`), and pattern matching on the
  agent's stream for the plugin's own failure signatures, declared in the
  manifest (`"authFailurePatterns": ["not logged in", "expired"]`).
- **Show** as the same row everywhere: in the Plugins surface, in the
  workspace rail, and inside a paused task.
- **Repair** with one of three strategies the manifest declares:
  `deviceCode` (the GitHub coordinator generalised), `terminal` (the existing
  launcher; the row enters "waiting" and re-runs `check` every few seconds
  until healthy or a timeout), `url` (open, then re-check on return to
  foreground — the badge already has `openAuthorization`, it lacks the
  re-check).
- **A session that expires mid-task pauses the run instead of failing it.**
  `AgentRuntimePolicyGuard` already pauses, asks and resumes for permission
  prompts; an auth failure mapped to a component takes the same path, shows
  the repair row in the task view, and `Retry` resumes once `check` passes.
- `repairAction` becomes a typed reference (component id + strategy), so a
  view can render it.

## UI

Follows `docs/design-system/lean-ui-system.md`: one card, status carried by
group headings, scan-first rows, expand in place, inline editing only after
expansion, one verb per meaning.

```text
Plugins                                   [search]   Add source

Action needed
  [mark] Google Cloud        1 step pending · on in 2 workspaces      v
         GCloud Agent        Skill · ready
         gcloud, bq, gsutil  CLI · installed 512.0
         Google Cloud account   No active session           Sign in
                                               Workspaces (2)   Remove
Ready
  [mark] GitHub              Skill · CLI gh · 1 workspace             >
  [mark] Jira                Skill · API token · 3 workspaces         >
Available
  [mark] Google Workspace    3 MCP servers · Gmail, Drive, Calendar   Add
  [mark] REDCap              Skill · API key · from catalog           Add
```

- Group headings carry status (`Action needed`, `Ready`, `Available`). Rows
  say only how many steps are pending.
- Every component kind renders as the same row: icon, name, kind, state, at
  most one verb. `gcloud`, a Jira account and an MCP server look alike.
- Verbs: `Add` (from a source), `Sign in` / `Connect` (a pending `connect`
  leg), `Remove`. Nothing else at the collapsed level.
- A connector component expanded shows an `Accounts` sub-list
  (`Stanford · API token · 3 workspaces`) and `Add account`.
- Brand marks via `BrandMark` as in the rail.
- The composer turns today's per-turn word matching into a suggestion ("This
  task mentions Jira; the Jira plugin is off in this workspace. Turn on")
  instead of a silent scope decision.
- Presentation copy and ordering live in a presentation type with a focused
  test, per the design system's implementation guidance.

## Sources

- The 12 built-ins become the default source, read from the app bundle as
  today, but the on-disk copy stops winning over the compiled one for content
  (`CapabilityLibrary.swift:481-530`, *static read*).
- `Add source` takes a git URL or `owner/repo`. A source is a repository with
  a marketplace file listing plugin entries (`name`, `source`, `description`),
  modelled on Claude Code's `.claude-plugin/marketplace.json` so one file can
  serve both.
- Updates: check per source on demand; detect local edits and warn before
  overwriting, as Cowork does. The startup
  `CapabilityDefinitionRepairService.refreshInstalledApprovedDefinitions`
  (`ASTRAApp.swift:989`, *verified*) is retired; definition changes arrive
  only through a source update the user can see.
- Importing a Claude-layout plugin: skills map to `skill`, `.mcp.json` entries
  to `mcp`; agents and hooks are reported as unsupported in the review sheet.

## Data ownership

| State | Owner in 2.0 | Removed |
| --- | --- | --- |
| Plugin definition | installed plugin folder, keyed by id + version + digest | compiled `fallbackBuiltInPackages` as a content source; static `packageCache` fingerprint by mtime |
| Approval | approval record written at add, same store | the view writing the store directly (`PluginCatalogView.swift:1153`, *static read*); `create(enableHere)` approving after enabling |
| Enablement | one `PluginActivation` row per (plugin, workspace) | `enabledCapabilityIDs`, `enabledGlobalSkillIDs/ConnectorIDs/ToolIDs`, `enabledPackIDs`, `installedPluginIDs/Versions` on `Workspace` |
| Accounts | `Account` rows under a service | the service/account conflation in `Connector` |
| Workspace mirror | `.astra-workspace.json` keeps listing plugin ids and account aliases for recovery; on import they are validated against the installed library, as `WorkspacePackageImportCoordinator` already does | the verbatim copy of enablement arrays and origin stamps (`WorkspaceConfigManager.swift:2056`, *verified*) |

Derived caches (composer snapshot, rail snapshot, browser policy cache) keep
existing but observe `PluginActivation` changes, and every read of a workspace
goes through the deleted-model guard added in `#495`.

## Phasing

Each phase ships on its own PR and leaves `main` working.

| Phase | Work | Exit criterion |
| --- | --- | --- |
| 0 | Single owner for enablement as a service (`WorkspaceCapabilityActivation`, no schema change), config import validates against the library, workspace views guarded against a deleted model. **Shipped in `aandresalvarez/astra#506`.** | the 2026-10-13 review's high item closed; zero writes to the enablement arrays outside the owner, and reads frozen per file by a registry that only ratchets down |
| 1 | Manifest + converter that projects a plugin into today's rows; `PluginActivation` and `Account` entities together in one schema `Vn+1`, behind the phase 0 owner; reads move behind the owner; alias/default-account resolution replaces keyword ranking | runtime tests unchanged and green; the read registry is empty; a two-account Jira workspace launches with the chosen account |
| 2 | New Plugins surface behind a dev flag; health loop with the three repair strategies; typed `repairAction` rendered in rail and task view | a `gcloud` session expired mid-task pauses, repairs from the task view, resumes |
| 3 | Built-ins migrated to the manifest; git sources; startup repair retired; `worksOn` shown at add | all 12 built-ins add in one step on a fresh dev store |
| 4 | Delete the old install/approve/enable path and `PluginCatalogView` | `Astra/Services/Capabilities` install side under half its current size |

Tests to add, by phase: forged-origin config import (0); cross-workspace
service-type reach (1); alias refusal and default-account selection (1); rail
and composer refresh on plugin change (2); repair-loop state machine per
strategy with a fake terminal launcher (2); mid-run pause on an auth pattern
(2); every built-in's `worksOn` against `MCPRuntimeSupportMatrix` (3).

## Security considerations

- One-click Add widens the blast radius of the config-import trust problem.
  Phase 0 is a prerequisite, not an option.
- Dropping the user-facing approval step does not drop the digest check or the
  catalog policy; it drops a confirmation the same user was giving.
- `connectorMatches` on service type alone lets another workspace's Jira
  account become reachable *(static read,
  `CapabilityRuntimeResourceMatcher.swift:114-124`)*. `PluginActivation` keyed
  by workspace closes it.
- A `tool` under a connector plugin runs under the shell policy, not the
  broker's read-only/proposal policy. The UI must never present it as an
  account.
- The host-control broker's refusal to pick a tenant stays; the default
  account only removes the question in the common case.
- Terminal repair uses Apple Events; a denied automation permission falls back
  to copy/paste, as today.

## Open questions

1. Should `worksOn: "shell-only"` plugins be addable at all on a runtime that
   cannot use them, or hidden there? Proposed: addable, with the warning in the
   review sheet.
2. Does a `tool` need its own account-like entity for CLIs with several
   profiles (`gcloud config configurations`)? Proposed: no in 2.0; one session
   per tool.
3. Keep `.astra-workspace.json` as a recovery mirror or drop plugin state from
   it entirely? Proposed: keep ids and aliases, drop everything else.
4. Where does the alias the broker uses today come from? *(unverified; likely
   the connector name.)* Phase 1 must settle it before the `Account` migration.

## References

- Claude Cowork, install plugins: https://claude.com/docs/cowork/guide/plugins
- Manage plugins for your organization: https://claude.com/docs/plugins/admin
- Claude Code, create a marketplace: https://code.claude.com/docs/en/plugin-marketplaces
- OpenAI Codex plugins: https://learn.chatgpt.com/docs/plugins
- ASTRA lean UI system: `docs/design-system/lean-ui-system.md`
- Permission levels: `docs/specs/2026-10-07-permission-levels-harmonization.md`
- Composer loader crash fix: `aandresalvarez/astra#495`
