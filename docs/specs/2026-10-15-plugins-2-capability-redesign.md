# Plugins 2.0: one way to add, configure, and keep capabilities working

Status: **redesign proposed, 2026-10-16.** Phases 0–4 were built on stacked
draft PRs (`aandresalvarez/astra#506`–`#510`), and review of them showed the
data model under phases 1–4 was the wrong one. Read **Redesign: one owner per
plugin fact** first; it supersedes the parts of this text it names. The rest
is the original proposal, kept for its reasoning. Originally written after a
read-only review of the capability code on `main` at `19bb27e6`, a comparison
with the plugin models of Claude Cowork, Claude Code and OpenAI Codex, and a
design conversation with the repository owner. Claims marked *(verified)* were
checked against the cited lines; claims marked *(static read)* come from a
code-reading pass that executed nothing; *(unverified)* means the spec relies
on it and nobody has confirmed it yet.

## Redesign: one owner per plugin fact (2026-10-16)

### Why the first build has to change

Review of the five implementation PRs produced 112 findings, 39 of them P1,
and the count did not converge: each fix to Update or plugin sources drew new
findings in the next round. Grouped by what produces them rather than by
symptom:

| Root cause | P1s | Typical findings |
| --- | --- | --- |
| No record owns an installed plugin. Add copies a plugin's skills, connectors and tools into shared global rows matched by name, service and base URL; each workspace keeps lists of IDs | ~10 | Update changes other workspaces; fan-out rollback; collisions with another plugin's rows; configured values lost; removed components left behind; cross-workspace reach |
| An account is a field copied inside `Connector`, not an entity | 4 | The alias lost in detached launches, shares, recovery snapshots, workspace copies; unchosen accounts still offered |
| Plugin sources (git and folders) are a package manager with untrusted input, added inside phase 3 | ~8 | Secrets in URLs, ID and filename collisions, provenance, duplicate IDs, rollback versions |
| The old catalog was replaced without an inventory of what it did | ~7 | Confirmations, Google OAuth, admin approval, the repair path while the preview flag is off |
| Session expiry detected from tool-output text; plugin-defined checks executed | ~7 | Failed calls only, executable positions, repair commands, resume vs replay |
| The manifest converted to `PluginPackage` with loss | ~3 | `worksOn`, setup contracts, component IDs |

The first two rows account for most of the findings that kept recurring, and
they come from one deviation. Phase 0's owner decision was "a service now,
the entity in phase 1"; this spec's phase 1 was to add `PluginActivation`
and `Account` in one schema version. Phase 1 as built added neither: it kept
the activation arrays on `Workspace` and put the account alias on
`Connector`. Every Add, Update and Remove therefore stayed a multi-row,
multi-workspace mutation with no transaction and identity by display fields,
and each patch to it (fan-out, compensation, preflight) opened the next edge.

Mechanics, *(verified 2026-10-16)*:

- **Add materializes.** `CapabilityInstaller` upserts global `Skill`,
  `Connector` and `LocalTool` rows for each manifest component, finding an
  existing one by name, service type and base URL
  (`existingGlobalConnector`, `existingGlobalTool`,
  `CapabilityRuntimeResourceMatcher.preferredPackageSkill`).
- **The runtime re-finds the copies.** `TaskCapabilityResolver` reads the
  enabled packages' definitions from the library, then matches them against
  every workspace and global row (`enabledPackageSkills`,
  `enabledPackageConnectors` through `connectorMatches`, which matches on
  service type alone). That match is where another workspace's account
  becomes reachable.
- **Enablement is parallel ID arrays** on `Workspace`, behind
  `WorkspaceCapabilityActivation`.
- **Connector secrets have two namespaces**: the connector's UUID, and a
  "stable" entity ID derived from service type, base URL and origin package
  and component (`KeychainSecretStore.connectorEntityIDs`). The stable one is
  shared by every connector that derives it.

### Principles

1. **One owner per fact.** A plugin's definition is its library entry (the
   manifest as authored, keyed by ID, version and digest). Whether it is on in
   a workspace, and that workspace's settings for it, is a `PluginActivation`.
   An account is an `Account`. Everything else is derived, not copied.
2. **Identity is (plugin ID, component ID)**, never a name, a service type or
   a URL.
3. **The runtime derives plugin resources from the manifest at launch.** No
   SwiftData row exists for a plugin's skill, connector or tool. Rows remain
   only for what the person authored.
4. **Turning a plugin off deletes nothing the person owns.** Accounts and
   their secrets outlive activations; deleting an account is its own action.
5. **Untrusted input comes after the model.** Plugin sources return once the
   model exists, with their own threat model.

### Model (one new schema version on `main`)

`main` is at V19 (phase 0 changed no schema), so this is V20 on `main`; the
V20 on the stacked branches (`Connector.accountAlias`, workspace default
accounts) is not shipped and is superseded.

