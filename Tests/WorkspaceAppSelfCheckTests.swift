import Foundation
import Testing
@testable import ASTRA

/// The builder-facing "does my app work?" engine across all three tiers: Tier 1 auto-exercise,
/// Tier 2 authored expectations, Tier 3 AI-authored-then-really-run.
@Suite("Workspace App Self Check")
struct WorkspaceAppSelfCheckTests {
    private func itemsManifest(extraActions: [WorkspaceAppActionSpec] = []) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "items", name: "Items"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text")
                ])
            ]),
            actions: [
                WorkspaceAppActionSpec(id: "list", type: "appStorage.query", label: "List", table: "items"),
                WorkspaceAppActionSpec(id: "add", type: "appStorage.insert", label: "Add", table: "items"),
                WorkspaceAppActionSpec(id: "update", type: "appStorage.update", label: "Update", table: "items"),
                WorkspaceAppActionSpec(id: "delete", type: "appStorage.delete", label: "Delete", table: "items"),
                WorkspaceAppActionSpec(id: "export", type: "artifact.export", label: "Export", table: "items", exportFormat: "csv")
            ] + extraActions,
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
    }

    private func expectation(_ kind: String, table: String? = nil, op: String? = nil, value: Int? = nil, text: String? = nil, actionID: String? = nil) -> WorkspaceAppCheckExpectation {
        WorkspaceAppCheckExpectation(kind: kind, table: table, op: op, value: value, text: text, actionID: actionID)
    }

    // MARK: - Tier 1

    @Test("auto-exercise runs every action: CRUD passes, simulated actions warn, nothing fails")
    func tier1AutoExercise() {
        let report = WorkspaceAppSelfCheck.autoExercise(manifest: itemsManifest())
        func status(_ id: String) -> WorkspaceAppCheckStatus? { report.results.first { $0.id == id }?.status }
        #expect(status("add") == .pass)
        #expect(status("list") == .pass)
        #expect(status("update") == .pass)
        #expect(status("delete") == .pass)
        #expect(status("export") == .warn)   // artifact.export is simulated in the sandbox
        #expect(report.failCount == 0)
        #expect(report.results.count == 5)
    }

    @Test("auto-exercise warns when a write-labelled action only reads")
    func tier1MislabeledWrite() {
        let manifest = itemsManifest(extraActions: [
            WorkspaceAppActionSpec(id: "save", type: "appStorage.query", label: "Save Items", table: "items")
        ])
        let save = WorkspaceAppSelfCheck.autoExercise(manifest: manifest).results.first { $0.id == "save" }
        #expect(save?.status == .warn)
        #expect(save?.detail.contains("Labelled as a write but only reads") == true)
    }

    // MARK: - Tier 2

    @Test("an authored rowCount check passes after an add and fails on the wrong count")
    func tier2RowCount() {
        let manifest = itemsManifest()
        let step = WorkspaceAppCheckStep(actionID: "add", record: ["id": .text("x1"), "name": .text("Apples")])
        let passing = WorkspaceAppCheck(id: "c1", label: "Add yields one row", steps: [step],
                                        expect: expectation("rowCount", table: "items", op: "eq", value: 1))
        #expect(WorkspaceAppSelfCheck.runCheck(passing, manifest: manifest).status == .pass)
        let failing = WorkspaceAppCheck(id: "c2", label: "Add yields five rows", steps: [step],
                                        expect: expectation("rowCount", table: "items", op: "eq", value: 5))
        #expect(WorkspaceAppSelfCheck.runCheck(failing, manifest: manifest).status == .fail)
    }

    @Test("summaryContains and unknown-action expectations evaluate against real runs")
    func tier2SummaryAndUnknown() {
        let manifest = itemsManifest()
        let summary = WorkspaceAppCheck(
            id: "s", label: "Add reports inserted",
            steps: [WorkspaceAppCheckStep(actionID: "add", record: ["id": .text("x1"), "name": .text("A")])],
            expect: expectation("summaryContains", text: "Inserted 1 record", actionID: "add")
        )
        #expect(WorkspaceAppSelfCheck.runCheck(summary, manifest: manifest).status == .pass)

        let unknown = WorkspaceAppCheck(id: "u", label: "Bad step",
                                        steps: [WorkspaceAppCheckStep(actionID: "ghost", record: nil)],
                                        expect: expectation("noErrors"))
        #expect(WorkspaceAppSelfCheck.runCheck(unknown, manifest: manifest).status == .fail)
    }

    // MARK: - Tier 3

    @Test("the scenario generator authors a check from the model and runs it for real")
    func tier3GeneratesAndRuns() async {
        let manifest = itemsManifest()
        let json = #"{"id":"c","label":"Add yields one row","steps":[{"actionID":"add","record":{"id":"x1","name":"Apples"}}],"expect":{"kind":"rowCount","table":"items","op":"eq","value":1}}"#
        let output = "ASTRA_APP_CHECK\n\(json)\nEND_ASTRA_APP_CHECK"
        let result = await WorkspaceAppScenarioCheckGenerator.generate(
            scenario: "after adding one item the table has one row", manifest: manifest, workspacePath: "/tmp",
            runner: { _, _, _ in AgentUtilityRunResult(exitCode: 0, output: output, error: "") }
        )
        #expect(result.check != nil)
        #expect(result.result.status == .pass)   // grounded in actual sandbox execution
    }

    @Test("the scenario generator fails cleanly on unparseable output, an unavailable model, or a bad action")
    func tier3Failures() async {
        let manifest = itemsManifest()
        let garbage = await WorkspaceAppScenarioCheckGenerator.generate(
            scenario: "x", manifest: manifest, workspacePath: "/tmp",
            runner: { _, _, _ in AgentUtilityRunResult(exitCode: 0, output: "no block here", error: "") }
        )
        #expect(garbage.check == nil)
        #expect(garbage.result.status == .fail)

        let unavailable = await WorkspaceAppScenarioCheckGenerator.generate(
            scenario: "x", manifest: manifest, workspacePath: "/tmp",
            runner: { _, _, _ in AgentUtilityRunResult(exitCode: 1, output: "", error: "API Error") }
        )
        #expect(unavailable.result.status == .fail)

        let badAction = #"{"id":"c","label":"bad","steps":[{"actionID":"nope"}],"expect":{"kind":"noErrors"}}"#
        let badActionResult = await WorkspaceAppScenarioCheckGenerator.generate(
            scenario: "x", manifest: manifest, workspacePath: "/tmp",
            runner: { _, _, _ in AgentUtilityRunResult(exitCode: 0, output: "ASTRA_APP_CHECK\n\(badAction)\nEND_ASTRA_APP_CHECK", error: "") }
        )
        #expect(badActionResult.result.status == .fail)
        #expect(badActionResult.result.detail.contains("nope"))
    }
}
