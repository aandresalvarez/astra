import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

/// Regression coverage for the action table-resolution bugs found in max-effort review:
/// an appStorage.insert used as a pipeline step (input.table == nil) must fall back to the
/// action's declared table like update/delete/query do, and the deterministic pipeline archetype's
/// chained query step must resolve its table instead of throwing missingTable.
@Suite("Workspace App — action table resolution")
struct WorkspaceAppActionTableResolutionTests {
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
            .appendingPathComponent("wsapp-tbl-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    @Test("appStorage.insert falls back to the action's declared table when input.table is nil")
    func insertFallsBackToActionTable() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "tbl-app", name: "Table App"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "rows", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "title", type: "text", required: true)
                ])
            ]),
            views: [WorkspaceAppViewSpec(id: "v", type: "table", title: "Rows", table: "rows")],
            actions: [
                WorkspaceAppActionSpec(id: "add", type: "appStorage.insert", label: "Add", table: "rows"),
                WorkspaceAppActionSpec(id: "list", type: "appStorage.query", label: "List", table: "rows")
            ],
            permissions: WorkspaceAppPermissions(writes: ["appStorage.records"], defaultMode: .draftOnly)
        )
        let created = try WorkspaceAppService().createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)
        let executor = WorkspaceAppActionExecutor()
        // No table in the input — the pipeline-step path. Must resolve via action.table.
        let result = try executor.execute(
            actionID: "add", app: created.app, workspace: env.workspace, manifest: manifest,
            input: WorkspaceAppActionInput(record: ["id": .text("r1"), "title": .text("X")]),
            modelContext: env.context
        )
        #expect(result.outputSummary.contains("rows"))
        let listed = try executor.execute(
            actionID: "list", app: created.app, workspace: env.workspace, manifest: manifest,
            input: WorkspaceAppActionInput(), modelContext: env.context
        )
        #expect(listed.rows.count == 1)
    }

    @MainActor
    @Test("the pipeline archetype's chained query step resolves its table (no missingTable)")
    func pipelineArchetypeStepResolvesTable() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        // "automate ..." routes to the pipeline archetype, whose run_pipeline chains list_review_items.
        #expect(WorkspaceAppArchetype.classify("automate the review pipeline") == .pipeline)
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "automate the review pipeline")
        #expect(manifest.actions.contains { $0.id == "run_pipeline" })
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)

        let created = try WorkspaceAppService().createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)
        let executor = WorkspaceAppActionExecutor()
        // The first pipeline step, run standalone with an empty input, must NOT throw missingTable.
        let listResult = try executor.execute(
            actionID: "list_review_items", app: created.app, workspace: env.workspace, manifest: manifest,
            input: WorkspaceAppActionInput(), modelContext: env.context
        )
        #expect(listResult.outputSummary.contains("review_items"))
    }
}
