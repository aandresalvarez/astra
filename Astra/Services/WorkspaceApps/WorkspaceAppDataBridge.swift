import Foundation
import WebKit

/// Vetted data + workflow bridge: lets a sandboxed dynamic HTML app reach **its own** governed
/// capabilities through an `astra.*` JS API. The bridge adds NO new capability — every request is
/// routed through the SAME governed action path the native UI uses (`WorkspaceAppActionExecutor` via
/// the host's `onRunAction` closure), which already enforces the app's `permissionMode`, requires
/// confirmation for destructive ops, records an audit run, and scopes the SQLite file to the app's
/// own `logicalID`. The bridge is only a JS entry point to the existing gate, never a way around it.
///
/// Surface and hard limits:
/// - **Data (Phase 2):** `astra.query/insert/update` against tables the app declares in ITS OWN
///   manifest, only the exact (op, table) pairs it grants as an action (the allowlist). DELETE is
///   deliberately NOT exposed — it is `.destructive` and a JS-minted confirmation would let a page
///   wipe records on load.
/// - **Workflow (Phase 5):** `astra.runAction(id)` triggers a DECLARED action whose type is in
///   `runnableActionTypes` (task.*, pipeline.run, loop.run, artifact.export, notification.show,
///   rows.reduce, clipboard.copy); `astra.runs()` reads this app's recent run snapshots;
///   `astra.actions()` lists the runnable actions.
/// - **Connector reads:** `astra.read(sourceId, {params})` runs a DECLARED `capability.read` against a
///   live connector (the app's real GitHub PRs, a BigQuery table, …) and replies with the resolved
///   SCALAR rows only — credentials NEVER cross back. Read-only by construction: `capability.WRITE` is
///   still EXCLUDED from JS (an external write must go through a gated native path), and the page can
///   read only a source it declares both in `sources` and as a `capability.read` action's `sourceRef`.
///   EXCLUDED: `capability.write` (networked external writes), `gate.*` (a human resolves these in the
///   native approval queue; JS may not mint a decision), `url.open` (arbitrary navigation), and storage
///   delete. The bridge NEVER sets `confirmedApproval`/`confirmedDestructive`, so an approval-required
///   external write triggered from JS SUSPENDS to the native attention queue rather than auto-running.
/// The document CSP (`default-src 'none'`) is unchanged; `postMessage` to native is orthogonal to
/// CSP, so there is still NO network egress.
enum WorkspaceAppDataBridge {
    /// The single message-handler name the injected JS posts to.
    static let handlerName = "astraAppBridge"

    /// A parsed `astra.*` request. `op` ∈ query | insert | update (no delete in Phase 2).
    struct Request: Equatable {
        var op: String
        var table: String
        var record: [String: WorkspaceAppStorageValue]
        var limit: Int?
    }

    /// The native result handed back to JS.
    enum Reply {
        case rows([[String: WorkspaceAppStorageValue]])
        /// (Phase 5) A workflow action's outcome: the run's status (`completed`/`waiting`/…), a
        /// summary, the run id (so the page can poll `astra.runs()`), and any rows it produced.
        case run(status: String, summary: String, runId: String, rows: [[String: WorkspaceAppStorageValue]])
        /// (Phase 5) Recent run snapshots, pre-serialized to JS dictionaries (see `jsRun`).
        case runs([[String: Any]])
        /// (Phase 5) The app's declared JS-runnable actions, as `{id,type,label}` dictionaries.
        case actions([[String: Any]])
        case error(String)
    }

    /// The host-supplied closure that actually runs a resolved STORAGE request through the governed
    /// executor. Built in `WorkspaceAppSurfaceView` from `onRunAction` + the manifest, so preview
    /// (in-memory) and published (SQLite) get parity for free. `@MainActor` because it calls the
    /// SwiftUI host's executor closure.
    typealias Run = @MainActor (Request) async -> Reply

