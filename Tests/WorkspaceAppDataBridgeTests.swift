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
        #expect(!js.contains("delete:")) // delete is NOT exposed
        #expect(js.contains("window.astra"))
        // Phase 5 workflow verbs.
        #expect(js.contains("runAction:"))
        #expect(js.contains("runs:"))
        #expect(js.contains("actions:"))
    }

    // MARK: - Phase 5: workflow bridge (runAction allowlist)

    @Test("resolveAction admits ONLY declared runnable workflow actions; storage/gate/connector/url are denied")
    func resolveActionEnforcesRunnableAllowlist() {
        // A real workflow HTML manifest: appStorage CRUD + a gate + a pipeline.
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .pipeline, intent: "process intake forms")

        // The pipeline IS runnable from JS.
        let pipeline = WorkspaceAppDataBridge.resolveAction(.init(actionId: "run_pipeline", record: [:]), in: manifest)
        #expect(pipeline?.action.type == "pipeline.run")
        // …and the bridge NEVER mints approval/destructive — the executor's gate stays the authority.
        #expect(pipeline?.input.confirmedApproval == false)
        #expect(pipeline?.input.confirmedDestructive == false)

        // A gate is a pipeline step a human resolves in the native queue — NOT directly JS-runnable.
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "approve_batch", record: [:]), in: manifest) == nil)
        // Storage actions are reached by query/insert/update, never runAction.
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "list_review_items", record: [:]), in: manifest) == nil)
        // notify_done is a notification.show (a runnable TYPE) but it is an internal pipeline STEP →
        // NOT directly runnable (only the parent run_pipeline is), so the pipeline can't be skipped.
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "notify_done", record: [:]), in: manifest) == nil)
        // An action id the app does not declare → denied.
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "ghost", record: [:]), in: manifest) == nil)

        // Connector / navigation actions are not runnable even if declared.
        var hostile = manifest
        hostile.actions.append(WorkspaceAppActionSpec(id: "leak", type: "capability.write", table: "review_items"))
        hostile.actions.append(WorkspaceAppActionSpec(id: "nav", type: "url.open"))
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "leak", record: [:]), in: hostile) == nil)
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "nav", record: [:]), in: hostile) == nil)
    }

    @Test("BLOCKER regression: a gated pipeline STEP (export) is not directly runnable, only its parent")
    func gatedExportStepIsNotDirectlyRunnable() {
        // reportGenerator wraps export_report behind approve_export in run_report. A hostile page must
        // NOT be able to call astra.runAction("export_report") to skip the approval gate.
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .reportGenerator, intent: "weekly status")
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "export_report", record: [:]), in: manifest) == nil)
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "approve_export", record: [:]), in: manifest) == nil)
        // Only the top-level pipeline is runnable.
        #expect(WorkspaceAppDataBridge.resolveAction(.init(actionId: "run_report", record: [:]), in: manifest)?.action.type == "pipeline.run")
    }

    @Test("runnableActionTypes excludes storage, connectors, gates, url.open, AND the un-gated write/agent verbs")
    func runnableTypesAreSafe() {
        let runnable = WorkspaceAppDataBridge.runnableActionTypes
        #expect(runnable.contains("pipeline.run"))
        #expect(runnable.contains("loop.run"))
        // artifact.export and task.createAndRun are NOT direct verbs — they may run only as a gated
        // pipeline step, never triggered straight from JS (their effects would otherwise skip approval).
        for forbidden in ["appStorage.delete", "appStorage.query", "capability.read", "capability.write",
                          "gate.humanApproval", "gate.agentRecommendation", "url.open",
                          "artifact.export", "task.createAndRun"] {
            #expect(!runnable.contains(forbidden), "\(forbidden) must NOT be a direct JS verb")
        }
    }

    @Test("runsIndicatePending throttles only while a run is waiting/running")
    func runsPendingPredicate() {
        #expect(WorkspaceAppDataBridge.runsIndicatePending([["status": "waiting"]]))
        #expect(WorkspaceAppDataBridge.runsIndicatePending([["status": "completed"], ["status": "running"]]))
        #expect(!WorkspaceAppDataBridge.runsIndicatePending([["status": "completed"], ["status": "failed"]]))
        #expect(!WorkspaceAppDataBridge.runsIndicatePending([]))
    }

    @Test("parseAction validates the runAction body and applies record caps")
    func parseActionValidates() {
        #expect(WorkspaceAppDataBridge.parseAction(["op": "runAction", "actionId": "run_pipeline"])
            == WorkspaceAppDataBridge.ActionRequest(actionId: "run_pipeline", record: [:]))
        #expect(WorkspaceAppDataBridge.parseAction(["op": "runAction"]) == nil)            // missing actionId
        #expect(WorkspaceAppDataBridge.parseAction(["op": "runAction", "actionId": ""]) == nil) // empty
        #expect(WorkspaceAppDataBridge.parseAction(["op": "runs"]) == nil)                  // wrong op
        // A nested value rejects the whole request (same strictness as storage).
        #expect(WorkspaceAppDataBridge.parseAction(["op": "runAction", "actionId": "x", "record": ["a": ["b": 1]]]) == nil)
    }

    @Test("jsRun and jsActions serialize to JS-safe dictionaries (epoch dates, runnable-only)")
    func runAndActionSerialization() {
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .reportGenerator, intent: "weekly status")
        let actions = WorkspaceAppDataBridge.jsActions(manifest)
        // Only runnable workflow actions are listed (the pipeline + export), never appStorage/gate.
        let types = Set(actions.compactMap { $0["type"] as? String })
        #expect(types.contains("pipeline.run"))
        #expect(!types.contains("gate.humanApproval"))
        #expect(!types.contains("appStorage.query"))

        let snapshot = WorkspaceAppRunSnapshot(
            id: UUID(), actionID: "run_report", trigger: .user, status: .waiting,
            startedAt: Date(timeIntervalSince1970: 1_000), completedAt: nil,
            outputSummary: "Waiting on approval", errorMessage: nil, linkedTaskID: nil, linkedArtifactPath: nil
        )
        let js = WorkspaceAppDataBridge.jsRun(snapshot)
        #expect(js["status"] as? String == "waiting")
        #expect(js["actionId"] as? String == "run_report")
        #expect(js["startedAt"] as? Double == 1_000)   // epoch seconds, not a Date
    }

    @Test("a workflow HTML app's handlers expose runAction; a plain data app's do not")
    @MainActor
    func handlersGateWorkflowSurface() {
        let runner = { (a: WorkspaceAppActionSpec, m: WorkspaceAppManifest, i: WorkspaceAppActionInput) throws -> WorkspaceAppActionExecutionResult in
            try WorkspaceAppPreviewRunner(manifest: m).run(a, manifest: m, input: i)
        }
        // Workflow app → runAction/runs/actions present.
        let workflow = WorkspaceAppStudioRecipes.manifest(for: .pipeline, intent: "intake")
        let wf = WorkspaceAppDataBridge.handlers(manifest: workflow, runs: [], onRunAction: runner)
        #expect(wf?.runAction != nil)
        #expect(wf?.runs != nil)
        // Plain data app (only appStorage) → storage present, workflow closures nil.
        let data = dataManifest(actions: ["query", "insert"])
        let d = WorkspaceAppDataBridge.handlers(manifest: data, runs: [], onRunAction: runner)
        #expect(d != nil)
        #expect(d?.runAction == nil)
    }

    @Test("a gated pipeline triggered from the bridge path is NOT auto-run — the approval gate holds")
    @MainActor
    func gatedPipelineFromBridgeIsNotBypassed() throws {
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .reviewQueue, intent: "triage tickets")
        let runner = WorkspaceAppPreviewRunner(manifest: manifest)
        // Seed a record so the pipeline's list step has data, then trigger the pipeline the way the
        // bridge does: resolveAction (allowlist) → the governed runner. The bridge NEVER mints
        // confirmedApproval, so the human-approval gate is reached and the run cannot auto-complete.
        if let insert = WorkspaceAppDataBridge.resolve(.init(op: "insert", table: "review_items", record: ["id": .text("r1"), "title": .text("Ticket"), "status": .text("open")], limit: nil), in: manifest) {
            _ = try runner.run(insert.action, manifest: manifest, input: insert.input)
        }
        let resolved = WorkspaceAppDataBridge.resolveAction(.init(actionId: "run_review", record: [:]), in: manifest)
        #expect(resolved?.action.type == "pipeline.run")
        #expect(resolved?.input.confirmedApproval == false)
        // The gate blocks the run from completing without human approval. (In the published app the
        // real executor suspends to the native approval queue; the in-memory preview runner surfaces
        // the same gate as a thrown approvalRequired — either way JS cannot bypass it.)
        #expect(throws: (any Error).self) {
            _ = try runner.run(resolved!.action, manifest: manifest, input: resolved!.input)
        }
    }
}
