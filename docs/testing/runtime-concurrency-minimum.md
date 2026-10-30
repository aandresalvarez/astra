# Minimal runtime concurrency: evidence and limits

## Scope of this increment

An ASTRA execution owner now reserves the native session it actually resumes or
reports. Different session IDs remain independent, even under the same runtime
and account. Session claims use the existing protected journal, admission lock,
retained execution history, and resource broker. They do not reserve an account.

This closes a concrete gap: a previously exported, settled task can be imported
into a different workspace and retain a native session still owned by uncertain
work in the source task. Matching launch signatures did not prevent that reuse.
The regression uses the production export/import and continuation policies.

The admission lock coordinates app processes using the **same ASTRA store**.
This increment does not certify two different stores sharing a provider profile.
It also does not redesign native tools, authentication, or token renewal.

## Resource boundaries retained from main

| Resource | Current protection / limitation |
| --- | --- |
| Workspace | Existing physical-path claims and persistent execution owner; uncertain work retains its claims. |
| Native session | Exclusive per runtime and opaque session ID; leading/trailing whitespace follows the real continuation policy. Old receipts and retained sessions also reserve their IDs. |
| Antigravity configuration | Existing physical-identity reservation remains in place for the full execution. Same-profile parallelism is not established by this patch. |
| Other runtime configuration | Existing adapters remain unchanged; they must be assessed individually before claiming six-runtime concurrency. |
| Credentials and authentication | No copying, relocation, new release rule, or claim of safe concurrent renewal. Existing authentication limitations remain open. |

An uncertain session cannot be released by a model, a timer, or an absent
provider PID. A newly reported conflicting session requests process termination
and retains uncertainty. A late session frame cannot erase the earlier identity.
Brief contention from another app process waits for the existing admission
lease. The disclosed identity and pending verification are saved before that
wait; even a clean process receipt cannot release them until verification ends.
Only protected receipts with complete release proof stop reserving old sessions.

## Baseline native-app experiment — 2026-10-30

Product base: `224e2eda6a3f3e8f3a952869e41078d66a0b1477`. This is **baseline evidence**,
not validation of the subsequently changed binary.

- ASTRA Dev bundle copied to a separate QA bundle identity and isolated support
  directory. Open files confirmed only that QA store was in use.
- Codex CLI `0.164.0`, model `gpt-6.1-sol`, existing ChatGPT login. Both executions
  used the same canonical provider profile; no credentials were copied.
- All UI actions used native macOS accessibility/keyboard control. Store reads
  and the synthetic scripts supplied additional diagnostics, not replacement UI evidence.
- User authorized Auto only for synthetic tasks A and C. Each had its own
  workspace and a 60-second script writing one timestamped progress record per
  second. Each request used a 50,000-token budget with hard-stop enforcement.

| Scenario | Observed result |
| --- | --- |
| Same-account overlap | A and C had distinct native sessions and tool PIDs. Both wrote progress during the same interval, including approximately 22 seconds before Stop. |
| Stop A while C works | Stop was pressed in A. C continued to all 60 steps and returned its answer with one provider launch. A's tool continued for approximately 35 seconds after Stop, then exited at its own bounded end. **Actual tool cancellation is not proved.** |
| Independent work with uncertainty | The earlier Ask experiment B retained its workspace reservation; A and C still launched. After Stop, A retained its reservation without blocking C. |
| Terminal C result | Its script and response finished, but reported usage was 230,586 tokens against 50,000. The app showed `Budget hit`, not successful task completion. Tool effects remained unverified. |
| Retry A | The app explained that earlier execution/tool termination was unconfirmed. Launch count stayed at one. |
| Restart QA app | After verifying all QA provider/tool PIDs were absent, the app was quit and relaunched. Owner IDs, execution IDs, sessions, limits, launch counts, stop proofs, and unreleased reservations were identical. No new provider execution appeared. |
| Ask policy | In a preceding baseline attempt, the command started before the approval prompt and outlived the Codex process. ASTRA retained the uncertain reservation. This is an existing blocker, not an accepted approval flow. |

Local evidence is under `/private/tmp/astra-concurrency-minimal-20261030`:
UI snapshots/screenshots, `auto-submit-times.json`, `stop-a.json`, per-workspace
`progress.jsonl`, and before/after restart receipts. These temporary artifacts do
not contain credentials and are not a permanent CI artifact.

## Automated regression and provider matrix

Before the fix, the new session-ownership regression failed on all six runtime
arguments plus the actual Codex export/import path: seven failed expectations
that a competing session launch should be rejected. Independent-session
admission and the import/signature prerequisites passed in that same run.

The ownership/continuation campaign passed **143 tests in 15 suites** in one
focused run (`native-session-final-focused.log`, 116.194 seconds of test time).
Coverage includes all six runtime IDs, real export/import, process-boundary
conflicts, late identity, protected history, clean versus uncertain model-change
continuations, admission contention, and shutdown during pending verification.
The independent reviewer found no remaining actionable P1/P2 after fixes.
The later extraction of result projection kept the existing runner line limit;
its focused check passed **15 tests in 3 suites** (`result-component-tests.log`).
Full-suite, hook and CI results belong to the final commit's PR checks; this
focused result is not a substitute for those checks.

## Candidate native-app session check

The verified development bundle was copied into the same isolated QA identity.
The test fixture imported the original real Codex history into independent
workspaces, preserving its session ID and launch signature. It did not edit
the original protected receipt. All app actions used native controls.

- A new follow-up on the imported copy, with **Ask**, attempted the original
  native session. The app displayed its session ID, owning task, workspace
  `Concurrency QA B`, and the missing confirmation of tool termination.
- The copy had **zero provider launches**. Its original task's owner, limits,
  session and uncertain stop receipt remained byte-for-byte unchanged.
- Retry of that blocked follow-up also settled with zero launches and preserved
  the token ceiling. The three original QA receipts remained unchanged.
- Restarting the candidate opened only its isolated QA store and preserved all
  five execution receipts exactly, including owners, limits and reservations.
  No new execution appeared; the QA app was then closed normally.
- A preliminary Retry of the imported *initial* request selected a new native
  session. It ran independently and encountered the known Ask limitation; its
  bounded script finished. That attempt is not counted as shared-session proof.

Artifacts: `import-continuation-blocked.png`, `import-continuation-final-ui.jsonl`,
`after-import-continuation.json`, `before-candidate-restart.json`, and
`after-candidate-restart.json` in the QA
directory. `RuntimeConcurrencyImportAppFixtureTests` is opt-in; use an isolated
support directory and a fresh `ASTRA_CONCURRENCY_IMPORT_QA_COPY` while the app is
closed. The fixture refuses to overwrite an existing copy.

| Runtime | Automated boundary coverage | Real ASTRA Dev concurrency | Remaining access / acceptance |
| --- | --- | --- | --- |
| Claude Code | Session ownership passed | Not run on this candidate | Access not rechecked |
| Codex CLI | Passed, including import, late identity, and process boundary | Baseline overlap; candidate imported-session block and Retry passed | Authenticated; tool-stop and full acceptance remain open |
| Google Antigravity CLI | Session ownership passed | Not run on this candidate | Existing shared configuration reservation preserved |
| GitHub Copilot CLI | Session ownership passed | Not run on this candidate | Access/quota not rechecked |
| Cursor CLI | Session ownership passed | Not run on this candidate | Access not rechecked |
| OpenCode CLI | Session ownership passed | Not run on this candidate | Access not rechecked |

The all-provider program is incomplete. Automated ownership tests do not prove
native-provider cancellation or credential safety. Keep the PR in draft and do
not describe this patch as full same-account concurrency certification.
