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
  unique `id` per component and a supported `manifestVersion`, and refuses
  an MCP server ID that another installed plugin already declares
  (`.duplicateMCPServerID` in `CapabilityPackageValidator`): projected MCP
  servers, provider configuration and permission names use the server ID
  unqualified. The install blockers `PluginPackage` carries today
  (`minAppVersion`, `requires`, `conflicts`, checked through
  `installBlockers`) are manifest fields too (`PluginManifest`), so Add still
  refuses an incompatible plugin.
- **`PluginActivation`** (`@Model`): `workspace`, `pluginID`, `enabled`,
  `recordedVersion`, `recordedDigest`, `configValues` keyed
  `componentID#KEY` for settings that belong to the workspace, not to an
  account (a skill's environment value; the key is split on its last `#`,
  and setting keys never contain `#`, so no two components' settings
  collide), `secretSettingKeys` (which secret settings are in the Keychain),
  `knownComponentIDs` (the components of the definition it was last
  reconciled against), `overriddenComponentIDs` (components the person
  replaced with an authored row, which the projection skips), and
  `revision`. Deleting an activation deletes its bindings
  (`@Relationship(deleteRule: .cascade)` on `PluginActivation.bindings`).
- **`AccountBinding`** (`@Model`): `activation`, `componentID`, `account`
  (relationships), `isDefault`. A component can bind several accounts (two
  Jira sites). A workspace has one default account per service across all
  its plugins, not one per component: `WorkspaceCapabilityActivation.bind`
  and `unbind` keep exactly one binding of each service the default, and
  `defaultAccount(forService:in:)` reads it. Deleting an account cascades to
  its bindings, so no activation keeps a dangling ID; a cascade alone would
  skip the promotion `unbind` does, so every deletion unbinds first:
  Delete account unbinds it from every activation, Configure's delete and
  the legacy Turn off call `WorkspaceCapabilityActivation.releaseAccount`,
  and removing an activation
  (Remove, a snapshot restore) unbinds each of its accounts. A service whose
  default was among them gets its oldest remaining account in the same
  save.
- **`Account`** (`@Model`): `id` (UUID), `serviceType`, `alias` (unique per
  normalized service among the accounts a workspace can see, checked on
  every bind; an account already bound in another workspace is never
  renamed, since the row is shared and its alias would change there too,
  and a collision it brings into the joining workspace is told apart per
  launch, where `ConnectorRuntimeProjection` suffixes duplicate aliases),
  `baseURL`, `authMethod`,
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
  library manifests and their bound accounts into value types. It is not
  cached itself; the cache that holds its result, the rail's
  (`CapabilityRailSnapshotSignature`), is keyed by each activation's
  `revision` and on/off state, the library packages, and every workspace and
  shared skill, connector and tool row (ID, name, `updatedAt`). Editing an
  account's URL, alias or settings changes its row, and deleting the
  authored row an override names removes it from that key, so either
  evicts the cached projection.
- The projection skips the components listed in the activation's
  `overriddenComponentIDs`; the authored row that replaced each one is in the
  inventory instead, so nothing is duplicated. An override whose authored row
  the store no longer has is ignored and the component projects again, so
  deleting the replacement never silently drops the component; a detached
  launch, whose copy lacks shared rows, keeps skipping it
  (`PluginRuntimeProjection`).
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
| Update | library entry (new digest, re-approved), and `recordedVersion`/`recordedDigest` on **every** activation of the plugin | the library holds one version, so an update is global: every workspace with an activation of the plugin, on or off, is checked first (`PluginUpdateService.refusals`), and one that refuses it (a pack rule, a missing dependency, a conflict) blocks the update with its reason. Removed components disappear because nothing derives them. A rename is never inferred: a component that was renamed lists its earlier ID in `"replaces": ["old-id"]`, and only then do the old ID's settings, bindings, override and secrets move to it (`moveComponentState`), and the templates and schedules that named its skill are rewritten (`retargetSkill`), and only when the kind and, for a connector, the service match. Any other changed or reused ID is a remove plus an add and starts empty; a `replaces` naming a component of another kind or service, naming more than one predecessor, or claimed by two components, is refused at validation. A connector that keeps its ID but no longer declares the sign-in method an account uses keeps the account bound and working, and the account is flagged on the row ("reconnect", `CapabilityPackageState`) as a pending step until the person reconnects it |
| Turn off | `activation.enabled = false` | deletes nothing, so it needs no confirmation |
| Remove | library entry, its activations (their bindings cascade), and the activations' secret settings | offered only once the plugin is off in this workspace, and confirmed by name (`PluginsSurfaceConfirmation.remove`): it turns the plugin off in every workspace and deletes its settings there; its accounts and their credentials stay, listed under Accounts. The activation-owned Keychain entries are recorded in the durable cleanup outbox before the activations are deleted |
| Delete account | the `Account` and its bindings (cascade), with its secrets recorded in the cleanup outbox before the save and cleaned after it | confirmed, naming the workspaces that use it; the only path that clears credentials |