- **Library entry = installation.** `CapabilityLibrary` keeps one entry per
  plugin. It stores the manifest as authored, so `worksOn`, setup steps,
  component IDs and `manifestVersion` survive; `PluginPackage` remains an
  in-memory projection for consumers not yet moved. The validator requires a
  unique `id` per component and a supported `manifestVersion`.
- **`PluginActivation`** (`@Model`): `workspace`, `pluginID`, `enabled`,
  `recordedVersion`, `recordedDigest`, `configValues` keyed
  `componentID.key` for settings that belong to the workspace, not to an
  account (a skill's environment value), `overriddenComponentIDs` (components
  the person replaced with an authored row, which the projection skips), and
  `revision`.
- **`AccountBinding`** (`@Model`): `activation`, `componentID`, `account`
  (relationships), `isDefault`. A component can bind several accounts (two
  Jira sites), one of them the default; deleting an account cascades to its
  bindings, so no activation keeps a dangling ID.
- **`Account`** (`@Model`): `id` (UUID), `serviceType`, `alias` (unique per
  service among the accounts a workspace can see), `baseURL`, `authMethod`,
  `credentialKeys`, `configValues` (per-account settings such as Jira
  projects or a tenant), and an owner: one workspace unless shared
  explicitly. `revision`.
- **Revisions.** `PluginActivation.revision` and `Account.revision` are
  integers the owner service bumps on every mutation it makes: an
  activation's settings, bindings or overrides; an account's alias, URL,
  auth method, credential keys or settings. Nothing else writes these
  models, so nothing can change them without a bump.
- **Removed:** the plugin entries in the `Workspace` activation arrays, and
  every plugin-origin `Skill`, `Connector` and `LocalTool` row. What the
  person authored is unchanged.

### Runtime

- `PluginRuntimeProjection` turns a workspace's enabled activations, their
  library manifests and their bound accounts into value types, cached by the
  activation's `revision`, the library digest and the `revision` of every
  bound account, so editing an account's URL, alias or settings evicts it.
- The projection skips the components listed in the activation's
  `overriddenComponentIDs`; the authored row that replaced each one is in the
  inventory instead, so nothing is duplicated.
- It also emits the plugin's templates as read-only templates. A template
  the person edited is migrated to an authored one and overridden, like a
  skill.
- It emits the snapshot types the detached-launch path already runs from
  (`SkillSnapshotConfig`, `ConnectorSnapshotConfig`,
  `LocalToolSnapshotConfig`), so `SkillResolver` and the prompt builders keep
  their inputs. `ConnectorSnapshotConfig` gains the account's ID and alias
  (non-secret), so a detached or resumed run still names the account the task
  chose and the broker resolves the same tenant. The projection also emits
  everything else a manifest declares that the resolver
  reads today from `PluginPackage`: browser adapters (`google-drive-browser`
  is nothing else), MCP servers and setup requirements. R2's parity test runs
  over every built-in, so a plugin that projects to nothing fails it. `TaskCapabilityResolver` takes authored rows plus the
  projection. A spike opens R2 to list what in the resolver still needs model
  objects.
- `ConnectorAccountResolver` runs over the accounts this workspace's
  activations bind, so another workspace's account is unreachable by
  construction, not by matching.

### Operations

| Action | What changes | Notes |
| --- | --- | --- |
| Add | approval for the digest, library entry, one activation | one save; no credential prompt |
| Update | library entry (new digest, re-approved), and `recordedVersion`/`recordedDigest` on **every** activation of the plugin | the library holds one version, so an update is global: every workspace with the plugin on is checked first, and one that refuses it (a pack rule) blocks the update with its reason. Removed components disappear because nothing derives them. A rename is never inferred: a component that was renamed lists its earlier IDs in `"replaces": ["old-id"]`, and only then do the old ID's settings, bindings and secrets move to it, and only when the kind and, for a connector, the service match. Any other changed or reused ID is a remove plus an add and starts empty; a `replaces` naming a component of another kind or service, or claimed by two components, is refused at validation |
| Turn off | `activation.enabled = false` | deletes nothing, so it needs no confirmation |
| Remove | library entry, its activations, and the activations' secret settings | confirmed, says it reaches every workspace; accounts stay, listed under Accounts. The activation-owned Keychain entries are recorded in the durable cleanup outbox before the activations are deleted |
| Delete account | the `Account`, its bindings (cascade), then its secrets | confirmed, naming the workspaces that use it; the only path that clears credentials |

The state lives in three stores (library and approval files, SwiftData,
Keychain), so no operation is one transaction. Each writes in a fixed order
that leaves a recoverable state at every step, and a launch-time
reconciliation finishes or undoes what an exit interrupted:

- **Add:** approval file, library entry, then activation. An approved entry
  with no activation is just an installed plugin; it shows under Available.
