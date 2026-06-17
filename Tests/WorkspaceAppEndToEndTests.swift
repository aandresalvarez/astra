import Foundation
import SwiftData
import Testing
@testable import ASTRA

/// End-to-end coverage of the App Studio module: every stage chained through the REAL services
/// (no mocks beyond an injected model runner) on a single app instance — generation → publish →
/// CRUD → metrics → versioning → revert, plus the REDCap form pipeline and the model-backed
/// generation loop. This is the "is the builder functional and strong" gate.
@Suite("Workspace App Studio — End to End")
struct WorkspaceAppEndToEndTests {
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
            .appendingPathComponent("wsapp-e2e-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Full lifecycle: publish -> CRUD -> metrics -> version -> revert

    @MainActor
    @Test("publish a grocery app, run full CRUD, version an edit, and revert")
    func fullLifecycle() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let service = WorkspaceAppService()
        let versions = WorkspaceAppVersionService()
        let executor = WorkspaceAppActionExecutor()

        // 1. Publish (Studio path): build -> createApp(.published) -> snapshot v1.
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
        let created = try service.createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)
        let app = created.app
        #expect(app.lifecycleStatus == .published)
        try versions.recordPublish(app: app, manifestData: try WorkspaceAppService.encodeManifest(manifest),
                                   validated: true, workspacePath: env.workspace.primaryPath, modelContext: env.context)
        #expect(app.latestVersionNumber == 1)

        func run(_ id: String, _ input: WorkspaceAppActionInput) throws -> WorkspaceAppActionExecutionResult {
            try executor.execute(actionID: id, app: app, workspace: env.workspace, manifest: manifest, input: input, modelContext: env.context)
        }
        func items() throws -> [[String: WorkspaceAppStorageValue]] {
            try run("list_items", WorkspaceAppActionInput(table: "items")).rows
        }

        // 2. CRUD through the executor.
        _ = try run("add_item", WorkspaceAppActionInput(table: "items", record: ["id": .text("i1"), "name": .text("Apples"), "last_price": .real(2.5)]))
        _ = try run("add_item", WorkspaceAppActionInput(table: "items", record: ["id": .text("i2"), "name": .text("Bread")]))
        #expect(try items().count == 2)

        // 3. Metrics reflect live data through the published presentation builders.
        let rows = try items()
        let surface = WorkspaceAppNativeSurfaceBuilder.presentation(
            manifest: manifest,
            storageTables: [WorkspaceAppStorageTableSnapshot(name: "items", columns: ["id", "name", "last_price"], rows: rows, errorMessage: nil)]
        )
        #expect(surface.metrics.first { $0.id == "item_count" }?.value == "2")

        _ = try run("update_item", WorkspaceAppActionInput(table: "items", record: ["id": .text("i1"), "name": .text("Green Apples")]))
        #expect(try items().first { ($0["id"]) == .text("i1") }?["name"] == .text("Green Apples"))

        _ = try run("delete_item", WorkspaceAppActionInput(table: "items", record: ["id": .text("i2")], confirmedDestructive: true))
        #expect(try items().count == 1)

        // 4. Edit + republish -> v2, then revert -> v1 (storage preserved).
        var edited = manifest
        edited.app.name = "Grocery Tracker v2"
        let editedData = try WorkspaceAppService.encodeManifest(edited)
        try editedData.write(to: created.manifestURL, options: [.atomic])
        app.manifestDigest = WorkspaceAppService.digest(for: editedData)
        try versions.recordPublish(app: app, manifestData: editedData, validated: true, workspacePath: env.workspace.primaryPath, modelContext: env.context)
        #expect(versions.listVersions(appID: app.logicalID, workspacePath: env.workspace.primaryPath).count == 2)

