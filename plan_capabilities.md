# Capabilities Architecture Plan

This plan turns ASTRA's current skills/connectors/tools structure into a user-facing Capabilities system. The goal is to make capabilities installable at the app-user level, enable them per workspace, support a future curated Stanford capabilities server, and simplify capability creation so users build one coherent capability instead of manually wiring separate skills, connectors, and tools.

## Status

- Branch: `codex/capabilities-architecture`
- Current mode: implementation
- Implementation status: shared skills/connectors/tools, app-local capability library, capability installer, catalog-source abstraction, capability wizard, CLI detection helpers, and duplication-based demotion implemented
- Primary objective: introduce a capability-centered architecture without breaking existing workspace skills, connectors, tools, tasks, schedules, or exports.

## Decisions So Far

- `Capability` should become the user-facing concept.
- `Skill`, `Connector`, `LocalTool`, and `TaskTemplate` should become internal capability elements.
- Capabilities should install locally to the ASTRA app user, not directly into a workspace.
- Workspaces should enable or disable installed capabilities by ID.
- Workspace export should include enough snapshots to recover enabled capabilities even if the local app capability library is missing.
- Sharing should become a first-class workflow, not a checkbox hidden deep inside an editor.
- Capability creation should be a guided flow:
  1. Select or detect local tools.
  2. Select or create connectors.
  3. Define behavior and safety instructions.
  4. Choose scope.
  5. Validate setup.
- A future remote Capabilities server should fit naturally as a catalog source that installs approved capability packages into the local app capability library.

## Current Findings To Fix

### P1: Global Connectors Do Not Round-Trip Through Workspace Export

File: `Astra/Services/WorkspaceConfigManager.swift`

Workspace export persists `enabledGlobalConnectorIDs`, but exported connector definitions only include `workspace.connectors` and connectors attached to exported skills. A standalone shared connector enabled in a workspace can be lost on import or recovery.

Fix direction:

- Export definitions for enabled shared connectors.
- Import enabled shared connector definitions into the app-level shared library or workspace recovery path.
- Add tests for standalone shared connector export/import.

### P2: Connector Sharing Detaches Without Enabling Current Workspace

File: `Astra/Views/ConnectorsManagerView.swift`

Toggling a connector to shared sets `connector.workspace = nil`, but does not append the connector ID to `workspace.enabledGlobalConnectorIDs`. The connector can disappear from the workspace where it was created.

Fix direction:

- Promote to shared as an atomic action:
  - set `isGlobal = true`
  - detach from workspace ownership
  - add ID to current workspace enabled IDs
  - save and auto-export
- Demotion needs a deliberate policy: either convert to current-workspace local, or leave installed but disabled.

### P2: Standalone Shared Tools Are Modeled But Not Implemented

File: `Astra/Models/LocalTool.swift`

`LocalTool.isGlobal` existed, and import/export had partial support, but `Workspace` had no `enabledGlobalToolIDs`, and `AgentTask.allLocalTools` did not resolve standalone global tools.

Fix direction:

- [x] Add `enabledGlobalToolIDs` to `Workspace`.
- [x] Resolve enabled global tools in task execution.
- [x] Add shared tool UI in Configure and right rail.
- [x] Add export/import coverage.

### P2: Configure Connectors Only Shows Local Connectors

File: `Astra/Views/ConfigureView.swift`

The Configure connectors tab only reads `workspace.connectors`. Shared connectors are only visible in the right rail toggle path, so the main configuration area cannot browse or edit the shared connector library.

Fix direction:

- Show sections for:
  - Workspace Connectors
  - Shared Library
  - Available Shared Connectors
- Allow enable/disable directly from Configure.
- Allow editing shared connector definitions from the shared section.

### P3: Composer Skill Picker Ignores Enabled Global Skills

File: `Astra/Views/Components/ComposerToolbar.swift`

The composer plus menu builds its skill submenu from `workspace.skills` only. Enabled global skills may be active by default, but once removed from a task they cannot be re-added from this menu.

Fix direction:

- Pass resolved available skills into `ComposerToolbar`, or teach it to use a shared workspace capability resolver.
- Include enabled global skills in the skill menu.
- Keep built-in filtering consistent across composer, chat panel, schedules, and Configure.

## Target Concepts

### Capability

A capability is the user-facing bundle ASTRA installs, enables, configures, validates, and presents.

