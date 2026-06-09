# Spec: persistent Local-MLX helper (model resident across turns)

**Status:** implemented behind an OFF-by-default flag. The app-side (session client, settings flag,
orchestrator wiring) is **compile-verified** (`swift build` green). The helper `serve` loop is written
and its MLX API usage is verified against pinned upstream (`mlx-swift-lm` 3.31.3), but a full **native
build + runtime test on Apple Silicon is still required** (the nested package can't be resolved from a
non-`astra` worktree directory, so it must be built from the canonical checkout via
`script/build_and_run.sh`). Targets the per-turn-reload finding from the PR #94 review.

## Problem (verified in this branch)

- `Tools/AstraLocalModelNative/.../main.swift` — the `run` path calls `MLXLMCommon.loadModelContainer`
  on **every** invocation, generates once, emits `completed`, optionally idles for `keepWarmTTL`, then
  the process **exits**.
- `Astra/Services/LocalAgentOrchestrator.swift:3782` — `runProcess` spawns a fresh
  `AgentExecutionScopedProcess` per call; the loop at `:768` (`for turn in 1...maxTurns`) calls it once
  per turn. Net: **N cold multi-GB model loads** + **O(N²) prompt re-tokenization**.
  `keepWarmTTLSeconds` (`:3754`) is plumbed but inert across turns.

## Design: one persistent helper per run

Load the model once; serve many turns; keep `ModelContainer` resident. Reuse the existing transport —
**no new fds, no port, no Python**:

```
                       fd 4 (control, app → helper)            fd 3 (events, helper → app)
  app  ──{"type":"run","requestFile":…,"requestID":id}──▶  helper   ──started/text/stats/…──▶  app
       ──{"type":"cancel","requestID":id}─────────────▶  (cancels current generation only)
       ──{"type":"shutdown"}────────────────────────▶  (exits 0)     ──completed{requestID:id}─▶ (turn done)
```

Turns are **strictly sequential** (the orchestrator `await`s each `generate`), so there is only ever
one in-flight turn — the app routes all fd-3 envelopes to the current turn and resolves it on the
terminal envelope (`completed`/`failed`/`cancelled`) whose `requestID` matches. `cancel` cancels the
**current generation** (not the process); `shutdown` exits. Single-shot `run` is **kept** for Local
*Chat* and `--smoke`; only the *Agent* loop uses `serve`, gated behind a setting.

### ⚠️ Transport correction (discovered during implementation)

The control pipe (fd 4) **auto-closes after the first write**: `AgentExecutionScopedProcess
.writeControlData(...)` calls `closeControlWriteIfNeeded()` (`AgentProcessSupport.swift:265-288`). So
`requestCancellation` is inherently one-shot. A persistent session must send **many** control
messages, so we add an **additive, non-closing** `sendControl(_:)` (this commit) and switch the helper
from `readDataToEndOfFile()` (one message at EOF) to a **line-delimited read loop**. `requestCancellation`
is untouched, so every other runtime's cancel semantics are unaffected.

---

## What landed in this commit (build-verified, app-side)

1. **`ASTRACore/LocalModelProtocol.swift`** — `LocalModelControlMessage` gains optional `requestID` +
   `requestFile` and `run(requestID:requestFile:)` / `shutdown()` factories; `LocalModelProtocolEnvelope`
   gains optional `requestID`. All backward-compatible (synthesized `encodeIfPresent` omits nil keys;
   versioned via `v`).
