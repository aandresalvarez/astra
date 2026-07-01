# ASTRA Packs Architecture

ASTRA Packs let teams shape ASTRA for a vertical without forking Core. A pack is
a declarative product profile: it can reference existing capability packages,
choose default native shelves, contribute App Studio template metadata, provide
vocabulary, and apply restrict-only policy. ASTRA Core remains the owner of
runtime execution, persisted workspace state, provider launch, credentials,
shelf implementations, and policy enforcement.

## Design Goals

- Keep one strong ASTRA Core that is shared by all verticals.
- Let vertical teams ship focused package/profile contributions instead of
  full product forks.
- Preserve least privilege: a pack can advertise or recommend resources, but it
  cannot silently grant runtime power.
- Keep pack behavior inspectable through JSON manifests, tests, and durable
  workspace state.

## Current Implementation Surface

This branch ships the first complete v1 pack path:

- `AstraPackManifest` in `ASTRACore` defines the JSON schema.
- `AstraPackCatalog` loads built-in packs from `Astra/Resources/Packs` and
  local packs from channel-specific ASTRA-managed storage.
- `AstraPackManifestValidator` rejects malformed manifests, unknown shelf
  references, duplicate IDs, and policy-widening attempts.
- `AstraPackComposition`, `AstraPackProfileResolver`, and
  `AstraPackPolicyResolver` compose multiple enabled packs into shelf,
  vocabulary, branding, and restrict-only policy state.
- `Workspace.enabledPackIDs` and `Workspace.shelfVisibilityOverrides` persist
  pack state and round-trip through `.astra-workspace.json`.
- `Workspace Settings > Packs` is the user-facing control surface for enabling,
  disabling, reloading, and inspecting packs.
- `WorkspaceAppTemplatePackCatalog` exposes pack App Studio templates only for
  packs enabled on the current workspace.

The bundled `astra.pack.devops` pack is the canonical example. It defaults the
Plan and Files shelves, contributes the PR / CI Review App Studio template
metadata, references `github-workflow`, and keeps `policyRestrictions` empty.

## Ownership Boundaries

Core owns:

- SwiftData models and persisted workspace state.
- Capability package governance, approval, enablement, and runtime projection.
- Native shelf descriptors, shelf implementations, and shelf availability.
- Provider prompts, launch manifests, credentials, tool allow-lists, browser
  adapters, MCP delivery, and runtime policy.
- App Studio manifest validation, dependency contracts, and generation repair.

Packs own:

- Pack identity, display name, version, and branding metadata.
- References to known capability package IDs.
- Default visibility for trusted native shelves.
- App Studio template metadata and provenance.
- Vocabulary overrides for product language.
- Restrict-only policy declarations.
- Documentation and example assets that help authors understand the vertical.

The pack boundary is intentionally narrow. Packs do not contain executable
Swift, SwiftUI, shell scripts, MCP servers, browser adapters, or provider code
in v1. If a vertical needs new runtime behavior, it should first become a
capability package or a Core-owned native extension with its own tests and
policy review; the pack can then reference it.

## Manifest Source Of Truth

Pack manifests decode as `AstraPackManifest` from
`ASTRACore/AstraPackManifest.swift`.

Current v1 fields:

| Field | Owner | Meaning |
| --- | --- | --- |
| `formatVersion` | Core | Manifest schema version. Must be `1`. |
| `id` | Pack | Stable lowercase pack ID, such as `astra.pack.devops`. |
| `name` | Pack | User-facing pack name. |
| `version` | Pack | Pack version string. |
| `coreAPIVersion` | Core | Core API compatibility. Must currently be `1.0`. |
| `description` | Pack | User-facing pack summary. |
| `capabilityPackageIDs` | Pack reference | Known capability package IDs the pack was designed around. |
| `shelfDefaults` | Pack profile | Native shelf IDs that should be visible by default when this pack is enabled. |
| `appTemplates` | Pack profile | App Studio template descriptors exposed only when the pack is enabled. |
| `policyRestrictions` | Pack policy | Restrict-only policy declarations. |
| `vocabulary` | Pack profile | Vertical wording overrides such as `PR Queue`. |
| `branding` | Pack profile | Accent color, SF Symbol, and display name. |