A capability may include any subset of:

- Behavior profile: currently represented by `Skill`
- Local tools: currently represented by `LocalTool`
- Connectors: currently represented by `Connector`
- Templates or workflows: currently represented by `TaskTemplate`
- Setup requirements: currently represented by plugin prerequisites
- Validation checks: CLI availability, connector test, secret presence, config presence
- Metadata: source, version, author, trust, category, tags

Examples:

- `Read-Only Reviewer`: behavior only
- `BigQuery Analyst`: behavior plus `bq` and `gcloud` tools
- `Jira`: connector only or connector plus behavior
- `REDCap Data QA`: connector plus secrets, tools, behavior, and templates
- `GitHub Workflow`: tools plus behavior and preflight checks

### Capability Library

The capability library is installed locally to the app user, not to an individual workspace.

Approved built-in capability definitions are maintained in the repo at:

```text
Astra/Resources/Capabilities
```

Each file is a `PluginPackage` v2 JSON capability package. Connector definitions that belong to a capability live inside that capability JSON, keeping the user-facing catalog capability-first while still making connectors easy to review and maintain in source control.

Development channel:

```text
~/Library/Application Support/AstraDev/Capabilities
```

Production channel:

```text
~/Library/Application Support/Astra/Capabilities
```

This follows the repo's app-channel isolation rules and avoids mixing dev experiments with production data.

### Workspace Enablement

Each workspace should store enablement and workspace-specific overrides:

- enabled capability IDs
- enabled standalone shared skill IDs during migration
- enabled standalone shared connector IDs during migration
- enabled standalone shared tool IDs during migration
- per-workspace config values
- per-workspace secret references
- task and schedule snapshots for recovery

The workspace should not be the primary install location for reusable capabilities.

### Catalog Sources

Catalogs should become sources for capability packages.

Initial sources:

- built-in packages bundled from `Astra/Resources/Capabilities`
- local app capability library

Future source:

- remote Stanford-approved Capabilities server

Expected flow:

```text
Repo bundle or remote catalog -> app-local Capabilities folder -> workspace enablement -> task execution
```

## Target File And Module Direction

The exact file names can change during implementation, but this is the intended structure.

```text
Astra/Models/Capability.swift
Astra/Models/CapabilityElement.swift
Astra/Models/CapabilityInstallation.swift
Astra/Services/CapabilityLibrary.swift
Astra/Services/CapabilityResolver.swift
Astra/Services/CapabilityInstaller.swift
Astra/Services/CapabilityValidator.swift
Astra/Services/CapabilityCatalogSource.swift
Astra/Views/CapabilitiesView.swift
Astra/Views/CapabilityEditorView.swift
Astra/Views/CapabilityCreationWizardView.swift
Tests/CapabilityResolverTests.swift
Tests/CapabilityPersistenceTests.swift
Tests/CapabilityInstallerTests.swift
Tests/CapabilityValidationTests.swift
```

Short-term implementation can avoid a full new model if needed by first introducing `WorkspaceCapabilities` as a resolver over the existing models.

## Implementation Strategy

Implement in layers. The first layer should remove inconsistency without forcing a full data-model rewrite. Later layers can introduce formal capability models and the app-local library.

## Phase 0: Baseline And Safety

Goal: capture the current behavior and prevent regressions while refactoring.

Checklist:

- [x] Confirm branch is `codex/capabilities-architecture`.
- [x] Run targeted baseline tests: `swift test --filter WorkspacePersistenceTests`.
- [x] Run targeted baseline tests: `swift test --filter SkillTests`.
- [x] Run targeted baseline tests: `swift test --filter PluginCatalogTests`.
- [x] Run targeted baseline tests: `swift test --filter PluginShareabilityTests`.
- [x] Record any existing failures before making implementation changes.
- [x] Review dev/prod App Support paths from `AppChannel` before adding capability storage.

## Phase 1: Shared Workspace Capability Resolver

Goal: introduce one source of truth for active, enabled shared, and available shared resources.

Create a resolver, likely named `WorkspaceCapabilities`, `WorkspaceCapabilitySummary`, or `CapabilityResolver`.

It should compute:

