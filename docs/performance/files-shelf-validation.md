# Files Shelf Responsiveness

Use the development channel for validation. Do not point a feature build at the
production workspace store.

## Root cause and ownership

The Files shelf used to enumerate every available workspace and task root on
each appearance, then publish as many as 5,000 nodes in one main-actor update.
Its view also repeatedly filtered the complete node array per root and prepared
the first file preview synchronously. The generic shelf transition event ended
when the SwiftUI shell committed, so it could not distinguish those costs.

The filesystem remains the durable source of truth. The shelf now:

1. selects task, workspace, or all roots before scanning;
2. presents a bounded derived snapshot cache, then always refreshes it;
3. pre-groups nodes by root and pre-normalizes their searchable text;
4. prepares list filtering and file previews off the main actor; and
5. applies only immutable snapshots on the main actor.

The cache is intentionally stale-while-refresh. It must never be treated as a
second owner of workspace contents.

## Measurements

The Logs window and diagnostic bundle expose these privacy-safe Performance
events. They contain counts, buckets, abbreviated IDs, scope, and cache state;
they never contain file paths, names, or content.

```text
event=files_shelf_to_chrome_ready
event=files_shelf_to_first_results
event=files_shelf_to_index_ready
event=files_shelf_index_scan
event=files_shelf_preview_load
```

`files_shelf_to_first_results` is the user-visible warm/cold milestone.
`files_shelf_to_index_ready` is the authoritative refresh completion. Compare
`cache_state=hit`, `refresh`, and `miss` cohorts separately. The index-ready
interval is also emitted as an Instruments signpost.

Warnings currently begin at 250 ms for chrome, 750 ms for first rows or preview,
and 1,000 ms for index completion. These are diagnostic thresholds, not product
SLOs. Establish p50/p95 baselines on representative workspaces before choosing
an SLO.

## Reproduction matrix

Run each case at least three times on the same Mac and build.

| Case | Expected evidence |
| --- | --- |
| Small task folder, cold | `cache_state=miss`; task roots only |
| Large workspace, task scope | workspace size should not affect task scan |
| Large workspace, workspace scope | bounded scan, with `truncated=true` at 5,000 nodes |
| Reopen unchanged scope | first rows from `cache_state=hit`, followed by refresh |
| Change files while shelf is open | refreshed snapshot replaces cached rows |
| Search a 5,000-node shelf | no main-actor stall while filtering |
| Select a slow preview then a fast file | latest selection wins; stale preview is discarded |

For a slow trace, correlate the Files events with SwiftUI, Time Profiler,
Hangs/Hitches, and the `os_signposts` track in Instruments.

## Automated checks

```bash
swift test --filter 'FilesShelfResponsivenessTelemetryTests|ShelfFileIndexControllerTests|ShelfMarkdownAsyncLoadingTests|WorkspaceFileIndexStoreTests'
RUN_UI_STRESS=1 swift test --filter UIStressFilesShelfTests
swift test --filter ArchitectureFitnessTests
swift test
./script/build_and_run.sh --verify
git diff --check
```
