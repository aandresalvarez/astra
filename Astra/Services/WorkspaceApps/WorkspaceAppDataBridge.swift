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
///   `astra.actions()` lists the runnable actions. EXCLUDED: `capability.*` (networked connectors —
///   deferred), `gate.*` (a human resolves these in the native approval queue; JS may not mint a
///   decision), `url.open` (arbitrary navigation), and storage delete. The bridge NEVER sets
///   `confirmedApproval`/`confirmedDestructive`, so an approval-required external write triggered
///   from JS SUSPENDS to the native attention queue rather than auto-running.
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
    typealias Run = @MainActor (Request) -> Reply

    /// (Phase 5) The full set of host closures backing `astra.*`. `storage` (query/insert/update) is
    /// always present for a data app; the workflow closures are nil for an app that declares no
    /// JS-runnable workflow actions, so a plain data app exposes no `runAction` surface at all.
    struct Handlers {
        var storage: Run
        var runAction: (@MainActor (ActionRequest) -> Reply)?
        var runs: (@MainActor (Int?) -> Reply)?
        var listActions: (@MainActor () -> Reply)?
    }

    private static let allowedOps: Set<String> = ["query", "insert", "update"]
    /// DoS caps: a hostile page can't flood the main actor with giant records.
    private static let maxRecordFields = 200
    private static let maxValueBytes = 256 * 1024

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
        for (key, raw) in dict {
            guard let value = scalarValue(from: raw) else { return nil }
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
            limit: request.limit ?? 100
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
    /// An action that is itself a STEP of some pipeline/loop is ALSO not directly runnable (see
    /// `isDirectlyRunnable`) — only its parent pipeline is, so the gate can't be skipped.
    static let runnableActionTypes: Set<String> = [
        "task.createDraft",
        "pipeline.run", "loop.run",
        "notification.show", "rows.reduce", "clipboard.copy"
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

    /// True if any run snapshot is still `waiting`/`running` — used to throttle `runAction` to one
    /// pending workflow run per app surface (a hostile page can't queue unbounded agent tasks).
    static func runsIndicatePending(_ items: [[String: Any]]) -> Bool {
        items.contains {
            let status = $0["status"] as? String
            return status == WorkspaceAppRunStatus.waiting.rawValue || status == WorkspaceAppRunStatus.running.rawValue
        }
    }

    /// Build the host `Handlers` for a manifest. Kept as plain (non-SwiftUI) code so the nested
    /// `@MainActor` closures don't pressure the View body's type-checker. Returns nil for a pure-UI
    /// HTML app (no storage AND no runnable workflow action) so no bridge is registered. The workflow
    /// closures are nil unless the app declares at least one `runnableActionTypes` action. Every
    /// closure routes through the SAME governed `onRunAction` (permission + audit + app-scoped DB).
    @MainActor
    static func handlers(
        manifest: WorkspaceAppManifest,
        runs: [WorkspaceAppRunSnapshot],
        onRunAction: @escaping (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) throws -> WorkspaceAppActionExecutionResult,
        onReload: @escaping () -> Void = {}
    ) -> Handlers? {
        // A directly-runnable action is a runnable type that is NOT an internal pipeline step.
        let hasStorage = manifest.storage?.tables.isEmpty == false
        let hasRunnable = manifest.actions.contains { isDirectlyRunnable($0, in: manifest) }
        guard hasStorage || hasRunnable else { return nil }

        let storage: Run = { request in
            guard let resolved = resolve(request, in: manifest) else {
                return .error("Operation '\(request.op)' on '\(request.table)' is not permitted by this app.")
            }
            do { return .rows(try onRunAction(resolved.action, manifest, resolved.input).rows) }
            catch { return .error(String(describing: error)) }
        }

        guard hasRunnable else {
            return Handlers(storage: storage, runAction: nil, runs: nil, listActions: nil)
        }

        let runAction: @MainActor (ActionRequest) -> Reply = { request in
            guard let resolved = resolveAction(request, in: manifest) else {
                return .error("Action '\(request.actionId)' is not runnable by this app.")
            }
            do {
                let result = try onRunAction(resolved.action, manifest, resolved.input)
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
        return Handlers(storage: storage, runAction: runAction, runs: runsHandler, listActions: listActions)
    }

    // MARK: - Reply (native → JS)

    static func jsRows(_ rows: [[String: WorkspaceAppStorageValue]]) -> [[String: Any]] {
        rows.map { row in row.mapValues(jsValue) }
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
    /// Durable throttle (NOT just anti-concurrency): once a `runAction` leaves a `waiting`/`running`
    /// run, further runAction calls are DENIED until it resolves — so a scripted `while(true) await
    /// astra.runAction(...)` loop on a `preApproved` app can't queue unbounded agent tasks. Cleared
    /// when an `astra.runs()` poll shows no pending run (the workflow template polls every 3s).
    private var workflowRunPending = false

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
            if runActionInFlight || workflowRunPending {
                replyHandler(nil, runActionInFlight
                    ? "Another action is already running."
                    : "A workflow run is already pending — resolve it in the app before starting another.")
                return
            }
            runActionInFlight = true
            Task { @MainActor in
                defer { self.runActionInFlight = false }
                let reply = runAction(request)
                // Hold the throttle if the run is still in progress / awaiting approval.
                if case let .run(status, _, _, _) = reply {
                    self.workflowRunPending = status == WorkspaceAppRunStatus.waiting.rawValue
                        || status == WorkspaceAppRunStatus.running.rawValue
                }
                Self.reply(reply, to: replyHandler)
            }
        case "runs":
            guard let runs = handlers.runs else { replyHandler(nil, "Runs are unavailable."); return }
            let limit = (message.body as? [String: Any]).flatMap { ($0["limit"] as? Int) ?? ($0["limit"] as? NSNumber)?.intValue }
            Task { @MainActor in
                let reply = runs(limit)
                // Refresh the throttle from the latest run state: clears once nothing is pending.
                if case let .runs(items) = reply { self.workflowRunPending = WorkspaceAppDataBridge.runsIndicatePending(items) }
                Self.reply(reply, to: replyHandler)
            }
        case "actions":
            guard let listActions = handlers.listActions else { replyHandler(nil, "Actions are unavailable."); return }
            Task { @MainActor in Self.reply(listActions(), to: replyHandler) }
        default:
            guard let request = WorkspaceAppDataBridge.parse(message.body) else {
                replyHandler(nil, "Invalid astra request.")
                return
            }
            Task { @MainActor in Self.reply(handlers.storage(request), to: replyHandler) }
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
