# ASTRA Pack Authoring

This guide is for ASTRA maintainers and future vertical teams authoring v1 pack
manifests. Packs customize product composition; they are not executable plugins.

Use `Astra/Resources/Packs/devops-pack.json` as the canonical bundled example.

## Authoring Checklist

Before writing JSON:

- Decide which behavior belongs in Core, a capability package, or the pack.
- Confirm every capability package ID already exists in `PluginCatalog`.
- Confirm every shelf ID is a trusted Core shelf.
- Confirm policy changes are restrictive only.
- Confirm App Studio template metadata is safe as untrusted provenance.

After writing JSON:

- Run the manifest through `AstraPackManifestValidator` via tests.
- Add or update catalog/profile/template/runtime non-grant tests.
- Run `git diff --check`.
- Run `./script/build_and_run.sh --verify` for bundled pack changes.

## Minimal Manifest

```json
{
  "formatVersion": 1,
  "id": "astra.pack.example",
  "name": "Example Pack",
  "version": "1.0.0",
  "coreAPIVersion": "1.0",
  "description": "Example product profile.",
  "capabilityPackageIDs": [],
  "shelfDefaults": [],
  "appTemplates": [],
  "policyRestrictions": [],
  "vocabulary": {},
  "branding": {
    "accentColor": "#3B82F6",
    "iconSystemName": "shippingbox",
    "displayName": "Example"
  }
}
```

IDs must use lowercase ASCII segments separated by dots or hyphens, for example
`astra.pack.devops` or `pr-ci-review`.

## Field Reference

| Field | Required | Notes |
| --- | --- | --- |
| `formatVersion` | Yes | Must be `1`. |
| `id` | Yes | Stable pack ID. Do not reuse across different verticals. |
| `name` | Yes | Display name. |
| `version` | Yes | Version string for review and ordering. |
| `coreAPIVersion` | Yes | Must currently be `1.0`. |
| `description` | Yes | Short user-facing summary. |
| `capabilityPackageIDs` | No | Provenance and defaults only; does not enable runtime resources. |
| `shelfDefaults` | No | Trusted native shelf defaults. |
| `appTemplates` | No | App Studio template descriptors exposed when the pack is enabled. |
| `policyRestrictions` | No | Restrict-only policy entries. |
| `vocabulary` | No | Vertical wording overrides. |
| `branding` | No | Accent color, SF Symbol, and display name. |

## Capability References

Use capability package IDs to document what a pack is designed around:

```json
"capabilityPackageIDs": [
  "github-workflow"
]
```

This does not enable the capability. Runtime resources are available only when
the workspace enables the capability package through `enabledCapabilityIDs`.
Pack enablement uses `enabledPackIDs` and only affects pack profile behavior.

Tests to add:

- a catalog test proving the pack references known package IDs
- a task resolver test proving pack enablement alone does not activate runtime
  skills, tools, connectors, browser adapters, or MCP servers

## Shelf Defaults

Shelf defaults choose which Core shelves are visible when the pack is enabled:

```json
"shelfDefaults": [
  {
    "id": "plan",
    "title": "Plan",
    "kind": "nativeShelf",
    "capabilityPackageIDs": []
  },
  {
    "id": "files",
    "title": "Files",
    "kind": "nativeShelf",
    "capabilityPackageIDs": []
  }
]
```

When a pack declares shelf defaults, ASTRA starts from that visible set. Other
Core shelves can be hidden by omission and later adjusted by workspace or admin
overrides.

Do not add implementation fields such as:

- `swiftUIViewType`
- `viewImplementation`
- `viewType`
- `modulePath`
- `bundlePath`
- `pluginPath`

Those fields are not part of v1. Packs may select trusted native shelves, not
load shelf code.

## App Studio Templates

Templates are visible only when the pack is enabled:

```json
"appTemplates": [
  {
    "id": "pr-ci-review",
    "name": "PR / CI Review",
    "contributionKind": "workspaceApp",
    "templateID": "workspace-app.pr-ci-review",
    "capabilityPackageIDs": [
      "github-workflow"
    ]
  }
]
```

Use `contributionKind: "workspaceApp"` for App Studio templates. Capability IDs
inside templates are provenance only. Generated apps must still declare their
own requirements and pass manifest validation.

