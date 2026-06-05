# Multi-Connector Instances Plan

## Goal

Let a workspace enable any capability (REDCap, Jira, GitHub, Slack, BigQuery, …) once and attach more than one configured connector instance to it. Two REDCap projects, two Jira sites, two GitHub orgs — all coexisting in the same workspace, each addressable by name, with no env var collisions and no per-capability special casing.

The mechanism must be **capability-general**. Adding a new capability later should not require any new framework code to support multi-instance — only data updates in its `PluginCatalog` entry.

## Problem

Today, connector records have unique UUIDs and Keychain entries are already scoped per-connector (`KeychainSecretStore.connectorEntityID(for:)`), so storage allows N connectors of the same service type. But the runtime flattens credentials into a single OS environment dictionary:

- [`Connector.allEnvironmentVariables`](../../Astra/Models/Connector.swift#L90-L94) merges credentials + config into one dict per connector.
- [`TaskCapabilityResolver.resolver`](../../Astra/Services/Capabilities/TaskCapabilityResolver.swift#L34-L39) iterates all live connectors and last-write-wins-merges them into `connEnvVars`.
- [`SkillResolver.resolvedEnvironmentVariables`](../../Astra/Services/Capabilities/SkillResolver.swift#L103-L122) merges that into the env passed to subprocesses.

The keys are literal (`REDCAP_API_TOKEN`, `JIRA_API_TOKEN`) declared in [`PluginCatalog`](../../Astra/Services/Capabilities/PluginCatalog.swift#L549). Two REDCap connectors → second one wins silently. The agent's behavior instructions hardcode `$REDCAP_API_TOKEN` ([PluginCatalog.swift:504](../../Astra/Services/Capabilities/PluginCatalog.swift#L504)), so there is no way for the agent to address a specific instance even if both env vars were somehow present.

## Design Principles

- **Capability is enabled once per workspace.** Code/permissions/feature flag.
- **Connector instance is the unit of credentials and endpoint.** N per capability.
- **Always namespaced.** Env vars are scoped by instance alias even when there is only one instance. No silent shape changes when a second is added.
- **The agent sees a structured manifest.** Connector identity and env var names are queryable, not implicit.
- **Behavior instructions are templates, not hardcoded names.** Per-capability strings reference the manifest instead of literal env var keys.
- **Framework is capability-agnostic.** Per-capability changes are mechanical data edits in `PluginCatalog`, not framework code.
- **Subprocess model unchanged.** Tools remain CLIs that read env vars. The only difference is the env var names.

## Architecture

### Capability vs Connector Instance

| Concept | Lives in code as | Cardinality | Owns |
|---|---|---|---|
| Capability | `PluginPackage` (already exists) | One enabled state per workspace | tool list, behavior instructions, env var *templates* |
| Connector instance | `Connector` (already exists, gets `alias`) | N per workspace per service type | credentials, baseURL, config values, human name, alias |

A capability declares the *shape* of its env contract (what keys exist, what they mean). A connector instance fills the shape with a specific alias and specific values.

### Env var naming contract

Every credential and config key declared on a capability becomes a template with an alias prefix.

Before (literal):

```
credentialKeys: ["REDCAP_API_TOKEN"]
configKeys:     ["REDCAP_API_URL"]
```

After (template):

```
credentialKeyTemplates: ["{ALIAS}_API_TOKEN"]
configKeyTemplates:     ["{ALIAS}_API_URL"]
```

At runtime, `{ALIAS}` expands to `<SERVICE>_<ALIAS>`, uppercased, non-alphanumerics → `_`. So a REDCap instance with alias `study_a_source` produces:

```
REDCAP_STUDY_A_SOURCE_API_TOKEN
REDCAP_STUDY_A_SOURCE_API_URL
```

Two REDCap instances → eight distinct env vars, no collision.

### The connector manifest

At task start, the runtime injects two things:

1. An `ASTRA_CONNECTORS` env var holding a JSON manifest of every connector available to the task.
2. A rendered, human-readable connector list in the system prompt.

Manifest shape:

```json
{
  "connectors": [
    {
      "alias": "study_a_source",
      "name": "Study A Source",
      "serviceType": "redcap",
      "capability": "redcap-workflow",
      "baseURL": "https://redcap.stanford.edu/api/",
      "env": {
        "apiURL":   "REDCAP_STUDY_A_SOURCE_API_URL",
        "apiToken": "REDCAP_STUDY_A_SOURCE_API_TOKEN"
      }
    },
    {
      "alias": "study_b_target",
      "name": "Study B Target",
      "serviceType": "redcap",
      "capability": "redcap-workflow",
      "baseURL": "https://redcap.stanford.edu/api/",
      "env": {
        "apiURL":   "REDCAP_STUDY_B_TARGET_API_URL",
        "apiToken": "REDCAP_STUDY_B_TARGET_API_TOKEN"
      }
    }
  ]
}
```

The `env` map uses *logical* names (`apiToken`, `apiURL`) declared on the capability, mapping to the actual env var names at runtime. The agent and any helper script can look up "give me the token env var for connector X" without parsing aliases.

### Prompt-side rendering

A new section is rendered into the system prompt by the agent runtime, *not* by each capability:

```
Connectors available in this workspace:

REDCap (capability: redcap-workflow)
  - "Study A Source"   alias: study_a_source
      $REDCAP_STUDY_A_SOURCE_API_URL
      $REDCAP_STUDY_A_SOURCE_API_TOKEN
  - "Study B Target"   alias: study_b_target
      $REDCAP_STUDY_B_TARGET_API_URL
      $REDCAP_STUDY_B_TARGET_API_TOKEN

When the user refers to a connector by name, role, or short description,
map it to the matching alias and use that alias's env vars in all commands.
If the reference is ambiguous, ask the user to disambiguate before acting.
```

This text is the only place natural-language → alias mapping happens. Capability-level instructions never need to know how many instances exist.

## Data Model Changes

### `Connector` ([Connector.swift](../../Astra/Models/Connector.swift))

V1 runtime slice: do **not** add a persisted column yet. Derive a deterministic runtime alias from connector name/service, collision-resolved with connector UUID, so existing stores do not need a SwiftData migration before the runtime bug is fixed.

Later, when alias editing becomes UI-visible, add:

Add:

```swift
/// Stable slug, unique within (workspace, serviceType). Used to namespace env vars.
/// Pinned at creation; renaming `name` does not change `alias`.
var alias: String
```

- Derivation: `slugify(name)` at creation; collision-resolved with connector UUID or numeric suffix (`study_a_source`, `study_a_source_2`).
- Validation: `^[a-z][a-z0-9_]{0,62}$`. Reserved aliases: `default`, `primary`, `main`.
- Immutable after first save unless the user explicitly edits it (advanced field, with warning that tasks referencing the old env vars break).

### `Workspace` ([Workspace.swift](../../Astra/Models/Workspace.swift))

No structural change. Add a uniqueness check at save time:

- `(workspaceID, serviceType, alias)` must be unique.
- Enforced in the SwiftData save path (no native unique constraint, so this is a guard in whichever service writes connectors — likely `ConnectorsManager` or the place `PluginCatalog` installs them).

### `PluginConnector` / `PluginSkill` ([PluginCatalog.swift](../../Astra/Services/Capabilities/PluginCatalog.swift))

Do **not** overload `hint.key`. It is already the UI/storage/Keychain lookup key and should remain logical and stable.

Add projection metadata separately. A future schema shape should be closer to:

```swift
struct PluginConnector {
  // existing fields...
  var credentialHints: [CredentialHint]   // hint.key remains logical, e.g. API_TOKEN
  var configHints: [ConfigHint]            // hint.key remains logical, e.g. API_URL
  var envTemplates: [String: String]       // logical key -> env template, e.g. API_TOKEN -> {PREFIX}_API_TOKEN
}
```

The current runtime can also support existing literal keys (`REDCAP_API_TOKEN`) by stripping a matching service/name prefix at projection time. That keeps current JSON packages working while we migrate catalog data toward logical keys.

`PluginSkill.environmentKeys` should stay for truly skill-global environment. Per-connector URL/token/project values belong on the connector, not the skill.

### Keychain

No change. [`KeychainSecretStore.connectorEntityID(for:)`](../../Astra/Services/Persistence/KeychainSecretStore.swift#L84) already keys by connector UUID. The credential *key* stored in Keychain remains the logical name without alias expansion (e.g., `API_TOKEN`); the alias only enters the picture when projecting into the env. This keeps Keychain entries renamable-safe.

Open question: do we store the templated key (`{ALIAS}_API_TOKEN`) or the logical key (`API_TOKEN`) in `Connector.credentialKeys`? Recommendation: **logical key only** (`API_TOKEN`), and expand to `<SERVICE>_<ALIAS>_API_TOKEN` only at env-projection time. Decouples storage from naming.

## Runtime Changes

### Env projection — `ConnectorRuntimeProjection`

Keep `Connector.allEnvironmentVariables` as legacy surface area for old callers/tests. Add a runtime projection layer that takes all selected connectors together, computes aliases, emits namespaced keys, and decides whether legacy single-instance keys are still allowed:

```swift
ConnectorRuntimeProjection(connectors: liveConnectors)
    .environmentVariables()
```

### Env aggregation — `TaskCapabilityResolver.resolver`

Replace the literal merge loop at [TaskCapabilityResolver.swift:34-39](../../Astra/Services/Capabilities/TaskCapabilityResolver.swift#L34-L39):

```swift
var connEnvVars: [String: String] = [:]
for connector in liveConnectors {
    for (k, v) in connector.projectedEnvironmentVariables(prefix: connector.envPrefix) {
        connEnvVars[k] = v
    }
}
connEnvVars["ASTRA_CONNECTORS"] = ConnectorManifest.json(for: liveConnectors)
```

`SkillResolver.resolvedEnvironmentVariables` ([SkillResolver.swift:103](../../Astra/Services/Capabilities/SkillResolver.swift#L103)) needs no structural change — it already takes a flat dict from the resolver. The behavior is identical; only the keys are namespaced.

### Snapshot path

`SkillResolver.snapshotConnectorEnvironmentVariables` ([SkillResolver.swift:129](../../Astra/Services/Capabilities/SkillResolver.swift#L129)) reads from `ConnectorSnapshotConfig.configKeys`. Snapshots need the same templating treatment: store the alias and apply the same prefix on read. This guarantees a detached snapshot of a task still resolves the right env vars after the workspace state has changed.

### Prompt assembly

Find wherever `resolvedBehaviorInstructions` ([SkillResolver.swift:97](../../Astra/Services/Capabilities/SkillResolver.swift#L97)) is assembled into the final agent system prompt. Prepend a `Connectors available in this workspace:` block rendered from the same manifest. One renderer, all capabilities.

## Per-Capability Migration Pattern

For each capability in [PluginCatalog.swift](../../Astra/Services/Capabilities/PluginCatalog.swift):

1. Convert `credentialHints` and `configHints` to logical storage keys where possible (`API_TOKEN`, `API_URL`) and declare env projection separately.
2. Move per-instance values out of `PluginSkill.environmentKeys`. Truly global env vars (like a feature flag) stay literal on the skill.
3. Rewrite `behaviorInstructions` to stop hardcoding env var names. Replace strings like *"Use the REDCAP_API_TOKEN environment variable"* with *"Use the token env var for the selected connector — see the connector manifest in the system prompt."*
4. Keep the curl example, but use a placeholder: *"Replace `$TOKEN` and `$URL` with the env vars for the chosen connector instance."*

Worked example — REDCap, before ([PluginCatalog.swift:504-507](../../Astra/Services/Capabilities/PluginCatalog.swift#L504-L507)):

```
AUTHENTICATION
Use the REDCAP_API_TOKEN environment variable. The Stanford API endpoint
is REDCAP_API_URL, prefilled as https://redcap.stanford.edu/api/.

Base curl pattern:
curl ... --data-urlencode "token=$REDCAP_API_TOKEN" ... "$REDCAP_API_URL"
```

After:

```
AUTHENTICATION
Each REDCap connector exposes its own token and URL env vars; see the
"Connectors available in this workspace" section of the system prompt.
For a connector with alias <ALIAS>, the token is $REDCAP_<ALIAS>_API_TOKEN
and the URL is $REDCAP_<ALIAS>_API_URL. Never print, log, echo, save, or
commit the token.

Base curl pattern (substitute the connector's env vars):
curl ... --data-urlencode "token=$TOKEN" ... "$URL"
```

The agent already substitutes shell variables from context; the change is in instruction style, not in tool capability.

## UI Changes

### Capability card

Today: per capability, one "Enabled / Disabled" state plus a single setup form.

Proposed: per capability, "Enabled / Disabled" plus a list of connector instances and an `Add another …` button.

```
REDCap                                              [ Enabled ]
─────────────────────────────────────────────────────
Connections
  • Study A Source   redcap.stanford.edu       Connected
  • Study B Target   redcap.stanford.edu       Connected
[ Add REDCap Project ]   [ Copy Setup From Another Workspace ]
```

Files to change:
- [`ConnectorsManagerView.swift`](../../Astra/Views/ConnectorsManagerView.swift) — render the per-capability instance list.
- Wherever the existing single-instance setup sheet lives — make it accept "new instance for capability X" with a name + alias field.

### Alias field

Name is required and human-readable. Alias is auto-derived and shown read-only in the basic flow. An "Advanced" disclosure lets power users override the alias (with a "this breaks any task referencing the old env vars" warning).

### Copy Setup From Another Workspace

[`CapabilitySetupCopier.swift`](../../Astra/Services/Capabilities/CapabilitySetupCopier.swift) already operates per-connector ([CapabilitySetupCopier.swift:78-98](../../Astra/Services/Capabilities/CapabilitySetupCopier.swift#L78-L98)). The change is small: include `alias` in `CapabilitySetupCopySummary`, and resolve alias collisions at install time (e.g., append `_2`).

Security decision: continue copying credential values across workspaces (current behavior). The alias and env var names will change if there is a collision; the credential itself is the same secret.

## Migration & Backward Compatibility

### One-time data migration

On first launch of the version that introduces `alias`:

1. For each existing `Connector`, derive `alias = slugify(name)` (collision-resolved).
2. Persist `alias` to SwiftData.
3. Re-project env vars on the next task run — they will be namespaced going forward.

### Behavior for existing tasks

The "always namespaced" rule means tasks that hardcode `$REDCAP_API_TOKEN` in shell commands break on the next run. Mitigations:

- **Deprecation window: one release.** During the deprecation release, also emit the un-prefixed env var (`REDCAP_API_TOKEN`) when there is exactly one connector of that service. Log a `WARN` whenever it's emitted, with the env var name and the suggested replacement.
- When a second instance is added, the deprecation var is dropped immediately and the user is shown a one-time loud migration prompt:
  > "Adding a second REDCap connector. Existing tasks that reference `$REDCAP_API_TOKEN` need to be updated to use the connector-specific env var. See the Connectors panel for the new names."
- One release later, deprecation is removed entirely. Single-instance workspaces also use namespaced env vars.

This is the only backwards-compat seam; we keep it small and time-boxed.

### `maxInstances` opt-out (deferred)

Some capabilities may genuinely be singleton (e.g., a workspace-wide license key). Add an optional `maxInstances: Int?` to `PluginPackage` only when something needs it. Default unbounded. Not in scope for v1.

## Implementation Phases

### Phase 1 — Framework (no user-visible change)

1. Implement runtime aliases without a persisted schema migration.
2. Implement `ConnectorRuntimeProjection` with namespaced env vars and single-instance legacy fallback.
3. Update [`TaskCapabilityResolver.resolver`](../../Astra/Services/Capabilities/TaskCapabilityResolver.swift#L34-L39) to use the projected vars.
4. Implement `ConnectorManifest.json(for:)` and inject as `ASTRA_CONNECTORS`.
5. Render the connector list block into the agent system prompt.
6. Mirror the changes in the snapshot path ([SkillResolver.swift:129](../../Astra/Services/Capabilities/SkillResolver.swift#L129)).
7. Implement the single-instance deprecation fallback for one release.

Exit criteria: with one REDCap connector configured, behavior is unchanged from today (because legacy env vars are still emitted). New namespaced env vars are present alongside them. Manifest is populated.

### Phase 2 — Validation slice

Pick one capability (REDCap is the obvious choice — has the clearest "two instances" use case). Migrate its `PluginCatalog` entry:

- Templates for credential and config keys.
- Behavior instructions rewritten to reference the manifest.

Configure two REDCap instances in a test workspace. Verify end-to-end:
- Both sets of env vars present.
- Agent correctly resolves "the source project" → `study_a_source` alias → correct env vars.
- Agent can compose across instances in a single task ("copy records from Study A to Study B").

Exit criteria: a real two-instance REDCap task runs cleanly without manual env var fiddling.

### Phase 3 — UI

- Per-capability instance list in [`ConnectorsManagerView.swift`](../../Astra/Views/ConnectorsManagerView.swift).
- `Add another …` flow with name + alias field.
- Alias preview and advanced edit.
- Update [`CapabilitySetupCopier.swift`](../../Astra/Services/Capabilities/CapabilitySetupCopier.swift) to handle alias.
- Split capability enable from connector-instance creation so installing a package does not upsert/overwrite an existing same-service connector.

Exit criteria: user can add a second REDCap instance from the UI without touching configuration files.

### Phase 4 — Roll out

Mechanical migration pass over the remaining capabilities in [`PluginCatalog.swift`](../../Astra/Services/Capabilities/PluginCatalog.swift): Jira, GitHub, Slack, Confluence, BigQuery, anything else with credentials. Rewrite each entry's keys as templates and behavior instructions to reference the manifest.

Exit criteria: every capability in the catalog supports multi-instance. Single-instance deprecation fallback can be removed in the next release.

## Open Questions

1. **Alias rename.** Do we let users rename an alias after creation? Current proposal: yes, with warning. Alternative: no — alias is forever, name is editable. Cleaner but more rigid.
2. **Truly global env vars.** A capability may have a single env var that applies to all its instances (e.g., a default page size). Should those stay literal (`REDCAP_DEFAULT_PAGE_SIZE`) or also be aliased? Recommendation: literal, declared at the capability level rather than the connector level.
3. **MCP tools and per-instance binding.** MCP servers configured per capability — do they get one server per instance or one server that knows about all instances? Likely the latter (server reads `ASTRA_CONNECTORS` and exposes instance-aware tools), but defer until an MCP server actually needs it.
4. **Default connector.** When the agent has no contextual signal for which instance to use, should there be a "default" connector per capability? Current proposal: no — force disambiguation. Adding a default later is easier than removing one.
5. **Audit log.** Connector-test audit fields ([Connector.swift:470-496](../../Astra/Models/Connector.swift#L470-L496)) already record `connector_id`. Add `alias` to all audit fields for human-readable forensics.

## Out of Scope

- Cross-workspace connector sharing beyond the existing global-connector mechanism.
- Per-connector permission scoping (e.g., "this connector is read-only for this task"). Worth doing, separate plan.
- A general capability authoring UI. Capability definitions stay in [`PluginCatalog.swift`](../../Astra/Services/Capabilities/PluginCatalog.swift) for now.
- Renaming `serviceType` strings. Whatever is there today (`"redcap"`, `"jira"`) becomes the lowercased prefix.

## Summary

Add `alias` to `Connector`. Change `PluginCatalog` env keys to templates with `{ALIAS}` placeholders. Project env vars per instance in `TaskCapabilityResolver`. Inject a manifest into env and prompt. Rewrite each capability's behavior instructions to reference the manifest instead of hardcoded env var names. Ship a one-release deprecation window for single-instance unscoped env vars, then remove.

No capability gets special multi-instance code. New capabilities inherit multi-instance support by following the template convention.