    /// (Phase 5) The full set of host closures backing `astra.*`. `storage` (query/insert/update) is
    /// always present for a data app; the workflow closures are nil for an app that declares no
    /// JS-runnable workflow actions, so a plain data app exposes no `runAction` surface at all.
    struct Handlers {
        var storage: Run
        /// (Connector read bridge) Runs a DECLARED `capability.read` against a live connector and
        /// replies with the resolved SCALAR rows. ASYNC because a connector read is real network I/O the
        /// synchronous storage path can't await; nil unless the app declares a `capability.read` action
        /// AND the host supplies the async executor (published surface only — preview has no bindings).
        var read: (@MainActor (ReadRequest) async -> Reply)?
        var runAction: (@MainActor (ActionRequest) async -> Reply)?
        var runs: (@MainActor (Int?) -> Reply)?
        var listActions: (@MainActor () -> Reply)?
        /// The DURABLE workflow throttle: a LIVE, UNCAPPED query (run each `runAction` call) that
        /// returns true iff the app currently has a non-terminal (waiting/running) run. This is the
        /// security authority — NOT a volatile flag or the capped display snapshot, both of which a
        /// hostile page can defeat (reset on reload; push its waiting run out of an 8-row history with
        /// storage writes, then poll to clear it). nil ⇒ no throttle (preview surface, no persisted runs).
        var isWorkflowRunPending: (@MainActor () -> Bool)?
    }

    /// A fail-closed `Handlers` whose every verb refuses. Installed on a REUSED WebView whose app no
    /// longer grants a bridge (belt-and-suspenders behind the WebView-identity recreation), so a stale
    /// `astra.*` call can never reach the prior app's closures. `read`/`runAction`/… stay nil, so those
    /// verbs reply "unavailable"; `storage` (the one required closure) refuses.
    @MainActor
    static var denyAll: Handlers {
        Handlers(storage: { _ in .error("This app has no data bridge.") })
    }

    private static let allowedOps: Set<String> = ["query", "insert", "update"]
    /// DoS caps: a hostile page can't flood the main actor with giant records. A single value is
    /// bounded (`maxValueBytes`), the field count is bounded (`maxRecordFields`), AND the TOTAL record
    /// size is bounded (`maxRecordBytes`) so 200 near-max fields can't combine into a multi-MB write.
    private static let maxRecordFields = 100
    private static let maxValueBytes = 64 * 1024
    static let maxRecordBytes = 256 * 1024
    /// The largest row count a bridge query may request, regardless of the page-supplied limit — well
    /// below the storage service's own 10k ceiling so a page can't pull a huge reply per call.
    static let maxQueryLimit = 1_000
    /// Connector-read (`astra.read`) row caps — tighter than storage, since each read is a live network
    /// fetch (a `gh` spawn), not a local SQLite query. The page may request fewer; it can never exceed
    /// the max, and an unspecified limit gets the small default.
    static let maxConnectorReadLimit = WorkspaceAppReadPolicy.maxConnectorReadLimit
    static let defaultConnectorReadLimit = WorkspaceAppReadPolicy.defaultConnectorReadLimit

    // MARK: - Parse (JS → native)

    /// Parse the raw `WKScriptMessage.body`. Returns nil for anything malformed, oversized, or
    /// containing unsupported values — the handler then replies with an error instead of touching
    /// storage.
    static func parse(_ body: Any) -> Request? {
        guard let dict = body as? [String: Any],
              let op = dict["op"] as? String, allowedOps.contains(op),
              let table = dict["table"] as? String, !table.isEmpty else {
            return nil
        }
        let record: [String: WorkspaceAppStorageValue]
        if let raw = dict["record"] as? [String: Any] {
            guard raw.count <= maxRecordFields, let strict = strictRecord(from: raw) else { return nil }
            record = strict
        } else {
            record = [:]
        }
        let limit = (dict["limit"] as? Int) ?? (dict["limit"] as? NSNumber)?.intValue
        return Request(op: op, table: table, record: record, limit: limit)
    }

