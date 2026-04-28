# Stanford ASTRA

Welcome to ASTRA: a Stanford-inspired macOS app for supervising delegated AI work.

ASTRA stands for **Agent Scheduler for Tasks, Runs, and Automation**. It helps you create durable workspaces, assign AI-powered tasks, review what changed, and decide when an agent should keep going, pause, or ask for help.

ASTRA is built around a simple idea:

> You should supervise meaningful work, not babysit raw transcripts.

## What ASTRA Does

ASTRA is a command center for agentic work on your Mac:

- Create workspaces that behave like durable software agents.
- Queue, run, resume, and review tasks across projects.
- Connect skills, tools, and local CLIs through a plugin catalog.
- Track runs, events, artifacts, logs, schedules, and task history.
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
- Claude CLI installed and authenticated
- Optional local CLIs for specific plugins, such as Docker or gcloud

The first-run onboarding flow checks the Claude CLI and helps choose a workspace root.

## Getting Started

Build the app:

```bash
swift build
```

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
SPARKLE_ED_KEY_FILE=/path/to/private-key \
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

If the project later needs the smoother Gatekeeper experience, use:

```bash
ASTRA_RELEASE_MODE=developer-id ./script/release_update.sh
```

That future path requires Apple Developer ID signing and notarization.

## Project Structure

```text
Astra/          SwiftUI app, views, services, models, resources, and assets
ASTRACore/      Shared core utilities, protocols, parsing, validation, and plugin types
AppExecutable/  Executable entry point for the Swift package
Tests/          Unit and integration tests
ASTRAUITests/   UI test target
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

For UI or workflow changes, also launch the app and exercise the affected flow:

```bash
./script/build_and_run.sh --verify
```

Keep changes focused, match the existing SwiftUI patterns, and prefer small product surfaces that make supervision easier.

## Current Status

ASTRA is under active development. The repository includes the SwiftUI macOS app, persistent SwiftData models, task scheduling, Claude CLI execution, plugin and skill management, onboarding, logging, and a growing test suite.

The long-term direction is a polished supervision system where people can confidently delegate work to durable software operators and stay in control of the important decisions.
