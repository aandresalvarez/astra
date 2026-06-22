import Foundation
import WebKit

/// Phase 2 vetted data bridge: lets a sandboxed dynamic HTML app read/write **its own** governed
/// storage through an `astra.*` JS API. The bridge adds NO new data-access surface — every request
/// is routed through the SAME governed action path the native UI uses
/// (`WorkspaceAppActionExecutor` via the host's `onRunAction` closure), which already enforces the
/// app's `permissionMode`, requires confirmation for destructive ops, records an audit run, and
/// scopes the SQLite file to the app's own `logicalID`. The bridge is therefore only a JS entry
/// point to the existing gate, never a way around it.
///
/// Hard limits (Phase 2): the API exposes ONLY `appStorage.{query,insert,update}` against tables the
/// app declares in ITS OWN manifest, and only the exact (op, table) pairs the manifest explicitly
/// grants as an action (the allowlist). DELETE is deliberately NOT exposed — it is `.destructive`
/// and the native UI requires a two-step confirm, so a JS-minted confirmation would let a page wipe
/// records on load; deletes wait for a host-controlled confirmed path. The API does NOT expose
/// connectors (`capability.*`), tasks, exports, or anything networked. The document CSP
/// (`default-src 'none'`) is unchanged; `postMessage` to native is orthogonal to CSP, so there is
/// still no network egress.
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
        case error(String)
    }

    /// The host-supplied closure that actually runs a resolved request through the governed
    /// executor. Built in `WorkspaceAppSurfaceView` from `onRunAction` + the manifest, so preview
    /// (in-memory) and published (SQLite) get parity for free. `@MainActor` because it calls the
    /// SwiftUI host's executor closure.
    typealias Run = @MainActor (Request) -> Reply

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
        update: function (table, record) { return call("update", { table: table, record: record || {} }); }
      };
    })();
    """
}

/// The `WKScriptMessageHandlerWithReply` that backs `astraAppBridge`. Holds the host's governed
/// `Run` closure; parses each message, runs it on the main actor, and replies with rows or an error.
/// Registered only for data-backed HTML apps (see `WorkspaceAppWebReportView`).
final class WorkspaceAppDataBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    /// `var` so the host can refresh the closure (and thus the current manifest allowlist) on each
    /// `updateNSView`, preventing a stale allowlist after an app refinement that changes
    /// storage/actions/permission without changing the HTML.
    var run: WorkspaceAppDataBridge.Run

    init(run: @escaping WorkspaceAppDataBridge.Run) {
        self.run = run
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let request = WorkspaceAppDataBridge.parse(message.body) else {
            replyHandler(nil, "Invalid astra request.")
            return
        }
        Task { @MainActor in
            switch run(request) {
            case .rows(let rows):
                replyHandler(["rows": WorkspaceAppDataBridge.jsRows(rows)], nil)
            case .error(let message):
                replyHandler(nil, message)
            }
        }
    }
}
