# ASTRA Capability Library

This folder is the repository-level authoring library for external ASTRA
capabilities. Add capability package JSON files here, validate them, then import
them into the development app's channel-local capability library.

The in-app `New Capability` flow can also save its generated source JSON here
when ASTRA Dev is running from this checkout. Generated packages are saved under
`capabilities/local/` and still need the normal local review/approval step.

Validate every package in this library:

```bash
./script/capability_package.sh validate-dir capabilities
```

Install every valid package into ASTRA Dev:

```bash
./script/capability_package.sh install-dev-dir capabilities
```

ASTRA installs validated packages into:

```text
~/Library/Application Support/AstraDev/Capabilities
```

The JSON files in this folder are source packages. They do not become runnable
until ASTRA imports them, resets them to local draft governance, and a local
admin reviews and approves them in the app.

Suggested layout:

```text
capabilities/
  examples/       Sample packages that should stay small and safe.
  local/          User-authored packages for this checkout.
  community/      Shared packages proposed for broader use.
```

External packages can define skills, connector profiles, local tool commands,
MCP server declarations, prerequisites, templates, and known ASTRA browser
adapter IDs. They cannot add native Swift code or new browser/provider runtime
implementations.
