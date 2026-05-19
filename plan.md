# Plan

Build an internal controlled capability catalog for ASTRA that keeps security as the core constraint while moving the capability architecture closer to the plugin, MCP, and skill models used by modern agent tools. The catalog should remain curated and policy-governed: packages can become more standard and composable, but only approved capabilities should be visible, installable, enabled, and active for a given workspace, role, and task.

Issue: https://github.com/susom/astra/issues/7

## Scope

- In: internal catalog governance, capability metadata, package provenance, role/category/risk filtering, admin approval states, exact package ownership tracking, runtime enforcement, first-class MCP package declarations, stronger tests, migration strategy, and developer documentation.
- In: preserving strongly coupled ASTRA platform capabilities such as Shelf browser control, Keychain-backed secrets, runtime launch, workspace isolation, audit logging, and permission policy.
- Out: public marketplace publishing, arbitrary unreviewed third-party code execution, replacing ASTRA's Shelf browser bridge with an external browser provider, production data testing, or changing Sparkle release mechanics.
- Out for first implementation pass: full multi-tenant organization server, remote admin console, or cloud-hosted catalog synchronization. The local app model should be designed so those can be added later.

## Current Architecture Summary

ASTRA already has the right foundation:

- `PluginPackage` in `ASTRACore/PluginPackage.swift` is the package definition format.
- Built-in approved packages live under `Astra/Resources/Capabilities/*.json`.
- `CapabilityLibrary` stores app-local installed package JSON under channel-specific App Support.
- `CapabilityInstaller` materializes packages into global or workspace-scoped `Skill`, `Connector`, `LocalTool`, and `TaskTemplate` records.
- `Workspace` stores enabled capability IDs and enabled global resource IDs.
- `TaskCapabilityResolver` resolves active skills, connectors, tools, and browser adapters for each task.
- `SkillResolver` converts resolved capabilities into allowed tools, behavioral instructions, and environment variables.
- `AgentPromptBuilder` renders the runtime prompt sections.
- `AgentRuntimeProcessRunner` injects environment variables, PATH entries, and browser shims into provider CLIs.
- `CapabilityUninstaller` removes local non-built-in packages and cleans up package-owned resources when no remaining package claims them.
- `CapabilityRuntimeIntegrityService` already blocks launches when enabled packages do not resolve to required runtime resources.

The main gap is that package approval, visibility, risk, ownership, and lifecycle policy are not explicit enough. The current system can seed and install packages, but it does not yet express a controlled internal catalog with strong review states, role/workspace targeting, precise origin tracking, and first-class MCP server lifecycle.

## Design Principles

- Keep ASTRA core strongly coupled where security and UX require it: browser, secrets, runtime launch, task supervision, audit, and policy enforcement.
- Make domain capabilities data-driven wherever possible: skills, prompts, connector schemas, MCP servers, CLI tools, templates, and browser adapter activation.
- Treat every capability package as untrusted input until it passes validation, approval, and runtime policy checks.
- Prefer allowlists over blocklists.
- Separate package installation, workspace enablement, user/admin authorization, and task activation.
- Make runtime state explainable: the user and logs should show why a package is visible, enabled, blocked, or active.
- Make removal exact: generated records should carry origin metadata instead of relying on names.
- Prefer MCP for serious integrations, while keeping CLI/script tools for simple or existing command-line workflows.
- Keep tests close to the blast radius for each phase, then run broader security and full test passes at integration milestones.

## Phase 0 - Baseline, Invariants, and Safety Harness

### Goal

Establish the exact behavior that must not regress before changing catalog semantics.

### Implementation Tasks

- Document the current capability lifecycle from package JSON to task runtime.
- Identify every service that reads or mutates capability state:
  - `ASTRACore/PluginPackage.swift`
  - `Astra/Services/PluginCatalog.swift`
  - `Astra/Services/CapabilityLibrary.swift`
  - `Astra/Services/CapabilityInstaller.swift`
  - `Astra/Services/CapabilityUninstaller.swift`
  - `Astra/Services/CapabilityActivationDisabler.swift`
  - `Astra/Services/CapabilityPackageState.swift`
  - `Astra/Services/CapabilityRuntimeIntegrityService.swift`
  - `Astra/Services/TaskCapabilityResolver.swift`
  - `Astra/Services/SkillResolver.swift`
  - `Astra/Services/AgentPromptBuilder.swift`
  - `Astra/Services/AgentRuntimeProcessRunner.swift`
  - `Astra/Views/PluginCatalogView.swift`
  - `Astra/Views/WorkspaceRightRailView.swift`
