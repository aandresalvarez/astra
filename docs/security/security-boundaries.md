# ASTRA Security Boundaries

This note captures the local security boundaries that should be exercised before
release validation. Normal security testing should use the development channel:
`ASTRA Dev.app`, `com.coral.ASTRA.dev`, `~/Library/Application Support/AstraDev`,
and `~/Documents/Astra Dev/Workspaces`.

## Assets

- Keychain-backed connector and skill secrets.
- Workspace files and imported workspace metadata.
- App Support stores, logs, task events, and exported workspace config.
- Agent runtime policy manifests and provider stream output.
- Installed capability package JSON and local tool definitions.
- Capability approval records and package digests.
- First-class MCP server declarations and runtime MCP manifests.
- Sparkle update metadata and public EdDSA key in production bundles.
- Authenticated browser content exposed through the Shelf browser bridge.

## Trust Boundaries

- User-selected files and folders enter through workspace import discovery and
  must not traverse or symlink into unrelated locations.
- Imported workspace configs are untrusted. The selected config folder is the
  authority for the workspace primary path, and imported connector/tool
  definitions must pass the same safety gates as installed capabilities.
- Agent runtimes can report tool use, file paths, shell commands, and network
  destinations; ASTRA's policy guard must enforce the run manifest across every
  observed URL, not just the first URL in a shell command.
- Capability packages can define skills, connectors, and local tools; package
  IDs, tool commands, default arguments, connector URLs, and browser adapters
  must be treated as untrusted input.
- Capability packages can also define MCP servers. Stdio MCP commands and
  arguments must pass the same local command safety policy as local tools.
  Remote MCP endpoints must use HTTPS, except loopback HTTP for local
  development.
- Catalog policy is a security boundary. A package must be visible, installable,
  enableable, and runnable for the current workspace context before it can
  affect a task. Approval, risk, visibility, dependency, conflict, unsafe local
  tool, unsafe connector, unsafe MCP, and digest-mismatch decisions must stay in
  the centralized policy evaluator.
- Local approval records are durable channel-specific state, separate from
  package JSON. They are keyed by package ID, version, and canonical source
  digest. A package content change must invalidate the prior approval and force
  re-review before enablement or runtime launch.
- Generated skills, connectors, local tools, and templates must carry origin
  metadata. Disable and uninstall flows should remove package-owned resources by
  origin first so a package cannot claim or delete another package's resources by
  name alone.
- Credentialed connectors must use HTTPS for remote services. Loopback HTTP is
  allowed only for local development or localhost services.
- Connectors are credential and configuration profiles, not execution surfaces.
  Execution must happen through ASTRA platform tools, local tools, browser
  bridge actions, or catalog-approved MCP servers.
- The Shelf browser bridge listens only on `127.0.0.1`, but localhost is still a
  shared machine boundary. Bridge requests require a per-session token.
- Browser control remains an ASTRA-owned platform capability. Package
  `browserAdapters` are catalog-gated site-specific helpers and must not bypass
  the task-bound Shelf browser bridge token.
- Development and production channels must keep app support, workspace roots,
  Keychain namespaces, and update behavior separate.
- Runtime readiness, diagnostics, and logs may receive credential-looking
  provider output and must avoid persisting secret values.
- Runtime permission manifests may list environment key names, credential
  labels, and MCP server IDs, but must not persist credential values or MCP
  environment values.

## Repeatable Checks

Run the security hunt script for a focused pass:

```bash
./script/security_hunt.sh
```

For manual red-team checks, use only the development app. Seed fake values such
as `ASTRA_TEST_SECRET_123`, attempt workspace escapes via `..` and symlinks,
exercise restricted agent runs that try `rm`, `sudo`, outside-workspace writes,
multi-URL `curl` commands, denied URL patterns, imported unsafe local tools,
credentialed HTTP connector URLs, unsafe MCP commands, digest-mismatched
approval records, origin-collision package resources, blocked governance status,
unknown browser adapter IDs, and unexpected network destinations, then
verify ASTRA blocks the action without leaking the fake secret in task events,
diagnostics, or app logs.
