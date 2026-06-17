import Foundation
import Testing
@testable import ASTRA

/// The sandbox runner backs App Studio's "test before publish" Preview. These tests pin the two
/// guarantees that make it trustworthy: (1) really-run actions (CRUD/gates/reduce/branch/pipeline)
/// mutate an in-memory store with the SAME semantics as the production executor, and (2)
/// side-effecting actions (capability/task/url/clipboard/notification/export) are simulated with a
/// "(preview — …)" summary and change nothing — and the permission gate is replayed faithfully.
@Suite("Workspace App Preview Runner — sandbox semantics")
struct WorkspaceAppPreviewRunnerTests {
    // MARK: - Fixtures

    private func itemsTable() -> WorkspaceAppStorageTable {
        WorkspaceAppStorageTable(name: "items", columns: [
            WorkspaceAppStorageColumn(name: "id", type: "text", primaryKey: true),
            WorkspaceAppStorageColumn(name: "name", type: "text"),
            WorkspaceAppStorageColumn(name: "qty", type: "integer")
        ])
    }

    private func manifest(
        mode: WorkspaceAppPermissionMode,
        tables: [WorkspaceAppStorageTable] = [],
        actions: [WorkspaceAppActionSpec] = []
    ) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "test-app", name: "Test"),
            storage: tables.isEmpty ? nil : WorkspaceAppStorageSchema(tables: tables),
            actions: actions,
            permissions: WorkspaceAppPermissions(defaultMode: mode)
        )
    }

    private func action(_ id: String, _ type: String, table: String? = nil) -> WorkspaceAppActionSpec {
        WorkspaceAppActionSpec(id: id, type: type, label: id, table: table)
    }

    // MARK: - CRUD really runs in-memory

    @Test("insert appends a row and a subsequent query + snapshot reflect it")
    func insertThenQuery() throws {
        let m = manifest(mode: .draftOnly, tables: [itemsTable()],
                         actions: [action("add", "appStorage.insert", table: "items")])
        let runner = WorkspaceAppPreviewRunner(manifest: m, sampleRowsPerTable: 0)
        #expect(runner.snapshot().storageTables.first?.rows.isEmpty == true)

        let add = m.actions[0]
        let input = WorkspaceAppActionInput(table: "items", record: [
            "id": .text("i1"), "name": .text("Apples"), "qty": .integer(3)
        ])
        let result = try runner.run(add, manifest: m, input: input)
        #expect(result.outputSummary.contains("Inserted 1 record"))
        #expect(runner.snapshot().storageTables.first?.rows.count == 1)
        #expect(runner.tables["items"]?.first?["name"] == .text("Apples"))
    }

    @Test("update mutates the primary-key-matched row; delete removes it")
    func updateAndDelete() throws {
        let m = manifest(mode: .draftOnly, tables: [itemsTable()], actions: [
            action("upd", "appStorage.update", table: "items"),
            action("del", "appStorage.delete", table: "items")
        ])
        let seeded = ["items": [["id": WorkspaceAppStorageValue.text("i1"), "name": .text("Apples"), "qty": .integer(3)]]]
        let runner = WorkspaceAppPreviewRunner(manifest: m, seededTables: seeded)

        _ = try runner.run(m.actions[0], manifest: m,
                           input: WorkspaceAppActionInput(table: "items", record: ["id": .text("i1"), "name": .text("Green Apples")]))
        #expect(runner.tables["items"]?.first?["name"] == .text("Green Apples"))
        #expect(runner.tables["items"]?.first?["qty"] == .integer(3))  // untouched column preserved

        _ = try runner.run(m.actions[1], manifest: m,
                           input: WorkspaceAppActionInput(table: "items", record: ["id": .text("i1")], confirmedDestructive: true))
        #expect(runner.tables["items"]?.isEmpty == true)
    }

    @Test("reset restores fresh sample data")
    func resetRestoresSamples() throws {
        let m = manifest(mode: .draftOnly, tables: [itemsTable()],
                         actions: [action("del", "appStorage.delete", table: "items")])
        let runner = WorkspaceAppPreviewRunner(manifest: m, sampleRowsPerTable: 3)
        #expect(runner.tables["items"]?.count == 3)
        // Empty the store through the public action path (sample PKs are "sample-items-N").
        for n in 1...3 {
            _ = try runner.run(m.actions[0], manifest: m,
                               input: WorkspaceAppActionInput(table: "items", record: ["id": .text("sample-items-\(n)")], confirmedDestructive: true))
        }
        #expect(runner.tables["items"]?.isEmpty == true)
        runner.reset()
        #expect(runner.tables["items"]?.count == 3)
    }

    // MARK: - Side effects are simulated, not real

    @Test("capability.write / task / url / clipboard / notification / export are simulated with no mutation")
    func sideEffectsSimulated() throws {
        let m = manifest(mode: .preApproved, tables: [itemsTable()], actions: [
            WorkspaceAppActionSpec(id: "w", type: "capability.write", label: "Sync", requirementRef: "redcap"),
            WorkspaceAppActionSpec(id: "t", type: "task.createAndRun", label: "Solve", taskGoal: "Solve it"),
            WorkspaceAppActionSpec(id: "u", type: "url.open", label: "Open", targetURL: "https://example.com"),
            WorkspaceAppActionSpec(id: "c", type: "clipboard.copy", label: "Copy", clipboardText: "hello"),
            WorkspaceAppActionSpec(id: "n", type: "notification.show", label: "Notify", notificationTitle: "Hi"),
            WorkspaceAppActionSpec(id: "e", type: "artifact.export", label: "Export", table: "items", exportFormat: "csv")
        ])
        let runner = WorkspaceAppPreviewRunner(manifest: m, sampleRowsPerTable: 2)
        let before = runner.tables

        for spec in m.actions {
            let summary = try runner.run(spec, manifest: m, input: WorkspaceAppActionInput()).outputSummary
            #expect(summary.contains("preview"))
        }
        #expect(runner.tables == before)  // nothing simulated touched the store
    }

    // MARK: - Permission gate replays the executor

    @Test("draftOnly blocks external writes; preApproved allows them (simulated)")
    func draftOnlyBlocksExternalWrite() throws {
        let writeAction = WorkspaceAppActionSpec(id: "w", type: "capability.write", label: "Sync", requirementRef: "redcap")

        let draft = WorkspaceAppPreviewRunner(manifest: manifest(mode: .draftOnly, actions: [writeAction]))
        #expect(throws: WorkspaceAppActionExecutionError.self) {
            _ = try draft.run(writeAction, manifest: draft.manifest, input: WorkspaceAppActionInput())
        }

        let approved = WorkspaceAppPreviewRunner(manifest: manifest(mode: .preApproved, actions: [writeAction]))
        let summary = try approved.run(writeAction, manifest: approved.manifest, input: WorkspaceAppActionInput()).outputSummary
        #expect(summary.contains("preview"))
    }

    @Test("readOnly blocks local writes; approvalRequired needs confirmedApproval for external writes")
    func readOnlyAndApprovalGates() throws {
        let insert = action("add", "appStorage.insert", table: "items")
        let readOnly = WorkspaceAppPreviewRunner(manifest: manifest(mode: .readOnly, tables: [itemsTable()], actions: [insert]))
        #expect(throws: WorkspaceAppActionExecutionError.self) {
            _ = try readOnly.run(insert, manifest: readOnly.manifest, input: WorkspaceAppActionInput(table: "items", record: ["id": .text("x")]))
        }

        let write = WorkspaceAppActionSpec(id: "w", type: "capability.write", label: "Sync", requirementRef: "redcap")
        let approval = WorkspaceAppPreviewRunner(manifest: manifest(mode: .approvalRequired, actions: [write]))
        #expect(throws: WorkspaceAppActionExecutionError.self) {
            _ = try approval.run(write, manifest: approval.manifest, input: WorkspaceAppActionInput(confirmedApproval: false))
        }
        let ok = try approval.run(write, manifest: approval.manifest, input: WorkspaceAppActionInput(confirmedApproval: true))
        #expect(ok.outputSummary.contains("preview"))
    }

    @Test("appStorage.delete requires confirmedDestructive")
    func deleteNeedsConfirmation() throws {
        let del = action("del", "appStorage.delete", table: "items")
        let m = manifest(mode: .draftOnly, tables: [itemsTable()], actions: [del])
        let runner = WorkspaceAppPreviewRunner(manifest: m, seededTables: ["items": [["id": .text("i1")]]])
        #expect(throws: WorkspaceAppActionExecutionError.self) {
            _ = try runner.run(del, manifest: m, input: WorkspaceAppActionInput(table: "items", record: ["id": .text("i1")], confirmedDestructive: false))
        }
        #expect(runner.tables["items"]?.count == 1)  // not deleted
    }

    // MARK: - Gates, reduce, and composites

    @Test("gate.expression passes/blocks on the record predicate")
    func expressionGate() throws {
        let gate = WorkspaceAppActionSpec(id: "g", type: "gate.expression", label: "qty>10",
                                          gateField: "qty", gateOperator: "greaterThan", gateValue: .integer(10))
        let runner = WorkspaceAppPreviewRunner(manifest: manifest(mode: .draftOnly, actions: [gate]))
        let pass = try runner.run(gate, manifest: runner.manifest, input: WorkspaceAppActionInput(record: ["qty": .integer(20)]))
        #expect(pass.outputSummary.contains("passed"))
        #expect(throws: WorkspaceAppActionExecutionError.self) {
            _ = try runner.run(gate, manifest: runner.manifest, input: WorkspaceAppActionInput(record: ["qty": .integer(5)]))
        }
    }

    @Test("gate.humanApproval blocks without confirmedApproval and passes with it")
    func humanApprovalGate() throws {
        let gate = WorkspaceAppActionSpec(id: "g", type: "gate.humanApproval", label: "Approve",
                                          approvalPrompt: "OK?", approvalDecisions: ["approve"])
        let runner = WorkspaceAppPreviewRunner(manifest: manifest(mode: .draftOnly, actions: [gate]))
        #expect(throws: WorkspaceAppActionExecutionError.self) {
            _ = try runner.run(gate, manifest: runner.manifest, input: WorkspaceAppActionInput(confirmedApproval: false))
        }
        let ok = try runner.run(gate, manifest: runner.manifest, input: WorkspaceAppActionInput(confirmedApproval: true))
        #expect(ok.outputSummary.contains("Approval recorded"))
    }

    @Test("rows.reduce folds the bound rows")
    func reduceFold() throws {
        let reduce = WorkspaceAppActionSpec(id: "r", type: "rows.reduce", label: "Sum",
                                            reduceStrategy: "sum", reduceColumn: "qty")
        let runner = WorkspaceAppPreviewRunner(manifest: manifest(mode: .draftOnly, actions: [reduce]))
        let rows: [[String: WorkspaceAppStorageValue]] = [["qty": .integer(2)], ["qty": .integer(3)]]
        let result = try runner.run(reduce, manifest: runner.manifest, input: WorkspaceAppActionInput(boundRows: rows))
        #expect(result.rows.first?["qty"] == .real(5))
    }

    @Test("a pipeline with a task step runs to completion instead of suspending")
    func pipelineWithTaskCompletes() throws {
        let m = manifest(mode: .preApproved, tables: [itemsTable()], actions: [
            action("list", "appStorage.query", table: "items"),
            WorkspaceAppActionSpec(id: "solve", type: "task.createAndRun", label: "Solve", taskGoal: "Go"),
            WorkspaceAppActionSpec(id: "pipe", type: "pipeline.run", label: "Run", steps: ["list", "solve"])
        ])
        let runner = WorkspaceAppPreviewRunner(manifest: m, sampleRowsPerTable: 2)
        let pipe = m.actions.first { $0.id == "pipe" }!
        let result = try runner.run(pipe, manifest: m, input: WorkspaceAppActionInput())
        #expect(result.outputSummary.contains("Ran 2 pipeline step"))
    }

    @Test("loop.run honors the preview iteration cap")
    func loopIsCapped() throws {
        let m = manifest(mode: .draftOnly, tables: [itemsTable()], actions: [
            action("noop", "appStorage.query", table: "items"),
            WorkspaceAppActionSpec(id: "loop", type: "loop.run", label: "Loop", steps: ["noop"], maxIterations: 1000)
        ])
        let runner = WorkspaceAppPreviewRunner(manifest: m, sampleRowsPerTable: 1)
        let loop = m.actions.first { $0.id == "loop" }!
        let result = try runner.run(loop, manifest: m, input: WorkspaceAppActionInput())
        #expect(result.outputSummary.contains("\(WorkspaceAppPreviewRunner.previewLoopIterationCap)"))
    }
}
