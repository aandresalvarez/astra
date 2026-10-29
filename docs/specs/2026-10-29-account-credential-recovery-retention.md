# Account credential recovery retention

Recovery transfers unverifiable cleanup candidates into immutable retention
debt. These are namespace references, never credential values or deletion
requests. A store change must not make an earlier store's secrets collectible.

## Compatibility with schema-21 collectors

Rejecting a v2 generation journal does not stop an older binary's ordinary
account and workspace deletion collectors. Before publishing a recovery receipt,
ASTRA therefore installs and synchronizes
`account-credential-recovery-v2.json` in both `ConnectorCredentialCleanup` and
`WorkspaceDeletionCleanup`, under the same shared root as the journal. These
are typed protocol fences, not workspace deletions. It contains only a fixed kind and version.

The schema-21 account outbox decoder cannot interpret that record and marks
its listing incomplete, blocking ordinary cleanup regardless of workspace
recovery state. The workspace outbox decoder also returns unknown ownership,
retaining cleanup debt instead of deleting secrets. The fences survive store selection/replacement
because the outbox and generation journal share their root. Older builds can
still open the unchanged SwiftData schema, but cannot safely resume credential
cleanup while this debt exists. A current build is required to settle cleanup.

Current readers skip only the exact verified fences. Unknown versions, damaged
bytes, directories and symlinks still block ownership scans. Current collectors
also require both fences whenever the journal contains a recovery receipt, and
read the actual holds from the journal's verified archives. The fence neither
duplicates those references nor grants deletion authority. Do not remove it
while retained recovery debt exists. No background task removes it.

## Bounded publication and compaction

Normal collection retains its limits of 32 archive reads, 4 MiB in aggregate
and 1 MiB per record. Explicit recovery can read up to 256 archives and 32 MiB
to repair histories produced before publication enforced these budgets.

Recovery verifies the complete admitted source history and deduplicates by
every cleanup fact, preserving distinct generations of the same account. It
preserves the exact source bytes, then creates an immutable, digest-named
snapshot containing all retained references and no recursive receipt. Only
after synchronizing both archives and both compatibility fences does it publish
the active receipt. Publication uses the same history validation as collection.

The receipt names the snapshot as the new owner of retained references and,
when different, names the exact source archive for integrity and investigation.
Older transitive archives remain untouched; collectors no longer need to walk
them after the validated transfer. The snapshot and direct source remain hash
verified. A new recovery normally requires at most two archive reads, each at
most 1 MiB, regardless of how many previous store changes occurred.

A snapshot whose distinct references cannot fit the per-record limit is
rejected before cutover, leaving the source and its recovery action intact.
An already matching journal with an older over-budget chain can be explicitly
repaired; a matching receipt missing its fence can explicitly restore it without
rewriting the journal. Missing or corrupt archive data never authorizes a
partial transfer or deletion.

## Regression evidence

- A frozen schema-21 collector and both historical outbox readers, two
  synthetic stores and a private vault exercise a committed deletion sharing
  an archived legacy alias. The old collector defers with and without a tracked
  workspace scan; current collectors settle debt while preserving the alias and the replacement account's generation.
- Forty real SQLite store replacements accumulate distinct generations without
  losing holds or exhausting normal collection's budget.
- Synthetic legacy histories exercise both the 33-archive and 4 MiB limits,
  with matching and foreign identities, and explicitly repair to bounded
  snapshots without changing any original archive.
- Publication failure, invalid fences, missing-fence repair, oversized distinct
  snapshots and damaged snapshots exercise failure boundaries.
