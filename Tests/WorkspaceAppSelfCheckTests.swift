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

    private func noteHTMLManifest(
        html: String = """
        <main>
          <button aria-label="Delete note"><span class="trash">trash</span></button>
          <script>window.astra.query("notes");</script>
        </main>
        """,
        actions: [WorkspaceAppActionSpec]? = nil
    ) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "notes", name: "Notes"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "notes", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "title", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "body", type: "text")
                ])
            ]),
            actions: actions ?? [
                WorkspaceAppActionSpec(id: "list_notes", type: "appStorage.query", label: "List Notes", table: "notes"),
                WorkspaceAppActionSpec(id: "add_note", type: "appStorage.insert", label: "Add Note", table: "notes"),
                WorkspaceAppActionSpec(id: "update_note", type: "appStorage.update", label: "Update Note", table: "notes")
            ],
            permissions: WorkspaceAppPermissions(reads: ["appStorage.records"], writes: ["appStorage.records"], defaultMode: .draftOnly),
            html: html
        )
    }

    private func noteArchiveActions() -> [WorkspaceAppActionSpec] {
        [
            WorkspaceAppActionSpec(id: "list_notes", type: "appStorage.query", label: "List Notes", table: "notes"),
            WorkspaceAppActionSpec(id: "add_note", type: "appStorage.insert", label: "Add Note", table: "notes"),
            WorkspaceAppActionSpec(id: "archive_note", type: "appStorage.update", label: "Archive Note", table: "notes")
        ]
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

    @Test("auto-exercise updates with changed values, not the same seeded row")
    func tier1UpdateInputMutatesAField() {
        let manifest = itemsManifest()
        let runner = WorkspaceAppPreviewRunner(manifest: manifest)
        let update = manifest.actions.first { $0.id == "update" }!
        let input = WorkspaceAppSelfCheck.defaultInput(for: update, runner: runner, manifest: manifest)
        let original = runner.tables["items"]?.first

        #expect(input.record["id"] == original?["id"])
        #expect(input.record["name"] != original?["name"])
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

    @Test("auto-exercise flags storage HTML that offers delete without an executable delete path")
    func tier1StorageHTMLDeleteAffordanceNeedsDeletePath() {
        let report = WorkspaceAppSelfCheck.autoExercise(manifest: noteHTMLManifest())
        let deleteCoverage = report.results.first { $0.id == "html-delete-affordance" }

        #expect(deleteCoverage?.status == .fail)
        #expect(deleteCoverage?.detail.contains("delete") == true)
        #expect(deleteCoverage?.detail.contains("removal path") == true)
    }

    @Test("auto-exercise accepts delete UI backed by an archive/update path")
    func tier1StorageHTMLDeleteAffordanceAcceptsArchiveUpdatePath() {
        let report = WorkspaceAppSelfCheck.autoExercise(manifest: noteHTMLManifest(actions: noteArchiveActions()))

        #expect(report.results.contains { $0.id == "html-delete-affordance" } == false)
        #expect(report.results.first { $0.id == "archive_note" }?.status == .pass)
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

    // MARK: - Repair prompts

    @Test("a failed result produces a focused App Studio repair prompt")
    func repairPromptIncludesFailureAndContracts() {
        let result = WorkspaceAppCheckResult(
            id: "delete",
            label: "Delete Note",
            status: .fail,
            detail: "Expected notes count eq 0, got 1."
        )

        let prompt = WorkspaceAppTestRepairRequestBuilder.prompt(for: result, manifest: noteHTMLManifest())

        #expect(prompt.contains("Fix this App Studio test failure"))
        #expect(prompt.contains("Delete Note"))
        #expect(prompt.contains("Expected notes count eq 0"))
        #expect(prompt.contains("appStorage.delete hard-deletes"))
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

    @Test("the scenario generator fails delete/trash scenarios when the app has no executable delete path")
    func tier3DeleteScenarioRequiresADeletePath() async {
        var runnerCalled = false
        let result = await WorkspaceAppScenarioCheckGenerator.generate(
            scenario: "notes should be removed when I click the trash can",
            manifest: noteHTMLManifest(),
            workspacePath: "/tmp",
            runner: { _, _, _ in
                runnerCalled = true
                return AgentUtilityRunResult(exitCode: 0, output: "", error: "")
            }
        )

        #expect(runnerCalled == false)
        #expect(result.check == nil)
        #expect(result.result.status == .fail)
        #expect(result.result.detail.contains("no executable delete/archive action") == true)
    }

    @Test("the scenario generator accepts delete/trash scenarios backed by archive/update")
    func tier3DeleteScenarioAcceptsArchiveUpdatePath() async {
        var runnerCalled = false
        let json = #"""
        {
          "id": "archive",
          "label": "Archive note",
          "steps": [
            { "actionID": "add_note", "record": { "id": "note-1", "title": "Draft", "body": "Body" } },
            { "actionID": "archive_note", "record": { "id": "note-1", "title": "Archived", "body": "Body" } }
          ],
          "expect": { "kind": "summaryContains", "actionID": "archive_note", "text": "Updated 1 record" }
        }
        """#
        let result = await WorkspaceAppScenarioCheckGenerator.generate(
            scenario: "notes should be removed when I click the trash can",
            manifest: noteHTMLManifest(actions: noteArchiveActions()),
            workspacePath: "/tmp",
            runner: { _, _, _ in
                runnerCalled = true
                return AgentUtilityRunResult(exitCode: 0, output: "ASTRA_APP_CHECK\n\(json)\nEND_ASTRA_APP_CHECK", error: "")
            }
        )

        #expect(runnerCalled == true)
        #expect(result.check != nil)
        #expect(result.result.status == .pass)
    }

    @Test("the scenario prompt documents hard-delete storage semantics")
    func tier3PromptDocumentsDeleteContract() {
        let prompt = WorkspaceAppScenarioCheckGenerator.buildPrompt(
            scenario: "remove a note with the trash can",
            manifest: noteHTMLManifest(actions: [
                WorkspaceAppActionSpec(id: "list_notes", type: "appStorage.query", label: "List Notes", table: "notes"),
                WorkspaceAppActionSpec(id: "delete_note", type: "appStorage.delete", label: "Delete Note", table: "notes")
            ])
        )

        #expect(prompt.contains("appStorage.delete hard-deletes"))
        #expect(prompt.contains("is_deleted"))
        #expect(prompt.lowercased().contains("soft-delete expectation"))
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