The manifest is loaded by `AstraPackCatalog`, validated by
`AstraPackManifestValidator`, resolved into workspace profile state by
`AstraPackProfileResolver`, and projected into App Studio template selection by
`WorkspaceAppTemplatePackCatalog`.

The pack inspector uses `WorkspacePackSettingsPresentation` to summarize each
catalog entry into source, version, shelves, templates, capability references,
and policy status. Missing enabled pack IDs remain visible in the settings UI so
the user can identify and disable stale workspace configuration.

## User Control Surface

Use the app UI when validating packs manually:

1. Open a workspace.
2. Open Workspace Settings.
3. Find the Packs section below General Instructions.
4. Use the toggle beside a pack to enable or disable it for that workspace.
5. Use the reload icon after adding or editing local pack manifests.

The Packs section shows:

- the enabled/available count
- each pack source, version, description, and icon
- shelf defaults
- App Studio templates
- capability package references
- policy restriction summary
- catalog diagnostics for malformed or unreadable packs

Toggling a pack writes `Workspace.enabledPackIDs`, updates the workspace
timestamp, and schedules the normal workspace auto-export path. It does not
enable runtime capabilities.

## Allowed Versus Enabled Resources

Packs distinguish three states:

- Referenced: the manifest names a capability package ID in
  `capabilityPackageIDs`, `shelfDefaults[].capabilityPackageIDs`, or
  `appTemplates[].capabilityPackageIDs`.
- Pack enabled: the workspace includes the pack ID in `Workspace.enabledPackIDs`;
  this can expose pack profile defaults and App Studio template choices.
- Capability enabled: the workspace includes a capability package ID in
  `Workspace.enabledCapabilityIDs`; only this path can make runtime resources
  eligible for task launch.

This distinction prevents packs from becoming a permission backdoor. The DevOps
pack references `github-workflow`, but enabling `astra.pack.devops` alone does
not expose the GitHub Agent, the `gh` CLI, browser adapters, MCP servers, or
credentials. Runtime resources still require explicit capability enablement and
the normal capability policy gates.

Local development note: in the development channel, local packs live under
`~/Library/Application Support/AstraDev/Packs`. In the production channel they
live under `~/Library/Application Support/Astra/Packs`. Put one pack manifest
JSON file per pack in that directory, then reload the Packs section.

## Shelf Model

Pack shelf defaults are profile preferences for ASTRA-owned native shelves.
They are not a plugin API.

V1 rules:

- A pack may default trusted Core shelves such as `plan` and `files` visible.
- A pack may hide other Core shelves by omission when it declares shelf
  defaults.
- Workspace and managed admin overrides can adjust shelf visibility through the
  normal override path.
- Unknown shelf IDs produce diagnostics and are not made presentable.
- Packs must not declare SwiftUI view types, module paths, bundle paths,
  plugins, or arbitrary shelf implementations.

This keeps ASTRA free to refactor shelf UI while preserving a stable pack
profile contract.

If a vertical needs a completely new shelf with new functionality, build it as a
Core-owned native shelf first. Follow
`docs/architecture/native-shelf-development.md`, then expose the trusted shelf
through `shelfDefaults` only after registry, availability, policy, and non-grant
tests pass.

## Policy Model

Packs may only restrict policy. They cannot widen Core, capability, runtime, or
workspace policy.

Valid policy effects:

- `restrict`

Invalid effects include:

- `allow`
- `grant`
- `enable`
- `elevate`

If a vertical needs broader access, the new access must be modeled in the
capability package or Core policy layer first, with review and tests. The pack
can then reference the approved capability.

## App Studio Template Boundary

Pack App Studio templates are metadata and untrusted provenance. They can name a
template, associate it with a pack, and show capability provenance. They do not
grant generated apps new contracts or bypass manifest validation.

