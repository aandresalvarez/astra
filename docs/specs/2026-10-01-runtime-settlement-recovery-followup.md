# Runtime settlement recovery follow-up

This branch follows PR #450 without modifying its branch. All six new review
findings are valid. They concern recoverable execution evidence and repeatable
projections, rather than changing permission scope or provider admission.

1. [Recovered session history](https://github.com/aandresalvarez/astra/pull/450#discussion_r4159341058): capture the original session message and record both session projections in shared settlement. Run IDs make repeated projection updates idempotent.
2. [Failed verdict save](https://github.com/aandresalvarez/astra/pull/450#discussion_r4159341065): persist a settlement-start marker before validation and a prepared outcome after finalization. Retry a prepared outcome without repeating validation or plan transitions. An interrupted attempt without a prepared result requires reconciliation; it does not rerun commands.
3. [Truncated checkpoints](https://github.com/aandresalvarez/astra/pull/450#discussion_r4159341074): mirror structured recovery evidence intact, outside presentation limits. Preserve pending runs and their original output even when bounded display history omits older records.
4. [Imported request owners](https://github.com/aandresalvarez/astra/pull/450#discussion_r4159341085): mirror the immutable request ledger and restore owners only when task, source-event and run identities match. Missing ownership is rejected before validation. Legacy mirrors without an owner ledger remain subject to reconciliation; ownership is not invented from current settings.
5. [Checkpoint retention](https://github.com/aandresalvarez/astra/pull/450#discussion_r4159341097): remove full result/progress checkpoints only after their verdict is saved. The bounded verdict remains the audit and downstream-intent record. Cleanup failures do not undo a committed verdict.
6. [Deleted chained task recreation](https://github.com/aandresalvarez/astra/pull/450#discussion_r4159341107): save a dispatch receipt in the child/request submission transaction. User deletion of that child does not erase the parent's consumed intent. Older durable chained events are recognized as dispatch evidence.

Regression coverage includes fresh-store mirror import with a large checkpoint,
reopened-store recovery after failed verdict persistence, a validation command
execution counter, interrupted preparation, session projection deduplication,
checkpoint retention, and deletion of a dispatched child before restart.

Mirrored request and checkpoint policies preserve credential references while
removing secret environment values. Redaction changes only the exported
projection; the original stored request policy remains unchanged.

## PR #464 review corrections

All five follow-up findings were reproduced or confirmed against the owning
services. Validation now has its own durable prepared phase before session-file
writes; finalization completion is recorded separately. A derived-file failure
can retry the projection and finalization without repeating validation or
turning a successful provider result into a failed verdict.

Startup cleanup explicitly saves and exports pruned checkpoints even when no
chained or scheduled work follows. Ordinary file imports quarantine runtime
events and do not restore executable request owners. They require explicit user
resume; trusted local missing-store recovery opts into owner restoration through
an independent policy, rather than inheriting schedule trust.

Mirror queries retrieve only active requests and owners of retained runs before
decoding policies. A malformed owner or checkpoint is omitted individually with
an audit event, so unrelated task mirrors continue to refresh. Regression tests
cover failed projections with a validation counter, durable cleanup after a
second store reopen, default import quarantine even when schedules are trusted,
malformed outer and nested policies, and exclusion of obsolete terminal owners.