Pack template metadata is sent to generation as bounded untrusted data. Do not
put instructions in pack metadata that ask a model to ignore ASTRA policy or
grant new contracts.

## Policy Restrictions

Policy entries can only restrict:

```json
"policyRestrictions": [
  {
    "id": "docs-read-consent",
    "contributionKind": "workspaceApp",
    "action": "requireExplicitConsent",
    "effect": "restrict",
    "targetMCPServerID": "google",
    "targetMCPToolName": "docs.get",
    "message": "Google Docs reads need local review in this vertical."
  }
]
```

Supported v1 actions are deliberately narrow:

| `contributionKind` | Supported actions | Required target |
| --- | --- | --- |
| `capabilityPackage` | `hideCapability`, `disableCapability`, `addWarning`, `requireReviewGate` | `targetID` or `targetTag` |
| `shelf` | `hideShelf` | `targetID` |
| `workspaceApp` | `requireExplicitConsent` | `targetMCPServerID` and `targetMCPToolName` |

Any effect other than `restrict` is invalid. Packs cannot grant capabilities,
enable tools, widen shell access, bypass browser policy, or override admin
policy.

## Vocabulary And Branding

Vocabulary lets a vertical tune product language:

```json
"vocabulary": {
  "prQueue": "PR Queue",
  "ciReview": "CI Review"
}
```

Branding is presentation metadata:

```json
"branding": {
  "accentColor": "#3B82F6",
  "iconSystemName": "arrow.triangle.pull",
  "displayName": "DevOps"
}
```

Keep vocabulary keys stable and generic enough for Core to render consistently.

## Bundled Pack Layout

Bundled packs live under `Astra/Resources/Packs`:

```text
Astra/Resources/Packs/
  README.md
  devops-pack.json
  devops/
    README.md
    pr-ci-review-template.md
```

`Package.swift` copies the `Packs` resource directory into the app bundle. Keep
supporting files under a pack-specific folder. The JSON manifest is still the
only v1 source of behavior.

## DevOps Example

The DevOps pack demonstrates:

- `id`: `astra.pack.devops`
- `capabilityPackageIDs`: `github-workflow`
- `shelfDefaults`: `plan`, `files`
- `appTemplates`: `pr-ci-review`
- `vocabulary`: `PR Queue`, `CI Review`
- `policyRestrictions`: empty

It intentionally does not enable the GitHub Agent or `gh` CLI by itself. The
task resolver regression in `TaskCapabilityResolverTests` protects that
boundary.

## Testing A Pack

For a bundled pack:

```bash
swift test --filter 'AstraPackCatalogTests|PluginCatalogTests|AstraPackProfileTests|WorkspaceAppStudioTemplatePackTests|TaskCapabilityResolverTests'
git diff --check
./script/build_and_run.sh --verify
```

For policy or shelf changes, broaden to:

```bash
swift test --filter 'AstraPackManifestValidatorTests|AstraPackPolicyTests|ShelfRegistryTests|ShelfAvailabilityPolicyTests|ArchitectureFitnessTests'
./script/prepush.sh
```

Each pack should have tests that cover:

- catalog loading
- validator failures for invalid IDs or policy widening
- profile resolution and shelf visibility
- template visibility when enabled and hidden when disabled
- known capability package references
- no runtime resource activation from pack enablement alone

## Migrating Fork Customizations

Use this loop for fork deltas:

1. List the fork change as vocabulary, branding, shelf default, template,
   capability, policy, or runtime behavior.
2. If it changes runtime power, move it into Core or a capability package first.
3. Add the pack reference only after the runtime owner exists and is tested.
4. Add a regression that enabling the pack alone does not grant runtime access.
5. Delete the fork-only conditional once the pack path covers the use case.

Do not encode customer, vertical, or fork names in Core conditionals when a pack
field can express the same behavior.

## Review Checklist

Before merge, confirm:

- Every manifest field exists in `AstraPackManifest`.
- Every ID follows the lowercase identifier rule.
- Every referenced capability package ID exists.
- Every shelf ID is a trusted native shelf.
- Policy entries are restrict-only.
- App Studio template metadata is untrusted provenance.
- Supporting assets are documentation or examples, not executable logic.
- `git diff --check` passes.