- Capture baseline behavior for:
  - built-in package seeding
  - local package install
  - built-in package disable
  - local package uninstall
  - workspace capability enablement
  - global skill/connector/tool sharing
  - runtime integrity failures
  - browser adapter exposure
  - connector environment projection
- Add or extend targeted tests only where current behavior is not already covered.

### Verification Gate

- A reviewer can read the baseline notes and point from each catalog lifecycle step to the responsible type.
- Existing built-in capability JSON still decodes.
- No production app data is touched.

### Strong Testing

- Run:
  - `swift test --filter PluginCatalogTests`
  - `swift test --filter CapabilityLibraryTests`
  - `swift test --filter CapabilityInstallerTests`
  - `swift test --filter CapabilityUninstallerTests`
  - `swift test --filter TaskCapabilityResolverTests`
  - `swift test --filter CapabilityRuntimeIntegrityServiceTests`
  - `git diff --check`
- If `CapabilityRuntimeIntegrityServiceTests` does not exist, add focused tests before feature work continues.

### Exit Criteria

- Baseline tests are green.
- Known gaps are tracked as concrete follow-up test additions, not left implicit.

## Phase 1 - Governance Metadata in Capability Packages

### Goal

Extend `PluginPackage` so a capability can describe approval, risk, visibility, and required authorization without adding ad hoc fields throughout the app.

### Proposed Data Model

Add a governance block to `PluginPackage`, with safe decoding defaults:

```swift
public struct CapabilityGovernance: Codable, Equatable, Sendable {
    public var approvalStatus: ApprovalStatus
    public var riskLevel: RiskLevel
    public var visibility: Visibility
    public var allowedRoles: [String]
    public var allowedWorkspaceTags: [String]
    public var requiresAdminApproval: Bool
    public var requiresExplicitUserConsent: Bool
    public var dataAccess: [DataAccessKind]
    public var externalEffects: [ExternalEffectKind]
    public var approvedBy: String?
    public var approvedAt: Date?
    public var reviewTicketURL: URL?
    public var policyNotes: String
}
```

Keep the exact enum names flexible, but the semantics should include:

- approval status: `draft`, `approved`, `deprecated`, `blocked`
- risk level: `low`, `medium`, `high`, `restricted`
- visibility: `everyone`, `roleScoped`, `workspaceScoped`, `adminOnly`, `hidden`
- data access: filesystem, browser authenticated content, connector credentials, network, app support, Keychain reference, logs
- external effects: read-only, local writes, external API writes, deploys, deletes, messages, approvals, purchases

### Implementation Tasks

- Add `CapabilityGovernance` and supporting enums in `ASTRACore`.
- Add `governance` to `PluginPackage` with backwards-compatible decoding.
- Add default governance for legacy packages:
  - built-in package with no governance: approved, medium risk unless known low, visible to everyone.
  - local package with no governance: draft or local-only, requires explicit user consent.
- Update built-in JSON files in `Astra/Resources/Capabilities/` with explicit governance.
- Update fallback packages in `PluginCatalog.swift` so source and fallback definitions match.
- Update `contentSummary` or catalog presentation only if useful; avoid overloading it with risk details.
- Add compact audit fields in `CapabilityAudit` for governance status and risk.

### Verification Gate

- All old package fixtures decode.
- All new built-in package JSON files encode/decode with explicit governance.
- The UI can still render package cards even when governance fields are omitted.

### Strong Testing

- Add tests:
  - `PluginPackageGovernanceTests`
  - legacy decode defaults
  - explicit governance round trip
  - invalid enum fallback or decode failure behavior, whichever we choose
  - built-in JSON governance coverage
  - fallback catalog governance parity
- Run:
  - `swift test --filter PluginPackagePrereqTests`
  - `swift test --filter PluginCatalogTests`
  - `swift test --filter CapabilityLibraryTests`
  - `swift test --filter PluginPackageGovernanceTests`
  - `git diff --check`

### Exit Criteria

- Package governance exists as a single reusable model.
- Every built-in package has an explicit approval and risk posture.
- Legacy package compatibility is proven by tests.

## Phase 2 - Exact Origin and Ownership Metadata

### Goal

Make capabilities removable and auditable without relying on fragile name matching.

### Proposed Data Model

Add origin fields to generated or linked capability resources:

- `Skill`
- `Connector`
- `LocalTool`
- `TaskTemplate`

Suggested fields:

```swift
var originPackageID: String?
var originPackageVersion: String?
var originComponentID: String?
var originComponentKind: String?
var originSourceKind: String?
```

Component IDs should be stable inside the package. If we do not add explicit component IDs to package schema immediately, derive them deterministically:

- skill: `skill:<normalized-name>`
- connector: `connector:<normalized-service-type>:<normalized-name>`
- local tool: `tool:<normalized-type>:<normalized-command>:<normalized-name>`
- template: `template:<normalized-name>`
- browser adapter: `browser-adapter:<normalized-adapter-id>`

### Implementation Tasks

- Add origin metadata fields to SwiftData models.
- Add a schema migration for existing stores.
- Update `CapabilityInstaller` to set origin fields on every generated or upserted record.
- Update `PluginCatalog.install` legacy path or consolidate it behind `CapabilityInstaller`.
- Update `CapabilityUninstaller` and `CapabilityActivationDisabler` to prefer origin metadata and fall back to name matching only for legacy records.
- Update `CapabilityPackageState` to link resources by origin first, then legacy matching.
- Update export/import paths in `WorkspaceConfigManager` so origin metadata survives workspace portability where appropriate.
- Ensure secrets are still cleaned up for origin-owned connectors.

### Verification Gate

- Installing a local capability records exact origin metadata on all created resources.
- Disabling a capability removes only resources owned exclusively by that capability.
- Shared resources claimed by multiple packages are preserved.
- Legacy records with no origin metadata still behave as before.

### Strong Testing

- Add tests:
  - install records origin on skills/connectors/tools/templates
  - update preserves origin and refreshes version
  - uninstall removes origin-owned resources
  - uninstall preserves resources claimed by another package
  - disable uses origin metadata before name matching
  - legacy no-origin package still disables by existing matching rules
  - workspace export/import preserves required origin fields
  - schema migration initializes origin fields safely
- Run:
  - `swift test --filter SchemaVersionTests`
  - `swift test --filter WorkspacePersistenceTests`
  - `swift test --filter CapabilityInstallerTests`
  - `swift test --filter CapabilityUninstallerTests`
  - `swift test --filter CapabilityPackageStateTests`
  - `swift test --filter CapabilityActivationDisablerTests`
  - `git diff --check`

### Exit Criteria

- Ownership is exact for new resources.
- Legacy compatibility is intentionally tested.
- Uninstall and disable behavior is deterministic and auditable.

## Phase 3 - Catalog Policy Evaluation

### Goal

Centralize the rules that decide whether a package is visible, installable, enableable, runnable, blocked, or requires approval.

### New Service

Add a policy evaluator, likely:

- `Astra/Services/CapabilityCatalogPolicy.swift`

Suggested inputs:

```swift
struct CapabilityCatalogPolicyContext {
    var userRoleIDs: Set<String>
    var workspaceID: UUID?
    var workspaceTags: Set<String>
    var isAdmin: Bool
    var channel: AppChannel
    var installedPackageIDs: Set<String>
    var enabledPackageIDs: Set<String>
}
```

Suggested output:

```swift
struct CapabilityCatalogDecision {
    var isVisible: Bool
    var canInstall: Bool
    var canEnable: Bool
    var canRun: Bool
    var requiresApproval: Bool
    var blockers: [CapabilityCatalogBlocker]
    var warnings: [CapabilityCatalogWarning]
}
```

### Implementation Tasks

- Implement a pure policy service with no SwiftUI dependency.
- Encode policy rules:
  - blocked packages are never visible to non-admin users.
  - hidden packages are visible only to admins or diagnostic views.
  - role-scoped packages require an allowed role.
  - workspace-scoped packages require matching workspace tags or explicit workspace allowlist.
  - admin-only packages require admin role.
  - packages requiring admin approval cannot be enabled until approved.
  - deprecated packages can stay enabled but should not be newly installed unless admin-approved.
  - dependencies, conflicts, app version, unsafe connector URLs, and unsafe local tool commands remain hard blockers.
- Update catalog inventory services to use policy decisions:
  - `CapabilityCatalogInventory`
  - `CapabilityGalleryInventory`
  - `PluginCatalogView` view models
  - `WorkspaceRightRailView` capability summaries
- Add audit logging for blocked visibility/install/enable attempts.
- Keep policy deterministic and testable without launching ASTRA.

### Verification Gate

- Given the same package and context, policy output is stable and explainable.
- Non-admin users cannot enable admin-only or blocked packages.
- Admin users can see why a package is blocked or restricted.
- Existing approved built-ins remain visible in normal development contexts.

### Strong Testing

- Add `CapabilityCatalogPolicyTests` with table-driven cases:
  - approved/everyone package
  - draft local package
  - blocked package
  - deprecated package
  - admin-only package
  - role-scoped package with and without role
  - workspace-scoped package with and without tag
  - package requiring admin approval
  - package with missing dependency
  - package with conflict
  - unsafe local tool command
  - unsafe credentialed HTTP connector URL
