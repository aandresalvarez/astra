import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Workspace App Automation Execution")
struct WorkspaceAppAutomationExecutionServiceTests {
    @MainActor
    @Test("service executes due automations and advances schedule state")
    func serviceExecutesDueAutomationsAndAdvancesScheduleState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-automation-execution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Automation", primaryPath: root.path)
        context.insert(workspace)
        let manifest = Self.inventoryManifest()
        let created = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: created.app.logicalID
        ))
        try WorkspaceAppStorageService().insertRecord(
            ["id": .text("item-1"), "name": .text("Apples")],
            into: "items",
            databaseURL: databaseURL
        )
        let states = try WorkspaceAppService().automationStates(for: created.app, modelContext: context)
        let state = try #require(states.first)
        let now = Date(timeIntervalSince1970: 1_200)
        state.isEnabled = true
        state.status = .enabled
        state.nextRunAt = Date(timeIntervalSince1970: 900)
        state.updatedAt = Date(timeIntervalSince1970: 600)
        try context.save()

        let results = try WorkspaceAppAutomationExecutionService().runDueAutomations(
            app: created.app,
            workspace: workspace,
            manifest: manifest,
            modelContext: context,
            now: now
        )

        #expect(results == [
            WorkspaceAppAutomationExecutionResult(
                automationID: "refreshItems",
                actionID: "listItems",
                runID: results[0].runID,
                status: .completed,
                errorMessage: nil
            )
        ])
        #expect(state.status == .enabled)
        #expect(state.lastRunAt == now)
        #expect(state.nextRunAt == Date(timeIntervalSince1970: 1_800))

        let runs = try context.fetch(FetchDescriptor<WorkspaceAppRun>())
        #expect(runs.count == 1)
        #expect(runs[0].trigger == .automation)
        #expect(runs[0].status == .completed)
        #expect(runs[0].actionID == "listItems")
        #expect(runs[0].outputSummary == "Read 1 records from items.")
    }

    @MainActor
    @Test("service blocks failing due automation without throwing")
    func serviceBlocksFailingDueAutomationWithoutThrowing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-automation-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Automation", primaryPath: root.path)
        context.insert(workspace)
        var manifest = Self.inventoryManifest()
        manifest.actions[0].table = nil
        let created = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let states = try WorkspaceAppService().automationStates(for: created.app, modelContext: context)
        let state = try #require(states.first)
        let now = Date(timeIntervalSince1970: 1_200)
        state.isEnabled = true
        state.status = .enabled
        state.nextRunAt = Date(timeIntervalSince1970: 900)
        try context.save()

        let results = try WorkspaceAppAutomationExecutionService().runDueAutomations(
            app: created.app,
            workspace: workspace,
            manifest: manifest,
            modelContext: context,
            now: now
        )

        #expect(results.count == 1)
        #expect(results[0].automationID == "refreshItems")
        #expect(results[0].actionID == "listItems")
        #expect(results[0].status == .blocked)
        #expect(results[0].errorMessage?.contains("requires a table") == true)
        #expect(state.status == .blocked)
        #expect(state.lastRunAt == nil)
        #expect(state.nextRunAt == Date(timeIntervalSince1970: 900))

        let run = try #require(try context.fetch(FetchDescriptor<WorkspaceAppRun>()).first)
        #expect(run.trigger == .automation)
        #expect(run.status == .failed)
        #expect(run.errorMessage?.contains("missingTable") == true)
    }

    @MainActor
    @Test("service leaves app state unchanged when no automations are due")
    func serviceLeavesAppStateUnchangedWhenNoAutomationsAreDue() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-automation-idle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Automation", primaryPath: root.path)
        context.insert(workspace)
        let manifest = Self.inventoryManifest()
        let created = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let originalAppUpdatedAt = created.app.updatedAt
        let originalWorkspaceUpdatedAt = workspace.updatedAt

        let results = try WorkspaceAppAutomationExecutionService().runDueAutomations(
            app: created.app,
            workspace: workspace,
            manifest: manifest,
            modelContext: context,
            now: Date(timeIntervalSince1970: 1_200)
        )

        #expect(results.isEmpty)
        #expect(created.app.updatedAt == originalAppUpdatedAt)
        #expect(workspace.updatedAt == originalWorkspaceUpdatedAt)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppRun>()).isEmpty)
    }

    static func inventoryManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "automation-inventory",
                name: "Automation Inventory",
                icon: "clock"
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "localRecords",
                    contract: "appStorage.records",
                    operations: ["queryRecords"]
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true)
                ])
            ]),
            actions: [
                WorkspaceAppActionSpec(
                    id: "listItems",
                    type: "appStorage.query",
                    label: "List Items",
                    requirementRef: "localRecords",
                    operation: "queryRecords",
                    table: "items"
                )
            ],
            automations: [
                WorkspaceAppAutomationSpec(
                    id: "refreshItems",
                    type: "schedule",
                    action: "listItems",
                    scheduleType: "interval",
                    intervalSeconds: 600
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                defaultMode: .readOnly
            )
        )
    }
}
