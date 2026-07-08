# Stanford ASTRA

Welcome to ASTRA: a Stanford-inspired macOS app for supervising delegated AI work.

ASTRA stands for **Agent Routines for Tasks, Runs, and Automation**. It helps you create durable workspaces, assign AI-powered tasks, review what changed, and decide when an agent should keep going, pause, or ask for help.

ASTRA is built around a simple idea:

> You should supervise meaningful work, not babysit raw transcripts.

## Value Proposition

ASTRA helps technical leaders adopt AI agents without losing operational
control. It turns ad hoc AI chat sessions into durable, supervised workspaces
where teams can assign work, preserve context, review evidence, and decide when
an agent should continue, pause, or ask for help.

For decision-makers, the value is straightforward:

- Increase engineering throughput by delegating repeatable work to AI agents.
- Reduce supervision cost by showing plans, outcomes, artifacts, and blockers
  before raw transcripts.
- Lower adoption risk with visible permissions, policies, prerequisites, logs,
  and trust signals.
- Preserve institutional context through workspace memory, task history,
  schedules, tools, and generated artifacts.
- Keep work local and auditable on macOS while supporting provider CLIs such as
  Claude Code and GitHub Copilot CLI.

The outcome is not just a better AI interface. ASTRA is an accountability layer
for AI-assisted work: it helps teams move faster while keeping humans in control
of important decisions.

## What ASTRA Does

ASTRA is a command center for agentic work on your Mac:

- Create workspaces that behave like durable software agents.
- Queue, run, resume, and review tasks across projects.
- Connect skills, tools, and local CLIs through a plugin catalog.
- Track runs, events, artifacts, logs, routines, and task history.
- Validate local prerequisites before agents start doing work.
- Keep the interface calm, readable, and grounded in a Stanford-inspired visual system.

The product model is:

```text
agent -> delegated work -> supervision
```

Tasks may begin as a simple request, but ASTRA keeps the surrounding context: workspace memory, access, schedules, tools, policies, artifacts, and trust signals.

## Requirements

- macOS 14 or newer
- Xcode or the Swift 5.10 toolchain
- At least one supported provider CLI installed and authenticated: Claude Code
  or GitHub Copilot CLI
- Optional local CLIs for specific plugins, such as Docker or gcloud

The first-run onboarding flow checks the selected provider CLI and helps choose
a workspace root.

## Getting Started

Build the app:

```bash
swift build
```

ASTRA is packaged as an Apple-Silicon-only macOS app. The bundle helper verifies
that it is running from a native `arm64` shell and that bundled executables are
`arm64`.

Run the test suite:

```bash
swift test
```

Build and launch a macOS app bundle:

```bash
./script/build_and_run.sh
```

Useful launch modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

Local development builds are isolated from the production app by default:

```bash
./script/setup_local_channels.sh
./script/build_and_run.sh
```

The local script launches `ASTRA Dev` with bundle ID `com.coral.ASTRA.dev`,
separate App Support, logs, Keychain namespace, and
`~/Documents/Astra Dev/Workspaces`. Production releases keep `ASTRA`,
`com.coral.ASTRA`, and `~/Documents/Astra/Workspaces`.

## Development vs Production App

ASTRA intentionally has two local app identities so you can develop the app while
also using the real production copy for work.

| Channel | App | Bundle ID | Workspaces | App Support | Updates |
| --- | --- | --- | --- | --- | --- |
| Development | `ASTRA Dev.app` | `com.coral.ASTRA.dev` | `~/Documents/Astra Dev/Workspaces` | `~/Library/Application Support/AstraDev` | Disabled |
| Production | `ASTRA.app` | `com.coral.ASTRA` | `~/Documents/Astra/Workspaces` | `~/Library/Application Support/Astra` | Sparkle |

Day-to-day development should use the development channel:

```bash
./script/build_and_run.sh
```

That builds and launches:

```text
dist/ASTRA Dev.app
```

Use the production channel only when testing release/update behavior:

```bash
ASTRA_CHANNEL=prod ./script/build_and_run.sh --verify
```

That builds and launches:

```text
dist/ASTRA.app
```

The production app is the only channel that talks to the Sparkle appcast. The
development app never checks for updates, never writes production App Support
data, and never uses the production Keychain namespace.

If you want to verify the updater, the installed production app must have a
lower `CFBundleVersion` than the GitHub Release appcast. For example, a local
`ASTRA 0.1.0 (1)` build can discover and install `ASTRA 0.1.1 (2)`, but a local
`ASTRA 0.1.1 (2)` build correctly reports that it is already up to date.