- Run:
  - `swift test --filter CapabilityCatalogPolicyTests`
  - `swift test --filter CapabilityGalleryInventoryTests`
  - `swift test --filter PluginCatalogTests`
  - `swift test --filter CapabilityInstallerTests`
  - `swift test --filter ConnectorPreflightServiceTests`
  - `git diff --check`

### Exit Criteria

- There is one obvious place to answer "can this user see/install/enable/run this capability?"
- UI and runtime services do not duplicate governance logic.

## Phase 4 - Internal Catalog UI and Risk Presentation

### Goal

Make the catalog the primary discovery surface for safe, approved agent capabilities.

### Implementation Tasks

- Update `PluginCatalogView` to display:
  - approval status
  - risk level
  - required roles
  - required admin approval
  - data access categories
  - external effect categories
  - prerequisites
  - installed/enabled state
  - readiness issues
- Add filters:
  - category
  - role eligibility
  - approval status
  - risk level
  - installed/enabled
  - needs attention
  - admin-only
- Add clear blocked states:
  - not visible due to role
  - visible but not installable
  - installable but not enableable
  - enabled but not runnable due to missing credential or executable
- Keep UI concise:
  - risk badges should summarize, not overwhelm.
  - detailed policy reasons should appear in a disclosure/details area.
- Update `WorkspaceRightRailView` capability summaries to show risk/readiness.
- Ensure no secrets or credential values are rendered in UI.
- Ensure development and production channel labels remain clear.

### Verification Gate

- A user can identify which capabilities they may use and why another capability is blocked.
- Risk information is visible before enablement.
- Missing credentials and missing CLI prerequisites are shown distinctly.
- Built-in browser and GitHub examples remain understandable.

### Strong Testing

- Prefer view-model or presentation tests over fragile UI snapshot tests.
- Add or extend:
  - `CapabilityRailPresentationTests`
  - `CapabilityGalleryInventoryTests`
  - `PluginCatalogPrereqBadgeTests`
  - `CapabilityPackageStateTests`
- Test:
  - risk badge text
  - approval status text
  - readiness messages
  - blocked install action state
  - missing credential state
  - missing executable state
  - role-filtered catalog list
  - admin-only visibility
- Run:
  - `swift test --filter CapabilityRailPresentationTests`
  - `swift test --filter CapabilityGalleryInventoryTests`
  - `swift test --filter PluginCatalogPrereqBadgeTests`
  - `swift test --filter CapabilityPackageStateTests`
  - `./script/build_and_run.sh --verify`
  - `git diff --check`

### Exit Criteria

- Catalog policy is visible to users in plain language.
- Risk labels are consistent with runtime enforcement.
- The app builds and launches in the development channel.

## Phase 5 - Admin Approval and Local Review Workflow

### Goal

Support internal review without requiring a remote admin service in the first iteration.

### Proposed Local Model

Add a local approval record separate from the package definition:

```swift
struct CapabilityApprovalRecord: Codable {
    var packageID: String
    var packageVersion: String
    var status: ApprovalStatus
    var approvedBy: String
    var approvedAt: Date
    var reviewNotes: String
    var sourceDigest: String
}
```

This avoids editing package JSON every time a local admin approves or blocks a package.

### Implementation Tasks

- Add approval storage under channel-specific App Support.
- Compute a package digest from canonical package JSON.
- Store approval decisions by package ID, version, and digest.
- Treat digest mismatch as needing re-review.
- Add admin-only approve/block/deprecate actions in catalog UI.
- Add audit logging for approval changes.
- Ensure built-in approved packages can ship with built-in approval metadata and do not require local approval unless policy says so.
- Ensure local packages default to draft/unapproved.

### Verification Gate

- A draft package cannot be enabled by a non-admin.
- An admin can approve a draft package.
- Changing package contents invalidates the previous approval.
- Blocking an already enabled package prevents new task launches and surfaces a clear message.

### Strong Testing

- Add tests:
  - approval record round trip
  - canonical digest stability
  - digest changes when package command/connector/browser adapter changes
  - draft package blocked for non-admin
  - approved package enableable
  - blocked enabled package fails runtime integrity
  - local approval store is channel-specific
- Run:
  - `swift test --filter CapabilityApprovalTests`
  - `swift test --filter CapabilityCatalogPolicyTests`
  - `swift test --filter CapabilityRuntimeIntegrityServiceTests`
  - `swift test --filter CapabilityLibraryTests`
  - `git diff --check`

### Exit Criteria

- Internal approval is represented as durable state.
- Approval cannot silently survive a package content change.
- Runtime launch honors blocked approval state.

## Phase 6 - Install, Enable, Activate Lifecycle Hardening

### Goal

