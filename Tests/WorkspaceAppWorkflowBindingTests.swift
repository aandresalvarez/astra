import Foundation
import SwiftData
import Testing
@testable import ASTRA

/// Slice 10 — workflow I/O binding: app data flows INTO a spawned agent task's goal (input binding)
/// and the agent's answer flows BACK into the workflow as a named field, optionally persisted to
/// storage (output binding). Covers schema digest stability, validation, the executor round-trip,
/// and preview-runner parity.
@Suite("Workspace App Workflow I/O Binding")
struct WorkspaceAppWorkflowBindingTests {
    // MARK: - Fixtures

    @MainActor
    private struct Env {
        var container: ModelContainer
        var workspace: Workspace
        var context: ModelContext
        var root: URL
    }

    @MainActor
    private static func makeEnv() throws -> Env {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wsapp-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)
        return Env(container: container, workspace: workspace, context: context, root: root)
    }

    private func resultsManifest(mode: WorkspaceAppPermissionMode, outputBinding: WorkspaceAppActionOutputBinding) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "analyzer", name: "Analyzer"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "results", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "answer", type: "text")
                ])
            ]),
            actions: [
                WorkspaceAppActionSpec(id: "analyze", type: "task.createAndRun", label: "Analyze",
                                       taskGoal: "Analyze the record.", outputBinding: outputBinding),
                WorkspaceAppActionSpec(id: "run", type: "pipeline.run", label: "Run", steps: ["analyze"])
            ],
            permissions: WorkspaceAppPermissions(defaultMode: mode)
        )
    }

    // MARK: - Schema helpers + digest stability

    @Test("jsonStringify renders rows as clean, key-sorted JSON")
    func jsonStringifyIsDeterministic() {
        let rows: [[String: WorkspaceAppStorageValue]] = [["name": .text("Apples"), "qty": .integer(3), "fresh": .bool(true)]]
        #expect(WorkspaceAppActionExecutor.jsonStringify(rows) == #"[{"fresh":true,"name":"Apples","qty":3}]"#)
    }

    @Test("storageValue(fromJSON:) maps JSON natives to storage values")
    func storageValueMapping() {
        #expect(WorkspaceAppActionExecutor.storageValue(fromJSON: "hi") == .text("hi"))
        #expect(WorkspaceAppActionExecutor.storageValue(fromJSON: true) == .bool(true))
        #expect(WorkspaceAppActionExecutor.storageValue(fromJSON: 5) == .integer(5))
        #expect(WorkspaceAppActionExecutor.storageValue(fromJSON: 2.5) == .real(2.5))
        #expect(WorkspaceAppActionExecutor.storageValue(fromJSON: NSNull()) == .null)
    }

    @Test("a binding-free action omits the binding keys (version digest stays stable)")
    func bindingFreeEncodingOmitsKeys() throws {
        let action = WorkspaceAppActionSpec(id: "a", type: "appStorage.query", label: "List")
        let json = String(data: try JSONEncoder().encode(action), encoding: .utf8) ?? ""
        #expect(!json.contains("inputBinding"))
        #expect(!json.contains("outputBinding"))
    }

    @Test("bindings round-trip through Codable")
    func bindingsRoundTrip() throws {
        let action = WorkspaceAppActionSpec(
            id: "analyze", type: "task.createAndRun", label: "Analyze", taskGoal: "go",
            inputBinding: WorkspaceAppActionInputBinding(source: "table", table: "items", label: "Items", limit: 10),
            outputBinding: WorkspaceAppActionOutputBinding(field: "answer", capture: "text", table: "results")
        )
        let decoded = try JSONDecoder().decode(WorkspaceAppActionSpec.self, from: try JSONEncoder().encode(action))
        #expect(decoded.inputBinding == action.inputBinding)
        #expect(decoded.outputBinding == action.outputBinding)
    }

    // MARK: - Validation

    @Test("valid bindings pass validation")
    func validBindingsPass() {
        let manifest = resultsManifest(
            mode: .preApproved,
            outputBinding: WorkspaceAppActionOutputBinding(field: "answer", capture: "text", table: "results")
        )
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("input binding with unknown source / table is a blocker")
    func inputBindingValidation() {
        var manifest = resultsManifest(mode: .preApproved, outputBinding: WorkspaceAppActionOutputBinding(field: "answer", table: "results"))
        manifest.actions[0].inputBinding = WorkspaceAppActionInputBinding(source: "nonsense", table: nil, label: nil, limit: nil)
        #expect(WorkspaceAppManifestValidator.validate(manifest).blockers.contains { $0.path.hasSuffix("/inputBinding/source") })

        manifest.actions[0].inputBinding = WorkspaceAppActionInputBinding(source: "table", table: "ghost", label: nil, limit: nil)
        #expect(WorkspaceAppManifestValidator.validate(manifest).blockers.contains { $0.path.hasSuffix("/inputBinding/table") })
    }

    @Test("output binding with empty field / bad capture / unknown table / non-column field are blockers")
    func outputBindingValidation() {
        func validate(_ binding: WorkspaceAppActionOutputBinding) -> WorkspaceAppManifestValidationReport {
            WorkspaceAppManifestValidator.validate(resultsManifest(mode: .preApproved, outputBinding: binding))
        }
        #expect(validate(WorkspaceAppActionOutputBinding(field: "  ", capture: "text", table: nil))
            .blockers.contains { $0.path.hasSuffix("/outputBinding/field") })
        #expect(validate(WorkspaceAppActionOutputBinding(field: "answer", capture: "xml", table: nil))
            .blockers.contains { $0.path.hasSuffix("/outputBinding/capture") })
        #expect(validate(WorkspaceAppActionOutputBinding(field: "answer", capture: "text", table: "ghost"))
            .blockers.contains { $0.path.hasSuffix("/outputBinding/table") })
        #expect(validate(WorkspaceAppActionOutputBinding(field: "not_a_column", capture: "text", table: "results"))
            .blockers.contains { $0.path.hasSuffix("/outputBinding/field") })
    }

    // MARK: - Executor: input binding injects app data into the agent goal

    @MainActor
    @Test("input binding injects the prior step's rows into the spawned task goal")
    func inputBindingInjectsIntoGoal() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "summarizer", name: "Summarizer"),
            actions: [
                WorkspaceAppActionSpec(id: "summarize", type: "task.createDraft", label: "Summarize",
                                       taskGoal: "Summarize the records.",
                                       inputBinding: WorkspaceAppActionInputBinding(source: "boundRows", table: nil, label: "Records", limit: nil))
            ],
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
        let created = try WorkspaceAppService().createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "summarize", app: created.app, workspace: env.workspace, manifest: manifest,
            input: WorkspaceAppActionInput(boundRows: [["name": .text("Apples")]]), modelContext: env.context
        )
        let task = try #require(try env.context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(task.goal.contains("Summarize the records."))
        #expect(task.goal.contains("Records (1 record)"))
        #expect(task.goal.contains("Apples"))
    }

    // MARK: - Executor: output binding captures the answer back into the workflow + storage

    @MainActor
    @Test("output binding renames the captured answer to its field and persists it to storage")
    func outputBindingCapturesAndPersists() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let manifest = resultsManifest(
            mode: .preApproved,
            outputBinding: WorkspaceAppActionOutputBinding(field: "answer", capture: "text", table: "results")
        )
        let created = try WorkspaceAppService().createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)
        let pipeline = try #require(manifest.actions.first { $0.id == "run" })

        let mapped = WorkspaceAppActionExecutor().applyOutputBinding(
            taskOutputRows: [["task_id": .text("t1"), "output": .text("All clear.")]],
            pipeline: pipeline, awaitedStepIndex: 0,
            app: created.app, workspace: env.workspace, manifest: manifest, modelContext: env.context
        )
        // Renamed forward.
        #expect(mapped.first?["answer"] == .text("All clear."))
        // Persisted to storage.
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: env.workspace.primaryPath, appID: created.app.logicalID
        ))
        let rows = try WorkspaceAppStorageService().records(in: "results", databaseURL: databaseURL, limit: 100)
        #expect(rows.contains { $0["answer"] == .text("All clear.") })
    }

    @MainActor
    @Test("output binding with capture=json parses the answer into columns")
    func outputBindingParsesJSON() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let manifest = resultsManifest(
            mode: .preApproved,
            outputBinding: WorkspaceAppActionOutputBinding(field: "raw", capture: "json", table: nil)
        )
        let created = try WorkspaceAppService().createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)
        let pipeline = try #require(manifest.actions.first { $0.id == "run" })

        let mapped = WorkspaceAppActionExecutor().applyOutputBinding(
            taskOutputRows: [["output": .text(#"{"score":5,"ok":true,"note":"fine"}"#)]],
            pipeline: pipeline, awaitedStepIndex: 0,
            app: created.app, workspace: env.workspace, manifest: manifest, modelContext: env.context
        )
        #expect(mapped.first?["score"] == .integer(5))
        #expect(mapped.first?["ok"] == .bool(true))
        #expect(mapped.first?["note"] == .text("fine"))
        #expect(mapped.first?["raw"] == .text(#"{"score":5,"ok":true,"note":"fine"}"#))
    }

    // MARK: - Preview-runner parity

    @MainActor
    @Test("preview pipeline simulates the agent step and captures its output via the binding")
    func previewCapturesSimulatedOutput() throws {
        let manifest = resultsManifest(
            mode: .preApproved,
            outputBinding: WorkspaceAppActionOutputBinding(field: "answer", capture: "text", table: "results")
        )
        let runner = WorkspaceAppPreviewRunner(manifest: manifest, sampleRowsPerTable: 0)
        let pipeline = try #require(manifest.actions.first { $0.id == "run" })
        _ = try runner.run(pipeline, manifest: manifest, input: WorkspaceAppActionInput())
        // The simulated agent answer was captured to the bound table in the in-memory store.
        #expect(runner.tables["results"]?.contains { row in
            if case .text(let value)? = row["answer"] { return value.contains("preview agent output") }
            return false
        } == true)
    }

    // MARK: - Phase 3: {{field}} goal interpolation (named variables)

    @Test("interpolatePlaceholders substitutes prior fields, record over boundRows")
    func interpolationSubstitutes() {
        let input = WorkspaceAppActionInput(record: ["name": .text("Bread")], boundRows: [["name": .text("Apples"), "qty": .integer(3)]])
        #expect(WorkspaceAppActionExecutor.interpolatePlaceholders("Buy {{name}} x{{qty}}", input: input) == "Buy Bread x3")
        #expect(WorkspaceAppActionExecutor.interpolatePlaceholders("no placeholders", input: input) == "no placeholders")
    }

    @MainActor
    @Test("a task goal interpolates {{field}} from the prior step's captured output")
    func goalInterpolationEndToEnd() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "impl", name: "Implementer"),
            actions: [
                WorkspaceAppActionSpec(id: "do_it", type: "task.createDraft", label: "Do it",
                                       taskGoal: "Implement {{summary}}.")
            ],
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
        let created = try WorkspaceAppService().createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "do_it", app: created.app, workspace: env.workspace, manifest: manifest,
            input: WorkspaceAppActionInput(boundRows: [["summary": .text("the approved plan")]]), modelContext: env.context
        )
        let task = try #require(try env.context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(task.goal.contains("Implement the approved plan."))
    }

    // MARK: - Chart kinds (bar / line / pie)

    private func chartSurface(kind: String?) -> WorkspaceAppNativeSurfacePresentation {
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "charts", name: "Charts"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "t", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text")
                ])
            ]),
            views: [
                WorkspaceAppViewSpec(id: "dash", type: "dashboard", title: "D", table: "t", widgets: [
                    WorkspaceAppWidgetSpec(id: "ch", type: "chart", label: "By status", groupBy: "status", aggregation: "count", chartKind: kind)
                ])
            ],
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
        let snapshot = WorkspaceAppStorageTableSnapshot(name: "t", columns: ["id", "status"], rows: [["id": .text("1"), "status": .text("a")]], errorMessage: nil)
        return WorkspaceAppNativeSurfaceBuilder.presentation(manifest: manifest, storageTables: [snapshot])
    }

    @Test("a chart widget's chartKind flows into the presentation; unknown defaults to bar")
    func chartKindFlowsThrough() {
        #expect(chartSurface(kind: "pie").charts.first?.kind == "pie")
        #expect(chartSurface(kind: "line").charts.first?.kind == "line")
        #expect(chartSurface(kind: "wat").charts.first?.kind == "bar")
        #expect(chartSurface(kind: nil).charts.first?.kind == "bar")
    }

    @Test("an unsupported chartKind is a validation blocker")
    func unsupportedChartKindBlocks() {
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "charts", name: "Charts"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "t", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text")
                ])
            ]),
            views: [
                WorkspaceAppViewSpec(id: "dash", type: "dashboard", title: "D", table: "t", widgets: [
                    WorkspaceAppWidgetSpec(id: "ch", type: "chart", label: "By status", groupBy: "status", aggregation: "count", chartKind: "donut")
                ])
            ],
            actions: [WorkspaceAppActionSpec(id: "add", type: "appStorage.insert", label: "Add", table: "t")],
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
        #expect(WorkspaceAppManifestValidator.validate(manifest).blockers.contains { $0.path.hasSuffix("/chartKind") })
    }
}
