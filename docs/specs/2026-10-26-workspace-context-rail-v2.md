# Workspace Context rail v2: presence, not progress

Status: **proposal, 2026-10-26, rev 2.** Rev 2 records the owner's first
decision: the boxes stay as they are today (subtle fill, 1 px stroke), and a
box exists only when it has content, never as an empty bar. Written after a
read of the rail on
`claude/astra-right-panel-redesign-7eca20` (branched from `main` at
`8dd383cd`), the lean UI system doc, and a comparison with the right panels of
Claude Code (desktop) and OpenAI Codex. Nothing here is implemented yet. The
visual mockup that accompanies this spec renders the current rail next to the
proposed one at real point sizes, with the attention, collapsed, and expanded
states: <https://claude.ai/artifact/7akz1XR2iWF4VgUQTVstRP> (private; share
from the page's Share menu).

## Why

The owner's reading of the current rail, which this spec agrees with:

- It is big and heavy. Three framed cards, each with a title, group labels,
  two-line rows of 56 to 60 pt, and accent-coloured verbs, spend about 630 pt
  of a 392 pt wide column on four facts (instructions are set, two capabilities
  are ready, memory is empty), then leave the rest of the column blank.
- The story it tells does not match the product. The panel is a **setup
  checklist**: every item has a `configured / reference / missing` state, the
  "missing" ones are grouped under **Needs setup**, and the section order flips
  to onboarding mode while anything is missing. But "not configured" is not
  "must be configured". Memory and remote access are optional per workspace.
  A workspace that never needs SSH is not incomplete.
- Claude Code and Codex solve the same panel with far less. Both list **what
  the conversation has** (environment, context, connectors, outputs or
  sources) as one-line rows in collapsible groups, with a quiet `+` to add
  more. Absence is simply absence. Neither has a "needs setup" group.

### Where the mismatch comes from in code

*(verified)* `WorkspaceRightRailView.swift`:

- `workspaceSetupState(for:)` derives the state from emptiness:
  `.memory` is `.missing` when `workspace.memories.isEmpty`, `.remoteAccess`
  is `.missing` when `sshConnections.isEmpty`.
- `workspaceSetupMissingCount > 0` feeds
  `WorkspaceRightRailPresentation.sectionOrder(hasPendingSetup:)`, so one empty
  optional item keeps **Workspace setup** above **Capabilities** indefinitely.
- Status for a configured item is repeated four ways: the `Configured` group
  label, the green `ConfiguredStatusDot`, the `3 configured` subtitle, and the
  `Show all (3)` verb.
- The two-line row grammar (`CapabilityRailLayout.rowMinHeight` 56/60,
  `setupRowMinHeight` 56, `leadingIconFrame` 30, title 14 pt semibold) is a
  phone-density list inside a desktop inspector. The sidebar next to it uses
  34 pt rows.
- The capability subtitle is inventory (`Built-in: 1 skill, 1 connector, 3
  tools`). It answers "what is this made of", not "can I use it now".

## Principle

**The rail lists what this workspace has. Absence is not a state.**

Four rules follow:

1. **Presence makes a row.** A row exists when there is something behind it
   (a folder, a memory, a server, a capability). The box's `+` is how the
   first one is added. The only exception is **Instructions**, which always
   shows a row because it is the one lever that changes every task; when empty
   it reads `Instructions` with the verb `Write`, in tertiary, with no warning
   tint.