Make capability lifecycle states explicit and enforce them consistently.

### Lifecycle States

Use these concepts throughout the code and UI:

- available in catalog
- installed in app-local capability library
- approved for use
- enabled for workspace
- configured for workspace
- authorized by user/admin
- activated for task
- blocked at runtime

### Implementation Tasks

- Update naming in services and UI where "installed" is used when the actual state is "enabled."
- Add a lifecycle state helper, likely:
  - `CapabilityLifecycleState`
  - `CapabilityLifecycleResolver`
- Make `CapabilityInstaller.install` and `.enable` call policy before mutating state.
- Make direct enable/disable actions in views call the same service path.
- Ensure task launch calls runtime integrity with governance checks, not just resource checks.
- Add lifecycle audit events:
  - install requested
  - install blocked
  - enabled
  - enable blocked
  - approval required
  - runtime activation blocked
  - disabled
  - uninstalled
- Keep local non-built-in uninstall behavior.
- Keep built-in packages non-removable but disableable.

### Verification Gate

- A package cannot bypass policy by entering through an older installer path.
- Runtime launch blocks packages that were enabled before being later blocked.
- UI state matches lifecycle resolver output.

### Strong Testing

- Add tests:
  - install blocked by policy
  - enable blocked by policy
  - runtime activation blocked after approval revoked
  - built-in package cannot be uninstalled
  - built-in package can be disabled
  - local package can be uninstalled
  - package with missing dependency cannot enable
  - package with conflict cannot enable
- Run:
  - `swift test --filter CapabilityInstallerTests`
  - `swift test --filter CapabilityUninstallerTests`
  - `swift test --filter CapabilityActivationDisablerTests`
  - `swift test --filter CapabilityRuntimeIntegrityServiceTests`
  - `swift test --filter PluginCatalogTests`
  - `git diff --check`

### Exit Criteria

- Lifecycle terms are precise in code and UI.
- Policy is enforced before mutation and again before runtime launch.

## Phase 7 - First-Class MCP Package Components

### Goal

Make MCP servers a first-class capability component while keeping them catalog-controlled and policy-governed.

### Proposed Package Schema

Add a package component like:

```swift
public struct PluginMCPServer: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var transport: Transport
    public var command: String?
    public var arguments: [String]
    public var url: URL?
    public var environmentKeys: [String]
    public var connectorBindings: [String]
    public var allowedTools: [String]
    public var excludedTools: [String]
    public var resourcesEnabled: Bool
    public var promptsEnabled: Bool
    public var trustLevel: TrustLevel
}
```

### Implementation Tasks

- Add `mcpServers` to `PluginPackage` with default empty decode.
- Add security validation:
  - stdio commands must pass safe command policy.
  - arguments must pass safe argument policy.
  - remote URLs must use HTTPS except loopback development.
  - package must be approved before MCP server activation.
  - high-risk MCP servers require explicit consent.
- Decide provider integration path:
  - initial path: render provider-specific MCP configuration for Claude/Copilot if supported.
  - fallback path: expose MCP tool names only when provider already has them configured.
  - future path: ASTRA-owned MCP client/proxy that can discover tools/resources/prompts and mediate calls.
- Add runtime manifest output that lists active MCP servers, tool allow/exclude policy, and source package.
- Add UI display for MCP servers under each capability.
- Update readiness to check MCP command existence or remote URL validity.

### Verification Gate

- A package can declare an MCP server without breaking old packages.
- Unsafe MCP stdio commands are blocked.
- Remote MCP URLs are policy checked.
- MCP server readiness appears in catalog state.
- No MCP server can activate from an unapproved package.

### Strong Testing

- Add tests:
  - package decode with `mcpServers`
  - package decode without `mcpServers`
  - safe stdio MCP server accepted
  - unsafe stdio command rejected
  - unsafe args rejected
  - HTTP remote URL rejected when credentialed or non-loopback
  - HTTPS remote URL accepted
  - unapproved package MCP server not active
  - MCP readiness missing executable
  - MCP tool allow/exclude rendering
- Run:
  - `swift test --filter PluginPackageMCPTests`
  - `swift test --filter CapabilityInstallerTests`
  - `swift test --filter CapabilityRuntimeIntegrityServiceTests`
  - `swift test --filter AgentRuntimeExecutionPolicyTests`
  - `git diff --check`

### Exit Criteria

- MCP is modeled as a package component, not as an informal local tool string.
- MCP activation remains internal-catalog controlled.

## Phase 8 - Connector Profiles as Auth and Configuration, Not Execution

### Goal

Clarify that connectors provide credentials/configuration, while execution happens through MCP tools, CLI tools, ASTRA platform tools, or browser actions.