- **Update:** library entry (the previous one kept as the rollback file the
  library already writes), then the activations. An activation whose
  `recordedDigest` differs from the library is shown as needing Update.
  Components the new version dropped are removed from each activation like a
  Remove of that component, in the same save that advances its digest: their
  bindings and `configValues` are deleted and their activation-owned secrets
  go through the cleanup outbox, so a later version that reintroduces the ID
  starts empty.
- **Remove:** a Remove intent for the plugin is written to the operation
  journal first, then the activations are deleted, then the library entry,
  then the intent is cleared. An intent found at launch finishes the Remove,
  which tells it apart from an installed plugin that was never turned on. An
  activation whose library entry is missing with no intent is shown as
  "missing, add it again" and never resolves.
- **Delete account and Remove:** the Keychain entries they release are
  recorded in the durable cleanup outbox first, then the SwiftData deletion
  is saved, then the entries are cleaned, exactly as
  `ConnectorCredentialCleanup.deleteThenClean` does today (the record is
  undone if the save fails), so neither an orphaned secret nor a secret
  deleted for a live owner is possible.

### Migration V19 → V20 (custom stage)

The dev store is backed up first; the stage is one-way.

1. Each workspace gets one activation per plugin in the union of
   `enabledCapabilityIDs` and `installedPluginIDs`, with `enabled` set from
   membership in `enabledCapabilityIDs`: turning a plugin off left it in the
   installed list, and its settings must survive until it is turned back on.
   `recordedVersion` comes from `installedPluginVersions`; `recordedDigest`
   is the digest of the matching library entry, so a migrated plugin is not
   shown as needing Update. The fixture asserts both. A workspace that
   turned on one shared plugin row by itself (`enabledGlobal*IDs`, through
   `CapabilitySharing`) without the plugin gets no activation, which would
   widen it to the whole plugin: that row is kept for it as an authored row
   and stays in its list, while workspaces that have the plugin use the
   projection instead.
2. Each plugin-origin connector, global or workspace-owned, becomes an
   `Account` with the **same UUID**, so its UUID secret namespace resolves
   unchanged; its config values move with it to `Account.configValues`.
   Credentials stored only under its stable entity ID are copied into the
   account's UUID namespace in R1 (the stable entries are deleted in R2 with
   the row), so the projection reads one namespace. Bindings come from
   ownership, not from what is enabled now: a workspace-owned connector binds
   to its workspace's activation of the plugin, and a global connector binds
   to every activation of its plugin in a workspace that had it enabled or
   installed, so a plugin that was turned off keeps its accounts. V19 stored
   no default account, so none is read: accounts are bound in creation
   order and each component's oldest account becomes its default. A
   component that ends up with more than one account shows that default on
   its Plugins row for the person to confirm or change.
3. Environment values on plugin skills move to `activation.configValues`
   under `componentID.key`. Secret ones are not in SwiftData (a skill keeps
   them in the Keychain under its UUID), so they move to a Keychain namespace
   owned by the activation and component (the projected skill's ID), and
   the projection reads them from there. A projected skill carries secret
   keys with empty values, exactly as a stored skill does, so
   `SkillSnapshotConfig` and `AgentTask.skillSnapshotsJSON` never hold a
   secret; the value resolves from the Keychain at execution. They are
   copied before the save and the old namespace is cleaned after it.
4. A plugin-origin skill, tool or template the person edited (it differs
   from the manifest) becomes an authored row with its origin stamps cleared,
   and its component ID is added to the activation's
   `overriddenComponentIDs` so the projection does not add the original back.
   The migration logs it (owner decision).

The migration and the switch of the runtime to the projection ship together
(phase R1): the unedited plugin rows and the plugin entries in the
`Workspace` arrays are deleted in the same release that starts reading the
projection. There is never a release in which a setting lives in both the
old row and the new model, so an edit can't land on a copy that is about to
be discarded, and plugins never disappear between phases.

Test fixture: a V19 store with two workspaces, two Jira accounts, a shared
Google Cloud connector with a project ID, and an edited built-in skill. After
migration the accounts keep their IDs and resolve their secrets, each
account keeps its own settings, the bindings and defaults match, and the
edited skill survives as an authored skill.

### Migration requirements found in review

Each is a decision R1 implements and its fixture tests.

1. **Aliases.** A migrated account's alias is its connector name with the
   service's own words removed (the rule `ConnectorAccountResolver.names`
   already applies), falling back to the connector name. Same-service
   collisions get " 2", " 3" in creation order. The two-Jira fixture asserts
   two distinct aliases.
2. **Plaintext credentials.** Before the schema stage, launch runs the
   existing `StartupCredentialMigrationService` against the V19 store. If any
   connector still holds a plaintext credential afterwards, the store stays on
   V19 and the failure is reported; the stage never runs with a credential it
   would drop.
3. **Edited components keep their settings.** An edited skill that survives
   as an authored row keeps its environment values on the row and its secrets
   under its own UUID; only unedited plugin skills move settings to the
   activation.
