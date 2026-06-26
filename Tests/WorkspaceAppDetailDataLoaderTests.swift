import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App Detail Data Loader")
struct WorkspaceAppDetailDataLoaderTests {
    @Test("loader reads manifest storage tables and app records")
    func loaderReadsManifestStorageTablesAndAppRecords() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-detail-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Grocery", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "grocery",
                name: "Grocery Tracker",
                description: "Track grocery records."
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "quantity", type: "integer")
                ])
            ])
        )
        let manifestURL = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceAppService.encodeManifest(manifest).write(to: manifestURL)

        let storageService = WorkspaceAppStorageService()
        try storageService.applySchema(try #require(manifest.storage), databaseURL: databaseURL)
        try storageService.insertRecord([
            "id": .text("item-1"),
            "name": .text("Apples"),
            "quantity": .integer(6)
        ], into: "items", databaseURL: databaseURL)
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )

        let snapshot = WorkspaceAppDetailDataLoader().load(app: app, workspace: workspace)

        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.manifest == manifest)
        #expect(snapshot.storageTables.count == 1)
        #expect(snapshot.storageTables[0].name == "items")
        #expect(snapshot.storageTables[0].columns == ["id", "name", "quantity"])
        #expect(snapshot.storageTables[0].rows.count == 1)
        #expect(snapshot.storageTables[0].rows[0]["name"] == .text("Apples"))
        #expect(snapshot.storageTables[0].rows[0]["quantity"] == .integer(6))
    }

    @Test("loader includes dependency bindings for the selected app")
    func loaderIncludesDependencyBindingsForSelectedApp() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-detail-bindings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "recon", name: "Reconciliation"),
            requirements: [
                WorkspaceAppRequirement(
                    id: "warehouse",
                    contract: "tabularQuery.read",
                    operations: ["describeTable", "runReadOnlyQuery"]
                )
            ]
        )
        let manifestURL = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceAppService.encodeManifest(manifest).write(to: manifestURL)

        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )
        let otherAppID = UUID()
        let bindings = [
            WorkspaceAppDependencyBinding(
                workspaceID: workspace.id,
                appID: otherAppID,
                appLogicalID: "other",
                requirementID: "other",
                contract: "appStorage.records",
                operations: ["queryRecords"],
                optional: false,
                status: .mapped,
                implementationID: "app-storage-native",
                provider: "astra",
                transport: .native
            ),
            WorkspaceAppDependencyBinding(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                requirementID: "warehouse",
                contract: "tabularQuery.read",
                operations: ["describeTable", "runReadOnlyQuery"],
                optional: false,
                status: .mapped,
                implementationID: "bigquery-read-task-backed",
                provider: "bigQuery",
                transport: .taskBacked
            )
        ]

        let snapshot = WorkspaceAppDetailDataLoader().load(
            app: app,
            workspace: workspace,
            dependencyBindings: bindings
        )

        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.dependencyBindings == [
            WorkspaceAppDependencyBindingSnapshot(
                requirementID: "warehouse",
                contract: "tabularQuery.read",
                operations: ["describeTable", "runReadOnlyQuery"],
                optional: false,
                status: .mapped,
                implementationID: "bigquery-read-task-backed",
                provider: "bigQuery",
                transport: .taskBacked
            )
        ])
    }

    @Test("loader includes automation states for the selected app")
    func loaderIncludesAutomationStatesForSelectedApp() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-detail-automations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Automation", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "auto-app", name: "Automation App"),
            actions: [WorkspaceAppActionSpec(id: "refresh", type: "pipeline", label: "Refresh")],
            automations: [
                WorkspaceAppAutomationSpec(id: "daily-refresh", type: "schedule", action: "refresh")
            ]
        )
        let manifestURL = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceAppService.encodeManifest(manifest).write(to: manifestURL)

        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )
        let otherAppID = UUID()
        let automations = [
            WorkspaceAppAutomationState(
                workspaceID: workspace.id,
                appID: otherAppID,
                appLogicalID: "other",
                automationID: "other-refresh",
                automationType: "schedule",
                actionID: "refresh",
                isEnabled: true,
                status: .enabled
            ),
            WorkspaceAppAutomationState(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                automationID: "daily-refresh",
                automationType: "schedule",
                actionID: "refresh",
                isEnabled: false,
                status: .disabled
            )
        ]

        let snapshot = WorkspaceAppDetailDataLoader().load(
            app: app,
            workspace: workspace,
            automationStates: automations
        )

        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.automationStates == [
            WorkspaceAppAutomationStateSnapshot(
                automationID: "daily-refresh",
                automationType: "schedule",
                actionID: "refresh",
                isEnabled: false,
                status: .disabled,
                lastRunAt: nil,
                nextRunAt: nil
            )
        ])
    }

    @Test("loader includes recent app run history for the selected app")
    func loaderIncludesRecentAppRunHistoryForSelectedApp() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-detail-runs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Runs", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "run-app", name: "Run App")
        )
        let manifestURL = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceAppService.encodeManifest(manifest).write(to: manifestURL)

        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )
        let otherAppID = UUID()
        let oldRun = WorkspaceAppRun(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            actionID: "old",
            trigger: .automation,
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            outputSummary: "Old summary"
        )
        let newRun = WorkspaceAppRun(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            actionID: "new",
            trigger: .user,
            status: .blocked,
            startedAt: Date(timeIntervalSince1970: 200),
            outputSummary: "",
            errorMessage: "Needs approval"
        )
        let otherRun = WorkspaceAppRun(
            workspaceID: workspace.id,
            appID: otherAppID,
            appLogicalID: "other",
            actionID: "other",
            startedAt: Date(timeIntervalSince1970: 300),
            outputSummary: "Other summary"
        )

        let snapshot = WorkspaceAppDetailDataLoader().load(
            app: app,
            workspace: workspace,
            runs: [oldRun, otherRun, newRun]
        )

        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.runs.map(\.actionID) == ["new", "old"])
        #expect(snapshot.runs[0].status == .blocked)
        #expect(snapshot.runs[0].errorMessage == "Needs approval")
        #expect(snapshot.runs[1].trigger == .automation)
        #expect(snapshot.runs[1].outputSummary == "Old summary")
    }

    @Test("loader returns a visible error when manifest is unavailable")
    func loaderReturnsVisibleErrorWhenManifestUnavailable() {
        let workspace = Workspace(name: "Missing", primaryPath: "/tmp/missing-\(UUID().uuidString)")
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: "missing-app",
            name: "Missing App",
            manifestRelativePath: ".astra/apps/missing-app/manifest.json",
            appDirectoryRelativePath: ".astra/apps/missing-app",
            manifestDigest: "digest"
        )

        let snapshot = WorkspaceAppDetailDataLoader().load(app: app, workspace: workspace)

        #expect(snapshot.manifest == nil)
        #expect(snapshot.storageTables.isEmpty)
        #expect(snapshot.errorMessage == "Could not load app manifest.")
    }

    @Test("run history surfaces waiting/blocked runs as the attention queue (B4)")
    func runHistoryAttentionQueuePartition() {
        func snap(_ status: WorkspaceAppRunStatus, _ action: String) -> WorkspaceAppRunSnapshot {
            WorkspaceAppRunSnapshot(
                id: UUID(),
                actionID: action,
                trigger: .user,
                status: status,
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: nil,
                outputSummary: "",
                errorMessage: nil,
                linkedTaskID: nil,
                linkedArtifactPath: nil
            )
        }
        let presentation = WorkspaceAppRunHistoryPresentationBuilder.presentation(runs: [
            snap(.completed, "done_step"),
            snap(.waiting, "await_step"),
            snap(.blocked, "budget_step"),
            snap(.running, "running_step")
        ])
        #expect(presentation.rows.count == 4)
        #expect(Set(presentation.attentionRows.map(\.actionID)) == ["await_step", "budget_step"])
    }
}
