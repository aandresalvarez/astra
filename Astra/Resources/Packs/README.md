# ASTRA Packs

This directory contains bundled ASTRA pack manifests and pack-owned supporting
assets.

Packs are declarative product profiles. They can reference existing capability
packages, choose default native shelves, contribute App Studio template
metadata, provide vocabulary, and apply restrict-only policy. They do not load
runtime Swift, SwiftUI, shell, MCP, browser, or plugin code.

Authoring and architecture references from the repository root:

- `docs/architecture/astra-packs.md`
- `docs/capabilities/astra-pack-authoring.md`

The canonical bundled example is `devops-pack.json` with supporting assets under
`devops/`.