4. **Missing library entry.** A plugin installed in V19 whose library entry is
   missing or unreadable still gets its activation, with `recordedDigest`
   empty and the "missing, add it again" state; its bindings and settings
   are kept for when it is added again. Its skill, tool and template rows
   cannot be compared with a manifest, so none is deleted: each is kept as
   an authored row with its origin stamps cleared, and the migration logs
   it.
5. **Cleanup ownership.** `ConnectorCredentialCleanup.Ownership` counts the
   namespaces accounts own, so deleting a migrated connector row in R2 never
   cleans the account's UUID namespace; R2 enqueues only the obsolete stable
   namespace.
6. **Accounts and workspace deletion.** A workspace-owned account is deleted
   with its workspace through the existing deletion outbox
   (`WorkspaceDeletionCleanupRecord` gains the account's namespaces). A shared
   account has no owning workspace and is untouched by it.
7. **Old snapshots still decode.** The fields added to
   `ConnectorSnapshotConfig` (account ID, alias) are optional, and an
   old-snapshot fixture decodes unchanged.
8. **Schedules keep their templates.** `TaskSchedule.templateID` is a
   `UUID`, so a projected template's ID is a UUID derived from the
   activation ID and the component ID (the same derivation as a projected
   skill's). When templates move to the projection, a schedule's
   `templateID` that pointed at a deleted plugin template row is rewritten
   to that UUID, and the scheduler resolves projected templates as well as
   `workspace.templates`. Template and schedule skill IDs that named a
   deleted plugin skill row are rewritten the same way.
10. **Missing entry, deferred mapping.** For a plugin whose library entry is
    missing, settings and bindings are kept under their legacy component IDs
    with the activation marked as pending a mapping; the next Add maps them
    through the manifest it supplies, item 9's rule.
11. **Approvals follow the conversion.** Converting a V19 library entry to the
    authored manifest changes its digest, so the migration issues an approval
    record for the converted digest with the old record's status (approved,
    deprecated or blocked), only when the old record matched the old digest.
12. **The mirror carries activations whole.** `.astra-workspace.json` keeps
    each activation's non-secret `configValues`, its overrides (with the
    authored row that replaced each component), and its accounts: the
    account records themselves (service, alias, base URL, auth method,
    credential keys and per-account settings, everything but the
    credentials) and the bindings with their component and default.
    Recovery from the workspace's own mirror restores all of it, including
    the activation's ID so its secret settings resolve again. A validated
    import restores them only for components the installed manifest still
    declares, binds them to the account rows the import itself created, and
    gives the activation a fresh ID; only credentials are entered again.

9. **Legacy component IDs.** Rows made by the current installer carry
   `originComponentID` values from `CapabilityResourceOrigin.componentID(for:)`
   (`skill:<name>`, `connector:<service>:<name>`). The converter records that
   legacy ID on each manifest component, and the migration maps through it to
   the manifest's component ID; a test covers every built-in.

### Health and repair

- Expiry: when a call to a known CLI fails, or a brokered connector call
  returns an authentication failure (the broker reports it as a structured
  result, not text), run that component's `verify` (a network check for a
  connector; for a CLI, its session-reading check). If it fails, stop with
  the component's repair. Text patterns only pick which component to check.
- Checks are read-only probes gated by approval and `canRun` (see Rules).
- Retry after a repair resumes the provider session (already on `#508`).

### UI

- Each row is built once into a `PluginRow` (library entry, activation,
  status). Expand, Add, Update and Remove all take that row; nothing resolves
  a package again by ID.
- Before the old catalog goes, a parity checklist: confirmations, deep links
  from the rail, import of a plugin file, account sign-in flows (Google
  OAuth), admin approve/deprecate/block, and removal of inactive plugins.
  Each item gets a home on the new surface or an explicit "dropped" from the
  owner.

### What carries over

| PR | Fate |
| --- | --- |
| `#506` phase 0 | Merge as is: the activation owner, config-import trust and deleted-model guards are independent of this change. |
| `#508` phase 2 | Rebase on `main`: the repair loop, `RepairAction`, the expiry stop and resume, and the Plugins screen behind its flag are reused. The expiry classifier is reworked per *Health and repair*. |
| `#507` phase 1 | Superseded. `ConnectorAccountResolver` and the manifest types move into R1; its V20 is not shipped. |
| `#509` phase 3 | Superseded. The built-in manifests and the Update and `worksOn` presentation move into R3; plugin sources move to R5. |
| `#510` phase 4 | Superseded by R4, which starts from the parity checklist. |

### Phasing

Each phase is one small PR with a behavioral exit criterion, not a line
count.