2. **`Astra/Services/Runtime/AgentProcessSupport.swift`** — `sendControl(_:)` (writes a control message
   **without** closing fd 4) + `closeControl()` (ends the session's input stream on shutdown).

These compile against the app target (`swift build` green) and have **no behavioral effect yet** — they
are the transport/protocol foundation the behavioral layer below consumes. No regression to the existing
single-shot path.

---

## Behavioral layer (implemented; helper pending native build + runtime test)

> Implemented in `main.swift` (`runServe`/`generateServeTurn`/`ServeControlChannel`),
> `LocalAgentOrchestrator.swift` (`LocalAgentInferenceClient` persistent session +
> `defer { inferenceClient.shutdown() }`), and `LocalModelSettingsStore.persistentHelperEnabled()`
> (default OFF). The app-side is compile-verified; the helper still needs a native build + the parity
> runtime test below. The original design notes follow.

### A. Helper `serve` mode — `Tools/AstraLocalModelNative/.../main.swift`

Add a `serve` subcommand that loads once and loops. Factor the generation body of `runInference`
(from `let parameters = …` through the final `completed` emit) into a shared
`generateOnce(request:container:output:requestID:cancellation:)` — unchanged except it (a) takes an
already-loaded `container`, (b) stamps every `emit(...)` with `requestID:`, (c) does **not**
`loadModelContainer`, **not** `Memory.clearCache()` in a `defer`, **not** `waitForKeepWarmTTL`.

```swift
// in run(arguments:)
guard let verb = arguments.first, verb == "run" || verb == "serve" else { … }
startParentWatchdog()
if verb == "serve" { return await runServe(arguments: arguments) }
// … existing single-shot `run` path UNCHANGED (Local Chat / smoke / fallback) …

private func runServe(arguments: [String]) async -> Int32 {
    let output = protocolOutputHandle()
    let control = ServeControlChannel(handle: protocolControlHandle())   // line-delimited reader (loop, not readToEOF)
    var loadedDir: String?
    var container: ModelContainer?
    let idleTTL = TimeInterval(intArgumentValue("--idle-ttl-seconds", in: arguments) ?? 300)

    while let msg = await control.next(timeout: idleTTL) {     // nil after idleTTL → clean exit
        switch msg.type {
        case "shutdown": return 0
        case "cancel":   control.cancelCurrent(reason: msg.reason)          // cancels in-flight gen only
        case "run":
            guard let path = msg.requestFile, let request = try? loadRequestFile(path) else { continue }
            let token = control.beginTurn(requestID: msg.requestID)         // fresh per-turn token
            do {
                configureMemoryLimits(for: request)
                if request.modelDirectory != loadedDir || container == nil {
                    container = try await MLXLMCommon.loadModelContainer(
                        from: URL(fileURLWithPath: request.modelDirectory ?? "", isDirectory: true),
                        using: #huggingFaceTokenizerLoader())
                    loadedDir = request.modelDirectory                      // RELOAD only on model change
                }
                try emit(.init(type: "started", requestID: msg.requestID, model: request.model), to: output)
                try await generateOnce(request: request, container: container!,
                                       output: output, requestID: msg.requestID, cancellation: token)
            } catch {
                Memory.clearCache()
                try? emit(.init(type: "failed", requestID: msg.requestID,
                                message: error.localizedDescription), to: output)
                // On memoryBudgetExceeded you may `return 1` so a poisoned container is never reused.
            }
        default: continue
        }
    }
    return 0
}
```

`ServeControlChannel` wraps `protocolControlHandle()`: a background loop splits fd-4 on `\n`,
JSON-decodes `LocalModelControlMessage`, and feeds `run` to a continuation the serve loop awaits, sets
the current `LocalModelCancellationToken` on `cancel`, and signals exit on `shutdown`. `beginTurn`
rotates the token; `next(timeout:)` returns nil after `idleTTL` of silence. (This is the one spot to
get right — a blocking `read()` loop on a utility queue feeding an `AsyncStream`/continuation; the
existing `startControlMonitor` is the seed.)

### B. App-side persistent session — `LocalAgentInferenceClient` (`LocalAgentOrchestrator.swift:3720`)

Spawn one helper (`serve`) lazily on first `generate`; install the fd-3 reader **once**; route envelopes
to the current turn; resolve its continuation on the terminal envelope; respawn-on-crash; `shutdown()`
at run end. Send each turn via `process.sendControl(.run(requestID:requestFile:))` (the new non-closing
primitive). `cancel()` → `process.sendControl(.cancel(...))` for the current `requestID`. The request
file is written exactly as today. Full sketch in the PR review thread / prior draft.

### C. Wiring + flag

- `LocalAgentOrchestrator.run(...)`: `defer { inferenceClient.shutdown() }` once the helper path starts.
- `LocalModelSettingsStore.persistentHelperEnabled()` (new, in `LocalModelRuntime.swift:1409`) — default
  **OFF**; when off, `generate` keeps the proven single-shot `run` path (zero regression risk). Local
  *Chat* stays single-shot regardless.

## Validation

1. **Unit (no MLX):** a fake helper speaking the protocol over fds — one process spans multiple
   `generate` calls; `requestID` demux correct; cancel/shutdown/timeout/crash-respawn resolve the right
   turn.
2. **Helper (arm64):** two `run` messages, same model dir → second turn emits **no** `phase:"load_model"`
   and starts in ms, not seconds.
3. **E2E parity:** reuse the `ASTRA_E2E_TEXT_OK` marker harness; compare wall-clock of a 6-turn task
   single-shot vs persistent on a 16 GB Mac — the number that proves it.

## Note on hooks

`script/precommit.sh` does not exist on this branch (it postdates the branch point), so commits here run
with `--no-verify`; correctness is gated by an explicit `swift build` of the app target. The nested
`AstraLocalModelNative` package is **not** built by the app target, so the `serve` changes (section A)
must be verified with the native build (`script/build_and_run.sh` / `build_native_local_model_helper`).
