import Foundation
import Testing
@testable import ASTRA

/// Phase 2 data bridge: the `astra.*` JS API that lets a dynamic HTML app reach ITS OWN governed
/// storage. The security-critical surface is `resolve` (the allowlist) — it must only admit
/// operations the manifest explicitly grants, on tables the app declares. These tests pin the
/// allowlist, the JS↔native value mapping, request parsing, and the injected API shape.
@Suite("Workspace App — Phase 2 data bridge")
struct WorkspaceAppDataBridgeTests {
    private func dataManifest(actions ops: [String]) -> WorkspaceAppManifest {
        var manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "notes", name: "Notes"),
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"], writes: ["appStorage.records"], defaultMode: .draftOnly
            ),
            html: "<main></main><script>1;</script>"
        )
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "notes", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "body", type: "text")
            ])
        ])
        manifest.actions = ops.map { WorkspaceAppActionSpec(id: $0, type: "appStorage.\($0)", table: "notes") }
        return manifest
    }

    // MARK: - resolve (the allowlist)

    @Test("resolve admits a declared op on an own table, and rejects undeclared ops + foreign tables + delete")
    func resolveEnforcesAllowlist() {
        let manifest = dataManifest(actions: ["query", "insert"])

        // Declared op on a declared table → admitted.
        let q = WorkspaceAppDataBridge.resolve(.init(op: "query", table: "notes", record: [:], limit: nil), in: manifest)
        #expect(q?.action.type == "appStorage.query")
        #expect(q?.input.table == "notes")

        // Op the app did NOT declare → rejected, even though the table is the app's own.
        #expect(WorkspaceAppDataBridge.resolve(.init(op: "update", table: "notes", record: [:], limit: nil), in: manifest) == nil)

        // A table the app does not declare → rejected (no cross-table access).
        #expect(WorkspaceAppDataBridge.resolve(.init(op: "query", table: "secrets", record: [:], limit: nil), in: manifest) == nil)

        // Delete is never exposed by the bridge, even if somehow requested directly.
        #expect(WorkspaceAppDataBridge.resolve(.init(op: "delete", table: "notes", record: [:], limit: nil), in: manifest) == nil)
    }

    @Test("a table-LESS appStorage action does NOT grant the op on a table (exact-table allowlist)")
    func resolveRequiresExactTable() {
        var manifest = dataManifest(actions: [])
        // A table-less query action — must NOT grant query on 'notes'.
        manifest.actions = [WorkspaceAppActionSpec(id: "q", type: "appStorage.query")]
        #expect(WorkspaceAppDataBridge.resolve(.init(op: "query", table: "notes", record: [:], limit: nil), in: manifest) == nil)
    }

    @Test("resolve builds the input with the query limit and never mints confirmedDestructive")
    func resolveBuildsInput() {
        let manifest = dataManifest(actions: ["query", "update"])

        let update = WorkspaceAppDataBridge.resolve(.init(op: "update", table: "notes", record: ["id": .text("x")], limit: nil), in: manifest)
        #expect(update?.action.type == "appStorage.update")
        #expect(update?.input.confirmedDestructive == false)

        let q = WorkspaceAppDataBridge.resolve(.init(op: "query", table: "notes", record: [:], limit: 25), in: manifest)
        #expect(q?.input.limit == 25)
    }

    // MARK: - parse (JS → native)

    @Test("parse accepts well-formed requests and rejects malformed/unsupported ones")
    func parseValidatesShape() {
        #expect(WorkspaceAppDataBridge.parse(["op": "query", "table": "notes"]) == WorkspaceAppDataBridge.Request(op: "query", table: "notes", record: [:], limit: nil))
        #expect(WorkspaceAppDataBridge.parse(["op": "bogus", "table": "notes"]) == nil) // unknown op
        #expect(WorkspaceAppDataBridge.parse(["op": "delete", "table": "notes"]) == nil) // delete not exposed
        #expect(WorkspaceAppDataBridge.parse(["table": "notes"]) == nil)                // missing op
        #expect(WorkspaceAppDataBridge.parse(["op": "query"]) == nil)                   // missing table
        #expect(WorkspaceAppDataBridge.parse(["op": "query", "table": ""]) == nil)      // empty table
        #expect(WorkspaceAppDataBridge.parse("not a dict") == nil)
        // A nested object/array value rejects the WHOLE request (no silent null).
        #expect(WorkspaceAppDataBridge.parse(["op": "insert", "table": "notes", "record": ["x": ["nested": 1]]]) == nil)
    }

    @Test("parse maps a JS record to typed storage values")
    func parseMapsRecord() {
        let request = WorkspaceAppDataBridge.parse([
            "op": "insert", "table": "notes",
            "record": ["body": "hi", "count": NSNumber(value: 3), "done": true, "ratio": NSNumber(value: 1.5)]
        ])
        #expect(request?.record["body"] == .text("hi"))
        #expect(request?.record["count"] == .integer(3))
        #expect(request?.record["done"] == .bool(true))
        #expect(request?.record["ratio"] == .real(1.5))
    }

    // MARK: - value mapping round-trip

    @Test("scalar values map JS→native and native→JS; non-finite/nested are rejected")
    func valueMappingRoundTrips() {
        #expect(WorkspaceAppDataBridge.scalarValue(from: "hi") == .text("hi"))
        #expect(WorkspaceAppDataBridge.scalarValue(from: 42) == .integer(42))
        #expect(WorkspaceAppDataBridge.scalarValue(from: 3.5) == .real(3.5))
        #expect(WorkspaceAppDataBridge.scalarValue(from: true) == .bool(true))
        #expect(WorkspaceAppDataBridge.scalarValue(from: NSNull()) == .null)
        // Non-finite numbers and nested values are invalid (nil), not stored as garbage/null.
        #expect(WorkspaceAppDataBridge.scalarValue(from: Double.nan) == nil)
        #expect(WorkspaceAppDataBridge.scalarValue(from: Double.infinity) == nil)
        #expect(WorkspaceAppDataBridge.scalarValue(from: ["nested": 1]) == nil)
        // native → JS
        #expect(WorkspaceAppDataBridge.jsValue(.text("x")) as? String == "x")
        #expect((WorkspaceAppDataBridge.jsValue(.integer(7)) as? NSNumber)?.int64Value == 7)
        #expect((WorkspaceAppDataBridge.jsValue(.bool(true)) as? NSNumber)?.boolValue == true)
        #expect(WorkspaceAppDataBridge.jsValue(.null) is NSNull)
    }

    // MARK: - governed round-trip (resolve → executor → rows)

    @Test("insert then query round-trips through the governed runner; an undeclared op is denied")
    @MainActor
    func bridgeRoundTripThroughGovernedRunner() {
        let manifest = dataManifest(actions: ["query", "insert"])
        let runner = WorkspaceAppPreviewRunner(manifest: manifest)
        // The exact path WorkspaceAppSurfaceView.dataBridgeRun builds: resolve (allowlist) → the
        // governed executor (permission + audit) → rows. No direct DB access anywhere.
        func run(_ request: WorkspaceAppDataBridge.Request) -> WorkspaceAppDataBridge.Reply {
            guard let resolved = WorkspaceAppDataBridge.resolve(request, in: manifest) else {
                return .error("denied")
            }
            do { return .rows(try runner.run(resolved.action, manifest: manifest, input: resolved.input).rows) }
            catch { return .error("\(error)") }
        }

        _ = run(.init(op: "insert", table: "notes", record: ["id": .text("n1"), "body": .text("hello")], limit: nil))
        guard case .rows(let rows) = run(.init(op: "query", table: "notes", record: [:], limit: nil)) else {
            Issue.record("query should return rows"); return
        }
        #expect(rows.contains { $0["body"] == .text("hello") })

        // The app declared only query + insert, so delete is denied at the allowlist (even though
        // 'notes' is the app's own table).
        guard case .error = run(.init(op: "delete", table: "notes", record: ["id": .text("n1")], limit: nil)) else {
            Issue.record("delete should be denied (not declared)"); return
        }
    }

    // MARK: - injected API

    @Test("the injected script exposes the astra.* API over the single handler")
    func injectedScriptShape() {
        let js = WorkspaceAppDataBridge.injectedScript
        #expect(js.contains("astraAppBridge"))
        #expect(js.contains("query:"))
        #expect(js.contains("insert:"))
        #expect(js.contains("update:"))
        #expect(!js.contains("delete:")) // delete is NOT exposed in Phase 2
        #expect(js.contains("window.astra"))
    }
}