- local workspace skills
- enabled shared skills
- available shared skills
- local workspace connectors
- enabled shared connectors
- available shared connectors
- local workspace tools
- enabled shared tools once implemented
- available shared tools once implemented
- active skill count
- active connector count
- active tool count
- task-ready resolved skills/connectors/tools

Checklist:

- [x] Add a resolver over existing `Workspace`, global `Skill`, global `Connector`, and eventually global `LocalTool`.
- [x] Keep built-in skill filtering consistent in one place.
- [x] Deduplicate resources by stable ID.
- [x] Replace duplicated skill count logic in `ConfigureView`.
- [x] Replace duplicated skill/connector logic in `WorkspaceRightRailView`.
- [x] Replace ad hoc available skill logic in `ChatPanelView`.
- [x] Replace ad hoc skill picker logic in `ComposerToolbar`.
- [x] Add tests for local plus enabled shared resource resolution.
- [x] Add tests for dedupe behavior.
- [x] Add tests for built-in filtering.

Acceptance criteria:

- Configure, right rail, composer, schedule editor, and task creation agree on which resources are active.
- Counts do not diverge between surfaces.
- Enabled shared skills can be removed and re-added from the composer.

## Phase 2: Fix Shared Connector Semantics

Goal: make connector sharing visible, reversible, and safe.

Checklist:

- [x] Change connector promotion to shared into an atomic action.
- [x] When a current workspace connector is promoted to shared, append its ID to `workspace.enabledGlobalConnectorIDs`.
- [x] Save and auto-export after connector sharing changes.
- [x] Decide and implement demotion behavior. Decision: do not convert a shared library definition back into a workspace-local item; duplicate it into the workspace and disable the shared item there.
- [x] Add a shared connector section to Configure connectors.
- [x] Allow enable/disable of shared connectors from Configure.
- [x] Keep right rail connector toggles but make them use the shared resolver.
- [x] Add visual labels for `Workspace`, `Shared`, and `Enabled here`.
- [x] Add tests for promoting a workspace connector to shared.
- [x] Add tests for enabling/disabling a shared connector in a workspace.

Acceptance criteria:

- A connector does not disappear from the current workspace after being shared.
- Shared connectors are discoverable in Configure, not only in the right rail.
- Runtime `AgentTask.allConnectors` includes enabled shared connectors.

## Phase 3: Fix Export And Recovery For Shared Connectors

Goal: workspace configs can recover enabled shared connectors even when the local app library is missing or stale.

Checklist:

- [x] Update `WorkspaceConfigManager.export` to include enabled shared connector definitions.
- [x] Preserve secret redaction: export credential keys, never credential values.
- [x] Import shared connector definitions as shared definitions when appropriate.
- [x] Ensure enabled shared connector IDs are restored on import.
- [x] Avoid duplicate shared connectors by ID first, then by safe fallback identity.
- [x] Add tests for standalone shared connector round-trip.
- [x] Add tests for redacted shared connector secrets in export JSON.
- [x] Add recovery tests where a workspace config references a shared connector not already in SwiftData.

Acceptance criteria:

- Workspace export/import preserves enabled shared connector availability.
- No plaintext secrets are written to workspace config.
- Import does not create duplicate shared connectors when an exact shared connector already exists.

## Phase 4: Implement Shared Tools Fully

Goal: make `LocalTool.isGlobal` real instead of partial.

Checklist:

- [x] Add `enabledGlobalToolIDs` to `Workspace`.
- [x] Add schema migration support if required by SwiftData migration plan. Decision: additive defaulted fields use SwiftData lightweight migration; workspace JSON export remains the recovery fallback.
- [x] Add global tool queries where shared tools need to be shown.
- [x] Update task resolution to include enabled shared standalone tools.
- [x] Update prompt/tool permission generation so enabled shared CLI/script/MCP tools are available to tasks.
- [x] Add shared tools to Configure tools.
- [x] Add shared tools to right rail tools section.
- [x] Add promotion/demotion behavior for tools.
- [x] Add export/import support for enabled shared tool definitions.
- [x] Add tests for enabled shared tool resolution.
- [x] Add tests for export/import of enabled shared tools.

Acceptance criteria:

- A standalone shared tool can be enabled in a workspace and used by a task.
- Shared tools are visible and manageable in the UI.
- Export/import preserves enabled shared tool definitions.

## Phase 5: Introduce App-Local Capabilities Folder

Goal: create the install location and file format for capabilities independent of workspaces.

