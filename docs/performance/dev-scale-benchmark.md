# Full ASTRA Dev scale benchmark

This opt-in benchmark runs the complete, already-built development application.
It changes no application code and requires no startup/sidebar instrumentation
from another PR. Timings and memory sizes are observations, never CI thresholds.
The Python isolation tests and exact fixture counts are functional checks.

## Run

Check disk capacity before building. A full app/test build needs several GiB;
the fixture database is approximately 332 MiB and each run needs a disposable
database, workspace copy, app copy, and room for runtime SQLite snapshots.
The runner refuses to start below 700 MiB free. Allow several GiB for repeated
runs; the free-space check is not a reservation against concurrent builds.

```sh
df -h .
# Build model modules and a Dev bundle in this checkout when needed.
swift build --target ASTRAModels
# The standard bundle script refuses cross-bundle Dev takeover. Do not override
# that protection when another checkout owns the running development app.
./script/build_and_run.sh bundle

python3 script/benchmarks/dev_scale_benchmark.py \
  --app "$PWD/dist/ASTRA Dev.app" \
  --build-dir "$(swift build --show-bin-path)" \
  --output "$PWD/.artifacts/dev-scale-baseline" \
  --runs 3 --cycles 5 --idle-seconds 10
```

The supplied app and compiled modules may also be an existing matching baseline
build, read only. This is useful on a shared disk: no other checkout's build
directory, bundle, branch, or data is modified. `--build-dir` accepts SwiftPM's
native `Modules`/object directories and Xcode's combined module/object output.
The fixture tool compiles alongside the actual `SidebarTaskFetch.swift`, reusing
the existing sidebar benchmark's descriptor and field reads.

The controller requires Accessibility access for its invoking application and a
logged-in macOS GUI session. It refuses every app except its uniquely identified
benchmark bundle. Run only one UI benchmark at a time. The runner holds
`/private/tmp/astra-dev-scale-benchmark.lock`; ASTRA's normal per-store lease is
also acquired by each isolated app. Other UI automation on the shared desktop
can invalidate a click; such a failed run is not a latency sample.

## Isolation

Each launch gets a new copied bundle with a unique
`com.coral.ASTRA.dev.scalebench.<UUID>` preferences domain. Its packaged and
linked channel remain development, so updates remain disabled. The runner sets
`ASTRA_DEV_APP_SUPPORT_DIR` to a new child of
`~/Library/Application Support/ASTRA Scale Benchmark/<UUID>/AstraDev`, the
location admitted by the existing development storage policy. It does not
replace `HOME`, provider identity, or normal development preferences.

Only the generated database is backed up with SQLite. Generated workspace and
artifact paths in that private copy are relocated before opening it. All
registered workspace roots and the workspace-recovery preference point into
that run's own output directory. No user store, task text, task folder, plugin,
credential, or provider execution is used as fixture input. Development logging
still follows the application's existing channel logging policy.

`lsof` verifies that the launched PID actually opened its disposable store and
did not open the normal production/development store. The runner never uses
`open`, `killall`, cross-bundle takeover, or process-name termination. It stops
only its own `Popen` child. A controller must acquire the owned app's foreground
focus before posting input. Existing ASTRA processes remain running.

Diagnostics and synthetic stores are retained for inspection; each copied app
bundle is removed after its owned process exits, so it cannot later be opened
without the isolated launch environment. Normal ASTRA file/URL handlers are
removed from the temporary bundle metadata. The output directory and
the isolated App Support parent carry `synthetic-benchmark.json` owner markers.
After all owned app processes exit, those specific marked directories may be
removed. Do not remove the normal Astra/AstraDev roots or other chats' outputs.

## Fixture dimensions

Seed: `0xA57A` (42362). IDs and record timestamps are deterministic; paths vary
with the disposable root. Every task has a distinct ID and a 5,040-byte goal.
All tasks and runs are terminal, with no execution requests or schedules.

| Dimension | Full fixture |
|---|---:|
| Workspaces | 23 |
| Tasks | 2,195 |
| Task events | 115,977 |
| Runs | 5,868 |
| Artifact database records | 30,110 |
| Long thread | 30,000 events |
| History-heavy workspace | 425 tasks, 15,259 events, 1,236 runs |
| Two-thread workspace | Long thread plus a two-event short thread |
| Initial regular task-folder files | 48,414 |
| Initial logical task-folder bytes | 2,230,871,040 (2.08 GiB) |
| Initial allocated task-folder bytes on baseline host | 198,299,648 (189.1 MiB) |
| Long-thread folder | 862 files |

File bodies are sparse synthetic text files, each 46,080 logical bytes. They
reproduce file-list and path pressure while conserving shared disk space; they
do not reproduce realistic document previews, file contents, or compression.
Artifact rows are a separate database dimension and do not imply that a body
was read. Events mix user messages, responses, and tool-result text; runs contain
synthetic output. This reproduces counts and selected workloads, not the full
distribution of a person's real data or four days of app uptime.

The generator checks persisted model counts and enumerates file count, logical
size, and allocated size. The runner verifies the cloned file count before
launch and checks that task/event/run/artifact/workspace row counts remain
unchanged after the workload. Instructions change intentionally through the UI.

For a file-volume control, reuse exactly the same seeded database and omit its
initial task-folder files:

```sh
python3 script/benchmarks/dev_scale_benchmark.py \
  --app "$BASELINE_DEV_APP" --build-dir "$BASELINE_BUILD_DIR" \
  --tools "$PWD/.artifacts/dev-scale-baseline" \
  --fixture "$PWD/.artifacts/dev-scale-baseline/fixture-data" \
  --omit-task-files --output "$PWD/.artifacts/dev-scale-without-files" \
  --runs 3 --cycles 5 --idle-seconds 10
```

