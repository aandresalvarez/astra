# ASTRA Architectural Review Remaining Execution Loop

**Coordinator branch:** `alvaro/arch-review-all-remaining-gaps`
**Foundation checkpoint:** `f3b882e` (`PR 1-4`)
**Source plan:** `docs/superpowers/plans/2026-07-01-architectural-review-pr-split.md`

## Loop Contract

For each remaining PR:

1. Create an isolated worktree and branch from the current coordinator branch.
2. Give the implementer the full PR text, owning boundary, and verification target.
3. Require a local commit in the PR worktree.
4. Run spec-compliance review against the actual diff.
5. Run code-quality review only after spec compliance passes.
6. Merge the PR branch into the coordinator branch.
7. Run focused tests for that PR plus `git diff --check`.
8. Only advance to the next PR after the coordinator branch is clean and verified.

## Remaining Queue

- [x] PR 5: Bound and Relocate the Workspace JSON Mirror
- [ ] PR 6: Derive Launch Arguments from `ProviderPolicyRender`
- [ ] PR 7: Introduce `TaskStateMachine`
- [ ] PR 8: Introduce `SceneSelectionModel`
- [ ] PR 9: Fix CI and Test Target Feedback Loops
- [ ] PR 10: Gate Credential Egress
- [ ] PR 11: Promote Continuation and Approval State to Typed Properties
- [ ] PR 12: Run Utility Prompts Through a Sandboxed Launch Plan
- [ ] PR 13: Extract First SwiftPM Leaf Targets
- [ ] PR 14: Extract a Shared Chat Transcript Component
- [ ] PR 15: Replace Browser Command Switches with a Handler Registry
- [ ] PR 16: Single-Source WorkspaceApps Permission Gate and Read Pipeline
- [ ] PR 17: Add `MCPServerKit` for Stdio Server Boundaries
- [ ] PR 18: Add a Shared `HardenedProcessExecutor`
- [ ] PR 19: Funnel SwiftData Saves Through Persistence Boundaries
- [ ] PR 20: Split Capability Resolution into Authorization and Relevance
- [ ] PR 21: Collapse Policy Vocabulary Drift and Runtime Protocol Strings
- [ ] PR 22: Hygiene and Drift Guardrails

## Final Verification Gate

- [ ] `swift test`
- [ ] `git diff --check`
- [ ] `script/precommit.sh`
- [ ] `script/prepush.sh`

## Completed PRs

### PR 5

- Branch: `alvaro/arch-review-pr5-json-mirror`
- Head: `03b28a5c2a4e2559b6f969bd29b248861f5dcf1e`
- Spec review: passed after fix loop.
- Code quality review: passed after fix loop.
- Coordinator merge: completed.
- Focused worker validation: `WorkspacePersistenceTests`, `WorkspaceStoreRepairTests`, `git diff --check`, `script/precommit.sh`.