### Implementation Tasks

- Update terminology in code comments and UI:
  - connector = auth/config profile
  - local tool = command execution surface
  - MCP server = structured external tool/resource provider
  - skill = behavior and policy instructions
- Keep `ConnectorRuntimeProjection` as the single runtime env projection path.
- Ensure connectors can bind to:
  - skills for behavior
  - MCP servers for auth/config
  - CLI tools for env injection
- Add connector binding metadata for MCP servers and local tools if needed.
- Update prompt rendering so connectors are described as available profiles, not implied tools.
- Preserve existing connector behavior for Jira, REDCap, gcloud, and Stanford mail.

### Verification Gate

- Existing connector-backed capabilities still work.
- Prompt text no longer implies `WebFetch` or raw connector execution.
- Multiple connectors of the same service still resolve via `ASTRA_CONNECTORS`.

### Strong Testing

- Run:
  - `swift test --filter ConnectorRuntimeProjectionTests`
  - `swift test --filter ConnectorPreflightServiceTests`
  - `swift test --filter TaskCapabilityResolverTests`
  - `swift test --filter AgentRuntimeWorkerTests`
  - `swift test --filter JiraConnectorAuthTests`
  - `swift test --filter CapabilitySetupCopierTests`
  - `git diff --check`
- Add or extend prompt snapshot assertions for:
  - connector credentials are listed as env vars only
  - no secret values appear in prompt text
  - multiple connectors show disambiguation guidance
  - connector-bound MCP/local tool context is explicit

### Exit Criteria

- Connector semantics are clear and tested.
- Existing capabilities do not regress.

## Phase 9 - Browser as Trusted Platform Capability With Catalog-Gated Adapters

### Goal

Keep Shelf browser control strongly coupled to ASTRA, while making site-specific behavior visible and governed by catalog packages.

### Implementation Tasks

- Keep `ShelfBrowserBridgeRegistry`, `BrowserBridgeServer`, `ShelfBrowserSession`, and `astra-browser` as ASTRA platform services.
- Keep generic browser control available only when the user enables task-bound browser control.
- Treat `browserAdapters` as capability-gated policy/semantic extensions.
- Add governance metadata to browser adapter packages:
  - browser authenticated content access
  - potential external write effects
  - user confirmation requirements
  - adapter-specific safety notes
- Update `BrowserSiteAdapters` so every adapter has:
  - ID
  - display name
  - host patterns
  - capabilities
  - risk/effect metadata or a link to package governance
- Make `CapabilityRuntimeIntegrityService` validate that enabled adapter IDs are known and active.
- Ensure prompt context lists enabled site adapters and clearly distinguishes generic browser control from site-specific helpers.

### Verification Gate

- Browser control is never exposed without a task-bound bridge endpoint.
- Site adapters are exposed only when enabled by approved packages or when ASTRA intentionally surfaces a safe helper for the current page.
- Google Drive and GitHub adapter behavior remains intact.

### Strong Testing

- Run:
  - `swift test --filter BrowserBridgeSecurityTests`
  - `swift test --filter BrowserToolShimTests`
  - `swift test --filter BrowserToolArgumentTests`
  - `swift test --filter BrowserControlSafetyTests`
  - `swift test --filter BrowserAnalysisTests`
  - `swift test --filter BrowserPageReadServiceTests`
  - `swift test --filter BrowserFailureDebugCaptureTests`
  - `swift test --filter TaskCapabilityResolverTests`
  - `swift test --filter CapabilityRuntimeIntegrityServiceTests`
  - `git diff --check`

### Exit Criteria

- Browser remains a trusted core capability.
- Catalog-gated adapters add semantics without bypassing browser safety.

## Phase 10 - Security Review and Threat-Model Hardening

### Goal

Treat the internal catalog as a security boundary and test it accordingly.

### Threats to Cover

- Unapproved package becomes visible or enableable.
- Package command injects shell control syntax.
- Package arguments inject shell control syntax.
- Connector URL downgrades credential transport to unsafe HTTP.
- Package changes after approval but keeps approval state.
- Package claims another package's resources by name.
- Uninstall removes resources owned by another package.
- Runtime launches with a blocked or deprecated package without warning.
- MCP server exposes unexpected tools.
- Prompt text leaks credential values.
- Browser bridge is exposed to the wrong task.
- Catalog import reads outside approved directories.

### Implementation Tasks

- Update `docs/security/security-boundaries.md` with catalog-specific boundaries.
- Extend `script/security_hunt.sh` with catalog tests.
- Add audit event coverage for catalog policy decisions.
- Add redaction checks for approval logs, runtime manifests, and connector env projection.
- Add test fixtures for malicious packages:
  - shell injection command
  - shell injection args
  - unsafe connector URL
  - unknown browser adapter
  - blocked governance status
  - digest mismatch
  - origin collision attempt
  - MCP server with unsafe command