2. **No box without content.** The boxes stay exactly as today (the owner
   likes them: content reads as contained objects, and the blank column below
   the last box reads as "nothing more"). But a box renders only when it has
   at least one row. An absent box is never an empty bar with a title and a
   `+`. Environment and Context always have a row (the folder, the
   instructions); Capabilities, and later Outputs, can be absent. When a box
   is absent, its first add lives in a quiet rail-level `Add…` at the foot of
   the rail, which lists every add action (absent boxes first, then the
   present boxes' adds), so nothing becomes undiscoverable.
3. **Only two things get colour.** A **blocked** capability (enabled, but it
   cannot run until the user signs in, approves, installs, or starts
   something) gets its repair verb as a small tinted button. **Working-tree
   state** (changes, ahead/behind) is neutral text, dropping to the info tint
   when a sync is blocking. Nothing else carries a dot, a pill, a count in
   colour, or the words configured, missing, needs setup, or ready.
4. **One line per fact.** Collapsed rows are key/value on a single line.
   Detail, editing, and inventory live behind expansion, as today.

## Structure

No panel header. The toolbar button already names and toggles the panel, and
the workspace name is in the sidebar and the window title. In overlay mode
(narrow windows) a thin bar with only the close control remains.

Three boxes, fixed order, each with the card chrome the rail has today and a
one-line disclosure header:

```
Environment                                   +
  Folder        Coral/Code/Astra
  Branch        main
  Runs in       Local
Context                                       +
  Instructions  Investigate data services…   Edit
Capabilities                                  +
  Google Cloud
  BigQuery Analyst
```

### Section header

`Title ▾` with the chevron tight against the title, a trailing `+` in
tertiary at the far right. Clicking the title toggles; clicking `+` opens a
menu of that section's add actions. Collapsed headers carry a one-line
tertiary summary after the title so the collapsed state stays truthful:

```
▸ Environment    Astra · main · 3 changed
▸ Context        Instructions · 3 memories
▸ Capabilities   Google Cloud, BigQuery Analyst
```

### Environment

Folds today's **Repository** card, **Container** card, and **Folder access**
row into one section of key/value rows:

| Row | Shown when | Value |
| --- | --- | --- |
| Repository | the workspace has more than one repository | picker, as today |
| Folder | always | the root, head-truncated, mono; one row per added folder |
| Branch | a repository exists | branch, trailing `3 changed` / `2 ahead` |
| Runs in | always | `Local` or `Docker · <name>`, picker as today |
| Remote | at least one SSH connection | `1 server` / names |
| Pull request | one is open | link row, as today |

Verbs stay in a button footer per lean rule 5a, but the footer renders only
when something is actionable: `Commit & push` with uncommitted changes, `Push`
with commits ahead and a clean tree, and `Create PR` beside either until a
pull request exists. An open pull request is a row, not a footer, so a clean,
pushed checkout with an open PR shows no buttons. A clean checkout shows no
buttons.

`+` menu: `Add folder…`, `Connect a server…`, `Run in a container…`. This is
where Remote access is discovered. It is never a row that says it is missing.

### Context

| Row | Shown when | Value / verb |
| --- | --- | --- |
| Instructions | always | first line of the instructions, or `Write` when empty |
| Memory | at least one memory | `3 details` |
| Routines | at least one schedule | `2 scheduled` |

Row click expands in place to today's editors (instructions editor, editable
memory rows, routine list). `+` menu: `Add memory`, `New routine…`.

### Capabilities

One line per enabled capability: brand mark or SF Symbol, then the name.
Ready capabilities show nothing else. The composition summary (`1 skill, 1
connector, 3 tools`) moves to the row tooltip and to the details sheet.

Order: blocked first, then ready, then drafts. A blocked row carries its
repair verb as a small bordered button tinted with the warning colour
(`Sign in`, `Approve`, `Install`, `Start Docker`). The presence of a button
is the signal; there is no separate pill. Drafts show `Draft` in tertiary.
The section auto-expands while anything is blocked.

