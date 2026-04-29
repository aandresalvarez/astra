# Approved Capabilities

This folder is the repo-maintained source for ASTRA's approved built-in capability catalog.

Each JSON file is a `PluginPackage` v2 capability package. Capabilities can include the connectors, local tools, skills, prerequisites, and setup text needed to enable that capability in a workspace.

The development app seeds these files into:

```text
~/Library/Application Support/AstraDev/Capabilities
```

The production app seeds them into:

```text
~/Library/Application Support/Astra/Capabilities
```

To add or update an approved capability, edit or add a JSON file here. Removing a built-in JSON file removes that built-in package from the seeded app-local capability catalog on the next launch or catalog refresh.
