# ASTRA Agent Guide

This repo is a SwiftPM macOS app. Follow these rules when working as a coding
agent in this checkout.

## App Channels

ASTRA has separate development and production identities. Keep them separate.

| Channel | App | Bundle ID | App Support | Workspaces | Updates |
| --- | --- | --- | --- | --- | --- |
| Development | `ASTRA Dev.app` | `com.coral.ASTRA.dev` | `~/Library/Application Support/AstraDev` | `~/Documents/Astra Dev/Workspaces` | Disabled |
| Production | `ASTRA.app` | `com.coral.ASTRA` | `~/Library/Application Support/Astra` | `~/Documents/Astra/Workspaces` | Sparkle |

Default local builds use the development channel:

```bash
./script/build_and_run.sh
```

This creates and opens:

```text
dist/ASTRA Dev.app
```

Use the production channel only for release/update validation:

```bash
ASTRA_CHANNEL=prod ./script/build_and_run.sh --verify
```

This creates and opens:

```text
dist/ASTRA.app
```

Do not test normal feature work against production data. The development app is
isolated specifically so the user's real ASTRA work, Keychain items, App Support
store, and workspaces are not affected by active development.

## Branch Cycle

Start feature work from current `main`:

```bash
git switch main
git pull --ff-only origin main
git switch -c codex/<feature-name>
```

Keep changes focused. Prefer the app's existing SwiftUI and service patterns.
After implementing, run the narrowest meaningful test first, then broaden as
risk increases.

Common checks:

```bash
swift test --filter <RelevantSuiteOrTestName>
./script/build_and_run.sh --verify
git diff --check
```

For shared behavior, persistence, updater, or release changes, run full tests:

```bash
swift test
```

Push feature branches and open draft PRs unless the user asks otherwise:

```bash
git push -u origin codex/<feature-name>
```

## Sparkle Release Cycle

Internal testing uses zero Apple cost:

- ad-hoc macOS code signing
- Sparkle EdDSA signatures
- GitHub Release assets
- no App Store
- no Apple Developer ID
- no notarization

The Sparkle private key lives in the user's login Keychain. The public key can
be printed with:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
```

Release builds should use the public key from Keychain:

```bash
SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY="$($SPARKLE_BIN/generate_keys -p)"

ASTRA_VERSION=0.1.1 \
ASTRA_BUILD=2 \
ASTRA_SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
SPARKLE_GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast" \
./script/release_update.sh
```

Upload both release assets:

```text
dist/release/ASTRA-<version>.zip
dist/release/appcast.xml
```

Sparkle checks:

```text
https://github.com/susom/astra/releases/latest/download/appcast.xml
```

To see the update button, the installed production app must have a lower
`CFBundleVersion` than the latest appcast. If the local production bundle was
rebuilt to the latest version, Sparkle will correctly report that ASTRA is up to
date.

Never commit or disclose the Sparkle private key. Only the public
`SUPublicEDKey` belongs in app metadata.

## Workspace Import

`Import Workspace` accepts folders, config files, or a parent `Workspaces`
folder. A selected parent named `Workspaces` expands into direct child
workspaces. Discovery supports:

- `.astra-workspace.json`
- `.agentflow-workspace.json`
- `.astra`
- `.agentflow`
- `.claude`
- `tasks`
- `memory.md`
- `ssh-connections.json`

Keep this behavior in mind when changing workspace import, recovery, or
persistence code.
