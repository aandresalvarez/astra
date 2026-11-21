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
script/swift_test.sh --filter <RelevantSuiteOrTestName>
./script/build_and_run.sh --verify
git diff --check
```

Do not run the full suite locally as a routine check. GitHub runs it on every
pull request as the required `Full Swift test suite` check, so a local run
repeats that check, takes close to an hour, and loads the machine the owner is
working on. For shared behavior, persistence, updater, or release changes,
widen the focused filter to the suites that cover the change, then let CI run
the full suite.

Run the full suite locally only when the owner asks for it, when CI is
unavailable, or to reproduce a failure that CI reported and a focused run does
not show. Tell the owner before starting one, and never run two at once:

```bash
script/swift_test.sh --no-parallel
```

The wrapper starts a private, synchronous permission-command harness before SwiftPM.
Real repair tests fail explicitly without it; they are never silently skipped.
This isolates their process launches from Swift Testing after reproducible local
kernel panics in `Process.run()`. It mitigates that trigger, not the OS defect.

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

When the PR is ready, follow "Merging Agent PRs" below instead of waiting for
the owner to click merge.

## Repository Protections

`main` should be protected by GitHub branch protection. Apply the current repo
default with:

```bash
script/configure_branch_protection.sh
```

The protection requires pull requests, an up-to-date branch, resolved
conversations, stale-review dismissal, no force-pushes, no branch deletion, and
the required status checks from `.github/workflows/ci.yml`:

- `Focused Swift tests`
- `Full Swift test suite`
- `Whitespace`

No general approval is required. Only PRs that touch a path in
`.github/CODEOWNERS` need a code-owner approval: SwiftData models and schemas,
persistence and Keychain, package metadata, CI, hooks, the guardrail and release
scripts, and the fitness tests that pin them. Keep that list narrow; adding a
broad source folder puts the owner back in front of every agent PR.

## Merging Agent PRs

A PR that does not touch a CODEOWNERS path merges itself once it is ready.
When the work is done, local checks pass, and every review comment is fixed or
answered and resolved:

```bash
gh pr ready <number>
gh pr merge <number> --auto --squash
```

GitHub then merges when all required checks are green and the branch is up to
date. If another merge leaves the branch behind `main`, update it and let CI
re-run; auto-merge stays armed:

```bash
gh pr update-branch <number>
```

Leave the PR as a draft, and do not arm auto-merge, when the user asked to
review it first, when it is a schema or data migration, or when its own checks
were skipped or failed. Fix a red check by pushing a new commit, never by
merging around it.

Never pass `--admin` to `gh pr merge` and never merge a PR whose required checks
are not green. Branch protection does not bind repository admins
(`enforce_admins: false`), and agents running with the owner's token are admins,
so this rule is the only thing stopping that bypass. A PR that touches a
CODEOWNERS path waits for the owner's approval or the owner's own merge.

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

Upload the release assets:

```text
dist/release/ASTRA.dmg
dist/release/ASTRA-<version>.zip
dist/release/ASTRA-<version>.dmg
dist/release/appcast.xml
```

The `.zip` is Sparkle's update payload; `ASTRA.dmg` is the stable
human-facing download URL; `ASTRA-<version>.dmg` is the versioned archival
copy. Point public download links at `ASTRA.dmg`, not the `.zip`.

```text
https://github.com/aandresalvarez/astra/releases/latest/download/ASTRA.dmg
```

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