The state lives in three stores (library and approval files, SwiftData,
Keychain), so no operation is one transaction. Each writes in a fixed order
that leaves a recoverable state at every step, and a launch-time
reconciliation finishes or undoes what an exit interrupted:

- **Add:** approval file, library entry, then activation. An approved entry
  with no activation is just an installed plugin; it shows under Available.
  The same order holds whenever a write replaces an approved copy: Create
  and enable of a newer version saves the new version's approval before the
  library write (`CapabilityApprovalStore.saveBeforeDependentWrite`, taken
  back if the install fails), so an exit between them leaves the new copy
  approved. A file import of a newer version writes no approval at all: an
  imported update is a draft until the person approves it, crash or not.
  The row's Update never writes the library; it reconciles activations with
  the copy already there.
- **Update:** library entry, then the activations. Reconciling needs only
  the new definition and the activation's own record (`knownComponentIDs`,
  its setting keys and `secretSettingKeys`), never the previous manifest, so
  an exit between the two is finished by the next launch's reconciliation;
  the library's rollback snapshot (`makePackageStorageSnapshot`) is in
  memory and only undoes an import that fails in the same process. An
  activation whose recorded version, digest or component list differs from
  the library, or whose plugin templates have drifted, is shown as needing
  Update (`PluginUpdateService.needsReconcile`). A component ID encodes
  the component's kind and, where it has one, its service or command
  (`skill:<name>`, `connector:<service>:<name>`,
  `tool:<type>:<command>:<name>`, `template:<name>`;
  `CapabilityResourceOrigin.componentID(for:)`), so a version that reuses a
  connector's name for another service, or a name for another kind, declares
  a different ID: reconciliation sees the old one dropped and the new one
  added, and no binding, setting or secret crosses between them. That needs
  nothing beyond `knownComponentIDs`. A stable explicit `id` keeps that
  property where it matters: a connector's identity is still
  `connector:<service>:<id>`, so a connector that keeps `id: "jira"` but
  becomes a Slack connector is a new component and no Jira binding,
  setting or secret moves to it; every identity starts with its kind, so a
  skill and a tool never share one. A tool with an explicit `id` is
  `tool:<id>`; a tool holds no settings, bindings or secrets, only an
  optional override row the person authored, which stays theirs. Components the new version
  dropped are removed from each activation like a Remove of that component,
  in the same save that advances its digest: their bindings and
  `configValues` are deleted and their activation-owned secrets go through
  the cleanup outbox, so a later version that reintroduces the ID starts
  empty. A key a kept skill no longer declares has its setting dropped in
  that save, and its Keychain entry is recorded in the same cleanup outbox
  (a `namespace#KEY` entry) before the save and deleted after it, or at the
  next launch; a key a live activation records again is spared. Launch
  never releases anything: the
  automatic pass (`PluginUpdateService.Mode.automatic`) only moves renamed
  components, and when a definition would drop something the activation
  stays on its recorded version and the row offers Update.
- **Remove:** a Remove intent for the plugin is written to the operation
  journal (`PluginRemoveJournal`) first, then the activations are deleted,
  then the library entry, then the intent is cleared. At launch an intent
  whose plugin no live activation names finishes the Remove, a plugin that
  never had an activation included; one whose activations are still stored
  (the save never landed, or the plugin was added again) is dropped; an
  unreadable store or a library entry that can't be removed keeps it for the
  next trusted launch. An activation whose library entry is missing with no
  intent is shown as "missing, add it again" and never resolves.
