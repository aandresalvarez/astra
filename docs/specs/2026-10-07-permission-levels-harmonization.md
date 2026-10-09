# Permission levels mean one thing everywhere

Status: **implemented on `codex/permission-levels-harmonization`;** decision
15 (Auto sends a staged write when the agent asks) on
`claude/auto-sends-at-proposal`, stacked on it. Every open question was
settled with its recommended default; see [Decisions](#decisions). Where the
implementation refined the design, the section below says so.

## The rule (decided 2026-10-07)

| Level | Meaning |
| --- | --- |
| **Ask** | ASTRA asks before anything with an effect: changing files, running commands, and any action outside ASTRA (publishing to GitHub, posting comments, writing to connectors such as Jira, sending messages). Reading stays free, as today. |
| **Auto** | ASTRA asks nothing. Every action outside ASTRA still leaves a visible record in the chat — what was done, where, with a link — so the user can see what was said or changed on their behalf. |
| **Custom** | The user's saved per-item rules for tools, shell, and network. Actions outside ASTRA follow Ask (Custom has no per-item knob for them). |

### What this does not change

Boundaries that are not prompts stay exactly as they are:

- The macOS Seatbelt wrap (`ExecutionSandbox`): Auto forces the wrap for the
  runtimes that drop their own confinement; Antigravity below Auto fails closed
  when it cannot be wrapped; Auto requires the strict privacy sandbox.
- Credential handling: Keychain storage, brokered credentials withheld from the
  agent process, manifests that never persist values.
- The read-only host broker (`astra-host-control`): GitHub, gcloud, bq, ssh,
  REDCap and history are read-only; Jira can only *propose*.
- Denied actions stay denied in every level (ASTRA-owned runtime state, read-only
  task inputs, out-of-boundary writes).

This spec changes **whether ASTRA asks**, never the width of a sandbox or
credential boundary.

## How a level flows today

`AgentPolicyLevel` (`ASTRACore/AgentPolicyTypes.swift`) is stored per
global/workspace/task. It is reduced to `PermissionPolicy`
(`.autonomous` / `.restricted` / `.interactive`) by
`ProviderPolicyModeResolver`, then rendered into each provider's CLI flags by
`AgentPolicyAdapters.swift`. That half is pinned by
`Tests/AgentPolicyRuntimeMatrixTests.swift`.

Actions ASTRA executes itself do not read the level through one owner. Some
branch on `permissionPolicy != .autonomous` (Git publication, credential
exposure, host-control shell routing), some ignore the level entirely
(connector credential prompt, Jira writes, GitHub review posting). Nothing pins
that half. That is the gap this spec closes.

## Inventory

"Before" means ASTRA asks before the effect happens; "run boundary" means ASTRA
sees the action in the provider stream, stops the run, and asks before
relaunching — the first effect may already have happened.

### A. The agent's own tools (provider-enforced, ASTRA-guarded)

| # | Action | Ask today | Auto today | Custom today | Enforced by | Target Ask | Target Auto |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | Read / Glob / Grep inside the run boundary | Free | Free | Free | Provider allow-list (`AgentPolicy.preset`) | Free | Free |
| A2 | Read outside the run boundary | Approval card (`.sandboxPath` read grant) | Free (broad render; Seatbelt privacy floor still applies) | As Ask | `AgentRuntimePolicyGuard.outOfBoundaryReadViolation`, `RunBoundary` | Unchanged (boundary, not an action) | Unchanged |
| A3 | File write / edit / patch in the workspace | Asks. Claude: live ask **before** (stdio control channel, `AgentInteractivePermissionChannel`). Copilot: the CLI refuses tools it was not granted, so nothing runs; ASTRA asks at the run boundary and relaunches with the grant. Codex (`workspace-write`, `approval_policy="never"`), Antigravity, Cursor, OpenCode: **run boundary** (`AskCoverageBadge.providerManaged`) | Free | Saved rules | Provider flags + `AgentRuntimePolicyGuard.validateObservedAction` + `AgentProcessSupport.recordPolicyViolation` | Asks (unchanged; see Decision 9 for the run-boundary runtimes) | Free |
| A4 | Shell command | Asks (as A3), **except** (a) `rm`, `sudo`, `chmod`, `chown`, `git push`, `deploy`, `publish` are **hard-denied**, never asked (`AgentPolicy.preset(.review).deniedShellPatterns`); (b) on Codex/Cursor/Antigravity/OpenCode every reachable local tool (`bq`, `gcloud`, `astra-browser`, mail readers…) is pre-granted as `<tool> *` and runs **without asking**, while Claude and Copilot ask for the same command | Free (Seatbelt applies) | Saved rules | `AgentPolicyAdapters.swift` (`PolicyLocalToolGrants.shellAllowPatterns` vs `.levelScoped`), guard | Asks for every command with an effect; same answer on every runtime (Decisions 5, 6) | Free |
| A5 | WebFetch / WebSearch | Asks (preset `askFirstTools`) | Free | Saved rules | Preset + guard | Unchanged: still asks (Decision 1) | Free |
| A6 | Catalog MCP server tools (`mcp__<server>__*`) | **Free at every level**, including tools with external effects | Free | Free | `MCPRuntimeProjection.allowedToolPermissions` (pre-allowed) | Should ask for tools with effects (Decision 7) | Free |
| A7 | Browser control (`astra-browser` CLI / browser MCP: click, type, submit on authenticated pages) | Claude/Copilot: asks (it is a shell command). Codex/Cursor/Antigravity/OpenCode: pre-granted, no ask (A4b). MCP transport: pre-allowed | Free | Saved rules | A4 / A6 | Asks before page-changing actions on every runtime (Decisions 6, 7) | Free (Decision 12 on records) |
| A8 | Subagents (`Agent`) | Not allowed | Allowed | Saved rules | Preset | Unchanged | Unchanged |
| A9 | Native Git/GitHub/cloud CLIs with real credentials (`git push`, `gh pr create`, `gh api -X POST`, `gcloud … deploy`) | Native shell denied when host-control tools are required; Git credentials withheld while ASTRA owns PR publication; `git push` hard-denied | **Allowed with native credentials; no ASTRA ask and no structured record** — only the agent's own tool rows | As Ask | `HostControlPlaneMCPProjection.requiresNativeShellDenial`, `TaskLaunchResourceResolver.brokersNetworkGitThroughAstra`, `AskGitPullRequestWorkflowPolicy` | Unchanged (asks through ASTRA's typed workflows) | Free, plus a best-effort observed record (Decision 3) |

