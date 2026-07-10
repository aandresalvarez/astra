# Feedback Report Manual QA — 2026-07-10

## Scope

- Development channel only: `dist/ASTRA Dev.app`
- Support base: `296a107296285eeba11a22b2746f058c477ca16c`
- Feature branch: `alvaro/feedback-report-ui` (unpublished during this run)
- Compiled ASTRA binary SHA-256: `6d24dcf891defa2b15a0df50045449e7bb06b242a6624e73b3750f8c55f4d053`
- No production ASTRA data, runtime provider, backend, or network sender was used.

## Deterministic local report flow

1. Opened **Help → Report a Problem…** in the rebuilt development app.
2. Entered synthetic, non-sensitive text in all three required statement fields.
3. Explicitly disabled application logs and task logs. Browser details, browser screenshots, and macOS diagnostics remained disabled.
4. Selected **Review Evidence**.
5. Verified the exact disclosure preview:
   - manifest SHA-256: `db32bc2453faa7d8551001ecb4e533e9d91ec84b9d58c4a0314f86df92df3a57`
   - disclosed evidence bytes: `0`
6. Selected **Queue Report**.
7. Verified the sheet transitioned to **Queued** and disabled further edits/evidence changes.
8. Read back the development SwiftData store and package boundary:
   - synthetic report ID: `3dd866c9-e54f-487f-9c41-0124d0414d0e`
   - local status: `queued`
   - package path: `packages/3dd866c9-e54f-487f-9c41-0124d0414d0e`
   - upload attempt count: `0`

This proves the V1 client transition is local and deterministic even when no AI runtime or backend is available. PR5 does not claim an upload or contact a third party.

## Accessibility and keyboard evidence

- The Help entry point, sheet, close button, statement fields, blocked-work checkbox, five evidence controls, disclosure preview, review action, queue action, and status all appeared in the macOS accessibility tree.
- Statement fields exposed stable identifiers:
  - `feedback.report.intendedOutcome`
  - `feedback.report.actualResult`
  - `feedback.report.expectedResult`
- Evidence controls exposed distinct stable identifiers for application logs, task logs, browser details, screenshots, and macOS diagnostics.
- `Control-Tab` moved between multiline editors. Plain `Tab` remained an editor input, matching native macOS multiline text behavior.
- The queued state remained readable through `feedback.report.status` and disabled controls that could invalidate the reviewed package.

## Defects found by the real app path

### Sub-millisecond evidence-window mismatch

The first queue attempt failed closed because SwiftData retained sub-millisecond `Date` precision while canonical JSON encoded millisecond timestamps. Outbox adoption compared the two exact representations and rejected the package.

The fix canonicalizes the evidence window once and uses that representation for collection, durable progress/contents, the envelope, and adoption. Regression coverage captures the provider interval and proves it equals the persisted and decoded envelope interval before queueing.

### Abandoned preview retention

The failed pre-fix preview remained under the trusted preparation root after process termination. That directory could contain sanitized logs, so view-disappearance cleanup alone was not a sufficient retention boundary.

The launch-time reconciler now removes only direct canonical ASTRA preview and construction directories. It rejects malformed entries, regular files, child symlinks, and symlinked storage ancestors. The regression preserves external sentinels for both child- and ancestor-symlink attacks.

Latest-app launch proof:

- launched PID: `68770`
- abandoned synthetic staging directory removed: `feedback-0cac8f92-768f-4df8-a3cf-c83ff549a4b9`
- queued package `3dd866c9-e54f-487f-9c41-0124d0414d0e` remained present
- queued SwiftData status and upload attempt `0` remained unchanged

## Validation receipts

- Root-cause regressions: 2/2 passed.
- `FeedbackReportPresentationTests`: 40/40 passed.
- Integrated feedback/privacy/runtime/outbox/crash/dock matrix: passed.
- `ArchitectureFitnessTests.ArchitectureFitnessTests`: 61/61 passed.
- `script/focused_test_targets_tests.sh`: passed.
- `git diff --check`: passed.
- Independent read-only correctness review: passed with no open findings against the code/test snapshot.
- `script/precommit.sh`: passed.
- `script/prepush.sh`: passed.
- Full `swift test --no-parallel`: 4,807/4,807 passed across 474 suites in 238.987 seconds.
- `script/build_and_run.sh --verify`: passed under restored disk headroom; ASTRA Dev launched as PID `79329`.

## Environmental note

The cold Swift build reduced free disk space to roughly 200 MiB. One packaging attempt copied the healthy compiled executable and then left the bundle executable empty when `install_name_tool` ran without enough working space. The compiled Mach-O hash was preserved, the worktree build cache was cleaned, the bundle executable was restored, its Sparkle runpath was added with sufficient space, the bundle was re-signed, and `codesign --verify --deep --strict` passed before the manual launch. That failed packaging attempt is not counted as a successful receipt. After restoring 2.2 GiB of free space, the unmodified normal `script/build_and_run.sh --verify` path passed and launched PID `79329`; that later run is the publication receipt.