The App Studio generator treats pack metadata as bounded untrusted data. A
template can suggest that an app was designed around `github-workflow`, but the
generated app must still declare explicit requirements, pass
`WorkspaceAppManifestValidator`, and run through the existing permission model.

The bundled DevOps `pr-ci-review-template.md` is an example asset and authoring
guide in v1. It is not currently loaded as executable generation logic.

## Canonical Example

`Astra/Resources/Packs/devops-pack.json` is the canonical v1 example.

It demonstrates:

- `id`: `astra.pack.devops`
- capability provenance: `github-workflow`
- shelf defaults: `plan`, `files`
- template contribution: `pr-ci-review`
- vocabulary: `PR Queue`, `CI Review`
- no policy widening: `policyRestrictions` is empty
- supporting assets under `Astra/Resources/Packs/devops/`

The important safety behavior is that a workspace can enable the DevOps pack for
layout, vocabulary, and templates without enabling GitHub runtime resources.

## Fork-To-Pack Migration

When a fork carries vertical-specific behavior, migrate it by classifying each
delta:

| Fork Delta | Pack Destination | If Not Supported |
| --- | --- | --- |
| Product wording | `vocabulary` | Add a Core vocabulary key first. |
| Accent/icon/display metadata | `branding` | Keep in fork until branding contract expands. |
| Default shelf visibility | `shelfDefaults` | Add a trusted Core shelf descriptor first. |
| Capability expectations | `capabilityPackageIDs` | Create or approve a capability package first. |
| App starter surface | `appTemplates` | Add a validated App Studio template contract first. |
| More restrictive policy | `policyRestrictions` with `restrict` | Add resolver support and tests first. |
| New runtime integration | Capability package | Do not put runtime code in the pack. |
| New native shelf UI | Core-owned shelf implementation | Do not load arbitrary SwiftUI from packs. |

The migration loop should be:

1. Identify the durable owner of the fork behavior.
2. Move behavior into Core or a capability package if it changes runtime power.
3. Reference that owner from the pack manifest.
4. Add catalog, resolver, and runtime non-grant regression tests.
5. Keep the pack manifest as composition data only.

## Validation Expectations

Every pack change should include a focused validation loop:

```bash
swift test --filter 'AstraPackCatalogTests|AstraPackManifestValidatorTests|AstraPackProfileTests|WorkspaceAppStudioTemplatePackTests|WorkspacePackSettingsPresentationTests|TaskCapabilityResolverTests'
git diff --check
```

Broaden validation when the pack touches shared behavior:

```bash
swift test --filter 'PluginCatalogTests|AstraPackPolicyTests|ShelfRegistryTests|TrustedShelfContributionTests|ArchitectureFitnessTests'
./script/build_and_run.sh --verify
./script/prepush.sh
```

Regression tests should prove:

- the manifest loads from bundled or local resources
- capability package IDs are known
- pack enablement and capability enablement stay separate
- shelf defaults resolve only to trusted native shelves
- policy restrictions cannot widen access
- App Studio template metadata remains provenance only
- the workspace settings presentation exposes enough detail for inspection and
  keeps missing enabled pack IDs visible for cleanup

## Architecture Invariants

- Core is the only runtime authority.
- Packs are declarative, validated, and inspectable.
- Pack enablement never implies capability enablement.
- Pack policy can only reduce permissions.
- Native shelf implementations are trusted Core code.
- App Studio still validates generated app manifests.
- A workspace with no enabled packs keeps existing ASTRA behavior.

## Continuing The Pack Platform

When adding a new vertical, keep the work in this order:

1. Define or reuse Core-owned capabilities, shelf descriptors, and App Studio
   template contracts.
2. Add a pack manifest that references those owners declaratively.
3. Add catalog, validator, profile, policy, template, and non-grant tests.
4. Verify the pack through Workspace Settings and App Studio in `ASTRA Dev`.
5. Only broaden Core APIs when the pack schema cannot express the behavior
   without executable code or hidden conditionals.

Do not add vertical-specific branches in runtime, task launch, permission, or
provider code. If a vertical needs more power, first model that power as a Core
capability or trusted native extension, then let the pack reference it.