### Verification Gate

- The security boundary doc has a catalog section.
- `script/security_hunt.sh` includes catalog policy and runtime integrity checks.
- Malicious package fixtures are blocked before runtime launch.

### Strong Testing

- Run:
  - `./script/security_hunt.sh`
  - `swift test --filter CapabilityCatalogPolicyTests`
  - `swift test --filter CapabilityRuntimeIntegrityServiceTests`
  - `swift test --filter CapabilityInstallerTests`
  - `swift test --filter CapabilityUninstallerTests`
  - `swift test --filter BrowserBridgeSecurityTests`
  - `swift test --filter AgentRuntimeExecutionPolicyTests`
  - `swift test --filter SecurityTests`
  - `git diff --check`

### Exit Criteria

- Catalog security is covered by automated tests and manual red-team guidance.
- Runtime activation is denied for unsafe or unapproved capabilities.

## Phase 11 - Migration and Compatibility

### Goal

Upgrade existing development and production stores safely.

### Implementation Tasks

- Add SwiftData schema migration for origin metadata and any approval/lifecycle models.
- Preserve existing workspace capability IDs and installed plugin records.
- Seed governance defaults for built-in packages.
- Repair existing enabled package activations using `CapabilityDefinitionRepairService`.
- Ensure older exported workspace configs import with safe defaults.
- Ensure unknown governance fields in future package JSON do not crash older-compatible paths if possible.
- Ensure local package removal remains possible for packages installed before governance metadata existed.

### Verification Gate

- Existing workspaces open.
- Existing enabled capabilities still appear enabled.
- Existing connectors keep Keychain values.
- Existing local packages are classified as local/draft unless explicitly approved.

### Strong Testing

- Add migration fixtures if not already present.
- Run:
  - `swift test --filter SchemaVersionTests`
  - `swift test --filter WorkspacePersistenceTests`
  - `swift test --filter CapabilityDefinitionRepairServiceTests`
  - `swift test --filter CapabilityLibraryTests`
  - `swift test --filter OnboardingWizardTests`
  - `git diff --check`

### Exit Criteria

- Migration path is tested from the previous schema.
- No capability becomes more privileged after migration.

## Phase 12 - Documentation and Developer Workflow

### Goal

Make it straightforward for maintainers to add approved internal capabilities without weakening catalog controls.

### Implementation Tasks

- Update `Astra/Resources/Capabilities/README.md` with:
  - required governance fields
  - risk level guidance
  - approval workflow
  - local testing workflow
  - review checklist
  - examples for read-only, external-write, browser, and MCP packages
- Add a package authoring checklist:
  - no secrets in JSON
  - commands must be binary names or safe paths
  - args must not contain shell control syntax
  - credentialed remote URLs must be HTTPS
  - browser adapters must be known IDs
  - MCP servers must be approved and pinned
  - risk metadata must match external effects
- Add troubleshooting docs:
  - why a package is hidden
  - why enable is blocked
  - why runtime launch is blocked
  - how to approve or deprecate a package
- Update `README.md` if the user-facing value proposition or setup flow changes.

### Verification Gate

- A maintainer can add a new approved package using only documented steps.
- The docs explain how security review maps to package fields.
- The docs explain how to test a capability without production data.

### Strong Testing

- Run:
  - `swift test --filter CapabilityLibraryTests`
  - `swift test --filter PluginCatalogTests`
  - `swift test --filter CapabilityCatalogPolicyTests`
  - `git diff --check`
- Manually validate docs links and file paths.

### Exit Criteria

- Documentation is accurate enough for the next internal capability addition.
- Reviewers have a concrete checklist.

## Phase 13 - End-to-End Validation in Development Channel

### Goal

Verify the complete catalog experience through ASTRA Dev.

### Manual Test Scenarios

- Launch development app with isolated data:
  - `./script/build_and_run.sh --verify`
- Scenario 1: normal user sees approved low/medium risk capabilities only.
- Scenario 2: admin sees admin-only and blocked diagnostic details.
- Scenario 3: researcher role sees curated research capabilities.
- Scenario 4: engineer role sees repo/test/review capabilities.
- Scenario 5: draft local package requires approval.
- Scenario 6: approval digest mismatch blocks enablement.
- Scenario 7: missing credential shows readiness issue.
- Scenario 8: missing CLI prerequisite shows readiness issue.
- Scenario 9: enabled but later blocked package cannot launch a task.
- Scenario 10: Google Drive Browser adapter appears only when enabled and browser control is task-bound.
- Scenario 11: GitHub capability shows `gh` prerequisite, skill instructions, local tool, and browser adapter.
- Scenario 12: uninstall local capability removes only owned resources.

