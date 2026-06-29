# Capability Package Schema

ASTRA external capabilities are JSON files or package folders that decode as `PluginPackage` v2 packages. They can be authored outside the app, validated, imported into the local capability library, reviewed, approved, and enabled in a workspace.

External packages are not native code plugins. ASTRA remains the trusted runtime for policy, credentials, browser adapters, provider launch, and workspace isolation.

## Local Import Rules

When a JSON package is imported from disk, ASTRA treats it as local:

- `sourceMetadata` is reset to the local capability library.
- `governance.approvalStatus` is reset to `draft`.
- `governance.visibility` is reset to `adminOnly`.
- `governance.requiresAdminApproval` is reset to `true`.
- `governance.requiresExplicitUserConsent` is reset to `true`.
- `approvedBy` and `approvedAt` are cleared.

This prevents an external file from declaring itself built-in or approved. Approval is stored separately under channel-specific App Support and is keyed by package ID, version, and canonical package digest.

## Required Fields

```json
{
  "formatVersion": 2,
  "id": "local.example-capability",
  "name": "Example Capability",
  "icon": "puzzlepiece.extension",
  "iconDescriptor": {
    "kind": "systemSymbol",
    "value": "puzzlepiece.extension",
    "fallbackSystemName": "puzzlepiece.extension",
    "monochromePreferred": true
  },
  "description": "Short user-facing summary",
  "author": "Local",
  "category": "Custom",
  "tags": ["example"],
  "version": "1.0.0",
  "setupGuide": "",
  "skills": [],
  "connectors": [],
  "localTools": [],
  "mcpServers": [],
  "templates": [],
  "browserAdapters": [],
  "prerequisites": [],
  "governance": {
    "approvalStatus": "draft",
    "riskLevel": "medium",
    "visibility": "adminOnly",
    "allowedRoles": [],
    "allowedWorkspaceTags": [],
    "requiresAdminApproval": true,
    "requiresExplicitUserConsent": true,
    "dataAccess": [],
    "externalEffects": ["readOnly"],
    "approvedBy": null,
    "approvedAt": null,
    "reviewTicketURL": null,
    "policyNotes": "Local capability pending review."
  }
}
```

`icon` remains the legacy SF Symbol fallback. New packages may also provide
`iconDescriptor`:

- `kind: "systemSymbol"` renders `value` as an SF Symbol.
- `kind: "brand"` renders an app-known brand mark such as `github`, `jira`,
  `googledrive`, `googlecloud`, or `microsoft365`.
- `kind: "asset"` renders a local package asset. `value` must be a relative
  path under `assets/`, such as `assets/icon.svg`.

Every descriptor needs `fallbackSystemName`; ASTRA uses it when the brand or
asset cannot be rendered.

## Package Folders

Single-file JSON packages are still supported:

```text
minimal-skill.json
```

Packages that own icon assets should use a folder:

```text
my-capability/
  capability.json
  assets/
    icon.svg
```

The folder root is the asset root. ASTRA imports the manifest and copies
declared assets into the local capability library. Approval digests include
the manifest plus the declared icon asset bytes, so changing `assets/icon.svg`
invalidates a prior local approval.

## Stable Components

- `skills`: behavior instructions, allowed provider tools, disallowed provider tools, custom tool names, and environment keys.
- `connectors`: credential and config profile shapes. Values are entered later and stored through ASTRA, not in JSON.
- `localTools`: command names and safe default arguments for local CLIs or scripts.
- `mcpServers`: stdio or remote MCP server declarations and tool allow/exclude lists.
- `templates`: task templates.
- `browserAdapters`: IDs for ASTRA-known native browser adapters.
- `prerequisites`: local CLI readiness checks.

### Remote MCP OAuth Contracts

Remote MCP servers that need Google Workspace or another OAuth-backed provider
must declare ASTRA-owned auth and policy metadata, not provider-owned secrets.
ASTRA owns OAuth account identity, requested scopes, consent, audit naming,
tool classification, and generated-app contract IDs.

Providers receive only ASTRA MCP configuration. Generated apps receive stable
contract IDs such as `googleWorkspace.drive.read` or
`googleWorkspace.gmail.send`; they must never receive OAuth tokens, refresh
tokens, raw Google tool names as their authority boundary, or provider-specific
credentials in manifests, prompts, logs, or config files.

Remote registry metadata is contract-only. It does not perform token exchange
or live MCP forwarding:

