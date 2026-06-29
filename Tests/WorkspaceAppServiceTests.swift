import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Workspace App Service")
struct WorkspaceAppServiceTests {
    @Test("manifest encoding preserves native widget specs")
    func manifestEncodingPreservesNativeWidgetSpecs() throws {
        var manifest = Self.reconciliationManifest()
        manifest.views[0].widgets.append(WorkspaceAppWidgetSpec(
            id: "review_notes",
            type: "markdown",
            label: "Review notes",
            markdownContent: "**Check** missing records before export."
        ))
        manifest.views[0].widgets.append(WorkspaceAppWidgetSpec(
            id: "review_flow",
            type: "diagram",
            label: "Review flow",
            diagramContent: "flowchart LR\nextract[Extract] --> validate{Validate}\nvalidate --> export[Export]",
            diagramKind: "pipeline"
        ))
        let data = try WorkspaceAppService.encodeManifest(manifest)
        let decoded = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        let view = try #require(decoded.views.first)
        let widget = try #require(view.widgets.first)
        let markdown = try #require(view.widgets.first { $0.id == "review_notes" })
        let diagram = try #require(view.widgets.first { $0.id == "review_flow" })

        #expect(view.table == "review_items")
        #expect(widget.id == "review_count")
        #expect(widget.type == "metric")
        #expect(widget.table == nil)
        #expect(widget.aggregation == "count")
        #expect(markdown.id == "review_notes")
        #expect(markdown.type == "markdown")
        #expect(markdown.markdownContent == "**Check** missing records before export.")
        #expect(diagram.type == "diagram")
        #expect(diagram.diagramKind == "pipeline")
        #expect(diagram.diagramContent?.contains("validate --> export") == true)
    }

    @Test("manifest encoding is stable enough for digest checks")
    func manifestEncodingIsStable() throws {
        let manifest = Self.reconciliationManifest()
        let first = try WorkspaceAppService.encodeManifest(manifest)
        let second = try WorkspaceAppService.encodeManifest(manifest)

        #expect(first == second)
        #expect(WorkspaceAppService.digest(for: first) == WorkspaceAppService.digest(for: second))
    }