| Phase | Work | Exit criterion |
| --- | --- | --- |
| R0 | Merge `#506`; rebase `#508` on `main` and merge it behind the preview flag | full suite green on `main` |
| R1 | `PluginActivation`, `AccountBinding`, `Account`, the migration, and `PluginRuntimeProjection`, in one release: the installer stops materializing plugin rows and the migrated rows are deleted as the runtime switches | the fixture migration test; the dev store migrates from a backup; no plugin-origin row exists after Add; a task in workspace A never sees workspace B's accounts; prompt scope for each built-in matches the pre-R1 scope |
| R2 | (merged into R1 so no release has two owners of a setting) | — |
| R3 | Add, Update, Turn off, Remove and Delete account on the new model; `PluginRow` | renaming a component across an Update keeps its settings; a removed component is gone; Turn off leaves accounts and secrets |
| R4 | Parity checklist, then retire the old catalog and the flag | every checklist item has a home or an owner's "dropped" |
| R5 | Plugin sources, with their own threat model | written as its own spec first: `docs/specs/2026-10-16-plugin-sources-threat-model.md` |

### How R1 was built (2026-10-16)

R1 is on `plugins2-r1`, stacked on `#514`. It implements the model, the
migration and the projection in one change, with these deviations from the
design above. Each one keeps the principle (one owner per fact, identity by
plugin and component, nothing found by name) and moves only where a fact is
stored.

1. **The account is the connector row.** There is no separate `Account`
   model. A connector row bound to an activation (`AccountBinding.account`)
   is that component's account; its UUID secret namespace, credential screens,
   Google OAuth and the broker work unchanged, and deleting the row cascades
   to its bindings. A bound row is in scope only through its binding: the
   runtime and the rail leave it out of the authored paths, so turning the
   plugin off takes it out of every run without deleting it. Add creates a
   workspace-owned account unless the activation already has one; a migrated
   shared connector stays shared and is bound in every workspace that used
   its plugin. The alias is the row's name; same-named accounts of one
   component get " 2", " 3" at migration.
2. **Component IDs are the runtime IDs already stamped on rows**
   (`skill:<name>`, `connector:<service>:<name>`, `tool:<type>:<command>:<name>`,
   from `CapabilityResourceOrigin`). The library still stores `PluginPackage`,
   so no digest changes and no approval has to be re-issued. Storing the
   authored manifest, mapping these IDs to manifest component IDs and
   requirements 9-11 move to R3, where Update first handles renames.
3. **Templates stay workspace rows** owned by the plugin (origin-stamped,
   removed with it) until R3. They were already per workspace, so they were
   never a cross-workspace reach.
4. **Overrides name their row.** `PluginActivation.overridingRowIDs` pairs
   each overridden component with the authored row that replaced it, so the
   projection brings that row in by ID. Without it an edited plugin skill fell
   out of every run: the runtime reached plugin skills only through name
   matching, never through `enabledGlobalSkillIDs`.
5. **The migration runs after the store opens, not as a custom stage.**
   V20 is additive (the legacy enablement arrays are renamed `legacy*` and
   kept, read only by the migration and cleared by it), so V19 stores
   lightweight-migrate. `PluginActivationMigration` runs synchronously at
   launch before any capability resolution, and again after workspace
   recovery. It is idempotent and one save; a secret it cannot copy aborts
   it before anything is deleted, and the next launch retries. Requirement 2
   (plaintext credentials) does not arise: no connector row is deleted.
   Dropping the `legacy*` fields is a later schema version.
6. **Settings.** Non-secret plugin skill settings live in
   `PluginActivation.configValues` (`componentID.KEY`); secret ones in the
   Keychain under the projected skill's ID, which is a name-based UUID of
   the activation ID and the component ID. The mirror carries the activation
   ID, so recovery from the workspace's own mirror keeps that namespace; a
   file the user imports gets a fresh activation, so a copy never shares its
   original's secrets.
7. **Task pins.** A stored task never pins a projected skill (SwiftData
   would insert it). Plugin skills reach a run through the activation, so
   the pin added nothing.
8. **Remove keeps accounts; their deletion is R3's "Delete account".**
   Remove deletes the activations; their projected skills' secret
   namespaces are written to `PluginSecretCleanupOutbox` before the save,
   cleaned after it, taken back if it fails, and finished at the next launch
   if a quit came between (only while nothing live names them). The
   migration records the namespaces of the skill rows it deletes the same
   way.
9. **The startup definition repair is retired.** It rewrote plugin skill
   rows to the current definition; the projection always reads the current
   definition, and the repair would have reverted edited (authored) rows.

Exit criteria, as tested on the branch:

- Migration fixture (`PluginActivationMigrationTests`): a V19 store with
  three workspaces, two Jira accounts in one, a shared Google Cloud
  connector with a project ID, an unedited shared skill with a setting and an
  edited built-in skill migrates; accounts keep their IDs and settings,
  bindings follow ownership, aliases are distinct, the edited skill stays
  authored and overrides the component, templates and schedules point at the
  projection, and a second run changes nothing.