    /// Strictly validate a JS record: every value must be a supported SCALAR within size limits.
    /// Nested objects/arrays, non-finite numbers, and oversized strings reject the WHOLE request
    /// (nil) rather than silently storing nulls/garbage.
    static func strictRecord(from dict: [String: Any]) -> [String: WorkspaceAppStorageValue]? {
        var out: [String: WorkspaceAppStorageValue] = [:]
        var totalBytes = 0
        for (key, raw) in dict {
            guard let value = scalarValue(from: raw) else { return nil }
            totalBytes += key.utf8.count
            if case .text(let string) = value { totalBytes += string.utf8.count } else { totalBytes += 8 }
            guard totalBytes <= maxRecordBytes else { return nil }   // reject an oversized aggregate write
            out[key] = value
        }
        return out
    }

    /// Map a JS value to a typed storage scalar, or nil for anything unsupported (nested object/
    /// array, non-finite number, oversized string). CFBoolean (a JS `true`/`false`) is detected
    /// before the numeric branch, since `NSNumber` also bridges booleans.
    static func scalarValue(from any: Any) -> WorkspaceAppStorageValue? {
        if any is NSNull { return .null }
        if let string = any as? String {
            return string.utf8.count <= maxValueBytes ? .text(string) : nil
        }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let value = number.doubleValue
            guard value.isFinite else { return nil }   // reject NaN / ±Infinity
            if value.rounded() == value && abs(value) < 9.0e15 { return .integer(number.int64Value) }
            return .real(value)
        }
        if let bool = any as? Bool { return .bool(bool) }
        return nil   // nested dict/array or unsupported type → invalid request
    }

    // MARK: - Resolve (allowlist + governance)

    /// Map a request to the DECLARED `appStorage.*` action + input, or nil when the app does not
    /// grant that EXACT (op, table). This is the allowlist: the bridge can only invoke an op the
    /// manifest declares as an action **for that specific table** — so a read-only viewer that only
    /// declares `appStorage.query` on `notes` cannot insert, nor touch any other table. The bridge
    /// never mints `confirmedDestructive` (delete isn't exposed at all). The executor then ALSO
    /// enforces `permissionMode` (a second, independent gate).
    static func resolve(
        _ request: Request,
        in manifest: WorkspaceAppManifest
    ) -> (action: WorkspaceAppActionSpec, input: WorkspaceAppActionInput)? {
        guard allowedOps.contains(request.op) else { return nil }
        guard manifest.storage?.tables.contains(where: { $0.name == request.table }) == true else {
            return nil
        }
        let actionType = "appStorage.\(request.op)"
        // Exact table match: a table-less action does NOT grant the op on every declared table.
        guard let action = manifest.actions.first(where: {
            $0.type == actionType && $0.table == request.table
        }) else {
            return nil
        }
        let input = WorkspaceAppActionInput(
            table: request.table,
            record: request.record,
            limit: min(request.limit ?? 100, maxQueryLimit)   // clamp: a page can't request a huge reply
        )
        return (action, input)
    }

    // MARK: - Workflow bridge (Phase 5)

    /// Action types a dynamic HTML app may TRIGGER from JS via `astra.runAction`. These are the
    /// SELF-GATING / harmless verbs: a `pipeline.run`/`loop.run` (whose external-write steps sit
    /// BEHIND a human-approval gate the pipeline suspends on), plus local-only verbs
    /// (notification.show, rows.reduce, clipboard.copy, task.createDraft — a draft, no agent run).
    /// Deliberately EXCLUDES, even though they may be DECLARED as pipeline steps:
    /// - `appStorage.*` (own query/insert/update verbs; delete never exposed),
    /// - `capability.*` (network — deferred to a future connector bridge),
    /// - `gate.*` (a human resolves these in the native queue; JS must never mint a decision),
    /// - `url.open` (arbitrary navigation),
    /// - **`artifact.export` and `task.createAndRun`** — these write/spawn-agent effects must run only
    ///   INSIDE a gated pipeline, never as a direct JS verb (their effect classes would otherwise let
    ///   a page export/launch without the approval the pipeline gate provides). They reach native only
    ///   as a step of a `pipeline.run` the human approves.
    /// - **`clipboard.copy`** — writes the SYSTEM pasteboard (`NSPasteboard.general`) and is classified
    ///   `.read`, so neither the executor nor a user gesture gates it; a page must not silently
    ///   overwrite the clipboard. HTML copy buttons use the browser's gesture-gated `navigator.clipboard`
    ///   instead. (It is also not declarable in an HTML app — see `isHTMLAppActionAllowed`.)
    /// An action that is itself a STEP of some pipeline/loop is ALSO not directly runnable (see
    /// `isDirectlyRunnable`) — only its parent pipeline is, so the gate can't be skipped.
    static let runnableActionTypes: Set<String> = [
        "task.createDraft",
        "pipeline.run", "loop.run",
        "notification.show", "rows.reduce"
    ]

    /// IDs referenced as a `steps` entry of any pipeline/loop action — internal, reachable ONLY
    /// through the parent pipeline (which gates them), never as a direct `astra.runAction`.
    static func pipelineStepIDs(in manifest: WorkspaceAppManifest) -> Set<String> {
        Set(manifest.actions.flatMap { $0.steps })
    }

    /// True if `action` may be invoked DIRECTLY from JS: its type is a runnable verb AND it is not an
    /// internal step of some pipeline. This is the bridge's top-level allowlist.
    static func isDirectlyRunnable(_ action: WorkspaceAppActionSpec, in manifest: WorkspaceAppManifest) -> Bool {
        runnableActionTypes.contains(action.type) && !pipelineStepIDs(in: manifest).contains(action.id)
    }

    /// A parsed `astra.runAction` request: the declared action id + an optional scalar input record.
    struct ActionRequest: Equatable {
        var actionId: String
        var record: [String: WorkspaceAppStorageValue]
    }

    /// Parse a `runAction` message body, applying the same DoS caps as a storage record. Returns nil
    /// for anything malformed or oversized — the handler then replies with an error.
    static func parseAction(_ body: Any) -> ActionRequest? {
        guard let dict = body as? [String: Any],
              (dict["op"] as? String) == "runAction",
              let actionId = dict["actionId"] as? String, !actionId.isEmpty else {
            return nil
        }
        let record: [String: WorkspaceAppStorageValue]
        if let raw = dict["record"] as? [String: Any] {
            guard raw.count <= maxRecordFields, let strict = strictRecord(from: raw) else { return nil }
            record = strict
        } else {
            record = [:]
        }
        return ActionRequest(actionId: actionId, record: record)
    }

    /// Resolve a `runAction` to a DECLARED, JS-runnable action + input, or nil. The action must EXIST
    /// in the manifest AND be a `runnableActionTypes` member — so a page cannot trigger a storage
    /// delete, a connector write, a gate decision, `url.open`, or an undeclared action. The input
    /// carries only the action's own declared table + the page's scalar record; it NEVER sets
    /// `confirmedApproval`/`confirmedDestructive`, so the executor's permission gate stays the sole
    /// authority (an approval-required run suspends for the native queue instead of auto-running).
    static func resolveAction(
        _ request: ActionRequest,
        in manifest: WorkspaceAppManifest
    ) -> (action: WorkspaceAppActionSpec, input: WorkspaceAppActionInput)? {
        guard let action = manifest.actions.first(where: { $0.id == request.actionId }),
              isDirectlyRunnable(action, in: manifest) else {
            return nil
        }
        return (action, WorkspaceAppActionInput(table: action.table, record: request.record))
    }

    // MARK: - Connector read bridge (capability.read)

    /// A parsed `astra.read` request: the SOURCE id the page wants to read + an optional scalar
    /// parameter record (a filter the source's provider understands, e.g. `{state:"open"}`). Read-only:
    /// there is nothing to persist and the bridge never mints a confirmation, since `capability.read`
    /// is a `.read` effect the executor permits under every permission mode.
    struct ReadRequest: Equatable {
        var sourceId: String
        var record: [String: WorkspaceAppStorageValue]
        var limit: Int?
    }

    /// Parse a `read` message body, applying the same DoS caps as a storage record. nil ⇒ malformed.
    static func parseRead(_ body: Any) -> ReadRequest? {
        guard let dict = body as? [String: Any],
              (dict["op"] as? String) == "read",
              let sourceId = dict["sourceId"] as? String, !sourceId.isEmpty else {
            return nil
        }
        let record: [String: WorkspaceAppStorageValue]
        if let raw = dict["record"] as? [String: Any] {
            guard raw.count <= maxRecordFields, let strict = strictRecord(from: raw) else { return nil }
            record = strict
        } else {
            record = [:]
        }
        let limit = (dict["limit"] as? Int) ?? (dict["limit"] as? NSNumber)?.intValue
        return ReadRequest(sourceId: sourceId, record: record, limit: limit)
    }

    /// Resolve a `read` to a DECLARED `capability.read` action + input, or nil. The page may read ONLY a
    /// source the app declares BOTH as a `sources` entry AND as the EXACT, non-empty `sourceRef` of a
    /// `capability.read` action — so a page can't read an undeclared source, can't make a `sourceRef`-less
    /// action read an arbitrary source (the executor's `normalized` precedence would otherwise let
    /// `input.table` pick the source), and an app with no connector reads exposes no read surface at all.
    /// The input carries the page's scalar params; it NEVER sets `confirmedApproval`/`confirmedDestructive`
    /// (a read needs neither). The executor's dependency binding (appID-scoped, status==.mapped) remains
    /// the sole credential/availability authority — credentials never cross back to JS, only scalar rows.
    static func resolveRead(
        _ request: ReadRequest,
        in manifest: WorkspaceAppManifest
    ) -> (action: WorkspaceAppActionSpec, input: WorkspaceAppActionInput)? {
        // The named source must be a CONNECTOR source (requirementRef set) — never a storage-shadowing
        // source whose id matches an app table. That keeps `astra.read` strictly on the connector path
        // (which the dependency binding gates); app storage is reached only through `astra.query`.
        guard let source = manifest.sources.first(where: { $0.id == request.sourceId }),
              let reqRef = source.requirementRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reqRef.isEmpty else {
            return nil
        }
        guard let action = manifest.actions.first(where: {
            $0.type == "capability.read" && ($0.sourceRef ?? "") == request.sourceId
        }) else { return nil }
        let limit = WorkspaceAppReadPolicy.connectorLimit(request.limit)
        let input = WorkspaceAppActionInput(
            table: request.sourceId, record: request.record, limit: limit
        )
        return (action, input)
    }

    /// Serialize a run snapshot to a JS dictionary for `astra.runs()`. Dates become epoch seconds
    /// (a plain number) so the bridge never hands a native `Date` across the boundary.
    static func jsRun(_ run: WorkspaceAppRunSnapshot) -> [String: Any] {
        var dict: [String: Any] = [
            "id": run.id.uuidString,
            "actionId": run.actionID,
            "status": run.status.rawValue,
            "summary": run.outputSummary,
            "startedAt": run.startedAt.timeIntervalSince1970
        ]
        if let completedAt = run.completedAt { dict["completedAt"] = completedAt.timeIntervalSince1970 }
        if let error = run.errorMessage { dict["error"] = error }
        return dict
    }

    /// The app's directly JS-runnable top-level actions as `{id,type,label}` dicts for
    /// `astra.actions()` — excludes internal pipeline steps (only their parent pipeline is listed).
    static func jsActions(_ manifest: WorkspaceAppManifest) -> [[String: Any]] {
        manifest.actions
            .filter { isDirectlyRunnable($0, in: manifest) }
            .map { ["id": $0.id, "type": $0.type, "label": $0.label ?? $0.id] }
    }

    /// Build the host `Handlers` for a manifest. Kept as plain (non-SwiftUI) code so the nested
    /// `@MainActor` closures don't pressure the View body's type-checker. Returns nil for a pure-UI
    /// HTML app (no storage AND no runnable workflow action) so no bridge is registered. The workflow
    /// closures are nil unless the app declares at least one `runnableActionTypes` action. Every
    /// closure routes through the SAME governed `onRunAction` (permission + audit + app-scoped DB).
    /// The canonical "should this app's HTML surface get an `astra.*` bridge?" predicate — true iff the
    /// app declares its own storage, a `capability.read` connector read, OR a JS-runnable workflow
    /// action. `handlers()` returns non-nil for EXACTLY these manifests, and the SwiftUI surface keys
    /// the WebView's identity on it, so bridge presence and WebView lifetime stay in lockstep. Both
    /// callers MUST use this one definition: when they drifted (the View omitted `capability.read`), a
    /// read app and a bridge-less app shared a WebView and the stale read handler leaked across apps.
    static func isBridgeEligible(_ manifest: WorkspaceAppManifest) -> Bool {
        if manifest.storage?.tables.isEmpty == false { return true }
        if manifest.actions.contains(where: { $0.type == "capability.read" }) { return true }
        return manifest.actions.contains { isDirectlyRunnable($0, in: manifest) }
    }

    @MainActor
    static func handlers(
        manifest: WorkspaceAppManifest,
        runs: [WorkspaceAppRunSnapshot],
        onRunAction: @escaping (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) async throws -> WorkspaceAppActionExecutionResult,
        onReload: @escaping () -> Void = {},
        isWorkflowRunPending: (@MainActor () -> Bool)? = nil,
        onCapabilityRead: (@MainActor (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) async throws -> WorkspaceAppActionExecutionResult)? = nil
    ) -> Handlers? {
        // Eligibility (storage / capability.read / runnable workflow action) is the SAME predicate the
        // surface keys the WebView on — single-sourced in `isBridgeEligible` so they can't drift.
        guard isBridgeEligible(manifest) else { return nil }
        // A directly-runnable action is a runnable type that is NOT an internal pipeline step.
        let hasRunnable = manifest.actions.contains { isDirectlyRunnable($0, in: manifest) }
        let hasReadable = manifest.actions.contains { $0.type == "capability.read" }

        let storage: Run = { request in
            guard let resolved = resolve(request, in: manifest) else {
                return .error("Operation '\(request.op)' on '\(request.table)' is not permitted by this app.")
            }
            do { return .rows(try await onRunAction(resolved.action, manifest, resolved.input).rows) }
            catch { return .error(String(describing: error)) }
        }

        // The connector-read closure: routes a DECLARED `capability.read` through the ASYNC executor
        // (the only path bound to the live native client). nil unless the app declares a read AND the
        // host supplied the async executor — so a preview surface (no `onCapabilityRead`) exposes no
        // read bridge and `astra.read` replies "not available" there.
        let read: (@MainActor (ReadRequest) async -> Reply)? = (hasReadable ? onCapabilityRead : nil).map { execute in
            { request in
                guard let resolved = resolveRead(request, in: manifest) else {
                    return .error("Source '\(request.sourceId)' is not readable by this app.")
                }
                do { return .rows(connectorRows(try await execute(resolved.action, manifest, resolved.input).rows)) }
                catch { return .error(String(describing: error)) }
            }
        }

        guard hasRunnable else {
            return Handlers(storage: storage, read: read, runAction: nil, runs: nil, listActions: nil)
        }

        let runAction: @MainActor (ActionRequest) async -> Reply = { request in
            guard let resolved = resolveAction(request, in: manifest) else {
                return .error("Action '\(request.actionId)' is not runnable by this app.")
            }
            do {
                let result = try await onRunAction(resolved.action, manifest, resolved.input)
                // Refresh the host snapshot so a subsequent `astra.runs()` poll reflects this run
                // (and the throttle re-derives accurately) instead of the run history going stale.
                onReload()
                return .run(
                    status: result.run.status.rawValue,
                    summary: result.outputSummary,
                    runId: result.run.id.uuidString,
                    rows: result.rows
                )
            } catch { return .error(String(describing: error)) }
        }
        let runsHandler: @MainActor (Int?) -> Reply = { limit in
            let capped = max(1, min(limit ?? 50, 200))
            return .runs(runs.prefix(capped).map(jsRun))
        }
        let listActions: @MainActor () -> Reply = { .actions(jsActions(manifest)) }
        return Handlers(
            storage: storage, read: read, runAction: runAction, runs: runsHandler, listActions: listActions,
            isWorkflowRunPending: isWorkflowRunPending
        )
    }

    // MARK: - Reply (native → JS)

    static func jsRows(_ rows: [[String: WorkspaceAppStorageValue]]) -> [[String: Any]] {
        rows.map { row in row.mapValues(jsValue) }
    }

    /// Connector reads cross an external-service boundary. The connector contract should never return
    /// credentials, but this defense-in-depth filter keeps credential-shaped fields out of JS even if a
    /// backend or fake resolver accidentally includes them in row data.
    static func connectorRows(_ rows: [[String: WorkspaceAppStorageValue]]) -> [[String: WorkspaceAppStorageValue]] {
        rows.map { row in
            row.filter { key, _ in !isCredentialKey(key) }
        }
    }

    static func jsConnectorRows(_ rows: [[String: WorkspaceAppStorageValue]]) -> [[String: Any]] {
        jsRows(connectorRows(rows))
    }

    private static func isCredentialKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        let markers = ["token", "secret", "password", "credential", "authorization", "bearer", "oauth"]
        return markers.contains { normalized.contains($0) }
    }

    static func jsValue(_ value: WorkspaceAppStorageValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .text(let string): return string
        case .integer(let int): return NSNumber(value: int)
        case .real(let double): return NSNumber(value: double)
        case .bool(let bool): return NSNumber(value: bool)
        }
    }

    // MARK: - Injected JS API

    /// The `astra.*` API injected at `documentStart`. With `WKScriptMessageHandlerWithReply`,
    /// `postMessage` returns a Promise that resolves with the reply (`{rows: [...]}`) or rejects with
    /// the error string — so the page can `await astra.query("t")`. No data is embedded here; it's a
    /// thin, dependency-free wrapper over the one native channel.
    static let injectedScript = """
    (function () {
      if (window.astra) { return; }
      function call(op, payload) {
        try {
          var body = { op: op };
          for (var k in payload) { if (payload.hasOwnProperty(k)) { body[k] = payload[k]; } }
          return window.webkit.messageHandlers.\(handlerName).postMessage(body);
        } catch (e) {
          return Promise.reject(new Error("astra bridge unavailable"));
        }
      }
      window.astra = {
        query: function (table, opts) { return call("query", { table: table, limit: (opts && opts.limit) || 100 }); },
        insert: function (table, record) { return call("insert", { table: table, record: record || {} }); },
        update: function (table, record) { return call("update", { table: table, record: record || {} }); },
        read: function (sourceId, opts) { return call("read", { sourceId: sourceId, record: (opts && opts.params) || {}, limit: (opts && opts.limit) }); },
        runAction: function (actionId, opts) { return call("runAction", { actionId: actionId, record: (opts && opts.record) || {} }); },
        runs: function (opts) { return call("runs", { limit: (opts && opts.limit) || 50 }); },
        actions: function () { return call("actions", {}); }
      };
    })();
    """
}