    @MainActor
    @Test("service writes canonical manifest and SwiftData index")
    func serviceWritesCanonicalManifestAndSwiftDataIndex() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(
                id: "hourly-refresh",
                type: "schedule",
                enabledByDefault: false,
                action: "refresh"
            )
        ]
        let result = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))

        #expect(FileManager.default.fileExists(atPath: result.manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(result.app.logicalID == "enrollment-reconciliation")
        #expect(result.app.name == "Enrollment Reconciliation")
        #expect(result.app.manifestRelativePath == ".astra/apps/enrollment-reconciliation/manifest.json")
        #expect(result.app.appDirectoryRelativePath == ".astra/apps/enrollment-reconciliation")
        #expect(result.app.permissionMode == .readOnly)
        #expect(result.app.dependencyStatus == .ready)

        let data = try Data(contentsOf: result.manifestURL)
        #expect(result.app.manifestDigest == WorkspaceAppService.digest(for: data))

        let decoded = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        #expect(decoded == manifest)

        let apps = try context.fetch(FetchDescriptor<WorkspaceApp>())
        #expect(apps.count == 1)
        #expect(apps[0].workspaceID == workspace.id)

        let bindings = try context.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>())
            .sorted { $0.requirementID < $1.requirementID }
        #expect(bindings.count == 2)
        #expect(bindings[0].appID == result.app.id)
        #expect(bindings[0].appLogicalID == "enrollment-reconciliation")
        #expect(bindings[0].requirementID == "sourceWarehouse")
        #expect(bindings[0].contract == "tabularQuery.read")
        #expect(bindings[0].operations == ["describeTable", "runReadOnlyQuery"])
        #expect(bindings[0].status == .mapped)
        #expect(bindings[0].implementationID == "bigquery-read-task-backed")
        #expect(bindings[0].provider == "bigQuery")
        #expect(bindings[0].transport == .taskBacked)
        #expect(bindings[1].requirementID == "targetRecords")
        #expect(bindings[1].status == .mapped)
        #expect(bindings[1].implementationID == "redcap-read-native")
        #expect(bindings[1].transport == .native)

        let automations = try context.fetch(FetchDescriptor<WorkspaceAppAutomationState>())
        #expect(automations.count == 1)
        #expect(automations[0].appID == result.app.id)
        #expect(automations[0].appLogicalID == "enrollment-reconciliation")
        #expect(automations[0].automationID == "hourly-refresh")
        #expect(automations[0].automationType == "schedule")
        #expect(automations[0].actionID == "refresh")
        #expect(automations[0].isEnabled == false)
        #expect(automations[0].status == .disabled)
    }

    @MainActor
    @Test("updateApp versions in place — same logicalID + record, name updated, no forked sibling")
    func updateAppVersionsInPlace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let service = WorkspaceAppService()
        let manifest = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "groceries")
        let created = try service.createApp(manifest: manifest, in: workspace, modelContext: context)
        let logicalID = created.app.logicalID
        let recordID = created.app.id
        let originalDigest = created.app.manifestDigest

        // Edit it (rename) and publish-in-place. The logical id is kept by the service even if the
        // caller passes the source manifest verbatim.
        var edited = created.manifest
        edited.app.name = "Groceries Renamed"
        let updated = try service.updateApp(created.app, manifest: edited, in: workspace, modelContext: context)

        #expect(updated.app.logicalID == logicalID)   // identity preserved — NOT "groceries-2"
        #expect(updated.app.id == recordID)            // same @Model record, not a new sibling
        #expect(updated.app.name == "Groceries Renamed")
        #expect(updated.app.manifestDigest != originalDigest)   // the rename changed the manifest
        #expect(try context.fetch(FetchDescriptor<WorkspaceApp>()).count == 1)   // no forked sibling

        // The on-disk manifest at the SAME path reflects the edit.
        let onDisk = try JSONDecoder().decode(
            WorkspaceAppManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(workspacePath: workspace.primaryPath, appID: logicalID)))
        )
        #expect(onDisk.app.name == "Groceries Renamed")
        #expect(onDisk.app.id == logicalID)
    }

    @MainActor
    @Test("service marks apps missing required dependencies when no compatible contract implementation exists")
    func serviceMarksAppsMissingRequiredDependencies() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-missing-dependency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let result = try WorkspaceAppService(
            contractRegistry: WorkspaceAppContractRegistry(implementations: [])
        ).createApp(
            manifest: Self.reconciliationManifest(),
            in: workspace,
            modelContext: context
        )

        #expect(result.app.dependencyStatus == .missingRequired)
        let bindings = try context.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>())
        #expect(bindings.count == 2)
        #expect(bindings.allSatisfy { $0.status == .missingRequired })
        #expect(bindings.allSatisfy { $0.implementationID == nil })
    }

    @MainActor
    @Test("service remaps dependency bindings without editing the app manifest")
    func serviceRemapsDependencyBindingsWithoutEditingManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-remap-dependency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let manifest = Self.reconciliationManifest()
        let creatingService = WorkspaceAppService(
            contractRegistry: WorkspaceAppContractRegistry(implementations: [])
        )
        let result = try creatingService.createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let originalManifestData = try Data(contentsOf: result.manifestURL)

        let remappingService = WorkspaceAppService()
        #expect(throws: WorkspaceAppServiceError.incompatibleContractImplementation(
            requirementID: "sourceWarehouse",
            implementationID: "redcap-read-task-backed"
        )) {
            try remappingService.remapDependencyBinding(
                app: result.app,
                requirementID: "sourceWarehouse",
                implementationID: "redcap-read-task-backed",
                workspace: workspace,
                modelContext: context
            )
        }

        try remappingService.remapDependencyBinding(
            app: result.app,
            requirementID: "sourceWarehouse",
            implementationID: "bigquery-read-task-backed",
            workspace: workspace,
            modelContext: context
        )
        #expect(result.app.dependencyStatus == .missingRequired)

        try remappingService.remapDependencyBinding(
            app: result.app,
            requirementID: "targetRecords",
            implementationID: "redcap-read-task-backed",
            workspace: workspace,
            modelContext: context
        )
        #expect(result.app.dependencyStatus == .ready)
        #expect(try Data(contentsOf: result.manifestURL) == originalManifestData)

        let bindings = try remappingService.dependencyBindings(for: result.app, modelContext: context)
        #expect(bindings.count == 2)
        #expect(bindings.allSatisfy { $0.status == .mapped })
        #expect(bindings.first { $0.requirementID == "sourceWarehouse" }?.implementationID == "bigquery-read-task-backed")
        #expect(bindings.first { $0.requirementID == "targetRecords" }?.implementationID == "redcap-read-task-backed")
    }

    @MainActor
    @Test("service enables automation state without editing the app manifest")
    func serviceEnablesAutomationStateWithoutEditingManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-enable-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(
                id: "daily-refresh",
                type: "schedule",
                enabledByDefault: false,
                action: "refresh",
                scheduleType: "interval",
                intervalSeconds: 3_600
            )
        ]

        let service = WorkspaceAppService()
        let result = try service.createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let originalManifestData = try Data(contentsOf: result.manifestURL)
        let enabledAt = Date(timeIntervalSince1970: 1_800_000_000)

        try service.setAutomationEnabled(
            app: result.app,
            automationID: "daily-refresh",
            isEnabled: true,
            workspace: workspace,
            modelContext: context,
            now: enabledAt
        )

        let automations = try service.automationStates(for: result.app, modelContext: context)
        #expect(automations.count == 1)
        #expect(automations[0].isEnabled)
        #expect(automations[0].status == .enabled)
        #expect(automations[0].nextRunAt == enabledAt.addingTimeInterval(3_600))
        #expect(automations[0].updatedAt == enabledAt)
        #expect(result.app.updatedAt == enabledAt)
        #expect(try Data(contentsOf: result.manifestURL) == originalManifestData)

        #expect(throws: WorkspaceAppServiceError.missingAutomation("missing")) {
            try service.setAutomationEnabled(
                app: result.app,
                automationID: "missing",
                isEnabled: true,
                workspace: workspace,
                modelContext: context
            )
        }
    }

    @MainActor
    @Test("service enables automation from canonical manifest when stored path is stale")
    func serviceEnablesAutomationFromCanonicalManifestWhenStoredPathIsStale() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-enable-automation-canonical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(
                id: "hourly-refresh",
                type: "schedule",
                enabledByDefault: false,
                action: "refresh",
                scheduleType: "interval",
                intervalSeconds: 3_600
            )
        ]

        let service = WorkspaceAppService()
        let result = try service.createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        result.app.manifestRelativePath = ".astra/apps/stale/manifest.json"
        result.app.appDirectoryRelativePath = ".astra/apps/stale"
        let enabledAt = Date(timeIntervalSince1970: 1_800_000_000)

        try service.setAutomationEnabled(
            app: result.app,
            automationID: "hourly-refresh",
            isEnabled: true,
            workspace: workspace,
            modelContext: context,
            now: enabledAt
        )

        let automation = try #require(try service.automationStates(for: result.app, modelContext: context).first)
        #expect(automation.nextRunAt == enabledAt.addingTimeInterval(3_600))
    }

    @MainActor
    @Test("service records app open and refresh lifecycle timestamps")
    func serviceRecordsAppOpenAndRefreshLifecycleTimestamps() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let service = WorkspaceAppService()
        let result = try service.createApp(
            manifest: Self.reconciliationManifest(),
            in: workspace,
            modelContext: context
        )
        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let refreshedAt = openedAt.addingTimeInterval(120)

        try service.openApp(result.app, in: workspace, modelContext: context, now: openedAt)
        try service.refreshApp(result.app, in: workspace, modelContext: context, now: refreshedAt)

        #expect(result.app.lastOpenedAt == openedAt)
        #expect(result.app.lastRefreshedAt == refreshedAt)
        #expect(result.app.updatedAt == refreshedAt)
        #expect(workspace.updatedAt >= openedAt)

        let fetched = try #require(try context.fetch(FetchDescriptor<WorkspaceApp>()).first)
        #expect(fetched.lastOpenedAt == openedAt)
        #expect(fetched.lastRefreshedAt == refreshedAt)
    }

    @MainActor
    @Test("service duplicates app manifest metadata and local storage")
    func serviceDuplicatesAppManifestMetadataAndLocalStorage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-duplicate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let service = WorkspaceAppService()
        let result = try service.createApp(
            manifest: Self.reconciliationManifest(),
            in: workspace,
            modelContext: context
        )
        let originalDatabaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: result.app.logicalID
        ))
        try WorkspaceAppStorageService().insertRecord(
            [
                "id": .text("review-1"),
                "source_record_id": .text("P-001"),
                "match_status": .text("missing")
            ],
            into: "review_items",
            databaseURL: originalDatabaseURL
        )

        let duplicate = try service.duplicateApp(
            result.app,
            in: workspace,
            modelContext: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(duplicate.app.id != result.app.id)
        #expect(duplicate.app.logicalID == "enrollment-reconciliation-copy")
        #expect(duplicate.app.name == "Enrollment Reconciliation Copy")
        #expect(duplicate.app.manifestRelativePath == ".astra/apps/enrollment-reconciliation-copy/manifest.json")
        #expect(FileManager.default.fileExists(atPath: duplicate.manifestURL.path))

        let duplicateManifest = try JSONDecoder().decode(
            WorkspaceAppManifest.self,
            from: Data(contentsOf: duplicate.manifestURL)
        )
        #expect(duplicateManifest.app.id == "enrollment-reconciliation-copy")
        #expect(duplicateManifest.app.name == "Enrollment Reconciliation Copy")

        let duplicateDatabaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: duplicate.app.logicalID
        ))
        let rows = try WorkspaceAppStorageService().records(in: "review_items", databaseURL: duplicateDatabaseURL)
        #expect(rows.count == 1)
        #expect(rows[0]["source_record_id"] == .text("P-001"))
        #expect(rows[0]["match_status"] == .text("missing"))

        let apps = try context.fetch(FetchDescriptor<WorkspaceApp>())
        #expect(apps.map(\.logicalID).sorted() == ["enrollment-reconciliation", "enrollment-reconciliation-copy"])

        let duplicateBindings = try service.dependencyBindings(for: duplicate.app, modelContext: context)
        #expect(duplicateBindings.count == 2)
        #expect(duplicateBindings.allSatisfy { $0.appID == duplicate.app.id })
        #expect(duplicateBindings.allSatisfy { $0.appLogicalID == duplicate.app.logicalID })
    }

    @MainActor
    @Test("service duplicates from the directory that owns the readable manifest")
    func serviceDuplicatesFromReadableManifestDirectoryWhenCanonicalDirectoryIsStale() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-duplicate-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let service = WorkspaceAppService()
        let result = try service.createApp(
            manifest: Self.reconciliationManifest(),
            in: workspace,
            modelContext: context
        )
        let canonicalDirectory = result.manifestURL.deletingLastPathComponent()
        let legacyDirectory = URL(fileURLWithPath: workspace.primaryPath)
            .appendingPathComponent(".astra/apps/legacy-reconciliation", isDirectory: true)
        try FileManager.default.moveItem(at: canonicalDirectory, to: legacyDirectory)
        try FileManager.default.createDirectory(
            at: canonicalDirectory.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true
        )
        result.app.manifestRelativePath = ".astra/apps/legacy-reconciliation/manifest.json"
        result.app.appDirectoryRelativePath = ".astra/apps/legacy-reconciliation"

        let legacyDatabaseURL = legacyDirectory
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("app.sqlite")
        try WorkspaceAppStorageService().insertRecord(
            [
                "id": .text("review-1"),
                "source_record_id": .text("P-001"),
                "match_status": .text("missing")
            ],
            into: "review_items",
            databaseURL: legacyDatabaseURL
        )

        let duplicate = try service.duplicateApp(
            result.app,
            in: workspace,
            modelContext: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let duplicateDatabaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: duplicate.app.logicalID
        ))
        let rows = try WorkspaceAppStorageService().records(in: "review_items", databaseURL: duplicateDatabaseURL)
        #expect(rows.count == 1)
        #expect(rows[0]["source_record_id"] == .text("P-001"))
    }

    @MainActor
    @Test("manifest store reads legacy app root stored paths without trusting nonportable IDs")
    func manifestStoreReadsLegacyAppRootStoredPathsWithoutTrustingNonportableIDs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-legacy-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Legacy Apps", primaryPath: root.path)
        let legacyDirectory = root.appendingPathComponent("apps/legacy-reconciliation", isDirectory: true)
        let manifestURL = legacyDirectory.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try WorkspaceAppService.encodeManifest(Self.reconciliationManifest()).write(to: manifestURL)
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: " legacy reconciliation ",
            name: "Legacy",
            manifestRelativePath: "apps/legacy-reconciliation/manifest.json",
            appDirectoryRelativePath: "apps/legacy-reconciliation",
            manifestDigest: "digest"
        )

        #expect(WorkspaceFileLayout.appDirectoryURL(workspacePath: workspace.primaryPath, appID: app.logicalID) == nil)

        let loaded = try WorkspaceAppManifestStore().loadManifest(app: app, workspace: workspace)

        #expect(loaded.location.manifestURL.path == manifestURL.path)
        #expect(loaded.location.appDirectoryURL.path == legacyDirectory.path)
        #expect(loaded.manifest.app.id == "enrollment-reconciliation")
    }

    @MainActor
    @Test("service deletes safely stored legacy app directories for nonportable logical IDs")
    func serviceDeletesSafelyStoredLegacyAppDirectoryForNonportableLogicalID() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-delete-legacy-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Legacy Apps", primaryPath: root.path)
        context.insert(workspace)
        let legacyDirectory = root.appendingPathComponent("apps/legacy-reconciliation", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try WorkspaceAppService.encodeManifest(Self.reconciliationManifest())
            .write(to: legacyDirectory.appendingPathComponent("manifest.json"))
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: " legacy reconciliation ",
            name: "Legacy",
            manifestRelativePath: "apps/legacy-reconciliation/manifest.json",
            appDirectoryRelativePath: "apps/legacy-reconciliation",
            manifestDigest: "digest"
        )
        context.insert(app)
        try context.save()

        try WorkspaceAppService().deleteApp(app, in: workspace, modelContext: context)

        #expect(!FileManager.default.fileExists(atPath: legacyDirectory.path))
        #expect(try context.fetch(FetchDescriptor<WorkspaceApp>()).isEmpty)
    }

    @MainActor
    @Test("service deletes app files and related domain records")
    func serviceDeletesAppFilesAndRelatedDomainRecords() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(id: "daily-refresh", type: "schedule", action: "refresh")
        ]
        let service = WorkspaceAppService()
        let result = try service.createApp(manifest: manifest, in: workspace, modelContext: context)
        let appDirectoryURL = URL(fileURLWithPath: workspace.primaryPath)
            .appendingPathComponent(result.app.appDirectoryRelativePath, isDirectory: true)
        let run = WorkspaceAppRun(
            workspaceID: workspace.id,
            appID: result.app.id,
            appLogicalID: result.app.logicalID,
            actionID: "refresh",
            status: .completed
        )
        let event = WorkspaceAppRunEvent(
            runID: run.id,
            workspaceID: workspace.id,
            appID: result.app.id,
            actionID: "refresh",
            type: "workspaceApp.action.completed"
        )
        context.insert(run)
        context.insert(event)
        try context.save()

        // The App Studio build journal lives inside the app directory, so it must be removed with
        // the app (no separate cascade — the recursive directory delete handles it).
        let journalPath = WorkspaceFileLayout.appStudioJournalFile(
            workspacePath: workspace.primaryPath, appID: result.app.logicalID
        )
        WorkspaceAppStudioJournalService().save(
            WorkspaceAppStudioJournal(messages: [StudioMessage(role: .user, text: "hi")]),
            appID: result.app.logicalID, workspacePath: workspace.primaryPath
        )
        #expect(FileManager.default.fileExists(atPath: journalPath))

        try service.deleteApp(
            result.app,
            in: workspace,
            modelContext: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(!FileManager.default.fileExists(atPath: appDirectoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: journalPath))   // journal removed with the app dir
        #expect(try context.fetch(FetchDescriptor<WorkspaceApp>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppAutomationState>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppRun>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppRunEvent>()).isEmpty)
    }

    @MainActor
    @Test("createApp rejects reserved path component IDs before writing app files")
    func createAppRejectsReservedPathComponentIDsBeforeWritingAppFiles() throws {
        for reservedID in [".", ".."] {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("workspace-app-reserved-id-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            let context = container.mainContext
            let workspace = Workspace(name: "Apps", primaryPath: root.path)
            context.insert(workspace)

            var manifest = Self.reconciliationManifest()
            manifest.app.id = reservedID

            do {
                _ = try WorkspaceAppService().createApp(
                    manifest: manifest,
                    in: workspace,
                    modelContext: context
                )
                Issue.record("Expected reserved app id '\(reservedID)' to be rejected.")
            } catch WorkspaceAppServiceError.invalidManifest(let blockers) {
                #expect(blockers.contains {
                    $0.path == "/app/id" && $0.message.contains("reserved path component")
                })
            }

            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".astra/manifest.json").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".astra/apps/manifest.json").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".astra/data/app.sqlite").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".astra/apps/data/app.sqlite").path))
        }
    }

    @MainActor
    @Test("createApp still accepts portable dotted app IDs inside the per-app directory")
    func createAppAcceptsPortableDottedAppIDsInsidePerAppDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-dotted-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        var manifest = Self.reconciliationManifest()
        manifest.app.id = "vendor.reconciliation"

        let created = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )

        #expect(created.app.logicalID == "vendor.reconciliation")
        #expect(created.manifestURL.path == root.appendingPathComponent(".astra/apps/vendor.reconciliation/manifest.json").path)
        #expect(FileManager.default.fileExists(atPath: created.manifestURL.path))
    }

    @MainActor
    @Test("createApp enforces workspace-unique logical IDs so two apps never share one SQLite file")
    func serviceEnforcesUniqueLogicalIDAcrossApps() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        // Two apps created with the SAME manifest.app.id in one workspace. Even though callers usually
        // dedupe first, the SERVICE must guarantee isolation: the logical id keys the storage dir +
        // SQLite file, so a collision would otherwise share `.astra/apps/<id>/data/app.sqlite`.
        let manifest = Self.reconciliationManifest()
        let service = WorkspaceAppService()
        let first = try service.createApp(manifest: manifest, in: workspace, modelContext: context)
        let second = try service.createApp(manifest: manifest, in: workspace, modelContext: context)

        // The first keeps the declared id; the duplicate is auto-suffixed to a fresh, unique id.
        #expect(first.app.logicalID == manifest.app.id)
        #expect(second.app.logicalID != first.app.logicalID)

        // The two apps therefore key DIFFERENT SQLite files, and both exist as separate databases.
        let firstDB = WorkspaceFileLayout.appDatabaseFile(workspacePath: workspace.primaryPath, appID: first.app.logicalID)
        let secondDB = WorkspaceFileLayout.appDatabaseFile(workspacePath: workspace.primaryPath, appID: second.app.logicalID)
        #expect(firstDB != secondDB)
        #expect(FileManager.default.fileExists(atPath: firstDB))
        #expect(FileManager.default.fileExists(atPath: secondDB))

        // The duplicate's PERSISTED manifest carries the suffixed id, so it matches its storage path.
        let persisted = try JSONDecoder().decode(WorkspaceAppManifest.self, from: Data(contentsOf: second.manifestURL))
        #expect(persisted.app.id == second.app.logicalID)

        // Both apps are distinct rows in the index.
        let logicalIDs = try context.fetch(FetchDescriptor<WorkspaceApp>()).map(\.logicalID)
        #expect(Set(logicalIDs).count == 2)
    }

    static func reconciliationManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "enrollment-reconciliation",
                name: "Enrollment Reconciliation",
                icon: "checklist.checked",
                description: "Compare warehouse records against REDCap."
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "sourceWarehouse",
                    contract: "tabularQuery.read",
                    minVersion: "1.0.0",
                    operations: ["describeTable", "runReadOnlyQuery"],
                    providerHint: "bigQuery",
                    dataClass: "sensitive"
                ),
                WorkspaceAppRequirement(
                    id: "targetRecords",
                    contract: "recordProject.read",
                    minVersion: "1.0.0",
                    operations: ["describeProject", "readRecords", "validateRecord"],
                    providerHint: "redcap",
                    dataClass: "sensitive"
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "source_record_id", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "match_status", type: "text", required: true)
                ])
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "latest_candidates",
                    requirementRef: "sourceWarehouse",
                    operation: "runReadOnlyQuery",
                    query: "SELECT * FROM clinical.enrollment_candidates LIMIT 100"
                ),
                WorkspaceAppSource(
                    id: "redcap_records",
                    requirementRef: "targetRecords",
                    operation: "readRecords",
                    projectRef: "enrollment-study"
                )
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "dashboard",
                    type: "dashboard",
                    title: "Enrollment Reconciliation",
                    table: "review_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "review_count",
                            type: "metric",
                            label: "Review records",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "records_by_status",
                            type: "chart",
                            label: "Records by status",
                            groupBy: "match_status",
                            aggregation: "count"
                        )
                    ]
                )
            ],
            actions: [
                WorkspaceAppActionSpec(id: "refresh", type: "pipeline", label: "Refresh"),
                WorkspaceAppActionSpec(id: "add_review_item", type: "appStorage.insert", label: "Add Review Item", table: "review_items")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["tabularQuery.read", "recordProject.read"],
                writes: ["appStorage.records"],
                defaultMode: .readOnly
            )
        )
    }
}