- No plugin-origin skill or tool row exists after Add, for every built-in
  (`PluginPromptScopeParityTests`).
- A task in workspace A never sees workspace B's accounts, and turning a
  plugin off takes its accounts out of scope without deleting them.
- Prompt scope for each built-in matches the pre-R1 scope, against a golden
  recorded from the pre-R1 installer and resolver.
- A detached launch resolves the same skills, accounts, tools and settings
  as the live task; the mirror round-trips activations.

### How R3 was built (2026-10-16)

R3 is on `plugins2-r3`, stacked on R1 (`#518`).

- **Component identity.** A skill, connector or tool may declare `id`
  (stable identity) and `replaces` (identities it takes over). Without `id`
  the identity is the runtime one R1 used. The validator refuses two
  components with one identity, a `replaces` naming another kind (or, for a
  connector, another service), one naming a component still declared, and
  one claimed twice. The library still stores `PluginPackage`, with these
  optional fields; nothing changes for a package that omits them.
- **Update is reconciliation.** `PluginUpdateService` brings each activation
  to the definition in the library: a component taken over through
  `replaces` keeps the old one's settings, bindings, override and secret
  settings (copied to the new namespace before the save), and the templates
  and schedules that named its skill are rewritten; a component the
  activation knew (`knownComponentIDs`) that is gone and not taken over is
  released, its secret namespace journaled. It runs after an import (which
  first refuses a version a workspace with the plugin on would refuse: a
  pack rule, a missing dependency, a conflict, an unsafe declaration, and
  restores the previous library entry if reconciling fails), on Add, and at
  launch after the built-in sync. A row whose activation still runs an
  earlier definition offers Update.
- **Remove** writes its intent (`PluginRemoveJournal`) before the save and
  clears it after the library entry goes; launch finishes an interrupted one
  and drops one whose activations were never deleted.
- **Accounts.** A plugin-created account is in scope only through a binding:
  after Turn off, Remove or a dropped component it stays, unbound and out of
  every run, until it is bound again or deleted. Add account, Make default
  and Delete account (confirmed, naming the workspaces that use it; the only
  path that clears its credentials, through the connector cleanup outbox)
  are on the row.
- **`PluginRow`.** The surface builds each row once from the package, the
  activation and the display state; Expand, Add, Update, Turn off, Remove,
  settings and accounts all take it. Turn off asks nothing. Plugin skill
  settings are edited on the expanded row (secret ones with
  `SecretEntryField`, into the Keychain).
- **Still rows:** plugin templates (workspace rows owned by the plugin);
  they move to the parity checklist in R4.

### How R4 was built (2026-10-16)

R4 is on `plugins2-r4`, stacked on R3. The Plugins screen is the only
capability screen: `PluginCatalogView`, its install sheet and router, the
prerequisite badge, the catalog-only presentation and cache types, the
preview flag and its Settings toggle are deleted.

| Parity item | Home, or the owner's call |
| --- | --- |
| Confirmations | Remove and Delete account confirm, naming what goes and what stays; Turn off deletes nothing and asks nothing |
| Deep links from the rail | A plugin the rail (or an MCP install) asks for opens expanded and scrolled to |
| Import of a plugin file | "Import file..." reviews the file and imports it through the action service; a newer version of an installed plugin is an Update |
| Account sign-in flows (Google OAuth) | **Dropped (owner, 2026-10-16).** The Google Workspace sign-in sheet, its setup presentation, the OAuth stack and the build script's client ID are deleted; a plugin whose setup needs an OAuth account is listed without Add, saying why |
| Admin approve / deprecate / block | On the expanded row for admins, keyed to the version's digest |
| Removal of inactive plugins | Remove is offered whether the plugin is on or off |
| Creating a plugin | **Kept (owner, 2026-10-16):** New > Create a plugin... (the wizard) and New > From an MCP server... |
| Export source JSON, copy setup from another workspace, validate before Add | **Dropped (owner, 2026-10-16)** |
| Category scopes, approval and risk filters, per-row risk labels | Replaced by the three status groups and search (UI section) |

Chat `/mcp` plugin creation, which the superseded phase 4 removed, stays:
it is a way to create a plugin, which the owner kept.

### Owner decisions (2026-10-16)