Checklist:

- [x] Add an `AppChannel`-aware capabilities directory.
- [x] Add repo-maintained approved capability JSON folder at `Astra/Resources/Capabilities`.
- [x] Bundle the approved capability JSON folder as a SwiftPM resource.
- [x] Use development path: `~/Library/Application Support/AstraDev/Capabilities`.
- [x] Use production path: `~/Library/Application Support/Astra/Capabilities`.
- [x] Define capability package JSON format using the existing `PluginPackage` v2 schema as the compatibility capability package format.
- [x] Include metadata currently available in `PluginPackage`: ID, name, version, author, trust, category, tags.
- [x] Add explicit source metadata.
- [x] Include elements: behavior, connectors, local tools, templates, prerequisites.
- [x] Include setup requirements and validation hints.
- [x] Add read/write service for the local capability library.
- [x] Sync bundled approved capabilities into the app-local library and remove stale built-in packages when repo JSON files are removed.
- [x] Add tests that dev and production capability folders are separate.
- [x] Add tests that bundled approved capabilities load from the repo resource folder.
- [x] Add tests for decoding older plugin packages during migration.

Acceptance criteria:

- ASTRA can list installed local capabilities from the app support folder.
- ASTRA can seed approved capabilities from repo-maintained JSON resources.
- Dev builds do not read or write production capability data.
- Existing plugin packages can still load or migrate.

## Phase 6: Capability Installer And Catalog Migration

Goal: move catalog installation from workspace-local copies toward app-local capabilities plus workspace enablement.

Checklist:

- [x] Introduce a `CapabilityInstaller` service.
- [x] Install catalog packages into the app-local capability library.
- [x] Enable installed capability in the current workspace after install.
- [x] Preserve current plugin catalog behavior behind compatibility paths while migrating.
- [x] Track installed capability versions app-wide through installed package files.
- [x] Track per-workspace enabled capability IDs.
- [x] Add capability update detection.
- [x] Keep prerequisite checks before or during install.
- [x] Add tests for install once, enable in multiple workspaces.
- [x] Add tests for updating a capability without duplicating workspace resources.

Acceptance criteria:

- Installing a capability once makes it available to all workspaces.
- Workspaces can enable or disable that capability independently.
- Existing catalog packages remain usable during migration.

## Phase 7: Capability Creation Wizard

Goal: replace manual wiring with a guided capability creation flow.

Wizard steps:

1. Tools
   - detect local CLIs
   - select known tools such as `bq`, `gcloud`, `gh`, `docker`
   - add script or MCP tool

2. Connectors
   - select existing connector
   - create connector inline
   - configure secrets and non-secret settings
   - test connector

3. Behavior
   - name capability
   - describe intended use
   - define behavior instructions
   - configure allowed and disallowed tools
   - add examples or guardrails

4. Scope
   - current workspace only
   - shared across all workspaces
   - installed but disabled

5. Validate
   - verify required CLIs
   - verify connector credentials
   - check required config fields
   - preview effective task prompt inputs

Checklist:

- [x] Design the wizard data model.
- [x] Build the tool selection step.
- [x] Add CLI detection helpers.
- [x] Build the connector selection/creation step.
- [x] Build the behavior step using existing skill fields.
- [x] Build the scope step.
- [x] Build the validation step.
- [x] Create capabilities from wizard output.
- [x] Add tests for partial capabilities: behavior-only, connector-only, tool-only, full bundle.
- [x] Add UI tests or screenshot checks for the wizard if feasible. Decision: no SwiftUI screenshot harness exists in this SwiftPM app yet; the wizard output is covered with factory, detector, and installer tests.

Acceptance criteria:

- A user can create a useful capability without manually visiting separate Skills, Connectors, and Tools screens.
- All wizard phases are optional except name/scope.
- The created capability is immediately usable in the selected workspace.

## Phase 8: UI Reframing

Goal: make Capabilities the primary user-facing navigation concept.

Checklist:

- [x] Rename or supplement "Skills", "Connectors", and "Tools" surfaces with a top-level "Capabilities" area.
- [x] Keep advanced element editors available for power users.
- [x] Add capability cards with status: installed and enabled here. Setup/prerequisite status remains in the catalog sheet.
- [x] Add visible share controls at the card/list level.
- [x] Add "Enable in this workspace" and "Disable in this workspace" actions.
- [x] Add "Edit shared definition" action.
- [x] Add "Duplicate for this workspace" action if demotion/copying is needed.
- [x] Make right rail a concise status and toggle surface.
- [x] Keep Configure as the full management surface.
- [x] Remove or reduce duplicate count logic.

