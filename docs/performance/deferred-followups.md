# Performance — deferred follow-ups

Recorded during the launch-time / memory / "make it lighter" performance work.
Most review items shipped (cold-launch deferral, browser-session eviction, binary
strip, auto-export off-main, etc.). The items below were **deliberately deferred**
with rationale, plus the measurement triggers that should gate the larger ones.

## 1. Workspace auto-export debounce (follow-up to the off-main export)

**Status:** partial — off-main + compact + atomic shipped; coalescing deferred.

`WorkspaceConfigManager.autoExport` now snapshots the `WorkspaceConfig` on the
main actor and hands the JSON encode + atomic file write to
`WorkspaceAutoExportWriter` (a serialized `actor`), dropping the synchronous
`encode(.prettyPrinted)` + `data.write` stall from every `modelContext.save()`
on a live run.

What's **not** done: rapid saves still each enqueue one detached encode+write.
A debounce already exists (`WorkspacePersistenceCoordinator.scheduleAutoExport`,
600 ms) but the hot run path calls `saveAndAutoExport` directly. Routing
non-terminal saves through the debounce would coalesce bursts. Deferred because
it requires classifying ~60 `saveAndAutoExport` call sites as terminal vs
non-terminal and changing `saveAndAutoExport` semantics — too broad for the
contained step. The encode+write is now off-main, so the remaining cost is
background CPU, not a main-thread stall.

## 2. Serif variable-font static-instancing — DEFER (not safe, not tooled)

`Astra/Resources/Fonts/SourceSerif4[opsz,wght].ttf` is ~1.18 MB and the largest
single resource. Static-instancing was considered to shrink it but is **deferred**:

- **Tooling absent here:** no `pyftsubset` / `fontTools` available, so the font
  cannot be instanced/subset in this environment.
- **The app uses the full variable range:** the serif is requested at ~53
  heading/excerpt call sites (sizes 15–30 pt) across `.regular`/`.semibold`/`.bold`
  via `StanfordTheme.brandFont()`, and CoreText walks the `opsz` axis across that
  span. Flattening to one weight/opsz would visibly regress heading contrast and
  optical-size adaptation — a design change requiring before/after visual QA.
- **Test coupling:** `Tests/ThemeTests.swift::bundledTypographyFontsArePackaged`
  pins the bundled font filenames against `StanfordFontRegistrar.bundledFontResourceNames`.

If revisited: pin `opsz` while preserving `wght` via `fontTools.varLib.instancer`
on a machine with the tooling, then run a full typography visual pass.

## 3. View-file splitting — DEFER (not a perf item)

Splitting the 5–7K-line view files (`TaskMainView.swift`, `ConfigureView.swift`,
etc.) is **compile-time only, zero runtime/perf benefit** (SwiftPM links one
static executable). Track it as a DX/build-time task, not under performance, and
weigh it against merge/regression risk across the many call sites in those files.

## 4. `@ModelActor` / background ModelContext — DEFER pending measurement

Every SwiftData insert/save/fetch/compaction runs on the single main-actor
context (there are **zero** `@ModelActor` declarations; `AstraIntentDataSource`
is a `@MainActor enum`, not a model actor). Under heavy multi-agent fan-out this
is the theoretical responsiveness ceiling, but it is a **large, risky refactor**
and should be deferred until measurement justifies it.

**Trigger:** Instruments (Time Profiler / SwiftData) shows main-thread DB stalls
during multi-worker fan-out — not before.

**Why risky:** SwiftData `@Model` objects aren't `Sendable`; a background context
means passing `PersistentIdentifier` and re-fetching everywhere, reworking
`OrderedMainActorTaskQueue` ordering, reconciling with `@Observable @MainActor`
view models + SwiftUI `@Query` reading the same objects live, and the codebase
hazard that **`#Predicate` enum-equality silently matches nothing on the
in-memory store** (predicate on nil/Bool/String, refine enums in memory).

**First candidates if/when justified, in priority order:**

- **A. Run-boundary save + export** (`WorkspacePersistenceCoordinator.saveAndAutoExport`).
  The synchronous file-write half is **already addressed** by the off-main
  `WorkspaceAutoExportWriter` (item 1). What remains on main is `modelContext.save()`
  itself, which must stay synchronous for correctness — so a background **save**
  context is the next lever here, not the write.
- **B. Streaming event inserts** (`AgentEventRecorder.record*`, append-only
  `TaskEvent` inserts via `OrderedMainActorTaskQueue`) — lowest-coupling slice to
  move to a background writer (no mid-stream UI read-back).
- **C. Compaction** (`AgentEventCompactor.compactEvents`, fetch+delete, 200/keep 50)
  — good batched-delete background candidate, but gated by `CompactionTests` (8
  `@MainActor` tests call it directly), so any isolation change has test impact.