1. Edited plugin skills survive the migration as authored skills.
2. An account belongs to one workspace unless shared explicitly.
3. `#507`, `#509` and `#510` are closed as superseded; R0 is under way.
4. R4 parity: creating a plugin is kept; Google OAuth sign-in, export, copy
   setup and validate-before-Add are dropped.

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
        "authMethods": ["api_token"],
        "transport": "brokered",
        "aliasRequiredWhenMultiple": true
      },
      "check":   { "kind": "credentialPresent" },
      "verify":  { "kind": "http", "path": "/rest/api/3/myself" },
      "connect": { "kind": "credentialForm", "fields": [
        { "key": "site",  "storage": "account.baseURL" },
        { "key": "email", "storage": "account.config" },
        { "key": "token", "storage": "secret" } ] },
      "repair":  { "kind": "connect" } }
  ]
}
```

Every `credentialForm` field declares where its value goes: `secret` (the
Keychain, under the account), `account.baseURL`, `account.alias`, or
`account.config` (a non-secret per-account setting). The validator rejects
a form with a field that declares none, so no value is ever classified by
its name, and a token can never land in SwiftData.

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

- `check` never needs the user and runs on add and on every refresh, but only
  for a plugin whose installed digest matches its approval and whose catalog
  decision is `canRun`. An `exec` check is a plugin-defined host subprocess,
  so a tampered, unapproved or blocked manifest's checks never run; its row
  shows the policy reason instead. Because checks repeat (every refresh, and
  every few seconds while a repair waits), an `exec` check must also be a
  read-only probe: the component's own binary, no shell syntax
  (`LocalToolSecurityPolicy`), and a status or version verb, never a command
  that writes CLI, host or remote state. A check that isn't one is refused
  at import like any other unrepresentable step. *(As built: the built-in
  checks are read-only — `--version`, `auth status`, `config config-helper`;
  there are no source plugins in R1-R4, and R5 does not run a source
  plugin's `exec` check, on refresh or in repair polling, until this
  read-only rule is enforced against it; until then its checks show as
  "not checked".)*
- A connector lists only the auth methods it declares a complete setup for.
  With more than one, the setup legs are keyed by method
  (`"setup": { "api_token": { … }, "oauth": { … } }`) and the person picks the
  method when connecting; an `oauth` method also names its authorization,
  scopes and token exchange. *(As built, a connector carries one
  `authMethod`, and ASTRA has no OAuth connector setup; a manifest whose setup
  steps the package can't carry is refused at import.)*
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
- `Approve`/`Deprecate`/`Block` leave the single-user UI. There is no managed
  mode yet; in the single-user app, revoking a plugin is Remove, and blocked or
  deprecated approval records that already exist are still honored by the
  policy. Phase 4 deleted the only screen that wrote those statuses, so a
  managed mode must ship with its own admin control on the Plugins surface
  (approve, deprecate, block, revoke) before it is offered to teams.

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
  preflight for every connector account in the launch's resolved capability
  set (not only the keyword-triggered `jira` entry in
  `triggerKeywordsByServiceType`; an enabled account the run does not use
  never gates it, and its health refreshes only the Plugins UI), and
  pattern matching on the
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
  the repair row in the task view, and `Retry` resumes once the component's
  `verify` passes (`check` only detects the failure; a present but expired
  token passes a shallow `check`). A component without a `verify` uses a
  `check` that reads the session state itself. *(As built: the built-in CLI
  checks read session state — `gcloud config config-helper` token expiry,
  `gh auth status` — so they serve as verify; connector `verify` before
  Retry is not built yet.)*
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
| Workspace mirror | `.astra-workspace.json` keeps, per plugin, its id, the source it came from and the digest that was approved, plus account aliases; on import a plugin is enabled only when the installed one has the same source and digest, as `WorkspacePackageImportCoordinator` already validates against the installed library. *(Not built yet: the mirror keeps ids only. Installed IDs are unique case-insensitively and a source plugin can't reuse a built-in ID, which narrows a swapped plugin but doesn't close it.)* | the verbatim copy of enablement arrays and origin stamps (`WorkspaceConfigManager.swift:2056`, *verified*) |

Derived caches (composer snapshot, rail snapshot, browser policy cache) keep
existing but observe `PluginActivation` changes, and every read of a workspace
goes through the deleted-model guard added in `#495`.

## Phasing

Each phase ships on its own PR and leaves `main` working.

| Phase | Work | Exit criterion |
| --- | --- | --- |
| 0 | Single owner for enablement as a service (`WorkspaceCapabilityActivation`, no schema change), config import validates against the library, workspace views guarded against a deleted model. **`aandresalvarez/astra#506`.** | the 2026-10-13 review's high item closed; zero writes to the enablement arrays outside the owner, and reads frozen per file by a registry that only ratchets down |
| 1 | Manifest + converter that projects a plugin into today's rows; `PluginActivation` and `Account` entities together in one schema `Vn+1`, behind the phase 0 owner; reads move behind the owner; alias/default-account resolution replaces keyword ranking | runtime tests unchanged and green; the read registry is empty; a two-account Jira workspace launches with the chosen account |
| 2 | New Plugins surface behind a dev flag; health loop with the three repair strategies; typed `repairAction` rendered in rail and task view | a `gcloud` session expired mid-task pauses, repairs from the task view, resumes |
| 3 | Built-ins migrated to the manifest; git sources; startup repair retired; `worksOn` shown at add | all 12 built-ins add in one step on a fresh dev store |
| 4 | Delete the old install/approve/enable path and `PluginCatalogView` | the install side (install, approve, enable, review, catalog, gallery, import, create and MCP-install services plus their UI) under half its size on `main` *(revised 2026-10-16 by the owner from "`Astra/Services/Capabilities` install side"; see below)* |