### Automated Test Command Set

Run narrow tests first:

```bash
swift test --filter PluginPackageGovernanceTests
swift test --filter CapabilityCatalogPolicyTests
swift test --filter CapabilityInstallerTests
swift test --filter CapabilityRuntimeIntegrityServiceTests
swift test --filter CapabilityUninstallerTests
```

Then broader capability tests:

```bash
swift test --filter PluginCatalogTests
swift test --filter CapabilityLibraryTests
swift test --filter CapabilityGalleryInventoryTests
swift test --filter CapabilityPackageFactoryTests
swift test --filter CapabilityPackageStateTests
swift test --filter TaskCapabilityResolverTests
swift test --filter SkillResolverTests
swift test --filter ConnectorPreflightServiceTests
```

Then runtime and browser tests:

```bash
swift test --filter AgentRuntimeWorkerTests
swift test --filter AgentRuntimeExecutionPolicyTests
swift test --filter BrowserBridgeSecurityTests
swift test --filter BrowserControlSafetyTests
swift test --filter BrowserAnalysisTests
swift test --filter BrowserToolShimTests
```

Then security and full validation:

```bash
./script/security_hunt.sh
swift test
./script/build_and_run.sh --verify
git diff --check
```

### Verification Gate

- All automated tests pass.
- Manual development-channel scenarios pass.
- No production App Support, Keychain, or workspace data is used.

### Exit Criteria

- Feature branch is ready for draft PR.
- PR description includes test output and remaining known risks.

## Proposed Milestones

### Milestone A - Governance Foundation

- Phase 0
- Phase 1
- Phase 2
- Phase 3

Deliverable: packages have governance and origin metadata, and policy decisions are testable.

### Milestone B - User-Facing Controlled Catalog

- Phase 4
- Phase 5
- Phase 6

Deliverable: catalog UI shows risk/approval/readiness and enforces install/enable/activate lifecycle.

### Milestone C - Standard Plugin Alignment

- Phase 7
- Phase 8
- Phase 9

Deliverable: ASTRA supports a clearer plugin-like package shape with MCP as a first-class component and browser adapters as trusted-platform extensions.

### Milestone D - Security, Migration, and Release Readiness

- Phase 10
- Phase 11
- Phase 12
- Phase 13

Deliverable: security boundaries, migrations, docs, and end-to-end development validation are complete.

## Acceptance Criteria

- Internal catalog policy controls which capabilities are visible, installable, enableable, and runnable.
- Built-in packages are explicitly approved and risk-labeled.
- Local packages default to restricted/draft behavior.
- Admin-only, role-scoped, workspace-scoped, deprecated, and blocked packages behave differently and predictably.
- Capability-generated resources carry exact origin metadata.
- Uninstall and disable paths remove only resources owned by the package being removed or disabled.
- Runtime launch cannot activate blocked, unapproved, unsafe, or incomplete capabilities.
- MCP servers are modeled as controlled package components, not informal prompt text.
- Connector credentials/config remain Keychain-backed and are projected through safe runtime env vars.
- Browser control remains ASTRA platform-owned and task-bound.
- Browser site adapters are catalog-gated and policy-visible.
- All new behavior has unit tests, runtime tests, migration tests, and security tests.
- Full test suite and development app verification pass before PR is marked ready.

## Open Questions

- Where should user roles and workspace tags come from in the first local-only version: settings, workspace config, imported org policy file, or all three?
- Should approval records be editable only in a hidden/admin mode, or should the UI expose an explicit "Catalog Admin" surface?
- Should ASTRA initially configure provider MCP servers directly, or build an ASTRA MCP proxy/client so runtime discovery and enforcement are provider-neutral?
- Should capability package signatures be required for all non-local packages in the first implementation, or introduced after local approval/digest checks?
- Should blocked packages be hidden from normal users or visible as "not available" when they were previously enabled in a workspace?

## Non-Negotiable Testing Rules

- Test normal feature work against `ASTRA Dev.app`, not production.
- Every phase must end with `git diff --check`.
- Every schema change must include `SchemaVersionTests`.
- Every runtime policy change must include `CapabilityRuntimeIntegrityServiceTests`.
- Every package decode change must include legacy decode coverage.
- Every install/enable/uninstall change must include ownership and cleanup tests.
- Every security boundary change must update `docs/security/security-boundaries.md` and `script/security_hunt.sh`.
- Any test that needs credentials must use fake values and assert they do not appear in prompts, events, diagnostics, or logs.