/// The `WKScriptMessageHandlerWithReply` that backs `astraAppBridge`. Holds the host's governed
/// closures; dispatches each message by `op` (storage query/insert/update, or the Phase 5 workflow
/// verbs runAction/runs/actions), runs it on the main actor, and replies with the appropriate
/// payload or an error. Registered only for data/workflow HTML apps (see `WorkspaceAppWebReportView`).
final class WorkspaceAppDataBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    /// `var` so the host can refresh the closures (and thus the current manifest allowlist) on each
    /// `updateNSView`, preventing a stale allowlist after an app refinement that changes
    /// storage/actions/permission without changing the HTML.
    var handlers: WorkspaceAppDataBridge.Handlers
    /// Serializes `runAction` (a heavier, side-effectful verb than a storage read): one in-flight at
    /// a time per WebView, so a hostile page can't flood the executor with concurrent task/pipeline
    /// runs. Storage reads/writes are unaffected. Touched only on the main thread (WebKit delivers
    /// these callbacks on the main thread).
    private var runActionInFlight = false
    /// Serializes `read` (a live connector read — network I/O, like `runAction`): one in-flight per
    /// WebView so a hostile page can't flood the executor with concurrent connector fetches. Storage
    /// reads/writes are unaffected. Touched only on the main thread.
    private var readInFlight = false
    /// Start time of the last accepted `read`, for the min-interval throttle below. Main-thread only.
    private var lastReadStartedAt: Date?
    /// Minimum gap between connector reads on one WebView. On top of the one-in-flight serialization,
    /// this bounds how fast a looping page can spawn live fetches (`gh` processes) and audit runs, so a
    /// `setInterval`-style poll can't grow the run log or hammer the connector without limit.
    private static let minReadInterval: TimeInterval = 0.5

    init(handlers: WorkspaceAppDataBridge.Handlers) {
        self.handlers = handlers
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let op = (message.body as? [String: Any])?["op"] as? String
        switch op {
        case "runAction":
            guard let runAction = handlers.runAction,
                  let request = WorkspaceAppDataBridge.parseAction(message.body) else {
                replyHandler(nil, "Invalid astra runAction request.")
                return
            }
            // Anti-concurrency pre-filter for the same WebView.
            if runActionInFlight {
                replyHandler(nil, "Another action is already running.")
                return
            }
            runActionInFlight = true
            Task { @MainActor in
                defer { self.runActionInFlight = false }
                // The DURABLE throttle, checked HERE (not before scheduling) so it is ATOMIC with the
                // synchronous executor on the serial main actor: a second WebView's task can't run
                // between this check and the run insertion, so two surfaces for the same app can't both
                // pass and double-launch. The query is live + uncapped and fails CLOSED on error.
                if self.handlers.isWorkflowRunPending?() == true {
                    replyHandler(nil, "A workflow run is already in progress — wait for it to finish or be approved.")
                    return
                }
                Self.reply(await runAction(request), to: replyHandler)
            }
        case "read":
            guard let read = handlers.read,
                  let request = WorkspaceAppDataBridge.parseRead(message.body) else {
                replyHandler(nil, "Invalid astra read request.")
                return
            }
            // Anti-concurrency pre-filter: one live connector read in flight per WebView.
            if readInFlight {
                replyHandler(nil, "Another read is already in progress.")
                return
            }
            // Min-interval throttle: bound how fast a looping page can spawn live fetches + audit runs.
            let now = Date()
            if let last = lastReadStartedAt, now.timeIntervalSince(last) < Self.minReadInterval {
                replyHandler(nil, "Reads are rate-limited; try again shortly.")
                return
            }
            lastReadStartedAt = now
            readInFlight = true
            Task { @MainActor in
                defer { self.readInFlight = false }
                Self.reply(await read(request), to: replyHandler)
            }
        case "runs":
            guard let runs = handlers.runs else { replyHandler(nil, "Runs are unavailable."); return }
            let limit = (message.body as? [String: Any]).flatMap { ($0["limit"] as? Int) ?? ($0["limit"] as? NSNumber)?.intValue }
            Task { @MainActor in Self.reply(runs(limit), to: replyHandler) }
        case "actions":
            guard let listActions = handlers.listActions else { replyHandler(nil, "Actions are unavailable."); return }
            Task { @MainActor in Self.reply(listActions(), to: replyHandler) }
        default:
            guard let request = WorkspaceAppDataBridge.parse(message.body) else {
                replyHandler(nil, "Invalid astra request.")
                return
            }
            Task { @MainActor in Self.reply(await handlers.storage(request), to: replyHandler) }
        }
    }

    /// Map a `Reply` to the WebKit reply handler's `(value, error)` shape.
    private static func reply(_ reply: WorkspaceAppDataBridge.Reply, to replyHandler: (Any?, String?) -> Void) {
        switch reply {
        case .rows(let rows):
            replyHandler(["rows": WorkspaceAppDataBridge.jsRows(rows)], nil)
        case .run(let status, let summary, let runId, let rows):
            replyHandler(["run": [
                "status": status, "summary": summary, "runId": runId,
                "rows": WorkspaceAppDataBridge.jsRows(rows)
            ]], nil)
        case .runs(let items):
            replyHandler(["runs": items], nil)
        case .actions(let items):
            replyHandler(["actions": items], nil)
        case .error(let message):
            replyHandler(nil, message)
        }
    }
}
