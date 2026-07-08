# ASTRA Agent Guide

This repo is a SwiftPM macOS app. Follow these rules when working as a coding
agent in this checkout.

## Architecture Principles

- Treat durable ASTRA domain state as the source of truth. SwiftData models,
  task events, run records, and task-folder state such as `current_state.json`
  should own persisted behavior; derive UI, prompt, provider, and generated-file
  views from those owners through services or policies.
- Avoid creating a second mutable owner for the same behavior. Derived caches
  and presentation state are acceptable only when their source, refresh path, and
  invalidation behavior are clear and testable.
- Prefer explicit event- and service-driven workflows over hidden background
  behavior. Workflow-changing task, run, plan, validation, permission, and
  artifact transitions should be recorded through typed services and durable
  events, with logging and regression coverage.
- Use background scans, timers, and view lifecycle tasks only for observable,
  idempotent refresh work. They should not silently change domain state without
  an explicit service boundary, error handling, and tests.

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

For UI and design work, read `docs/design-system/lean-ui-system.md` first. It
captures ASTRA's lean operational design language: one card boundary, grouped
status, scan-first rows, progressive disclosure, and inline editing only after
expansion. Use it as the baseline unless the target surface clearly needs a
different pattern.

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

Install the repo hooks once per clone so local commits run the same lightweight
guardrails that agents are expected to respect:

```bash
git config core.hooksPath .githooks
```

The pre-commit hook runs `script/precommit.sh`, which checks
`ArchitectureFitnessTests` and whitespace. The pre-push hook runs
`script/prepush.sh`, which adds focused runtime, persistence, and adapter
regression suites before allowing a push.

Push feature branches and open draft PRs unless the user asks otherwise:

```bash
git push -u origin codex/<feature-name>
```

## Repository Protections

`main` should be protected by GitHub branch protection. Apply the current repo
default with:

```bash
script/configure_branch_protection.sh
```

The protection requires pull requests, one code-owner review for non-admin
merges, stale-review dismissal, resolved conversations, no force-pushes, no
branch deletion, and the required status checks from `.github/workflows/ci.yml`:

- `Focused Swift tests`
- `Whitespace`

Changes to runtime, persistence, models, package metadata, scripts, GitHub
configuration, hooks, or architecture fitness tests are covered by
`.github/CODEOWNERS` and should receive explicit owner review. Branch
protection does not enforce these rules for repository admins so the owner can
merge without an additional reviewer when intentionally choosing to do so. Do
not use that bypass for agent-authored changes unless the repository owner
explicitly directs it.

## Sparkle Release Cycle

Internal testing (`ASTRA_RELEASE_MODE=internal`, the default) uses zero Apple cost:

- ad-hoc macOS code signing
- Sparkle EdDSA signatures
- GitHub Release assets
- no App Store
- no Apple Developer ID
- no notarization

A Developer ID + notarization path also exists (`ASTRA_RELEASE_MODE=developer-id`)
and is validated live end to end, including the ad-hoc→Developer-ID Sparkle
update transition for existing installs — see
[docs/code-signing.md](docs/code-signing.md) and
[docs/specs/2026-07-07-apple-developer-program-adoption-plan.md](docs/specs/2026-07-07-apple-developer-program-adoption-plan.md).
It requires a Developer ID identity + notary credentials, so `internal` stays
the zero-cost default for day-to-day testing.

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

Upload all three release assets:

```text
dist/release/ASTRA-<version>.zip
dist/release/ASTRA-<version>.dmg
dist/release/appcast.xml
```

The `.zip` is Sparkle's update payload; the `.dmg` is the human-facing
download (double-click-to-mount, app + Applications-folder shortcut side by
side) -- point download links at the `.dmg`, not the `.zip`.

Sparkle checks:

```text
https://github.com/aandresalvarez/astra/releases/latest/download/appcast.xml
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