ASTRA may create its own task state/history files during either workload. The
control changes initial physical files, keeping the same database record counts,
IDs, history, goals, and artifact paths relative to the workspace. It does not isolate file previews from
file indexing or every UI consequence of absent files.

For the separate sidebar model-fetch experiment, use the compiled fixture tool
in fresh processes. The `sidebar-4` and `sidebar-23` profiles each have 2,195 tasks;
`sidebar-4-small` and `sidebar-23-small` each have 17. All four omit events, runs,
artifacts and task-folder files, with distinct 5,040-byte goals. These change
workspace and task counts independently. `sidebar` reports milliseconds and charged physical
footprint delta in bytes while the fetched rows are still retained:

```sh
BENCH="$PWD/.artifacts/dev-scale-baseline"
for profile in sidebar-4-small sidebar-23-small sidebar-4 sidebar-23; do
  "$BENCH/fixture" seed "$BENCH/$profile" "$profile"
  for run in 1 2 3; do
    "$BENCH/fixture" sidebar "$BENCH/$profile" "$profile"
  done
done
```

Each invocation prints JSON; retain stdout per invocation because the convenience
`sidebar-counts.json` file is replaced. Existing `SidebarTaskFetchBenchmarkTests`
remain available through `RUN_UI_STRESS=1 script/swift_test.sh --no-parallel
--filter SidebarTaskFetchBenchmarkTests`; their historic 726-task row-width/sort
comparison is a different experiment from this full-app baseline.

## Workload and measurement boundaries

`dev-scale-plan.json` defines one warm-up followed by identical measured cycles:

1. Expand/collapse the 425-task workspace; wait for its first eligible task row
   to appear/disappear. Open the two-task workspace and wait for its long row.
2. Select the long thread and wait for a specific late response, open/close the
   Files shelf, and select the short thread, waiting for its own user message.
3. Open the history-heavy workspace configuration, edit instructions, click
   Save, and verify the exact new instructions in its recovery mirror. Close
   its folder and return to the workspace home for the configured idle interval.

The click clock starts immediately before posting native mouse-down/up events.
It stops when the expected accessibility content is observed. Initial readiness
must be false; a stale selected task or an already open panel is rejected.
Targets use ASTRA's existing accessibility identifiers. Each target's geometry
must stop moving before input; that setup wait is outside the click clock. Mouse
presses last 50 ms. The workspace context menu uses its supported `AXShowMenu`
action; its item and the Files toolbar use `AXPress`. These activations are
labeled separately from mouse-click timings. Readiness queries batch
attributes, stop at the first match, exclude global macOS menus, and poll every
20 ms between queries. Failed/incomplete accessibility reads cannot prove an
element absent. `last_ready_probe_ms` exposes the final query's observation cost.

These are **click-to-accessibility-ready upper bounds**, including UI input
queueing, view work, accessibility query cost and polling. They do not measure
pixels presented on screen or split queue delay from handler execution. A fresh
process launch is timed from `Popen` to the long thread's sidebar row. macOS file
caches are not purged, so “cold” means a new process/store copy, not a cold disk.
Each launch also starts a new preferences domain, so first-profile/per-build
startup work is included. This is not a same-profile restart measurement.
Save-to-mirror time starts at external controller dispatch and includes helper
startup; it is recorded separately from click-to-editor-dismissal.

At launch, after warm-up, after each cycle, after each idle period and at final
idle, `vmmap -summary` supplies current and lifetime peak **physical footprint**.
Units in JSON are bytes; MiB means 1,048,576 bytes. vmmap's displayed units have
limited precision. Footprint includes charged compressed pages; RSS is not
substituted. The measured process is ASTRA, not the Python controller, SwiftPM
tests, or a sum with WebKit helpers. Browser is not exercised in this plan.

`heap --noContent -s` records live allocation counts/sizes by class after warm-up
and at final idle. `leaks --noContent -q` is corroborating evidence. Compare
allocator categories, live heap, and idle footprint across cycles: a higher
footprint alone does not identify live owners or establish a leak, and zero
Leaks findings does not exclude reachable retained state. For owner/reference
trees, use an Allocations trace attached explicitly to the owned PID; inspect
that trace before sharing it.

`report.json` records the app's embedded revision/build/date, source executable
(before re-signing) and
controller/source hashes, fixture counts, requested runs/cycles, raw action and
memory samples, host/model/RAM/toolchain/power, free disk, load averages and a
process-name/CPU snapshot. Preserve run-level values and describe contention
when comparing revisions. Never treat a comparison between different host
conditions or different workloads as a causal estimate of a fix.

For a changed UI, `--prepare-only` launches a supervised disposable app and
writes `ax-launch.json` plus its PID. Inspect that process while the command
remains running; do not relaunch its bundle without the store override. Quit
the owned app to end preparation. Customize `--plan` only after verifying its
ready conditions. Failed preparation attempts are excluded from baseline runs.

## Checks

```sh
python3 script/benchmarks/test_dev_scale_benchmark.py
script/swift_test.sh --package-path Tests/ArchitectureFitnessTests
git diff --check
```

The Python tests verify footprint units/peak parsing and that SQLite relocation
changes only the disposable backup, leaving the source database and files intact.
They also inject disk-full during bundle staging and verify that only the partial
copy is removed.
These tests do not launch the application or assert machine-specific performance.

## Recorded baseline

The [November 2 baseline](baselines/2026-11-02-b7908367.md) records six complete
full-app processes and twelve standalone sidebar samples against the common
`b7908367b8fe` build, including source JSON, invocation, observation overhead,
allocation evidence, Leaks findings and limitations.