### How the phases landed

The code departs from the plan above in these places; the code is the
reference.

- **Phase 1 (`aandresalvarez/astra#507`).** No `PluginActivation` entity and
  no separate `Account` entity. Schema V20 (V19 frozen with its digest pinned)
  adds `Connector.accountAlias` and the workspace's default account per
  service (`Workspace.defaultAccountServiceTypes/ConnectorIDs`); the activation
  arrays stay on `Workspace`, and every read and write goes through
  `WorkspaceCapabilityActivation` (`workspace.capabilityActivation`), with the
  read registry empty apart from the two config-format files. An account is a
  connector with an alias. `ConnectorAccountResolver` picks the account a turn
  names (alias, or the connector's name minus the service's own words), then
  the workspace default; with neither it keeps every account in scope rather
  than blocking the launch. `connectorMatches` on service type is unchanged, so
  the cross-workspace reach under *Security considerations* is still open.
- **Phase 2 (`aandresalvarez/astra#508`).** The health loop is
  `PluginRepairCoordinator` (polls the check every 5 s, needs two passing
  checks, gives up at 300 s). A mid-run expiry is detected by
  `CLISessionExpiryClassifier` on tool results (Google Cloud and GitHub
  families), stops the run with `capability_session_expired`, and records
  `runtime.repair_required`; the task view offers the repair and Retry, which
  resumes the provider session (the stop reason is resumable like a
  cancellation), so work done before the expiry, external writes included,
  isn't replayed. The
  `gcloud` check reads `config config-helper --format=value(credential.token_expiry)`
  so the health view never prints a token.
- **Phase 3.** The ten built-in files (not twelve; the earlier count included
  assets) are manifests, and the bundle reader accepts both shapes. Sources are
  a git URL, `owner/repo` or a folder, cloned shallow with `file:` transport
  refused and read through `HostFileAccessBroker`, which refuses symlinks that
  leave the source; a source plugin reusing a built-in ID cannot be added.
  `worksOn` is keyed by `AgentRuntimeID` raw values (`claude_code`,
  `codex_cli`, …); phase 1 used display names by mistake. The startup repair is
  gone: an added plugin whose library version differs from the one the
  workspace recorded shows **Update**, which re-runs Add in every workspace
  that has the plugin on and retires every component kind the new version
  dropped: skills, shared accounts and tools are deactivated and unlinked,
  workspace accounts and templates are deleted, and configured values are
  kept for keys that remain. Workspace-local legacy copies of a
  built-in skill are no longer rewritten. Local-edit detection before an update
  is not built.
- **Phase 3 PR:** `aandresalvarez/astra#509`.
- **Phase 4 (`aandresalvarez/astra#510`).** The Plugins surface is the only
  capability screen. Deleted with `PluginCatalogView` and its preview flag:
  the generic install sheet, the creation wizard, export source, the admin
  approve/revoke review, the install-time copy-setup menu, the old catalog
  presentation, and the compiled built-in fallback (the bundled manifests are
  the only copy). By the owner's decision, chat `/mcp` plugin creation and the
  custom Google Workspace sign-in sheet are removed too; `/mcp` is now an
  ordinary message. Google Workspace stays listed but is not offered: a plugin
  whose setup needs an OAuth account shows "Needs an account sign-in that
  ASTRA can't do yet" instead of Add, until an OAuth `connect` leg exists. Kept: "Import file…" (one plugin
  JSON, through `CapabilityCatalogActionService.importFile`) and the catalog
  persistence events, which the surface observes.
  The Google OAuth services were deleted as well: nothing called them, and
  even on `main` the one reader of the stored tokens
  (`GoogleWorkspaceRemoteMCPRuntimeService`) had no caller, so a sign-in never
  reached a run. The build script no longer writes `ASTRAGoogleOAuthClientID`.
  Dead code that a periphery scan found in the remaining install services was
  removed.
  **Exit criterion, measured against `main`:** the install side (services plus
  UI) went from 13,554 lines to 6,017 (44%), which meets the criterion as the
  owner revised it. Counting `Astra/Services/Capabilities` alone, the original
  wording, it went from 8,054 to 5,410 (67%). The rest is the installer,
  validator, catalog policy and credential cleanup the surface still calls;
  the owner chose not to rewrite those security checks to reach a
  services-only half.

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
  `CapabilityRuntimeResourceMatcher.swift:114-124`)*. **Still open:** the
  `PluginActivation` entity keyed by workspace that was meant to close it was
  not built (phase 1 kept the activation arrays), and `connectorMatches` is
  unchanged. Closing it needs workspace-scoped connector matching; until
  then the account resolver only narrows which of the reachable accounts a
  turn narrates.
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
