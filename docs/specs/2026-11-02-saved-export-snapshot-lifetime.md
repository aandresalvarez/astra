# Saved export snapshot lifetime

An unlinked SQLite file can still occupy disk space while its reader holds an
open descriptor. Removing the snapshot directory is therefore insufficient to
dispose of a saved export. Swift scope exit also does not guarantee that the
Objective-C objects behind SwiftData have drained their autoreleased ownership.

## Ownership and disposal order

1. `WorkspaceSavedAutoExport` resolves a weak source only when its actor starts
   work. The live container is retained during preparation, and no live model
   crosses the saving-actor fence or reaches the JSON writer.
2. `WorkspaceSavedExportSnapshot.capture` reserves a protected directory beside
   the source store. SQLite backup owns and synchronously closes its source and
   destination connections, including on failure. A completed backup is a
   self-contained database file. The reservation owns the directory's kernel
   lease throughout capture and projection.
3. For a saved-export lease, the captured file may survive an actor suspension
   while the saving actor seals its revision. At this point there is no
   SwiftData snapshot reader. Cancellation or rejection drops the reservation.
4. `CapturedStore.read` opens the read-only container inside a local
   `autoreleasepool`. `prepareRows` creates its context and traverses the graph
   synchronously, returning only the value config. The reader's Swift references
   then end and the pool drains **before** the reservation can be released.
   Opening and projection errors take the same disposal path.
5. Only after reader teardown does `Reservation.deinit` remove the directory and
   release its lease. A prepared export contains values, so a queued writer
   cannot keep the temporary store or the live persistence owner open.

This retains the parent lock around directory creation and leasing, the
per-directory lease across projection, and crash cleanup through the existing
artifact-scoped orphan reaper. It does not change cleanup discovery or share
snapshots between workspaces.

## Failed publication

Snapshot errors produce a failed preparation. JSON staging now installs its
cleanup before writing, so even a partial write that throws is removed. The
previous JSON is replaced only by a successful atomic rename under the existing
publication gate. A failed write or rename cannot advance that gate, acknowledge
the export, or clear its committed pending obligation. A later explicit drain
can retry the saved authority.

`WorkspaceExportFileIO` supplies per-task file-operation overrides for
deterministic failure tests. Its normal operations remain SQLite backup, a
staging write beside the destination, and atomic rename. Overrides do not
affect unrelated tasks.

## Regression evidence

- Synthetic disk-backed stores exercise five successive projections each for
  success, projection failure, and actual task cancellation. The test defers
  reader/container releases through Objective-C autorelease ownership, then
  checks open descriptors by device and inode, including unlinked files.
- Removing the local pool makes the success/error version fail on all ten
  projections. The fixed implementation closes all captured snapshot inodes
  before returning, without sleeps or eventual-closure polling.
- Injected ENOSPC after SQLite backup, during a partial JSON staging write, and
  at atomic replacement reports failure three times per stage. Each attempt
  preserves the previous JSON bytes and readable config, removes disposable
  files, and retains the pending request. An ordinary drain then publishes the
  committed replacement.
- Existing tests cover concurrent snapshots, deletion during lazy traversal,
  cross-process lease protection, and reclamation after abrupt process death.