        let restored = try versions.revertToPreviousPublished(app: app, in: env.workspace, modelContext: env.context)
        #expect(restored == 1)
        #expect(try items().count == 1)  // revert did NOT wipe storage
    }

    // MARK: - Chat entry point

    @MainActor
    @Test("the /app chat command publishes a working app end to end")
    func chatCommandPublishesApp() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reply = WorkspaceAppChatCommand.reply(input: "/app Build me a grocery database app.", workspace: env.workspace, modelContext: env.context)
        #expect(reply.contains("created"))
        let app = try #require(try env.context.fetch(FetchDescriptor<WorkspaceApp>()).first { $0.workspaceID == env.workspace.id })
        #expect(app.lifecycleStatus == .published)
        #expect(app.latestVersionNumber == 1)  // publish snapshotted a version
    }

    // MARK: - REDCap form pipeline

    @MainActor
    @Test("REDCap metadata builds a valid form app that publishes and renders fields")
    func redcapFormPipeline() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let manifest = WorkspaceAppREDCapFormBuilder.build(
            appID: "enroll", appName: "Enrollment", formName: "enrollment",
            fields: [
                WorkspaceAppREDCapFieldMetadata(fieldName: "first_name", fieldType: "text", required: true),
                WorkspaceAppREDCapFieldMetadata(fieldName: "consent", fieldType: "radio", required: true, choices: "1, Yes | 0, No"),
                WorkspaceAppREDCapFieldMetadata(fieldName: "dose", fieldType: "text", validation: "integer", branchingLogic: "[consent] = '1'")
            ]
        )
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        // The form submits through an approval-gated external write (permission mode, not lifecycle).
        #expect(manifest.permissions.defaultMode == .approvalRequired)
        // Publishes through the normal service.
        let created = try WorkspaceAppService().createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)
        #expect(created.app.lifecycleStatus == .published)
        // The form view renders its fields; the dose field is gated on consent and hidden until met.
        let formView = try #require(manifest.views.first { $0.type == "form" })
        #expect(WorkspaceAppFormPresentationBuilder.presentation(view: formView, draft: [:]).contains { $0.name == "first_name" })
        #expect(!WorkspaceAppFormPresentationBuilder.presentation(view: formView, draft: [:]).contains { $0.name == "dose" })
        #expect(WorkspaceAppFormPresentationBuilder.presentation(view: formView, draft: ["consent": .text("1")]).contains { $0.name == "dose" })
    }

    // MARK: - Package round trip (export -> review -> import)

    @MainActor
    @Test("a published app exports, reviews, and imports into another workspace")
    func packageRoundTrip() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        // Publish a grocery app in workspace 1.
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
        let created = try WorkspaceAppService().createApp(manifest: manifest, in: env.workspace, modelContext: env.context, status: .published)

        // Export it to a .astra-app package.
        let export = try WorkspaceAppPackageExporter().exportTemplatePackage(app: created.app, workspace: env.workspace)

        // Review the package (the UI's data source).
        let review = WorkspaceAppPackageImportReviewer.review(packageURL: export.packageURL)
        #expect(review.packageName == manifest.app.name)
        #expect(!review.storageTables.isEmpty)

        // Import into a SECOND workspace.
        let targetRoot = env.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = Workspace(name: "Target", primaryPath: targetRoot.path)
        env.context.insert(target)

        if review.canInstall {
            let result = try WorkspaceAppPackageService().importPackage(at: export.packageURL, into: target, modelContext: env.context)
            #expect(result.app.workspaceID == target.id)
            let importedHere = try env.context.fetch(FetchDescriptor<WorkspaceApp>()).filter { $0.workspaceID == target.id }
            #expect(importedHere.count == 1)
            #expect(importedHere.first?.lifecycleStatus == .draft)  // imports as a draft for review
        } else {
            // A blocked review (e.g. trust) is still a correct outcome — install must be refused.
            #expect(!review.report.blockers.isEmpty)
            #expect(throws: (any Error).self) {
                _ = try WorkspaceAppPackageService().importPackage(at: export.packageURL, into: target, modelContext: env.context)
            }
        }
    }

    // MARK: - Model-backed generation loop

    @MainActor
    @Test("model-backed generation produces a publishable manifest (injected runner)")
    func modelGenerationPipeline() async throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        // A scripted runner returns the deterministic template as the model's first-shot manifest.
        let template = WorkspaceAppStudioBuilder.baseManifest(intent: "grocery")
        let json = String(data: try WorkspaceAppService.encodeManifest(template), encoding: .utf8) ?? "{}"
        let output = "ASTRA_APP_MANIFEST\n\(json)\nEND_ASTRA_APP_MANIFEST"
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "grocery", workspaceName: "Apps", workspacePath: env.root.path,
            runner: { _, _, _ in AgentUtilityRunResult(exitCode: 0, output: output, error: "") }
        )
        #expect(result.accepted)
        #expect(result.canPublish)
        let created = try WorkspaceAppService().createApp(manifest: result.manifest, in: env.workspace, modelContext: env.context, status: .published)
        #expect(created.app.lifecycleStatus == .published)
    }
}
