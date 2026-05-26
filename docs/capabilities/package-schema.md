# Capability Package Schema

ASTRA external capabilities are JSON files that decode as `PluginPackage` v2 packages. They can be authored outside the app, validated, imported into the local capability library, reviewed, approved, and enabled in a workspace.

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

## Stable Components

- `skills`: behavior instructions, allowed provider tools, disallowed provider tools, custom tool names, and environment keys.
- `connectors`: credential and config profile shapes. Values are entered later and stored through ASTRA, not in JSON.
- `localTools`: command names and safe default arguments for local CLIs or scripts.
- `mcpServers`: stdio or remote MCP server declarations and tool allow/exclude lists.
- `templates`: task templates.
- `browserAdapters`: IDs for ASTRA-known native browser adapters.
- `prerequisites`: local CLI readiness checks.

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

The importer warns:

- governance is missing
- source metadata was reset to local
- approval was reset to draft
- declared prerequisites are missing locally
- package has no installable payload

## Developer Workflow

Validate a package:

```bash
./script/capability_package.sh validate docs/capabilities/examples/minimal-skill.json
```

Validate a repository-level capability library:

```bash
./script/capability_package.sh validate-dir capabilities
```

Install into the development channel:

```bash
./script/capability_package.sh install-dev docs/capabilities/examples/minimal-skill.json
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

## Runtime Boundary

External packages can add data-driven capability behavior. They cannot add new native ASTRA behavior. These require app code changes:

- new browser adapter implementations
- bundled Swift tools
- connector-specific validators
- Keychain storage semantics
- provider runtimes
- app-specific UI beyond the generic import, setup, review, and enable screens