```json
{
  "id": "google-workspace",
  "displayName": "Google Workspace Remote MCP",
  "transport": "http",
  "url": "https://mcp.astra.local/google-workspace",
  "remoteRegistry": {
    "registryID": "google-workspace",
    "providerID": "googleWorkspace",
    "providerDisplayName": "Google Workspace",
    "tokenDelivery": "astraBrokered",
    "exposesRawProviderToolsToGeneratedApps": false,
    "contractIDs": ["googleWorkspace.drive.read"],
    "toolClassifications": [
      {
        "toolName": "drive.files.list",
        "contractID": "googleWorkspace.drive.read",
        "effect": "read",
        "dataAccess": ["externalService"],
        "riskLevel": "medium",
        "requiresExplicitUserConsent": false,
        "auditEventName": "google.workspace.drive.files.list"
      }
    ],
    "authProfile": {
      "id": "google-workspace-primary",
      "providerID": "googleWorkspace",
      "authorizationKind": "astraOwnedOAuth",
      "consentRequired": true,
      "auditEventNamespace": "google.workspace",
      "scopes": [
        {
          "value": "https://www.googleapis.com/auth/drive.metadata.readonly",
          "purpose": "Read Drive metadata for generated app contract responses.",
          "sensitivity": "restricted",
          "required": true
        }
      ]
    }
  }
}
```

### MCP Control Plane Metadata

Each `mcpServers[]` entry may include optional `controlPlane` metadata. This
metadata keeps the MCP server declaration as the package source of truth while
recording the refs and matrix rows that future runtime PRs need. It is
contract-only in this slice: it does not project provider config, mutate global
provider settings, exchange OAuth tokens, or forward MCP calls.

`controlPlane` separates refs from values:

- `authProfileRefs`: ASTRA-owned auth profile handles and provider IDs.
- `secretRefs`: declared secret handles only. Do not store access tokens,
  refresh tokens, API keys, client secrets, or cookie values here.
- `configRefs`: declared non-secret config handles only.
- `runtimeBindings`: environment/header templates made from literal text plus
  `secretRef`, `configRef`, or `authProfileRef` segments. The template can say
  "Bearer " and reference a token handle; it cannot carry the token value.
- `providerCapabilities`: stable provider capability rows for future capability
  matrices, including contract IDs, availability, required refs, scopes, and
  tool effects.

Example:

```json
{
  "id": "google-workspace",
  "displayName": "Google Workspace Remote MCP",
  "transport": "http",
  "url": "https://mcp.astra.local/google-workspace",
  "controlPlane": {
    "authProfileRefs": [
      {
        "id": "google-workspace-primary",
        "providerID": "googleWorkspace",
        "purpose": "ASTRA-owned OAuth account for Google Workspace MCP.",
        "required": true
      }
    ],
    "secretRefs": [
      {
        "id": "google-workspace-access-token",
        "purpose": "Short-lived access token projected by ASTRA at the gateway boundary.",
        "required": true
      }
    ],
    "configRefs": [
      {
        "id": "google-workspace-domain",
        "purpose": "Optional hosted-domain constraint for policy display.",
        "required": false
      }
    ],
    "runtimeBindings": [
      {
        "id": "google-workspace-authz",
        "destination": "httpHeader",
        "name": "Authorization",
        "logRedaction": "whenReferencesSensitive",
        "template": [
          { "kind": "literal", "literal": "Bearer " },
          {
            "kind": "reference",
            "reference": {
              "kind": "secretRef",
              "id": "google-workspace-access-token"
            }
          }
        ]
      }
    ],
    "providerCapabilities": [
      {
        "id": "drive-files-read",
        "displayName": "Drive files read",
        "contractID": "googleWorkspace.drive.read",
        "availability": "preview",
        "requiredAuthProfileRefs": ["google-workspace-primary"],
        "requiredSecretRefs": ["google-workspace-access-token"],
        "requiredConfigRefs": ["google-workspace-domain"],
        "requiredScopes": [
          {
            "value": "https://www.googleapis.com/auth/drive.metadata.readonly",
            "purpose": "Read Drive metadata for generated app contract responses.",
            "sensitivity": "restricted",
            "required": true
          }
        ],
        "supportedToolEffects": ["read"]
      }
    ]
  }
}
```

Runtime delivery and validation drift evidence are also stable serializable
ASTRACore contracts, but they are not package manifest source of truth. Future
health-check services should store evidence separately and reference package MCP
server IDs by stable ID. Evidence records carry IDs, status enums,
fingerprints, and diagnostic references, not raw provider responses or secret
values.

### MCP Install Sources

Each `mcpServers[]` entry may include optional `installSource` metadata. This
metadata is not executed by the importer. It records where the MCP server comes
from so ASTRA can show policy, readiness, and launch-preflight guidance before
the server is enabled.

Use `command` and `arguments` for the runtime launch contract, and
`installSource` for provenance:

```json
{
  "id": "github",
  "displayName": "GitHub MCP",
  "transport": "stdio",
  "command": "npx",
  "arguments": ["-y", "@acme/github-mcp@1.0.0"],
  "installSource": {
    "kind": "npm",
    "identifier": "@acme/github-mcp",
    "version": "1.0.0",
    "installMode": "npx",
    "registryURL": "https://registry.npmjs.org/",
    "packageManagerArguments": ["-y"],
    "riskNotes": []
  }
}
```

Supported `installSource.kind` values are `npm`, `pypi`, `nuget`, `oci`,
`dockerImage`, `mcpb`, `remoteHTTP`, `localBinary`, and `unknown`. Supported
`installMode` values are `npx`, `uvx`, `pipx`, `dotnetTool`, `dockerGateway`,
`dockerRun`, `globalBinary`, `localBinary`, `remote`, and `manual`.

Prefer exact versions or immutable digests:

- npm: `npx -y @scope/server@1.2.3`
- PyPI/uvx: `uvx mcp-server==1.2.3`
- Docker: `docker run --rm -i ghcr.io/org/server:1.2.3` or a digest-pinned image
- Remote MCP: HTTPS URLs only, except loopback HTTP for local development

Versionless package-manager targets and unpinned Docker images are accepted for
review but surfaced as higher-risk warnings. Remote HTTP URLs outside loopback
are blocked.

## Validation Rules

The importer blocks:

- malformed JSON
- empty or duplicate package IDs
- package ID filename collisions
- invalid semantic versions
- unsafe local tool commands or default arguments
- credentialed connector URLs over remote cleartext HTTP
- unknown browser adapter IDs
- unsafe MCP stdio commands or arguments
- remote MCP URLs that are not HTTPS, except loopback HTTP for local development
- MCP servers requesting environment keys the package does not declare via
  its own connector hints or skill environment keys (prevents a server from
  reading unrelated host secrets)
- MCP server IDs or tool names that break the `mcp__<server>__<tool>`
  permission grammar (no `__`, whitespace, or other separators)
- icon asset paths that are remote, absolute, outside `assets/`, contain path
  traversal, use unsupported extensions, point to symlinks, or exceed 512 KB
- declared icon assets that are missing from a package folder

The importer warns:

- governance is missing
- source metadata was reset to local
- approval was reset to draft
- declared prerequisites are missing locally
- MCP install sources are mutable, unpinned, or otherwise require elevated
  review before approval
- package has no installable payload
- a strictly newer version of an installed local package imports as an
  update: the file is replaced, the package returns to draft, and the
  digest change requires re-approval before it runs again

## Developer Workflow

Validate a package:

```bash
./script/capability_package.sh validate docs/capabilities/examples/minimal-skill.json
```

Validate a package folder:

```bash
./script/capability_package.sh validate capabilities/local/my-capability
```

Validate a repository-level capability library:

```bash
./script/capability_package.sh validate-dir capabilities
```

Install into the development channel:

```bash
./script/capability_package.sh install-dev docs/capabilities/examples/minimal-skill.json
```

Install a package folder and copy its assets into the development channel:

```bash
./script/capability_package.sh install-dev capabilities/local/my-capability
```

Install all valid packages from a repository-level library into the development channel:

```bash
./script/capability_package.sh install-dev-dir capabilities
```

Then open ASTRA Dev, review the imported package in Manage Capabilities, approve it locally, and enable it in the workspace.

`install-dev-dir` validates the entire directory before writing anything. If one package has a blocker, no package from that batch is installed.

## In-App Create Round Trip

The in-app `New Capability` flow uses the same `PluginPackage` schema. When a repository-level `capabilities/` folder is available, the create flow can save the generated package JSON into `capabilities/local/` before installing or enabling it in ASTRA Dev.

Set `ASTRA_CAPABILITY_SOURCE_LIBRARY=/path/to/capabilities/local` to override the source directory used by the app. The exported JSON is always saved as a local draft package; approval records are not written to source JSON.

MCP servers can also start from pasted text. In chat, use `/mcp <target>` or
paste an obvious MCP target; in Manage Capabilities, use `Add MCP Server`.
ASTRA recognizes exact `npx` commands, `npm:` targets, `uvx` commands, Docker
run commands, HTTPS remote MCP URLs, and Claude-style JSON containing a
top-level `mcpServers` object. The paste flow creates a local draft capability
package and opens the same governed review UI as hand-authored package JSON.

## Runtime Boundary

External packages can add data-driven capability behavior. They cannot add new native ASTRA behavior. These require app code changes:

- new browser adapter implementations
- bundled Swift tools
- connector-specific validators
- Keychain storage semantics
- provider runtimes
- app-specific UI beyond the generic import, setup, review, and enable screens