Acceptance criteria:

- Users can discover sharing without opening a detail editor.
- The path from install to enable to validate is obvious.
- Configure and right rail show consistent counts and statuses.

## Phase 9: Future Capabilities Server Readiness

Goal: prepare the local architecture for a remote curated catalog without implementing the server yet.

Checklist:

- [x] Define a `CapabilityCatalogSource` protocol or equivalent abstraction.
- [x] Support source metadata on installed capabilities.
- [x] Support trust metadata: built-in, local, remote-approved.
- [x] Support signed package metadata or leave a clear extension point.
- [x] Add source URL and last refreshed timestamp fields.
- [x] Keep install path independent of source.
- [x] Add tests for multiple catalog sources returning capability packages.
- [x] Document how a Stanford-approved catalog would plug in later.

Acceptance criteria:

- A future remote server can be added as a catalog source without changing workspace enablement or task resolution.
- Trust/source is visible in the model and can be surfaced in UI later.

### Stanford-Approved Catalog Extension Point

The future Stanford-approved capabilities server should plug in as another `CapabilityCatalogSource`.

Expected shape:

1. The server returns signed or approval-stamped `PluginPackage`/capability package JSON using the same package format used by built-in and local packages.
2. ASTRA adds a `RemoteCapabilityCatalogSource` that fetches packages, annotates them with `CapabilitySourceMetadata` using `trust = remoteApproved`, `sourceURL`, and `lastRefreshedAt`, then returns them through the same catalog interface.
3. Installation remains unchanged: `CapabilityInstaller` writes the selected package into the app-local `Capabilities` folder and enables it per workspace.
4. Workspace runtime remains unchanged: tasks and schedules resolve active skills/connectors/tools through `WorkspaceCapabilities`.
5. Workspace export remains recoverable because enabled shared definitions are snapshotted into the workspace config without secret values.

## Data Model Migration Notes

Potential new fields:

- `Workspace.enabledCapabilityIDs`
- `Workspace.enabledGlobalToolIDs`
- `Capability.id`
- `Capability.name`
- `Capability.version`
- `Capability.source`
- `Capability.trustLevel`
- `Capability.skillIDs` or embedded behavior config
- `Capability.connectorIDs` or embedded connector requirements
- `Capability.localToolIDs` or embedded tool requirements
- `Capability.templateIDs`

Compatibility requirements:

- Existing workspace-local skills must continue to work.
- Existing global skills must continue to work.
- Existing global connectors must be migrated or resolved.
- Existing local tools must continue to work.
- Existing workspace exports must still decode.
- Existing plugin package JSON must still decode.
- Secret values must remain in Keychain and never move into JSON exports.

Migration strategy:

- Start with resolver-based compatibility.
- Add new fields with defaults.
- Keep old enabled global ID lists during transition.
- Add capability IDs only when installing or creating new capabilities.
- Export both capability snapshots and legacy skill/connector/tool snapshots until compatibility is no longer needed.

## Testing Plan

Run narrow tests after each phase, then broaden when shared behavior changes.

Targeted tests:

```bash
swift test --filter WorkspacePersistenceTests
swift test --filter SkillTests
swift test --filter PluginCatalogTests
swift test --filter PluginShareabilityTests
swift test --filter SkillResolverTests
swift test --filter TaskSchedulerTests
```

New tests to add:

- `CapabilityResolverTests`
- `CapabilityPersistenceTests`
- `CapabilityInstallerTests`
- `CapabilityValidationTests`

Manual validation:

```bash
./script/build_and_run.sh --verify
git diff --check
```

Full validation before PR:

```bash
swift test
./script/build_and_run.sh --verify
git diff --check
```

## Risk Register