- **Delete account and Remove:** the Keychain entries they release are
  recorded in the durable cleanup outbox first, then the SwiftData deletion
  is saved, then the entries are cleaned, exactly as
  `ConnectorCredentialCleanup.deleteThenClean` does today (the record is
  undone if the save fails), so neither an orphaned secret nor a secret
  deleted for a live owner is possible. `PluginOperations.deleteAccount`
  goes through `ConnectorCredentialCleanup.deleteThenClean`, and Remove
  (`CapabilityUninstaller`) through `PluginSecretCleanupOutbox.deleteThenClean`.

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
   account's UUID namespace in R1, so the projection reads one namespace.
   *(As built, the connector row is the account and the migration deletes no
   connector row, so the stable namespace stays derivable from the row; it
   is cleaned when the account is deleted, through the
   `ConnectorKeychainCleanup` that `ConnectorCredentialCleanup` records
   before the save. No connector namespace is released without a durable
   record.)* Bindings come from
   ownership, not from what is enabled now: a workspace-owned connector binds
   to its workspace's activation of the plugin, and a global connector binds
   to every activation of its plugin in a workspace that had it enabled or
   installed, so a plugin that was turned off keeps its accounts. V19 stored
   no default account, so none is read: accounts are bound in creation
   order through `WorkspaceCapabilityActivation.bind`, and each service's
   oldest account in the workspace becomes its one default, across plugins.
   A service that ends up with more than one account shows that default on
   its Plugins row for the person to confirm or change.