## Testing App Intents and Voice Commands

ASTRA exposes in-app App Intents for opening workspaces and tasks, continuing
the latest unfinished task in a named workspace, creating draft tasks, and
explicitly creating and running a task. Test these against `ASTRA Dev` unless
you are deliberately validating production behavior.

First run the normal build and routing checks:

```bash
./script/build_and_run.sh --verify
swift test --filter AstraExternalRoutingTests
```

The development bundle registers the `astra-dev` URL scheme. After launching
`ASTRA Dev`, get a workspace ID from one dev workspace config:

```bash
WORKSPACE_CONFIG=$(find "$HOME/Documents/Astra Dev/Workspaces" -name .astra-workspace.json | head -n 1)
WORKSPACE_ID=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORKSPACE_CONFIG")
echo "$WORKSPACE_ID"
```

Then test direct routes:

```bash
open "astra-dev://workspace/$WORKSPACE_ID"
open "astra-dev://create-task?workspace=$WORKSPACE_ID&goal=Test%20draft%20task%20from%20URL&run=0"
open "astra-dev://continue?workspace=$WORKSPACE_ID"
```

Public `create-task` URLs always create drafts. Recognized immediate-run query
values such as `run=1` and `run=true` are ignored unless a route-local
authorization mechanism is added later.

To test Shortcuts or voice, open the macOS Shortcuts app, create a new
shortcut, and search for `ASTRA` or `ASTRA Dev`. The expected actions are:

- `Open ASTRA Workspace`
- `Open ASTRA Task`
- `Continue ASTRA Task`
- `Create ASTRA Task`
- `Create and Run ASTRA Task`

Useful voice phrases:

```text
Create an ASTRA task in <workspace name>
Create and run an ASTRA task in <workspace name>
Continue my unfinished ASTRA task in <workspace name>
Open my ASTRA task
```

If the actions do not appear in Shortcuts, launch `dist/ASTRA Dev.app` once,
quit it, and reopen Shortcuts so macOS refreshes the app shortcut metadata.

## Development Cycle

Use this cycle for normal feature work:

1. Start from current `main`.

```bash
git switch main
git pull --ff-only origin main
git switch -c codex/<feature-name>
```

2. Build and run the isolated development app.

```bash
./script/build_and_run.sh --verify
```

3. Add focused tests for the changed behavior.

```bash
swift test --filter <RelevantSuiteOrTestName>
```

4. Run broader checks when the change touches shared behavior.

```bash
swift test
git diff --check
```

5. Push the branch and open a draft PR.

```bash
git push -u origin codex/<feature-name>
```

Do not develop against the production app unless the work is specifically about
release packaging, Sparkle, production data paths, or update behavior.

## Internal Test Releases

ASTRA can be distributed internally with zero Apple cost during testing. The
release helper defaults to this mode:

```bash
/path/to/Sparkle/bin/generate_keys
```

Copy the printed public key into `ASTRA_SPARKLE_PUBLIC_ED_KEY`. Keep the private
key in your login Keychain, or export it and pass it to the release helper with
`SPARKLE_ED_KEY_FILE=/path/to/private-key`.

```bash
ASTRA_VERSION=0.1.0 \
ASTRA_BUILD=1 \
ASTRA_SPARKLE_PUBLIC_ED_KEY="..." \
SPARKLE_GENERATE_APPCAST=/path/to/Sparkle/bin/generate_appcast \
./script/release_update.sh
```

This produces:

```text
dist/release/ASTRA-0.1.0.zip
dist/release/appcast.xml
```

The internal release path uses ad-hoc macOS code signing plus Sparkle EdDSA
update signatures. It does not require the Mac App Store, Apple Developer
Program, Developer ID, or notarization. The tradeoff is trust UX: the first
manual install on each Mac may require a right-click Open or Security & Privacy
approval because Apple has not notarized the app. After the app is trusted,
Sparkle can handle signed updates from the appcast.

The current release command should normally read the public key from Keychain:

```bash
SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY="$($SPARKLE_BIN/generate_keys -p)"

ASTRA_VERSION=0.1.1 \
ASTRA_BUILD=2 \
ASTRA_SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
SPARKLE_GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast" \
./script/release_update.sh
```

Then upload both generated files to the GitHub Release:

```text
dist/release/ASTRA-<version>.zip
dist/release/appcast.xml
```

Sparkle reads the appcast from:

```text
https://github.com/aandresalvarez/astra/releases/latest/download/appcast.xml
```

The private Sparkle key stays in Keychain. Do not commit or paste the private
key into GitHub. The public key is safe to embed in `Info.plist`.

For the smoother Gatekeeper experience (no unidentified-developer warning), use:

```bash
ASTRA_RELEASE_MODE=developer-id ./script/release_update.sh
```

This requires a paid Apple Developer Program membership; the project has one
and this path is validated live — notarization, stapling, Gatekeeper
acceptance, and the ad-hoc→Developer-ID Sparkle update transition have all
been tested end to end. It isn't the default yet because it needs a real
Developer ID identity and notary credentials on the machine (or in CI
secrets — see Phase 4). Full details, live-validation results, and adoption
sequencing are tracked in
[docs/specs/2026-07-07-apple-developer-program-adoption-plan.md](docs/specs/2026-07-07-apple-developer-program-adoption-plan.md).

For the full code-signing setup — including a stable self-signed identity for
local development (which avoids the Keychain re-prompts that ad-hoc signing
causes on every rebuild) and the Developer ID + notarization steps — see
[docs/code-signing.md](docs/code-signing.md).

## Project Structure

```text
Astra/          SwiftUI app, views, services, models, resources, and assets
ASTRACore/      Shared core utilities, protocols, parsing, validation, and plugin types
AppExecutable/  Executable entry point for the Swift package
Tests/          Unit and integration tests
docs/           Product specs, design reviews, and icon iterations
script/         Local build and launch helpers
```

## Core Concepts

**Workspace**

A durable agent context. A workspace owns memory, skills, connectors, local tools, task history, and schedules.

**Task**

A bounded unit of delegated work. Tasks can be drafted, queued, running, waiting on the user, completed, failed, cancelled, or over budget.

**Run**

A single execution attempt for a task. Runs are useful for diagnostics, cost, retry behavior, and audit history.

**Artifact**

A visible output of work, such as a changed file, note, report, or generated result.

**Skill, Connector, Tool**

The capability layer that decides what an agent can do and how it should behave while doing it.

## Design Direction

ASTRA uses a Stanford-inspired identity layer with cardinal red, lagunita teal, restrained neutrals, and brand typography helpers. The interface should feel calm, practical, and trustworthy:

- Prioritize next actions over raw logs.
- Show plans, outcomes, and evidence before transcripts.
- Surface approvals and blocked work clearly.
- Keep debugging detail available without making it the default experience.
- Make trust, permissions, and local environment health visible.

## Contributing

Before opening a change:

```bash
swift test
```

Install repo-managed git hooks once per clone:

```bash
git config core.hooksPath .githooks
```

The pre-commit hook runs the architecture fitness suite and whitespace check.
The pre-push hook adds focused runtime, persistence, and adapter regression
suites. GitHub CI also requires `Focused Swift tests` and `Whitespace` checks on
protected branches. Repository admins can apply the default `main` branch
protection with:

```bash
script/configure_branch_protection.sh
```

Default tests do not call account-backed provider CLIs. To run live provider
integration checks, including Claude/Copilot smoke paths, opt in explicitly:

```bash
RUN_PROVIDER_INTEGRATION=1 swift test --filter IntegrationTests
RUN_REAL_PROVIDERS=1 swift test --filter RealProviderSmokeTests
```

For provider stream debugging, launch ASTRA with `ASTRA_STREAM_DEBUG=1`. Normal
runs keep only compact counters; debug mode adds bounded raw stream samples,
unknown JSON shapes, stderr tail, and timing to the task log.

In Instruments, filter the `Performance` signpost category for
`process_stream_line`, `parse_provider_stream`, `persist_provider_event`,
`build_thread_snapshot`, and `render_task_thread` to isolate stream-to-render
latency.

For UI or workflow changes, also launch the app and exercise the affected flow:

```bash
./script/build_and_run.sh --verify
```

Keep changes focused, match the existing SwiftUI patterns, and prefer small product surfaces that make supervision easier.

## Current Status

ASTRA is under active development. The repository includes the SwiftUI macOS app, persistent SwiftData models, task scheduling, provider-agnostic CLI execution, plugin and skill management, onboarding, logging, and a growing test suite. Claude Code and GitHub Copilot CLI are supported today, with the runtime registry shaped so additional providers such as Codex and Gemini CLIs can be added deliberately.

The long-term direction is a polished supervision system where people can confidently delegate work to durable software operators and stay in control of the important decisions.