### B. Actions ASTRA itself executes outside the machine

| # | Action | Ask today | Auto today | Custom today | Enforced by | Chat record today | Target Ask | Target Auto |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | Connector credential first use in a task (launch gate) | Card "Permission needed" (Allow once / Allow for task) | **Card** — "Allow for this task" leads (PR #441); a test pins that Auto never bypasses it | Card | `AgentRuntimeLaunchPreflight.finishPreLaunchCredentialApprovalRequest`; `TaskDecisionDockPresentation.prefersTaskScopedRuntimePermission`; `ConnectorPreflightServiceTests` | `permission.approval.requested` card | Asks (unchanged) | **No card.** Granted for the task, one chat line: "Auto allowed Jira for this task" (Decision 4) |
| B2 | Connector credential offer after a sealed call ("this turn's wording did not mention it") | Offer card (`futureUse`) | **Offer card** | Offer card | `BrokeredCredentialWithholding.recordOpenRequest` | Card | Asks (unchanged) | Granted for the task + chat line; the run continues next turn |
| B3 | Jira write: `create_issue`, `add_comment`, `update_issue`, `transition_issue` | Agent proposes → staged file → dock "Review & send" → sheet → send | **Same sheet** | Same | `ConnectorMutationDiscovery`, `ConnectorMutationCoordinator`, `ConnectorMutationSender`, `Astra/Views/TaskConnectorMutationReview.swift` | **None in the chat** — `connector.mutation.receipt` is a structured event the thread never shows | Asks (sheet, unchanged; Decision 10 on "for this task") | **Sent when the agent proposes it** in a run that launched in Auto, the receipt returned to the agent; chat record with key and link (decision 15) |
| B4 | Git draft pull request publication | Agent told not to push; ASTRA builds the exact proposal → "Publication approval needed" → "Review & publish" sheet → `gitPublish` grant | **Agent publishes itself** with native credentials (A9); ASTRA queues no proposal (`TaskSuccessfulCompletionService` skips it for `.autonomous`; `TaskCompletionPolicy` only blocks on an already-pending one) | As Ask | `AskGitPullRequestWorkflowPolicy`, `TaskGitPullRequestPublishCoordinator`, `TaskCompletionPolicy.decideSuccessfulCompletion`, `gitPublishProposal` sheet in `TaskMainView.swift` | `task.approved` text "Published draft pull request #N: url" | Asks (unchanged) | Agent keeps publishing; ASTRA records it (Decision 3) |
| B5 | GitHub pull-request review posting | "GitHub review ready to post" → "Review comments" sheet → POST | **Same sheet** | Same | `GitHubReviewPublicationService`, `GitHubReviewPublicationRequirement`, `TaskCompletionPolicy` | `system.info` "Posted GitHub review: url" | Asks (unchanged) | **Posted when the agent asks ASTRA to post the file**, the link returned to it; chat record with link (Decisions 2, 15) |
| B6 | GitHub thread reply / resolve (PR #482, paused) | — | — | — | future host `github` write operations | — | Asks in the chat: "Allow once & continue" / "Allow for this task" | Executes, result returned to the agent, chat record with link |
| B7 | Messages (mail) | No send operation exists: `stanford-*-mail` tools are read-only | — | — | `Tools/Stanford*MailTool` | — | Must ask when one is added | Must record when one is added |
| B8 | REDCap, gcloud, bq, ssh, GitHub reads via the host broker | Free (read-only by construction) | Free | Free | `Tools/HostControlToolSupport/*Policy.swift` | — | Free | Free |

### C. Gates that are not action permissions

| # | Gate | Today (all levels unless noted) | Owner | Target |
| --- | --- | --- | --- | --- |
| C1 | Seatbelt denial → widen sandbox path | Card in every level; Auto launch explicitly keeps it ("Sandbox path approvals remain explicit") | `TaskRuntimePermissionOpenRequestStore.closeRequestsAuthorizedByAutonomousPolicy` | Unchanged — widening a sandbox is not "asking before an action" (Decision 8) |
| C2 | Sensitive-data (PHI) runtime switch acknowledgement | Asks in every level | `RuntimeSensitiveDataLaunchGate`, `RuntimeSensitiveDataSwitchPolicy` | Unchanged (data governance) |
| C3 | Antigravity unwrappable below Auto | Run blocked | `ExecutionSandboxSettings.failClosedRuntimes` | Unchanged |
| C4 | Codex needs native Git/SSH credentials below Auto | Run blocked | `unsupportedProviderNativeCredentialReadBlock` | Unchanged |
| C5 | Plan execution | Ask: Claude runs the plan with live asks, others one step per approval; Auto: whole plan | `PlanCheckpointPolicy` | Unchanged — already follows the rule |
| C6 | Workspace app operations with `requiresApproval` (`WorkspaceAppContractRegistry`: `submitCreate`, `sendMessage`, `createIssue`, `createEvent`, …) | The app's own human-approval / agent-recommendation gate; the agent-facing data bridge never confirms an approval | `WorkspaceAppActionExecutor`, `WorkspaceAppDataBridge` | Unchanged — the app author's gate, not the task level |
| C7 | Capability package approval and digest | Install-time review | Catalog policy | Unchanged |

## Findings

- **G1 — Auto still asks.** B1, B2, B3, B5 prompt in Auto, and the dock even
  re-orders its buttons for Auto instead of not asking.
- **G2 — Auto records almost nothing.** The one thing Auto must do — show what
  was done outside ASTRA — happens for GitHub reviews only (a text line). A
  Jira write leaves no chat line in any level; an agent-published PR in Auto
  leaves only tool rows.
- **G3 — Ask is not the same on every runtime.** Local tools (`astra-browser`,
  `bq`, `gcloud`, mail readers) run unasked on Codex, Cursor, Antigravity and
  OpenCode but ask on Claude and Copilot. The brokered adapters call
  `PolicyLocalToolGrants.shellAllowPatterns` directly, skipping the
  `levelScoped` filter whose own comment says every renderer must apply it.
- **G4 — Ask denies some effects instead of asking.** `rm`, `chmod`, `chown`,
  `git push`, `deploy*`, `publish*` cannot be approved in Ask; the only way to
  run them is to switch to Auto.
- **G5 — Ask lets catalog MCP tools through.** Server tools are pre-allowed at
  every level; ASTRA has no read/write metadata for them.
- **G6 — "Before" is only literal on Claude.** Copilot refuses ungranted
  tools and asks at the run boundary, so nothing ran; Codex, Cursor,
  Antigravity and OpenCode may apply the first change before ASTRA stops the
  run, as `AskCoverageBadge.providerManaged` already admits.
- **G7 — The level is read from three places.** External-action sites read
  the provider-clamped `PermissionPolicy` (so Copilot-in-Docker Auto counts as
  Ask), the task's current level, or nothing.
- **G8 — The picker explains nothing.** Ask / Auto / Custom show no
  description; Auto's tooltip talks about provider prompts and sandboxes.

## Target design

### 1. One owner for "does this level ask?"

```swift
/// What ASTRA does about an action that leaves the machine. One answer per
/// (level, action), so a site cannot drift from the user's rule.
enum ExternalActionKind: String, Codable, CaseIterable, Sendable {
    case connectorCredentialUse
    case connectorMutation          // Jira today
    case gitPullRequestPublication
    case githubReviewPublication
    case githubThreadReply          // PR #482
    case githubThreadResolution     // PR #482
    case agentCommand               // git/gh the agent ran itself (A9)
}

enum ExternalActionDisposition: Equatable, Sendable {
    case askUser            // stage and ask: sheet or chat card
    case performAndRecord   // act now, append a visible record
}

enum ExternalActionPolicy {
    static func disposition(
        for kind: ExternalActionKind,
        level: AgentPolicyLevel
    ) -> ExternalActionDisposition
}
```

- The input is the **user-facing `AgentPolicyLevel` of the run that produced
  the action** (`RunPermissionManifest.policyLevel`), not the provider-clamped
  `PermissionPolicy` (fixes G7) and not the task's current level: a Jira
  proposal staged under Ask stays for review after the user switches to Auto.
- Auto → `.performAndRecord` for every kind; Ask and Custom → `.askUser`.
- Every site in table B calls it; the scattered `permissionPolicy !=
  .autonomous` checks for external actions are replaced. Provider rendering
  (table A) keeps its own owner, `ProviderPolicyModeResolver`.

### 2. The visible record

**No new owner of the facts.** Each external action already writes a typed
receipt event, and the receipt stays the owner:

| Kind | Receipt event (owner) | Link |
| --- | --- | --- |
| Jira write | `connector.mutation.receipt` (`ConnectorMutationReceipt`) | `createdURL` or issue URL |
| GitHub review | `github.review.receipt` (`GitHubReviewPublicationRecord`) | `reviewURL` |
| Git PR | `TaskExternalOutcomeEventTypes.publicationReceipt` (`GitPullRequestPublishReceipt`) | `pullRequestURL` |
| GitHub thread reply / resolve | new receipt types in PR #482 | comment / thread URL |

Changes:

1. Each receipt gains an optional `authorization` field —
   `.userReviewed` (sheet), `.userGrantedForTask`, `.autoPolicy(level)`.
   JSON in `TaskEvent.payload`, decoded with `decodeIfPresent`; a missing
   value reads as `.userReviewed`, which is what every pre-change receipt was.
   No SwiftData schema change.
2. `ExternalActionRecordProjection` — a pure function over task events that
   turns each receipt into a presentation value:

   ```swift
   struct ExternalActionRecord: Equatable, Identifiable {
       let id: UUID                     // the receipt event's id
       let kind: ExternalActionKind
       let title: String                // "Created STAR-12558", "Opened draft PR #12"
       let destination: String          // "STAR / Bug", "owner/repo"
       let url: URL?
       let authorization: ExternalActionAuthorization
       let timestamp: Date
   }

   protocol ExternalActionRecordSource {
       static var eventTypes: Set<String> { get }
       static func record(payload: Data, eventID: UUID, timestamp: Date) -> ExternalActionRecord?
   }
   ```

   Each source decodes only the receipt fields the row shows. Sources register
   in `ExternalActionRecordProjection.sources`; PR #482 adds one for its
   reply/resolve receipts — nothing else in the chat changes.
3. `TaskThreadSnapshot` gains `.externalAction(ExternalActionRecord)`,
   rendered as one lean row (state, not a button): service symbol, noun-led
   title, destination as metadata, an **Auto** pill when the record came from
   `.autoPolicy`, and the row opens the link. It appears in every level; in Ask
   it confirms what the approval did, in Auto it is the only notice.
4. The legacy text lines for the same receipt ("Posted GitHub review: …",
   "Published draft pull request #N: …") are still written — other code reads
   them — and the thread hides a legacy line when a record for the same
   receipt is present, so nothing shows twice.
5. A record is written only from a receipt, so it never claims an action that
   did not complete. Failures and indeterminate sends keep their existing error
   lines and are never auto-retried.

Auto-granted connector credentials (B1/B2) are not external writes and have
no receipt; they get one `system.info` line ("Auto allowed Jira to use its
saved credentials for this task.") next to the task-scoped grant, recorded with
source `auto_policy`.

What the agent sees follows the level (decision 15): in Ask and Custom a
proposal waits for the user's review, and the broker's reply and the prompt
contract say so; in Auto the reply carries the receipt, and Auto guidance is
appended to the contract with the same level the broker uses.

### 3. Per-action changes

| Action | Change |
| --- | --- |
| B1 connector credential gate | Auto: grant the launch's labels for the task through the same path "Allow for this task" uses (`TaskRuntimePermissionGrants`), write the line, continue the launch. Ask/Custom unchanged. |
| B2 credential offer | Auto: same grant instead of an offer card. |
| B3 Jira writes | Decision 15: in Auto the broker asks the app right after staging, the app sends through `ConnectorMutationCoordinator.prepare`/`send` and the receipt is the tool result (`BrokeredExternalActionHandler`, `sendWhenProposed`). Ask and Custom unchanged: reviewed in the sheet after the run. |
| B4 Git PR | Decision 3: Auto unchanged (the agent publishes); add the observed-action record below. |
| B5 GitHub review | Decision 15: in Auto the agent asks ASTRA to post a review file it wrote (`github` `post_review`, CLI `--post-review`); the app posts that file, bound to the digest the broker read, through `GitHubReviewPublicationService.prepare`/`publish`, and returns the link (`publishWhenRequested`). Ask and Custom unchanged. |
| B6 PR #482 | Uses `ExternalActionPolicy` + `ExternalActionReceipt`; specified there. |
| A4/A7 Ask local tools | Apply `PolicyLocalToolGrants.levelScoped` in every adapter so Ask asks the same on every runtime (Decision 6). |
| A4 Ask hard denies | Decision 5: `rm`, `chmod`, `chown`, `git push`, `deploy`, `publish` become ask-first in Ask; `sudo` stays denied. |
| A9 agent-observed external actions (Auto) | Record only (`AgentExternalActionObserver`): each of the run's shell calls whose own result came back successful (a failure names its call) and that is not known local work (`LocalShellCommands`, the reading Ask asks by) writes an `external.action.observed` event titled with the command it ran, or — for a call that is exactly one `git push` (not a dry run), `gh pr create\|merge\|comment\|review\|edit\|close\|ready` (`--undo` as a draft conversion), `gh issue create\|comment\|edit\|close`, `gh release create`, or `gh api` with a write method or fields — that action's title, with the destination and the first GitHub URL from the result. Rendered with the same row and an "Agent" pill. Never a gate. |

### 4. Picker copy

One line under each level in the menu, and the same text as the tooltip:

| Level | Menu line | `shortDescription` / tooltip |
| --- | --- | --- |
| Ask | Asks before changes and before acting outside ASTRA | Asks before changing files, running commands, or acting outside ASTRA — GitHub, Jira, messages. Reading files stays free. |
| Auto | Does everything without asking | Does everything without asking. Actions outside ASTRA are recorded in the chat with a link. Sandbox and credential protections still apply. |
| Custom | Your saved rules; asks before acting outside ASTRA | Uses your saved tool, shell, and network rules. Acting outside ASTRA asks first, as in Ask. |

The legacy presets keep their wording in Policy details. SwiftUI `Menu`
labels on macOS are flattened (see the memory note on greedy menu labels), so
the two-line item is verified in the running Dev app, not only in a hosted
view test.

## Migration notes

- No SwiftData schema change. Receipts gain one optional JSON field.
- The decision reads the producing run's recorded level, so switching a task
  between Ask and Auto never auto-sends something composed under Ask, and
  never re-asks for something an Auto run already did.
- Open connector-credential requests on a task now in Auto are resolved by the
  next Auto launch's grant (today Auto closes and re-asks them).
- `ConnectorPreflightServiceTests` — "Auto never bypasses the credential
  prompt" is inverted to "Auto grants for the task and records it", and the
  dock's `prefersTaskScopedRuntimePermission` loses its Auto branch.
- User defaults keys and stored levels are unchanged.
- Docs: `docs/security/security-boundaries.md` gains a "Permission levels"
  section; `docs/testing/runtime-security.md` gains the level × action matrix
  next to the level × runtime matrix.

## Tests

- `Tests/PermissionLevelActionMatrixTests.swift`, in the style of
  `AgentPolicyRuntimeMatrixTests`: every `AgentPolicyLevel` × every
  `ExternalActionKind`; a new kind fails the suite until it is placed; Auto is
  the only level that performs without asking; legacy presets resolve through
  `userFacingLevel` to Custom.
- One integration pin per site, Ask and Auto each: credential gate, credential
  offer, Jira discovery-to-send, review posting, PR publication, and the
  record projection (record present, link correct, Auto pill only for
  `.autoPolicy`, legacy line hidden).
- A runtime × Ask pin that local tool commands ask on every runtime (G3).
- Mutation checks: each rule is removed in turn and the matching test must
  fail; the PR body lists each removal and the failing test.
- Order: focused suites, `script/runtime_security_tests.sh`, then full
  `swift test`.

## Implementation plan (after agreement)

1. `ExternalActionPolicy` + matrix tests; route existing sites through it with
   no behavior change.
2. Picker copy and descriptions.
3. Record projection, receipt `authorization`, chat row.
4. Auto: connector credentials (B1, B2).
5. Auto: Jira writes (B3).
6. Auto: GitHub review (B5).
7. Auto: observed external actions (A9), which cover the agent-published PR (B4).
8. Ask consistency (G3, G4).
9. Docs.

## Decisions

Settled with the user on 2026-10-07. Decisions 1–4 were answered explicitly;
5–12 took the recommended default. The chosen answer is in **bold**.

1. **Network reads in Ask.** WebFetch/WebSearch ask today. A fetch to an
   arbitrary URL can carry data out in the query string. **Keep asking**, or
   make web reads free like file reads?
2. **Review sheets in Auto (Jira, GitHub review).** **Replace with the chat
   record**, or keep the sheet in Auto because the payload is long?
3. **Git PR in Auto.** **(a) The agent keeps publishing with its own
   credentials; ASTRA adds the best-effort observed record** — or (b) route
   Auto publication through ASTRA's typed publisher too (exact receipt, but
   Auto loses native `git push`).
4. **Connector credentials in Auto.** **Grant for the task and record it**
   (reverses the PR #441 decision and its pinned test), or keep asking once
   per task because it is credential handling?
5. **Ask hard denies.** **Make `rm`, `chmod`, `chown`, `git push`, `deploy`,
   `publish` ask-first; keep `sudo` denied** (it cannot run non-interactively),
   or keep them all denied?
6. **Local tools in Ask.** **Ask on every runtime** (Claude/Copilot today), or
   pre-grant on every runtime?
7. **Catalog MCP tools in Ask.** **Follow-up**: needs per-tool read/write
   metadata (MCP `readOnlyHint` or package declarations) — or ask before every
   MCP tool in Ask now?
8. **Prompts that remain in Auto.** **Sandbox-path widening (C1) and the PHI
   acknowledgement (C2) stay** because they widen a boundary rather than
   approve an action — confirm.
9. **Run-boundary Ask (G6).** **Out of scope; keep the coverage badge** — or
   tighten now (for example Codex `read-only` in Ask, widened per approval)?
10. **"Allow for this task" for external writes in Ask.** Planned for PR #482
    thread replies. For Jira and reviews, **keep the per-item sheet** (the
    payload is the point), or allow task-scoped approval too?
11. **Custom.** **External actions follow Ask**, with no per-item knob — or
    add knobs now?
12. **Browser in Auto.** **No per-click record** (tool rows already show it),
    or record page-changing actions?
13. **How a shell command is judged (2026-10-08).** The first design read
    each command for an action outside the machine and listed the ones it
    found (`git push`, `curl -d`, a remote Docker daemon, a side-effecting
    SQL `SELECT`). That list could not be finished: every review round found
    another spelling (`eval "$x"`, `env -S`, `node --eval=`, `npm --scope x
    publish`, `xargs -r`), and a program it did not know (an internal deploy
    CLI behind a Custom `Bash` rule) ran unasked. **Judge the opposite question
    from a fixed list of known local work (`LocalShellCommands`)**: anything
    not on it, or not readable, asks in Ask and Custom and is recorded in
    Auto. The list judges the command, not the project code it runs.
14. **What the list guarantees (2026-10-09).** After decision 13, about two
    thirds of the review findings were of two kinds: a listed tool with an
    option, variable or setting that names a program to run (`rg --pre`,
    `make --eval`, `rustc -C linker=`, `GOFLAGS=-toolexec`), and shell state
    that changes what a word means at run time (`rg "$OPT"`, a glob that
    expands to `--x`, `read PATH`). Both are code hiding an action, and the
    list cannot stop that by construction: running project code is local, so
    `printf 'curl -d …' > x.sh && bash x.sh` passes. **The list guarantees
    that an action the command itself expresses asks (Ask, Custom) or is
    recorded (Auto); containing code that hides one is the operating-system
    boundary's job** (Seatbelt sandbox, network policy, launch credentials).
    The forms already rejected stay rejected. A new form of either kind is
    answered with this decision rather than another entry.
15. **When Auto sends a staged write (2026-10-09).** Decision 2 had Auto
    send a staged Jira write and post a requested GitHub review without the
    sheet. ASTRA learned of either only when it read the task folder after the
    run, so it sent them during settlement, and every state a run can reach
    between proposing and sending became a review finding: a failed check, a
    cancel, a crash, an upgrade, a decline in the meantime, the order of
    dependent proposals, a review that failed beside a Jira write. That window
    was a second owner of "when the write happens". **Auto sends when the agent
    asks**, as the agent's own `git push` happens when it runs. Implemented on
    `claude/auto-sends-at-proposal`:
    - The broker gets one way to ask the app, `BrokeredExternalActionRequesting`,
      bound by the worker to the task, the run, and the run's own level
      (`RunPermissionManifest.policyLevel`), like the history reader. It never
      sends and never reads a level. After staging a Jira proposal it asks with
      the file it wrote and the digest of what it wrote; `github` gains
      `post_review` (`--post-review` on the CLI relay), which reads the named
      review file under the task folder and asks with its name and digest. The
      reply tells the agent exactly what the app answered: `sent: true` with
      the key and link, `sent: false` with the error, `sent: unknown` (do not
      ask again), or that the proposal waits for review.
    - The app answers on the main actor (`BrokeredExternalActionHandler`)
      through `ExternalActionPolicy`. Ask and Custom record nothing and the
      run boundary offers the proposal for review, as before. Auto records the
      proposal with `authorization: .autoPolicy` and sends it through the
      sheet's own `prepare` and `send` (`sendWhenProposed`): digest re-read,
      derived route, re-resolved destination, durable reservation before
      dispatch, no resend of an ambiguous outcome. Any outcome retires an Auto
      record, so a refusal goes back to the agent rather than waiting in the
      dock for a second attempt; the dock hides one while it is in flight.
    - A requested review is posted only for the file the request names, while
      it holds the bytes the broker read, through `prepare` and `publish`, and
      only while the user's request to post is open (`publishWhenRequested`).
      "A file at this path was written or touched by the run" never makes one
      eligible, so a review an earlier Ask run left for the user waits for the
      user unless an Auto run's agent names that file in a request of its own.
      Dispatch is matched by the file's place in the task folder, so the dock
      never re-offers a posted review under another spelling of its path.
    - Nothing depends on how the run ends, its checks, settlement or crash
      recovery; the run boundary sends nothing at any level. A send still in
      flight when ASTRA stops leaves a record with no outcome, which the dock
      shows like any other proposal, refused as already sent when the send was
      claimed. The broker waits a bounded time; past it the agent is told the
      outcome is not yet known, and the send still records its own.

## PR #482 reuse

The paused thread-reply workflow needs exactly two things from this spec:
`ExternalActionPolicy.disposition(.githubThreadReply / .githubThreadResolution,
level:)` to choose between the chat ask and immediate execution, and an
`ExternalActionRecordSource` for its reply and resolve receipts so the chat
shows the same row with the comment link. In Auto the operation's result
goes back to the agent in the same turn; in Ask the existing permission
continuation ("Allow once & continue" / "Allow for this task") resumes it.
