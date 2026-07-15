# Memory Leak and Retained-Growth Validation

Use the development channel only. Memory profiling must never load production
App Support, Keychain state, or workspaces.

## What counts as a failure

Three different failure classes need different evidence:

1. **Ownership leak:** an object remains strongly reachable after its owner has
   released it. `MemoryLifecycleTests` uses weak references for deterministic
   regression coverage.
2. **Unbounded retained state:** a cache or preference is still reachable by
   design but grows with every task, conversation, or file. Hard count limits
   and LRU tests cover this class.
3. **Process growth:** ASTRA or a WebKit helper keeps allocating across repeated
   open/close cycles. Allocations generations, Leaks, VM Tracker, and repeated
   process measurements are required to distinguish a leak from allocator
   warm-up or a legitimate cache high-water mark.

A passing stress suite does not prove the app is leak-free. Stress tests provide
repeatable pressure and enforce bounded owners; Instruments provides heap and
reference evidence in the running application.

## Durable ownership contracts

- Remembered canvas preferences are task-owned SwiftData state. Deleting a task
  deletes its preference naturally, and explicit preference writes touch only
  that task instead of rewriting a process-global conversation map. The legacy
  version-1 defaults dictionary is imported once at startup, then removed only
  after the migrated task values save successfully.
- The terminal task snapshot cache remains capped at 12 entries.
- Files snapshots remain capped by their existing store capacity and the
  5,000-node scan limit.
- Per-task browser sessions use a soft cap of six. An active, loading, or
  agent-driven session may temporarily exceed the cap because interrupting
  active work is worse than a short-lived memory excess. Eligible sessions are
  reclaimed in deterministic LRU order and explicitly torn down.
- Task and workspace Markdown sessions are released with task/workspace
  deletion and with their window-scoped store. Dirty editor state must never be
  discarded merely to meet a memory target.

## Deterministic automated checks

Run focused ownership and bound checks first:

```bash
swift test --filter 'MemoryLifecycleTests|PanelLayoutGeometryTests|ShelfBrowserPanelLayoutTests|RightPanelPresentationModelTests'
```

Run all opt-in UI stress suites with repeated process summaries:

```bash
ASTRA_MEMORY_STRESS_RUNS=3 script/run_memory_stress.sh
```

The harness writes per-run logs plus `summary.json` under
`.artifacts/memory-stress` by default. It records maximum resident set size and
peak memory footprint for trend comparison. These values include SwiftPM test
process overhead and are not an application leak verdict. Compare the same
machine, toolchain, commit type, and workload; investigate a sustained upward
shift before adding a threshold.

The normal `CI` workflow keeps deterministic lifecycle and bounded-retention
tests as merge blockers through the full Swift suite. The separate,
non-blocking `Memory Monitoring` workflow runs the repeated stress harness and
the focused Address Sanitizer lane daily or by manual dispatch. Address
Sanitizer catches use-after-free, buffer errors, and related memory safety
faults; it does not replace Allocations or Leaks for retained objects.

Run the monitoring workflow manually with:

```bash
gh workflow run memory-monitoring.yml
```

Each run publishes `summary.json` in the GitHub Actions run summary and retains
it as an artifact for 30 days. Failed stress runs also retain their detailed
test and timing logs for 14 days. Successful runs do not retain those verbose
logs, and CI never retains full Instruments traces automatically.

## ASTRA Dev Instruments procedure

Build and open the development app:

```bash
./script/build_and_run.sh --verify
```

Warm up the target surfaces once before measuring. Then start the local trace:

```bash
ASTRA_MEMORY_TRACE_DURATION=3m script/record_memory_trace.sh
```

While the recording is active, perform 50 or more identical cycles:

1. Select a deterministic development task with a long transcript.
2. Open and close Files.
3. Open a Markdown preview, then close it.
4. Open Browser, visit the local test page, then close it.
5. Switch to a second task and return.

Use an Instruments **Allocations** trace with generation marks after warm-up,
after the first measured block, and after the final block. Inspect persistent
growth by type and use Memory Graph or reference trees to identify the owner.
Run the **Leaks** instrument as corroborating evidence; zero reported leaks does
not rule out an object that is still reachable through an unintended owner.

The script refuses to attach to `ASTRA.app`, records with `--noContent` for the
post-run Leaks summary, and writes a local `.trace` plus a small Markdown
summary under `.artifacts/memory-trace`.

## WebKit process accounting

Browser memory is split between ASTRA and one or more
`com.apple.WebKit.WebContent` processes. A browser investigation must record
both:

- ASTRA retained objects, session-store counts, delegates, observers, bridge
  listeners, and `WKWebView` ownership; and
- WebContent physical footprint before warm-up, after the first cycle block,
  and after the final block.

Do not add ASTRA and WebContent into one unexplained number. A stable ASTRA heap
with a growing WebContent process points to different ownership and remediation
than an ASTRA-side `ShelfBrowserSession` retain cycle.

## Artifact policy

- Always retain the sanitized JSON/Markdown summary for a scheduled run.
- Upload a full `.trace` only for a failed threshold, a manually requested
  investigation, or release validation.
- Retain failure traces for 7–14 days and summaries for 30 days.
- Treat `.trace` files as potentially sensitive. Do not publish them or attach
  them to a public issue without inspecting their contents.

## Acceptance criteria

- Lifecycle tests prove released owners deallocate.
- App-owned collections remain within their documented hard or soft bounds.
- Repeated stress runs pass without sanitizer findings.
- After warm-up, later Allocations generations reach a stable plateau rather
  than retaining one new owner graph per cycle.
- ASTRA and WebContent are evaluated separately.
- Any regression includes a focused ownership/count test before the fix lands.
