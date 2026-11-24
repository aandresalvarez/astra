# Archived capabilities

These capability packages used to ship with ASTRA. They are archived here, out
of the app bundle, because nobody was using them, and each one shipped is one
more thing to support. Bring one back when someone needs it.

| Package | Why archived (2026-11-23) |
| --- | --- |
| `security-auditor.json` | Never enabled in any workspace. |
| `stanford-apple-mail.json` | Enabled in one workspace; its tool was never called. |
| `stanford-healthcare-graph-mail.json` | Enabled in one workspace; its tool was never called. |
| `google-workspace.json` | Never enabled; no Google account was connected. |
| `google-drive-browser.json` | Enabled in one workspace; unused since June 2026. |

## What archiving does

- The app no longer bundles the package, so it is not offered in the gallery
  and is never loaded into a run.
- On the next launch `CapabilityLibrary.syncApprovedPackages` deletes the
  installed copy in App Support (it drops built-in packages that left the
  catalog).
- On the same launch `RetiredBuiltInActivationCleanup` retires any workspace
  activation of an archived package through the normal Remove, keeping its
  settings for a later Add. Left enabled without its definition, it would stop
  every new task in that workspace at preflight. Add a package's ID to
  `retiredBuiltInIDs` when you archive it.
- The supporting code stays: the Stanford mail tools (`Tools/StanfordAppleMailTool`,
  `Tools/StanfordGraphMailTool`), Google Workspace OAuth and remote MCP
  planning, and the Google Drive browser adapter. Archive those separately if
  they should stop shipping too.

## Bringing one back

1. Move the JSON back to `Astra/Resources/Capabilities/` and bump its
   `version`, and take its ID out of
   `RetiredBuiltInActivationCleanup.retiredBuiltInIDs` (the cleanup already
   skips an ID with a definition, but the list should say what is retired).
2. If the package used to have an in-code copy in
   `PluginCatalog.fallbackBuiltInPackages` (Security Auditor and Google Drive
   Browser did), restore it from git history so the fallback matches.
3. Restore the tests that pinned it (`git log -- capabilities/archived/<id>.json`
   leads to the archiving commit), and run the capability suites.

A workspace that removed the package keeps its retired activation, so adding
the package back restores its settings and templates.

`google-workspace.json` and `google-drive-browser.json` point at
`assets/google-drive.svg`, which still lives in
`Astra/Resources/Capabilities/assets/`.