- [x] SwiftData migrations can be fragile if new model fields are introduced too early. Mitigation: additive defaulted workspace fields only; workspace JSON remains the recovery path.
- [x] Shared connector secrets may imply cross-workspace credential reuse; the UI must make this explicit. Mitigation: shared connector editor now separates shared definition from per-workspace enablement and duplication.
- [x] Workspace export must not leak secrets while still preserving recoverability. Mitigation: exports include credential keys only, never credential values.
- [x] Built-in skills are currently special-cased by name; capability migration should avoid increasing name-based behavior. Mitigation: new runtime resolution uses IDs through `WorkspaceCapabilities`; name fallback remains only for legacy import/update compatibility.
- [x] Catalog install and workspace import can create duplicates if ID and name fallback rules are unclear. Mitigation: import/install reuse by ID first, then conservative fallback identity.
- [x] Prompt/tool permission resolution must stay deterministic after adding shared tools and capabilities. Mitigation: resolver deduplicates and sorts active skills, connectors, and tools.
- [x] UI renaming from skills/connectors/tools to capabilities can be confusing if advanced users lose access to the underlying elements. Mitigation: Capabilities is added as a top-level surface while Skills, Connectors, Tools, and Templates remain available.

## Open Questions

- [x] Should demoting a shared connector/tool create a workspace-local copy, or simply disable it in the current workspace? Decision: use "Duplicate for this workspace"; the shared definition remains installed and is disabled in the current workspace.
- [x] Should secrets on shared connectors be shared across all workspaces by default, or should each workspace provide its own secret values? Decision: shared definitions carry credential key names; secret values remain in Keychain and are never exported.
- [x] Should capability packages embed element definitions directly, or reference app-library element IDs after installation? Decision: packages embed definitions; installation materializes reusable global elements and stores workspace enablement IDs.
- [x] Should templates become first-class capability elements immediately, or remain workspace-local until the core capability model stabilizes? Decision: keep templates workspace-local in this implementation while the resolver-based compatibility model stabilizes.
- [x] What trust states should the UI show before the Stanford-approved server exists? Decision: support built-in, local library, and remote-approved metadata now; only built-in/local are populated until a remote source exists.

## Master Progress Checklist

### Architecture

- [x] Define final vocabulary: Capability, element, library, catalog, enablement, validation.
- [x] Add shared resolver over existing resources.
- [x] Decide short-term compatibility model.
- [x] Decide long-term capability model.
- [x] Document capability JSON shape.

### Persistence

- [x] Fix shared connector export.
- [x] Fix shared connector import/recovery.
- [x] Add shared tool enablement persistence.
- [x] Add app-local capabilities folder.
- [x] Add channel-isolated capability paths.
- [x] Preserve old workspace config compatibility.

### Runtime

- [x] Resolve enabled shared skills consistently.
- [x] Resolve enabled shared connectors consistently.
- [x] Resolve enabled shared tools consistently.
- [x] Ensure tasks receive correct environment variables.
- [x] Ensure allowed tools include required CLI/script/MCP tools.
- [x] Ensure schedules can attach enabled shared skills/capabilities.

### UI

- [x] Make sharing visible in Configure.
- [x] Add shared connector library UI.
- [x] Add shared tool library UI.
- [x] Fix composer skill picker.
- [x] Add capability install/enable status.
- [x] Add capability creation wizard.
- [x] Keep advanced editors available.

### Catalog

- [x] Store approved built-in capability packages in `Astra/Resources/Capabilities`.
- [x] Load built-in catalog packages from bundled repo JSON resources.
- [x] Sync stale built-in package removals from the repo folder into the app-local library.
- [x] Install capabilities app-locally.
- [x] Enable installed capability per workspace.
- [x] Preserve existing plugin package install compatibility.
- [x] Add app-wide installed version tracking.
- [x] Prepare remote catalog source abstraction.

### Validation

- [x] Add unit tests for resolver.
- [x] Add unit tests for shared connector export/import.
- [x] Add unit tests for shared tool runtime resolution.
- [x] Add unit tests for capability install and enablement.
- [x] Run targeted tests after each phase.
- [x] Run full tests before PR.
- [x] Run build verification before PR.

## Suggested First Implementation PR

Keep the first PR narrow and useful:

1. [x] Add a shared workspace capability resolver over the current models.
2. [x] Fix connector promotion to shared so it remains enabled in the current workspace.
3. [x] Include enabled shared connectors in export/import.
4. [x] Make Configure connectors show shared connectors.
5. [x] Fix composer skill picker to include enabled global skills.
6. [x] Add focused tests for those behaviors.

This gives immediate product value while creating the foundation for the larger capability model.