`+` opens the capability library (today's `Add`).

With no enabled capability the box does not render. Today's empty-state
prompt (`No active capabilities · Add capability`) goes away; `Add
capability…` is the first item of the rail-level `Add…` instead.

### Rail-level `Add…`

A quiet tertiary chip at the foot of the rail content, below the last box.
Its menu lists the first-add action of every absent box, then the adds of the
present boxes: `Add capability…`, `Add memory`, `New routine…`, `Add
folder…`, `Connect a server…`, `Run in a container…`. It is the one place
that covers everything, so absent boxes cost nothing in discoverability.

### Outputs

Claude Code and Codex both end with **Outputs** or **Sources**: the files
the conversation produced or was given. The rail's fourth box is task-scoped
and lists what the selected task produced, newest first, from the same owner
the task header reads (`TaskHeaderFilesReader`: runs' file changes plus the
task folder), minus the user's inputs and any folder.

| Row | Shown when | Value / verb |
| --- | --- | --- |
| One per file (up to 8) | the task produced it | none; the icon is the shelf that renders it, a tap opens it there |
| `N more in Files` | more than 8 files | a link row that opens the Files shelf on the next file |

No `+`: outputs are produced, not added. No task, or no files, no box. The
header carries a refresh control for the read, which is also re-keyed by the
task's status and last update. Collapsed: `3 files · PLAN.md, index.html,
results.csv`.

## Density

| Token | Today | Proposed |
| --- | --- | --- |
| Section title | 15 pt semibold | 13 pt medium |
| Row title | 14 pt semibold | 13 pt regular |
| Row value | 12 pt secondary, stacked under the title | 12 pt secondary, trailing on the same line |
| Row min height | 56 / 60 (setup 56, summary 58) | 30 |
| Leading icon | 16 pt in a 30 pt frame | 13 pt in a 20 pt frame |
| Box chrome | fill + 1 px stroke, `railCompactCardCornerRadius` | unchanged |
| Box padding | 16 all round | 4 top, 6 sides, 8 bottom (rows carry their own 30 pt) |
| Box gap | 12 | 10 |
| Column width | 392 default, 340 min, 460 max | 340 default, 300 min, 420 max |

In the mockup, the three sections for the owner's workspace measure about
390 pt instead of about 630 pt, at 340 pt wide instead of 392, with the same
data and the same toolbar. A workspace with one folder and no remote server
lands near 300 pt.

Rev 1 proposed flat sections with hairlines; the owner chose to keep the
boxes, so that a short rail reads as a few contained objects rather than an
empty column. The reduction comes entirely from inside the boxes.

## Copy

| Today | Proposed |
| --- | --- |
| `Workspace Context` / workspace name header | none |
| `Workspace setup` | `Context` (instructions, memory, routines) and `Environment` (folders, branch, container, remote) |
| `Needs setup`, `Configured`, `Reference` | removed |
| `Memory · Details the agent remembers · Add` | no row; `+ → Add memory` |
| `Remote access · Servers the agent can reach · Connect` | no row; `+ → Connect a server…` |
| `Folder access · Workspace root only` | `Folder · ~/…/Astra` (the root is the row) |
| `Instructions · Main task guidance is set · Edit` | `Instructions · <first line> · Edit` |
| `Google Cloud · Built-in: 1 skill, 1 connector, 3 tools` | `Google Cloud` |
| `No active capabilities · Add capability` (empty box) | no box; `Add… → Add capability…` at the rail foot |
| `Changes · Clean` + disabled `Commit & push` + `Create PR` | `Branch · main`, no footer on a clean checkout |
| `Show all (3)` / `Hide` | section chevron |
| `Needs setup` pill + `Sign in` button | `Sign in` button only |
| `Repository · Show controls` | `Environment` expanded by default |

## State and persistence

- All three sections expanded by default. The user's choice is remembered per
  workspace through `RailDisclosureStore`, with new toggles
  `environmentExpanded`, `contextExpanded`, `capabilitiesExpanded`.
  `repositoryShowsDetails` migrates to `environmentExpanded`;
  `configuredSetupExpanded`, `readyCapabilitiesExpanded`, and
  `draftCapabilitiesExpanded` are cleared on first launch of the new rail.
- Row expansion (instructions editor, memory rows, folder rows) stays
  ephemeral, as today.
- No adaptive section order. The reorder existed to surface pending setup;
  with no pending-setup concept a fixed order is more predictable.
- Capabilities auto-expands (without persisting) while any capability is
  blocked, so the only attention the rail raises is visible.

## Implementation plan

Four PRs, each independently shippable. Line budgets matter:
`WorkspaceRightRailView.swift` is at 2,397 of its 2,400-line ratchet, so the
rebuild splits sections into their own files rather than editing in place.

1. **Presentation model and tests, no view change.** *(implemented on this
   branch)* `Astra/Views/WorkspaceRailSectionPresentation.swift` is the pure
   model: facts in (`EnvironmentFacts`, `ContextFacts`, `CapabilityFacts`),
   boxes and rows out (`boxes(environment:context:capabilities:)`), plus the
   rail-level `railAddActions(for:)`, collapsed summaries, the verbs footer
   rule, and the density tokens under `Layout`. Nothing renders it yet.
   `Tests/WorkspaceRailSectionPresentationTests.swift` pins: an empty memory
   produces no row and no attention; an empty SSH list produces no row;
   empty instructions produce a `Write` row with no warning; a workspace
   with no capability has no Capabilities box and no box ever has zero rows;
   the rail-level `Add…` lists absent boxes first; a blocked capability sorts
   first and carries exactly one verb (its repair verb, `Set up` when the
   repair names none); working-tree state is neutral unless behind; the
   footer appears only when actionable; the retired checklist vocabulary
   never appears; the order is fixed; collapsed boxes name their contents;
   the density tokens are lighter than v1's and below the chat body size.
2. **Context and Capabilities boxes.** *(implemented on this branch, stacked
   on PR 1)* The rail view now renders the model's boxes after the Repository
   and Container cards, on a v2 row vocabulary in `ContextRailRows.swift`
   (`RailBoxHeader` with chevron and `+` menu, `RailKeyValueRow`,
   `RailAddMenuButton` for the `+` and the rail-level `Add…` chip, and a
   one-line `CapabilityRailRow`). The panel header, the checklist states and
   groups, the `Show all (n)` / `Hide` verbs and the status pills are gone;
   today's inline editors (instructions, memory, folders, remote, routines)
   are reused unchanged behind row expansion. `RailDisclosureStore` gained
   `environmentExpanded`, `contextExpanded` and `capabilitiesExpanded` and
   clears the three retired toggles. The folder helpers moved to
   `WorkspaceFolderPresentation` in `WorkspaceRightRailPresentation.swift`.
   Interim: the Environment box carries only the folder and remote rows (and
   a summary of them) while the Repository and Container cards stay; PR 3
   lifts that filter when it folds the cards in, and only then does
   `Run in a container…` join the add menus.
3. **Environment box.** *(implemented on this branch, stacked on PR 2)* The
   Repository and Container cards are gone; their rows live inside the
   Environment box as row groups that keep their behaviour (pickers,
   popovers, sheets, the changes drawer, image builds, credential
   projection). The rail owns `WorkspaceGitViewModel` and
   `WorkspaceDockerViewModel`, so the model's facts (repository, branch,
   changes, ahead/behind, pull request, container) feed the box's rows and
   collapsed summary. Row order: folders, remote, runs-in (the container
   picker when containers exist, otherwise a plain `Local`), then source
   control, whose verbs footer renders only with something to commit, push or
   pull. The box header carries one refresh control for both scans. Git rows
   are one line (scope and path in the Repository tooltip, the worktree
   caption in the Changes tooltip, counts neutral); container rows are
   key/value (`Provider · Host`), with `Build` and `Switch` as verbs and a
   tinted `Refresh` beside a Docker daemon that is not answering. The
   `repositoryShowsDetails` toggle retired. `PanelLayoutGeometry` reads the
   rail's width tokens: 300 minimum, 340 default, 380 automatic maximum, 420
   drag maximum. `Run in a container…` stays out of the add menus: the
   picker row is the way to change where tasks run.
4. **Outputs box.** *(implemented on this branch, stacked on PR 3)* A fourth,
   task-scoped box, last in the order: the files the selected task produced,
   read off the main actor by `TaskHeaderFilesReader` (the task header's
   owner of file facts: runs' file changes plus the task folder), minus the
   inputs the user attached and any folder. One line per file, newest first,
   with the icon of the shelf that renders it; a tap opens it there (HTML in
   the browser, tables in Query, the rest in Files) through
   `onOpenGeneratedFile`. Up to eight rows, then one link row `N more in
   Files` that opens the Files shelf on the next file. No `+`: outputs are
   produced, not added. No task, or no files, no box. The box header carries
   a refresh control; the read is also re-keyed by the task's status and
   `updatedAt`. Persisted as `outputsExpanded`.

Also: update `docs/design-system/lean-ui-system.md` (the card rule becomes a
section rule; add "presence, not progress" as principle 0 and note the
exception for Instructions), and update the pinned tests in
`Tests/CapabilityRailPresentationTests.swift` that encode today's density,
ordering, checklist states, and summary verbs:

- `workspace context uses desktop inspector density`
- `capability rows reserve space without mobile scale`
- `workspace right rail orders primary work before setup and inventory`
- `rail leads with setup while pending and with capabilities once configured`
- `summary disclosures name how many rows they reveal`
- `workspace setup checklist summary stays compact`
- `workspace setup rows disclose configuration details inline`
- `repository rail exposes git controls by default`
- `capability rail summarizes ready capabilities without expanding the inventory`

Verification per PR: focused `CapabilityRailPresentationTests` and
`RailDisclosureStoreTests`, then `./script/build_and_run.sh --verify` and a
look at `ASTRA Dev.app` with a workspace that has an empty memory, no SSH
connection, one blocked capability, and uncommitted changes.

## Out of scope

- The top-right toolbar (`Files`, `Browser`, panel toggle) is unchanged.
- The capability details sheet and the library are unchanged.
- The Files, Plan, Query, and Browser shelves are unchanged.

## Decisions

1. Boxes stay, as today; a box renders only when it has content (owner,
   2026-10-26).

## Open questions

1. Should the Environment verbs footer hide on a clean checkout (recommended;
   the current screenshot shows a disabled `Commit & push` beside `Create PR`
   on a clean tree), or always show `Create PR` disabled?
2. Is Outputs wanted in this cycle, or later?
