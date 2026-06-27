# Approved Capabilities

This folder is the repo-maintained source for ASTRA's approved built-in capability catalog.

Each JSON file is a `PluginPackage` v2 capability package. Capabilities can include skills, connector profiles, local tools, MCP servers, browser adapters, prerequisites, templates, and setup text needed to enable that capability in a workspace.

Every built-in package must include explicit `governance` metadata. ASTRA treats local or legacy packages without this block as draft, admin-only packages that require explicit review.

Required governance fields:

- `approvalStatus`: `approved`, `draft`, `deprecated`, or `blocked`.
- `riskLevel`: `low`, `medium`, `high`, or `restricted`.
- `visibility`: `everyone`, `roleScoped`, `workspaceScoped`, `adminOnly`, or `hidden`.
- `requiresAdminApproval`: use `false` only for reviewed built-ins.
- `requiresExplicitUserConsent`: use `true` for sensitive data, clinical data, deploy/delete, message send, or browser edit effects.
- `dataAccess`: document every broad data class the package can reach, such as `workspaceFiles`, `connectorCredentials`, `network`, `externalService`, `authenticatedBrowserContent`, `email`, or `clinicalData`.
- `externalEffects`: document what the package can do outside ASTRA, such as `readOnly`, `externalAPIWrite`, `ticketMutation`, `browserNavigation`, `deploy`, or `delete`.
- `approvedBy`: use `ASTRA` for repo-maintained built-ins.
- `policyNotes`: short review notes that explain why the risk level matches the declared access and effects.

Review checklist:

- Do not store secrets or real credentials in JSON.
- Commands must be binary names or safe paths; keep shell syntax out of `command`.
- Default arguments must not contain shell control syntax.
- Credentialed remote connector URLs must use HTTPS, except loopback development URLs.
- Browser adapters must be known ASTRA adapter IDs and must declare authenticated-browser data access when relevant.
- MCP servers must be declared in `mcpServers`, not hidden in skill prompt text or local tool notes.
- Stdio MCP commands must be binary names or safe paths, and MCP arguments must not contain shell control syntax.
- Remote MCP URLs must use HTTPS, except loopback HTTP for local development.
- Package-managed MCP servers should declare `installSource` with the package
  kind, identifier, exact version or digest when available, install mode, and
  registry/documentation URLs. Keep runtime launch in `command`/`arguments`;
  use `installSource` only for review, readiness, and remediation metadata.
- Connector-bound MCP servers should list the connector service names in `connectorBindings` and required env keys in `environmentKeys`; never store values in JSON.
- Risk metadata must match the strongest declared data access or external effect.
- Use `iconDescriptor` for package-owned icons. Built-in brand assets live under
  `assets/`, use relative paths such as `assets/github.svg`, and should include
  an SF Symbol `fallbackSystemName`.
- Set `iconDescriptor.monochromePreferred` to `true` for single-color assets
  that should tint with ASTRA's light/dark appearance. Reserve `false` for
  full-color assets that should render with their original colors.
- Keep vendored brand assets small, local, and source-attributed. Do not point
  package JSON at remote icon URLs.
- Add or update focused tests when changing package schema, prerequisites, governance, or runtime activation behavior.

MCP lifecycle:

- Author MCP servers through the capability package `mcpServers` array. Do not model first-class MCP servers as `LocalTool(toolType: "mcp")`; that path is only a legacy/custom-tool hint.
- Every stdio MCP server should have an explicit command contract. If readiness needs to check installation before enablement, add a `prerequisites` entry for the command with a liveness probe that exits quickly.
- Prefer exact npm/PyPI versions or Docker digests. Versionless package-manager
  targets and unpinned Docker images are treated as higher-risk install sources
  during local review.
- MCP servers may reference environment keys only when those keys are declared by the same package's connector credential/config hints or skill environment keys.
- Remote MCP URLs must be HTTPS, except loopback HTTP for local development.
- Runtime launch still performs a final MCP preflight and blocks missing stdio commands for runtimes that support MCP servers.

Approval workflow:

- Built-in packages are reviewed in-repo and ship with `governance.approvalStatus = approved`.
- Local or legacy packages without governance decode as draft, admin-only, and explicit-consent-required.
- Local review decisions are stored as channel-specific approval records under App Support and are keyed by package ID, version, and canonical package digest.
- Any package content change changes the digest and requires re-review before the previous approval can be used.
- For packages with asset icons, changing the declared asset bytes also changes
  the approval digest.
- Blocking a package prevents new task launches even if the package had already been enabled in a workspace.

Local testing workflow:

- Use the development channel only: `./script/build_and_run.sh --verify`.
- Run focused schema and policy tests before launching the app:

```bash
swift test --filter PluginPackageGovernanceTests
swift test --filter CapabilityCatalogPolicyTests
swift test --filter CapabilityApprovalTests
swift test --filter PluginPackageMCPTests
swift test --filter CapabilityInstallerTests
swift test --filter TaskCapabilityResolverTests
```

Troubleshooting:

- Hidden package: check `visibility`, allowed roles, allowed workspace tags, and whether the package is blocked.
- Enable blocked: check approval status, digest mismatch, app version, dependencies, conflicts, unsafe connector URLs, unsafe local tools, and unsafe MCP server declarations.
- Runtime launch blocked: check whether the package is still approved and runnable, and whether declared skills, connectors, local tools, browser adapters, MCP commands, and prerequisites resolve in the workspace.

The development app seeds these files into:

```text
~/Library/Application Support/AstraDev/Capabilities
```

The production app seeds them into:

```text
~/Library/Application Support/Astra/Capabilities
```

To add or update an approved capability, edit or add a JSON file here. Removing a built-in JSON file removes that built-in package from the seeded app-local capability catalog on the next launch or catalog refresh.