3. Environment values on plugin skills move to `activation.configValues`
   under `componentID#KEY`. Secret ones are not in SwiftData (a skill keeps
   them in the Keychain under its UUID), so they move to a Keychain namespace
   owned by the activation and component (the projected skill's ID), and
   the projection reads them from there. A projected skill carries secret
   keys with empty values, exactly as a stored skill does, so
   `SkillSnapshotConfig` and `AgentTask.skillSnapshotsJSON` never hold a
   secret; the value resolves from the Keychain at execution. They are
   copied before the save; the old skill rows' namespaces are recorded in
   `PluginSecretCleanupOutbox` before the save and cleaned after it, and on
   any failure the copied secrets are put back as they were.
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
   collisions get " 2", " 3" in creation order. The collision check covers
   every account of the normalized service that a workspace the account
   joins can see, across components and plugins, not one component's
   accounts (`WorkspaceCapabilityActivation.bind`, which the migration, Add
   and mirror restore all go through). The two-Jira fixture asserts two
   distinct aliases.
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
   it. So that re-adding the plugin does not project a second copy, the
   migration records each kept skill and tool row with the component it came
   from as pending on the workspace's retired-plugin record
   (`RetiredPluginActivation.pendingOverrides`, in the existing JSON column).
   When the definition is back, through Add or a launch that finds the
   library entry, `adoptPendingOverrides` makes each row the activation's
   override of the component it names, if the definition still declares it,
   and takes shared rows out of the shared lists, as for an edited override.
   Every workspace with an activation of the plugin is reconciled in the same
   save. A row that was deleted, or names a component no longer declared,
   stays authored. Templates need nothing: Add upserts a plugin template by
   name.
5. **Cleanup ownership.** `ConnectorCredentialCleanup.Ownership` counts the
   namespaces accounts own, so deleting a migrated connector row in R2 never
   cleans the account's UUID namespace; R2 enqueues only the obsolete stable
   namespace. *(R2 merged into R1, which deletes no connector row; see step
   2.)*
6. **Accounts and workspace deletion.** A workspace-owned account is deleted
   with its workspace through the existing deletion outbox
   (`WorkspaceDeletionCleanupRecord` gains the account's namespaces). A shared
   account has no owning workspace and is untouched by it. The record also
   holds every namespace the workspace's activations' projected skills may
   hold secrets under (`PluginRuntimeProjection.secretNamespaces`, every
   component the activation remembers), written before the save
   (`WorkspaceDeletionCleanup`).
7. **Old snapshots still decode.** The fields added to
   `ConnectorSnapshotConfig` (account ID, alias) are optional, and an
   old-snapshot fixture decodes unchanged.
8. **Schedules keep their templates.** `TaskSchedule.templateID` is a
   `UUID`, so a projected template's ID is a UUID derived from the
   workspace ID, the plugin ID and the component ID (the same derivation as
   a projected skill's, `PluginRuntimeProjection.derivedID`), never from
   the activation ID, so Remove then Add in the same workspace yields the
   same IDs and schedules and templates keep resolving. When templates move
   to the projection, a schedule's
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
    the activation's ID, `knownComponentIDs` and `secretSettingKeys`; its
    secret settings resolve again because the workspace keeps its ID. A
    validated
    import restores them only for components the installed manifest still
    declares, binds them to the account rows the import itself created
    (with fresh UUIDs, since a connector's Keychain namespace is derived from
    its ID, so a copy imported on the same Mac never resolves the original's
    credentials), and gives the activation a fresh ID and namespace seed;
    only credentials are entered again. Templates and schedules that name a
    projected skill are remapped from the file's own workspace ID to the
    IDs the new activation derives, also when the copy gets a fresh
    workspace UUID (Duplicate), so they keep resolving. Recovery from the
    workspace's own mirror keeps account IDs. An Import
    Workspace action that imports several workspaces at once (a parent
    `Workspaces` folder) shares one import session: each exported shared
    account gets one fresh row for the whole action, stays shared, and every
    imported activation that named it binds that row; the fresh ID still never
    resolves an existing Keychain credential, and a single-workspace import or
    mirror recovery is unchanged.

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
- As built (`plugins2-repair`, merged into R1 and R3):
  `CLISessionExpiryClassifier` has four built-in families (`googleCloud`,
  `googleCloudApplicationDefault`, `gitHubEnvironmentToken`, `gitHub`) and matches only a failed structured tool result of a command
  that starts one of those CLIs, never agent text. Expiry for connector
  components (the broker's structured auth failure) and for patterns a
  manifest declares is not built: those components still fail the run
  rather than entering repair, so the health loop is complete only for the
  built-in Google Cloud and GitHub families. Neither is scheduled in R1-R5;
  connector expiry needs connector `verify` first (see Health and repair
  below).
- Checks are read-only probes gated by approval and `canRun` (see Rules).
- As built: a check runs on every scan (rail, Plugins surface, launch
  preflight, repair polling) with no click, so ASTRA runs it only when it is
  a known read-only status command for that CLI (`HealthCheckPolicy`,
  matched by `CLICommandShape`). Its positional words must match a listed
  status command exactly and every flag must be one that command lists; a
  flag's separate value counts as a positional unless the flag takes one.
  Allowed: `--version`/`version` for any CLI; `gh auth status` (`--hostname`,
  `--active`); `gcloud auth list` (`--format`, `--filter`); `gcloud config
  get-value <property>` (`--format`); `az account show` (`--output`,
  `--query`); `aws sts get-caller-identity` (`--output`, `--profile`,
  `--query`, `--region`); `docker version|info` (`--format`); `docker ps`
  (`--format`, `--quiet`). Only in their exact forms, because their default
  output is a token or a script: `gcloud config config-helper
  --format=value(credential.token_expiry)`, `gcloud auth application-default
  print-access-token --format=value(expiry)` and `osascript -e 'return
  "ok"'`. A check that fails the rule is never executed: its status is
  `notChecked`, shown as "Not checked" (not a pass) with no repair offered;
  a repair's re-check applies the same rule; `CapabilityPackageValidator`
  refuses it at import ("Unsafe health check"). The rule is the same for
  every plugin, and every bundled check passes it (test-pinned).
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
   its plugin. The alias is the row's name; an account whose name another
   account of the same normalized service already has, among the accounts
   any workspace it joins can see (other components and plugins included),
   is renamed " 2", " 3" when it is bound (`WorkspaceCapabilityActivation.bind`,
   used by the migration, Add and mirror restore; new accounts take
   `uniqueAlias`).
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
   launch before any capability resolution, and again after the
   asynchronous workspace recovery import (`afterImport`). It is idempotent
   and one save; a secret it cannot copy aborts it before anything is
   deleted, the secrets already copied are put back on any failure, and the
   next launch retries. Requirement 2
   (plaintext credentials) does not arise: no connector row is deleted.
   Dropping the `legacy*` fields is a later schema version.
6. **Settings.** Non-secret plugin skill settings live in
   `PluginActivation.configValues` (`componentID#KEY`, split on the last
   `#`; an emptied setting is kept as an explicit empty value); secret ones
   in the Keychain under the projected skill's ID, which is a name-based
   UUID (SHA-256, version 5 layout) of the workspace ID, the plugin ID and
   the component ID (`PluginRuntimeProjection.derivedID`). It survives
   Remove then Add in the same workspace, so schedules and templates that
   name it keep resolving; the cleanup outbox spares a namespace a live
   activation names again. Recovery from the workspace's own mirror keeps
   the workspace ID and so the namespace; a file the user imports into
   another workspace derives other IDs, so a copy never shares its
   original's secrets.
7. **Task pins.** A stored task never pins a projected skill (SwiftData
   would insert it). Plugin skills reach a run through the activation, so
   the pin added nothing.
8. **Remove keeps accounts; their deletion is R3's "Delete account".**
   Remove deletes the activations; their projected skills' secret
   namespaces are written to `PluginSecretCleanupOutbox` before the save,
   cleaned after it, taken back if it fails, and finished at the next launch
   if a quit came between (only while nothing live names them). Adding the
   plugin again in that workspace derives the same namespaces, so Add first
   settles the ones it would reuse (no activation owns them yet) and refuses
   ("can't be added yet") while one is still pending or the record can't be
   read (`PluginSecretCleanupOutbox.settleBeforeAdding`): a new activation
   never inherits the old values. The migration records the namespaces of
   the skill rows it deletes the same way.
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
  connector, another service), one naming a component still declared, one
  claimed twice, and a component naming more than one predecessor
  (`PluginUpdateService.replacesProblems`), so a rename never has to merge
  two components' settings, accounts or secrets. MCP server IDs must be
  unique across installed plugins (`.duplicateMCPServerID`). The library
  still stores `PluginPackage`, with these
  optional fields; nothing changes for a package that omits them.
- **Update is reconciliation.** `PluginUpdateService` brings each activation
  to the definition in the library: a component taken over through
  `replaces` keeps the old one's settings, bindings, override and secret
  settings (`moveComponentState`; secrets copied to the new namespace
  before the save, a value the new component already has wins, and every
  copy is put back by `PluginUpdateService.undo` if any activation's
  reconciliation or the save fails), and the templates and schedules that
  named its skill are rewritten (`retargetSkill`). Before any state moves,
  a destination namespace still journaled for deletion (a component of
  that ID removed earlier whose cleanup failed) is cleared, keeping only
  the keys the activation records there; while it can't be cleared, Update
  refuses ("can't be updated yet") and the automatic pass holds back, so a
  renamed component never inherits old credentials
  (`PluginSecretCleanupOutbox.settleRenameDestination`). The predecessor's own
  namespace is journaled in `PluginSecretCleanupOutbox` before the save and
  deleted after it once no activation owns it, so a rename leaves no
  ownerless credentials; a failed save keeps it. The automatic launch pass
  copies every secret the predecessor recorded, declared or not, and moves
  the markers, so nothing is deleted before the person's Update releases a
  key the new version no longer declares; a component the
  activation knew (`knownComponentIDs`) that is gone and not taken over is
  released, its secret namespace journaled. A setting a kept skill no
  longer declares is released too (its Keychain entry journaled in
  `PluginSecretCleanupOutbox` and deleted after the save), and the plugin's
  templates follow the definition
  (`PluginTemplateSync`; a template the definition dropped stays as an
  authored row). Releasing deletes the
  person's settings and secrets, so only an action of theirs does it
  (`Mode.release`): an import they chose (which first refuses a version a
  workspace with an activation of the plugin, on or off, would refuse: a
  pack rule, a missing dependency, a conflict, an
  unsafe declaration, and restores the previous library entry if
  reconciling fails), Add, or the row's Update, scoped to its plugin. After
  any reconcile, and after an account is deleted, the mirror of every
  workspace it changed is exported. The automatic pass (`Mode.automatic`) at
  launch after the built-in sync, and after workspace recovery, only moves
  renamed components (nothing is lost) and records the new version when
  the definition drops nothing; when it would drop a component the
  activation stays on its recorded version and the row offers Update,
  which names what goes. The library holds one definition and the runtime
  always projects that one (the approved digest), so a dropped component
  stops running at once; "stays on its recorded version" means its
  settings, accounts and secrets are kept, not that the old definition
  runs. Keeping old definitions runnable per activation is not planned:
  the approval is for the library's digest, and running two versions of
  one plugin side by side is what the redesign removes.
- **`knownComponentIDs`** is part of V20 (R1 and R3 ship together; no
  release has the model without it). The migration seeds it from the
  definition each activation was migrated against, Add and every
  reconciliation set it, and the workspace mirror carries it, so a dropped
  component is always identifiable, including one that only had secrets.
  An activation restored without it (a mirror an older build wrote) is
  reseeded at launch before any reconcile: `PluginActivationMigration`
  treats an empty `knownComponentIDs` on a plugin with components as
  pending. Reconcile also counts every component the activation's settings,
  secrets, bindings and overrides name, so nothing it holds is missed.
- **Remove** writes its intent (`PluginRemoveJournal`) before the save and
  clears it after the library entry goes. On every trusted launch an intent
  whose plugin no live activation names is finished, a plugin that never
  had an activation included; one whose activations are still stored is
  dropped; one whose store is unreadable or whose library entry can't be
  removed is kept. Remove is offered only once the plugin is off in this
  workspace and asks a named confirmation (`PluginsSurfaceConfirmation`).
- **Accounts.** A plugin-created account is in scope only through a binding:
  after Turn off, Remove or a dropped component it stays, unbound and out of
  every run, until it is bound again or deleted. Add account, Make default
  and Delete account (confirmed, naming the workspaces that use it; the only
  path that clears its credentials: `PluginOperations.deleteAccount`
  records them in the connector cleanup outbox before the save) are on the
  row. Make default sets the workspace's one default for the service,
  across plugins.
- **`PluginRow`.** The surface builds each row once from the package, the
  activation and the display state; Expand, Add, Update, Turn off, Remove,
  settings and accounts all take it. Turn off asks nothing. Plugin skill
  settings are edited on the expanded row (secret ones with
  `SecretEntryField`, into the Keychain).
- **Still rows:** plugin templates (workspace rows owned by the plugin).
  R3 keeps them in step with the definition (`PluginTemplateSync`: the row
  stamped with the plugin and component is rewritten on Update, a new one
  is added, a dropped one stays as the person's), so installed content is
  never stale after Update. A sync never overwrites an edit: the activation
  records each template row's content digest as the sync wrote it
  (`PluginActivation.templateDigests`, seeded by the migration for rows that
  still match the definition), and a stamped row whose content no longer
  has that digest, or that has no digest and differs from the definition,
  is unstamped and kept as the person's own row before the definition's
  template is written as a new row. Moving templates into the projection (an
  edited template becoming an authored override, schedules rebound to
  projected template IDs, requirement 8) is not part of R1-R5; until a
  phase takes it, the "It also emits the plugin's templates" line under
  Runtime describes the target, not what ships.

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
| Removal of inactive plugins | Remove is offered for a plugin that is off in this workspace, whether or not it is on elsewhere or was ever on (R3 offers it only once the plugin is off here, since it reaches every workspace) |
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

*(verified: `Astra/Resources/Capabilities/*.json`, 10 packages; corrected
2026-10-16 from 12, which counted the `assets` folder and `README.md`.)*

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
  "worksOn": { "claude_code": "full", "codex_cli": "full", "copilot_cli": "full",
               "cursor_cli": "shell-only", "opencode_cli": "shell-only",
               "antigravity_cli": "shell-only" },
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

`worksOn` is keyed by `AgentRuntimeID` raw values (`claude_code`,
`codex_cli`, `copilot_cli`, `cursor_cli`, `opencode_cli`,
`antigravity_cli`); a display name is not a key. A manifest also carries
the install blockers a package has today (`minAppVersion`, `requires`,
`conflicts`), which Add checks as before.

Every `credentialForm` field declares where its value goes: `secret` (the
Keychain, under the account), `account.baseURL`, `account.alias`, or
`account.config` (a non-secret per-account setting). The validator rejects
a form with a field that declares none, so no value is ever classified by
its name, and a token can never land in SwiftData. A declared destination
is not trusted on its own either: `account.config` is plain text and goes
into the workspace mirror, and the key is the package's choice, so a name
heuristic alone can't keep a token out. Plain storage is therefore decided by
who wrote the definition, not by the field's name: a field stays
`account.config` only when ASTRA's bundled definition for the same plugin ID
declares it on the same connector component and its key matches nothing the
Keychain treats as a credential. Every field of any other plugin (an
imported file, a plugin source, one made in ASTRA) is stored as a `secret`,
whatever it declares: it goes to the Keychain, the form masks it, and the
mirror never writes it. *(As built, a connector declares its fields as
`credentialHints`, which go to the Keychain, and `configHints`, plain
settings; `PluginConnectorFieldTrust` owns the decision and is applied by
account creation, Update's account sync, setup copy, the install sheet and
the runtime copy. A plain value an older row still holds keeps reaching the
run and moves to the Keychain the next time Add saves the account.
`CapabilityPackageValidator` still refuses a bundled definition that names a
setting like a credential, "Credential stored as a setting".)*

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
  `unsupported` for the three runtimes without MCP delivery, since nothing
  in it reaches them; `shell-only` is reserved for a plugin with at least
  one skill or tool the shell relay can use. The UI shows it before the
  user adds the plugin. *(As built in R5: `PluginManifestConverter.defaultWorksOn`
  gives `unsupported` on those runtimes to a plugin with MCP servers and no
  skill, account or tool, and `shell-only` otherwise; the review sheet a
  plugin file or a source plugin goes through shows the result before
  import.)*
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
  launch*. The broker's refusal stays as the last line. *(As built in R1
  and R3: a workspace has at most one stored default account per service,
  held only in `AccountBinding.isDefault`: the first account bound becomes
  the default, Make default moves it, and removing a binding promotes the
  oldest remaining one. Turning a plugin off keeps its bindings, default
  included, so turning it back on restores the default.
  `PluginRuntimeProjection` derives the projected default per service: the
  projected account a binding marks default, else the oldest projected
  binding (by creation time, then ID), so turning off the default's plugin
  never leaves the other plugins' accounts without one. The launch marks
  those accounts `isDefault` in `ASTRA_CONNECTORS` (an optional field, absent
  otherwise). A brokered call that names no alias uses the one account of
  that service marked default; a named alias, name or ID always wins. With
  more than one marked default, or only accounts enabled outside a plugin
  (which carry no mark), the broker still refuses and lists the aliases.
  Choosing the account from an alias in the task text, and asking before
  launch, are the resolver's and are not built in R1-R5.)*
- **Alias is required and visible** as soon as a service has two accounts,
  which is the broker's rule promoted to the UI. Aliases are unique per
  normalized service among the accounts a workspace can see, so a name
  always selects one account: `WorkspaceCapabilityActivation.bind` renames
  a colliding account " 2", " 3" when it joins a workspace (sharing
  included), and a new account takes `uniqueAlias`.

This needs a new schema version (account is a new entity; today it is the
`Connector` row). Follow the repository rule: add `Vn+1`, never edit a shipped
version.

## Install and enable flow

Target: three user steps, matching Cowork and Codex.

1. **Find.** Search by name, summary and component contents (`bigquery` finds
   Google Cloud because `bq` is one of its tools). Sources: built-ins plus any
   git source the user added.
2. **Add.** One review sheet shows the components, what each one will be able
   to do, and `worksOn` for the user's runtimes. One confirmation, in this
   order (`CapabilityCatalogActionService.add`):
   - runs `CapabilityCatalogPolicy.decision` and the install blockers, and
     stops with their reasons if they refuse;
   - writes the approval record automatically (digest kept; it still catches
     tampering) with `approvedBy: "user"`;
   - installs once into the library and turns the plugin on in the
     workspace it was added from (`CapabilityInstaller.install`, then
     `enable`); other workspaces turn it on from the expanded row;
   - only then runs `check` on every component and sorts them into ready /
     needs setup: a check runs only for an approved digest whose decision
     is `canRun` (see Manifest, Rules), so it never runs before the
     approval exists.
3. **Connect, lazily.** `connect` legs are never run on add. The plugin row
   shows "N steps pending"; the user runs them when they want, or the first
   task that needs the component triggers the existing first-use gate
   (`AgentRuntimeLaunchPreflight.swift:486`, *verified*).

So adding a plugin for the current workspace stays three steps: Find, Add
(which turns it on here), Connect. Enabling it in another workspace is a
switch in the plugin's expanded row
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
  never gates it, and its health refreshes only the Plugins UI, without
  blocking; as built, preflight considers only the launch's scoped
  connectors, `ConnectorPreflightService.connectorsRequiringPreflight`),
  and the plugin's own failure signatures, declared in the manifest
  (`"authFailurePatterns": ["not logged in", "expired"]`). Patterns are
  matched only against a structured failure of the implicated component: a
  failed tool result of a command that starts the component's own
  executable, or the broker's structured auth failure for a connector.
  They are never matched against arbitrary agent text, so a report that
  mentions an expired certificate does not pause a run. *(As built,
  `CLISessionExpiryClassifier` applies this rule to built-in patterns for
  Google Cloud and GitHub; manifest-declared patterns are not read.)*
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
- `repairAction` becomes a typed reference, so a view can render it. It
  names the plugin ID and component ID (component IDs are unique only
  within a plugin) and the strategy, and for a connector the account ID,
  so a workspace with two accounts of a service repairs the one that
  failed. *(As built, `RepairAction` carries the strategy, a display name
  and the CLI's sign-in and check commands, no IDs: the built-in families
  are CLI sessions, one per tool (Open question 2), so no account applies.
  Connector repair, and with it the plugin and account IDs, waits for
  connector `verify` and is not scheduled in R1-R5.)*

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
- `Remove` reaches every workspace, so it is offered only once the plugin
  is off in this workspace, and it asks a named confirmation in place
  before acting (`PluginsSurfaceConfirmation.remove`): the plugin turns off
  in every workspace and its settings and secret settings there are
  deleted; its accounts and their credentials stay, listed under Accounts,
  and only `Delete account` (its own named confirmation, listing the
  workspaces that use the account) clears them. Turn off deletes nothing
  and asks nothing.
- A connector component expanded shows an `Accounts` sub-list
  (`Stanford · API token · 3 workspaces`) and `Add account`.
- Accounts no plugin row shows (kept by Remove, or released by an Update
  that dropped their component) are listed in their own group, "Accounts
  not used by a plugin", built from the durable account rows rather than
  any manifest, each with Edit and `Delete account` (the same named
  confirmation), so a retained credential always has a way to be cleared
  (`PluginsSurfacePresentation.unusedAccounts`, `PluginAccountsSection`).
- Brand marks via `BrandMark` as in the rail.
- The composer turns today's per-turn word matching into a suggestion ("This
  task mentions Jira; the Jira plugin is off in this workspace. Turn on")
  instead of a silent scope decision.
- Presentation copy and ordering live in a presentation type with a focused
  test, per the design system's implementation guidance.

## Sources

- The ten built-ins become the default source, read from the app bundle as
  today, but the on-disk copy stops winning over the compiled one for content
  (`CapabilityLibrary.swift:481-530`, *static read*).
- `Add source` takes a git URL or `owner/repo`. A source is a repository with
  a marketplace file listing plugin entries (`name`, `source`, `description`),
  modelled on Claude Code's `.claude-plugin/marketplace.json` so one file can
  serve both.
- Updates: check per source on demand; detect local edits and warn before
  overwriting, as Cowork does. *(As built in R3: a skill or tool the person
  edits becomes an authored row that overrides the component, so an Update
  never overwrites it. Plugin templates are still workspace rows, and the
  row's Update rewrites a stamped template to the definition, edits
  included; the automatic launch pass never does. Warning before that
  overwrite is not built; it is a requirement for the change that moves
  templates to the projection, where an edited template becomes an
  authored override like a skill.)* The startup
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
| Workspace mirror | `.astra-workspace.json` keeps, per plugin, its id, the source it came from and the digest that was approved, plus account aliases; on import a plugin is enabled only when the installed one has the same source and digest, as `WorkspacePackageImportCoordinator` already validates against the installed library. *(As built in R1 and R3: the mirror keeps each plugin's id and version and its activation whole (migration requirement 12): settings, overrides, `knownComponentIDs`, `secretSettingKeys`, and each account binding with its component and `isDefault` (`PluginAccountRef`), so recovery keeps the workspace's default account per service. Each activation also carries the approval digest the workspace accepted (`InstalledPluginRef.digest`). A chosen file's activation whose digest is missing or differs from the installed copy's comes in off, with none of its settings, overrides or account bindings, and is reported as changed (`CapabilityImportVerifier.installedDigests`). The digest covers the content, so it also pins the source: provenance is itself keyed by content digest (R5), and two copies with one digest are the same bytes.)* | the verbatim copy of enablement arrays and origin stamps (`WorkspaceConfigManager.swift:2056`, *verified*) |

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
| 3 | Built-ins migrated to the manifest; git sources; startup repair retired; `worksOn` shown at add | all ten built-ins add in one step on a fresh dev store *(corrected from twelve, which counted assets)* |
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
  *(Superseded by R1: a default always exists per workspace and service;
  see Cardinality.)*
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
  so the health view never prints a token. Phase 2 is complete for those
  CLI families only: Jira, REDCap and other connector components, and any
  manifest-declared `authFailurePatterns`, are not classified, so their
  expiry still fails the run (see the redesign's Health and repair).
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
  is not built. *(Superseded by R3: Update is offered when the recorded
  version, digest or component list differs from the library, or the
  plugin's templates drifted (`PluginUpdateService.needsReconcile`), so
  same-version content changes are caught too; for source plugins, T7 in
  the threat model shows an equal version with a different digest as
  changed. Local edits: see Sources.)*
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
   *(Settled by migration requirement 12: the mirror carries activations
   whole, each binding's default included.)*
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
