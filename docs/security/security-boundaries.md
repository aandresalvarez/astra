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
- Credentialed connectors must use HTTPS for remote services. Loopback HTTP is
  allowed only for local development or localhost services.
- The Shelf browser bridge listens only on `127.0.0.1`, but localhost is still a
  shared machine boundary. Bridge requests require a per-session token.
- Development and production channels must keep app support, workspace roots,
  Keychain namespaces, and update behavior separate.
- Runtime readiness, diagnostics, and logs may receive credential-looking
  provider output and must avoid persisting secret values.

## Repeatable Checks

Run the security hunt script for a focused pass:

```bash
./script/security_hunt.sh
```

For manual red-team checks, use only the development app. Seed fake values such
as `ASTRA_TEST_SECRET_123`, attempt workspace escapes via `..` and symlinks,
exercise restricted agent runs that try `rm`, `sudo`, outside-workspace writes,
multi-URL `curl` commands, denied URL patterns, imported unsafe local tools,
credentialed HTTP connector URLs, and unexpected network destinations, then
verify ASTRA blocks the action without leaking the fake secret in task events,
diagnostics, or app logs.
