# External Capability Packages Goal

## Goal

Make ASTRA capable of accepting capability packages authored outside the app, validating them, installing them into the channel-local capability library, approving them locally, and enabling them in a workspace without requiring an ASTRA rebuild for ordinary skill, connector, local tool, prerequisite, template, and MCP declaration changes.

The target is plugin-like external authoring, not arbitrary native extension loading. ASTRA remains the trusted runtime, policy, credential, browser, and provider boundary.

## Current State

ASTRA already has most of the internal runtime pieces:

- `PluginPackage` is a Codable package shape for skills, connectors, local tools, MCP servers, templates, prerequisites, browser adapter IDs, setup text, source metadata, and governance.
- `CapabilityLibrary` stores installed package JSON under channel-specific App Support:
  - Development: `~/Library/Application Support/AstraDev/Capabilities`
  - Production: `~/Library/Application Support/Astra/Capabilities`
- Built-in package JSON ships from `Astra/Resources/Capabilities` and is seeded into the channel-local library.
- `CapabilityInstaller`, `CapabilityCatalogPolicy`, `CapabilityApprovalStore`, `TaskCapabilityResolver`, and `CapabilityRuntimeIntegrityService` enforce install, approval, runtime, and resource readiness rules.
- The management UI can create local capabilities and save local approval records.

The missing product surface is a first-class external package path: author, validate, import, review, approve, enable, run, and debug a package that was built outside ASTRA.

## Scope

In scope:

- A stable `PluginPackage` JSON schema and examples for external authors.
- A package validator that returns precise structured errors and warnings.
- A local import flow for package JSON files.
- A small developer CLI or script for validation/import automation.
- Local approval UX that clearly moves a package from draft to runnable.
- Runtime integrity checks for imported packages.
- Regression tests for every accepted bug fix or issue found while building this.

Out of scope for this milestone:

- Arbitrary Swift/native code plugins.
- Third-party code signing or remote package marketplace distribution.
- Downloading packages from remote registries.
- New provider runtimes.
- New browser adapter implementations from JSON alone.
- Production-channel testing against real user workspaces or credentials.

## Success Criteria

1. A developer can author a capability package outside ASTRA as JSON.
2. ASTRA can import that JSON into the development channel capability library.
3. Invalid or unsafe packages are rejected before installation with actionable errors.
4. Imported local packages default to draft/admin review, then can be locally approved.
5. Approved local packages can be enabled in a workspace and resolved by task runtime.
6. Runtime launch blocks if a package is enabled but missing required skills, connectors, tools, MCP server executables, browser adapters, credentials, or policy approval.
7. Built-in packages remain curated and seeded from `Astra/Resources/Capabilities`.
8. No imported package can silently gain more privilege by editing the JSON after approval; digest mismatch forces review again.

## Package Contract

External package JSON must use the existing `PluginPackage` v2 shape. Required author-facing fields:

- `id`: stable package ID, safe for filenames and workspace references.
- `name`: user-visible name.
- `icon`: SF Symbol name.
- `description`: concise capability summary.
- `author`: package author or organization.
- `category`: catalog grouping.
- `tags`: searchable labels.
- `version`: semantic version.
- `setupGuide`: optional setup instructions.
- `skills`: behavior instructions and provider tool policy.
- `connectors`: credential and config profile shapes.
- `localTools`: CLI or script commands ASTRA may expose.
- `mcpServers`: structured MCP server declarations.
- `templates`: optional task templates.
- `browserAdapters`: ASTRA-known adapter IDs only.
- `prerequisites`: local CLI readiness checks.
- `governance`: approval, risk, visibility, data access, and external effect metadata.

Local packages without explicit governance should still decode as draft, admin-only, explicit-consent-required packages.

## Validation Rules

Add one central validator, for example `CapabilityPackageValidator`, used by both UI import and developer CLI/script paths.

Required validation:

- Decode JSON into `PluginPackage`.
- Reject empty or duplicate package IDs.
- Reject unsafe filenames after `CapabilityLibrary.safeFileName(for:)`.
- Require semantic versions for new external packages.
- Warn when governance is omitted and explain the draft/admin-only default.
- Reject unsafe local tool commands or default arguments.
- Reject credentialed connector URLs that use remote cleartext HTTP.
- Reject unknown browser adapter IDs.
- Reject MCP stdio commands or arguments with shell control syntax.
- Reject remote MCP URLs that are not HTTPS, except loopback HTTP for local development.
- Warn when declared prerequisites are not currently installed.
- Warn when a package declares no installable payload.

Validation must be deterministic and testable without launching the app.

## Import UX

Add an import action to the capability management surface:

- Button label: `Import Capability`.
- Accept only `.json`.
- Show a preflight review screen before writing anything.
- Show decoded identity, source path, version, contents, governance status, warnings, and blockers.
- If validation passes, install into `CapabilityLibrary`.
- If validation blocks, keep the package out of the library and show all blockers.
- After import, focus the package detail screen.
- If package is draft, show the catalog review controls before enablement.

The import flow should not require users to know the App Support path.

## Developer CLI

Add a small local command or script for repeatable package development:

```bash
./script/capability_package.sh validate path/to/package.json
./script/capability_package.sh install-dev path/to/package.json
./script/capability_package.sh validate-dir capabilities
./script/capability_package.sh install-dev-dir capabilities
```

Expected behavior:

- `validate` prints blockers and warnings and exits nonzero on blockers.
- `validate-dir` recursively validates capability JSON files in a repository-level library.
- `install-dev` validates, writes to `~/Library/Application Support/AstraDev/Capabilities`, and refuses production by default.
- `install-dev-dir` validates the full directory before writing anything, then installs all valid packages into the development channel.
- The script must not write approval records.
- Approval stays an explicit ASTRA review step.

If a Swift command target is preferable later, keep the shell script as a thin wrapper.

## Approval Workflow

Imported local packages should be understandable in the catalog:

- Source badge: `Local`.
- Approval badge: `Draft`, `Approved`, `Deprecated`, or `Blocked`.
- Digest status: `Current` or `Changed since approval`.
- Enable button disabled while policy blocks.
- Review controls visible to local admin mode.
- Approval record keyed by package ID, version, and canonical digest.

Editing a local package file after approval must change the digest and force review before runtime activation.

## Runtime Boundary

External packages can define:

- Prompt behavior through skills.
- Provider tool allow/deny/custom tool hints.
- Local CLI command exposure.
- Connector credential/config profiles.
- MCP server declarations and runtime manifests.
- Setup prerequisites.
- Task templates.

External packages cannot define without ASTRA code changes:

- New native browser adapter behavior.
- New bundled Swift tools.
- New connector-specific validators.
- New Keychain storage semantics.
- New runtime providers.
- New app UI beyond the generic package/setup/review surfaces.

This boundary should be visible in the author docs and validation messages.

## Implementation Phases

### Phase 1 - Schema and Author Docs

- Add `docs/capabilities/package-schema.md`.
- Add example packages under `docs/capabilities/examples/`.
- Document which fields are stable, draft, or ASTRA-internal.
- Include a minimal package, CLI tool package, connector package, MCP package, and browser-adapter-gated package.

Validation:

```bash
swift test --filter PluginPackageGovernanceTests
swift test --filter PluginPackageMCPTests
swift test --filter PluginPackagePrereqTests
```

### Phase 2 - Central Validator

- Add `CapabilityPackageValidator`.
- Reuse existing policy helpers instead of duplicating safety checks.
- Return structured blockers and warnings.
- Add tests for safe, unsafe, legacy, local draft, MCP, browser adapter, connector URL, and local tool cases.

Validation:

```bash
swift test --filter CapabilityPackageValidatorTests
swift test --filter CapabilityCatalogPolicyTests
swift test --filter CapabilityInstallerTests
```

### Phase 3 - Import UI

- Add `Import Capability` to `PluginCatalogView`.
- Add file picker and preflight review screen.
- Install only after validation succeeds.
- Refresh the catalog and focus the imported package.
- Keep imported draft packages disabled until approved.

Validation:

```bash
swift test --filter CapabilityLibraryTests
swift test --filter CapabilityGalleryInventoryTests
swift test --filter CapabilityApprovalTests
```

### Phase 4 - Developer Script

- Add `script/capability_package.sh`.
- Implement `validate` and `install-dev`.
- Reuse the same validation logic if exposed through a Swift command target; otherwise keep behavior mirrored and covered by fixtures.
- Document the development workflow.

Validation:

```bash
swift test --filter CapabilityPackageValidatorTests
git diff --check
```

### Phase 5 - Runtime Verification

- Confirm imported approved packages resolve through `TaskCapabilityResolver`.
- Confirm runtime integrity blocks missing companion resources.
- Confirm approval digest mismatch blocks runtime activation.
- Confirm development channel import never touches production App Support.

Validation:

```bash
swift test --filter TaskCapabilityResolverTests
swift test --filter CapabilityRuntimeIntegrityServiceTests
swift test --filter CapabilityApprovalTests
./script/build_and_run.sh --verify
```

## Regression Test Requirements

Every implementation issue found during this work must get a regression test before it is considered fixed.

Required new or expanded suites:

- `CapabilityPackageValidatorTests`
- `CapabilityLibraryTests`
- `CapabilityApprovalTests`
- `CapabilityCatalogPolicyTests`
- `CapabilityInstallerTests`
- `CapabilityRuntimeIntegrityServiceTests`
- `TaskCapabilityResolverTests`
- UI-focused tests only where behavior cannot be covered at service level.

Minimum regression cases:

- Malformed JSON import fails without writing a package file.
- Package with unsafe local tool command is blocked.
- Package with unsafe MCP declaration is blocked.
- Package with credentialed HTTP connector is blocked.
- Package with unknown browser adapter is blocked.
- Local package without governance imports as draft/admin-only.
- Approved local package becomes blocked after content digest changes.
- Imported package appears in catalog after install.
- Imported package can be enabled only after policy permits it.
- Runtime blocks enabled packages with missing credentials or missing executables.

## Rollout

Use the development channel first:

```bash
./script/build_and_run.sh --verify
```

Do not validate this feature against production data during normal feature work. Production package import can be tested only after the development channel flow is stable, covered by tests, and manually verified with synthetic packages.

## Open Questions

- Decision: `Import Capability` blocks an existing package ID. Remove the current package before importing a replacement.
- Decision: local package approval shows digest state as `Digest current`, `Changed since approval`, or `No local record`.
- Decision: package examples live in docs for this milestone. A creation-wizard export action can be added later if external authoring becomes a common workflow.
- Decision: repository-level authoring starts in top-level `capabilities/`; ASTRA still imports into channel-local App Support after validation.
- Decision: the in-app create flow can save generated source JSON into `capabilities/local/` when a repository source library is discoverable; exported source JSON remains draft/local and does not carry approval records.
