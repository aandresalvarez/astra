import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace App Version Service (Slice 3)")
struct WorkspaceAppVersionServiceTests {
    // MARK: - Fixtures

    /// A temp workspace + in-memory store + a created (draft) app, ready to publish.
    @MainActor
    private struct Fixture {
        var root: URL
        var container: ModelContainer  // retained so the context + @Model instances stay valid
        var workspace: Workspace
        var context: ModelContext
        var app: WorkspaceApp
        var manifest: WorkspaceAppManifest
        var service = WorkspaceAppVersionService()

        var manifestURL: URL {
            URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
                workspacePath: workspace.primaryPath, appID: app.logicalID
            ))
        }

        /// Mirror the real publish path: rewrite the active manifest + model digest
        /// (as `createApp` would on an edit), then snapshot the version.
        @discardableResult
        func publish(_ manifest: WorkspaceAppManifest, validated: Bool, at seconds: TimeInterval) throws -> Int {
            let data = try WorkspaceAppService.encodeManifest(manifest)
            try data.write(to: manifestURL, options: [.atomic])
            app.manifestDigest = WorkspaceAppService.digest(for: data)
            return try service.recordPublish(
                app: app, manifestData: data, validated: validated,
                in: workspace, modelContext: context,
                now: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    @MainActor
    private static func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wsapp-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
        let result = try WorkspaceAppService().createApp(manifest: manifest, in: workspace, modelContext: context)
        return Fixture(
            root: root, container: container, workspace: workspace,
            context: context, app: result.app, manifest: manifest
        )
    }

    private static func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    // MARK: - Snapshot on publish

    @MainActor
    @Test("publish flow exports workspace mirror only after version fields are recorded")
    func publishFlowExportsMirrorAfterVersionFields() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wsapp-publish-mirror-\(UUID().uuidString)", isDirectory: true)
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
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath))

        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
        let created = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context,
            status: .published,
            persistence: .saveOnly
        )
        #expect(!FileManager.default.fileExists(atPath: configURL.path))

        let manifestData = try WorkspaceAppService.encodeManifest(created.manifest)
        let digest = WorkspaceAppService.digest(for: manifestData)
        try WorkspaceAppVersionService().recordPublish(
            app: created.app,
            manifestData: manifestData,
            validated: true,
            in: workspace,
            modelContext: context
        )

        let config = try await Self.waitForExportedWorkspaceConfig(at: configURL)
        let appConfig = try #require(config.workspaceApps?.first { $0.logicalID == created.app.logicalID })
        #expect(appConfig.latestVersionNumber == 1)
        #expect(appConfig.publishedManifestDigest == digest)
        #expect(appConfig.lastKnownGoodManifestDigest == digest)
    }

    @MainActor
    @Test("publishing snapshots version 1 and mirrors it onto the model")
    func publishSnapshotsVersionOne() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }

        let number = try fixture.publish(fixture.manifest, validated: true, at: 1000)
        #expect(number == 1)

        let versionData = try Data(contentsOf: URL(fileURLWithPath: WorkspaceFileLayout.appVersionFile(
            workspacePath: fixture.workspace.primaryPath, appID: fixture.app.logicalID, versionNumber: 1
        )))
        let activeData = try Data(contentsOf: fixture.manifestURL)
        #expect(versionData == activeData)  // byte-identical to the published manifest

        let index = fixture.service.loadIndexOrEmpty(
            appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        )
        #expect(index.entries.count == 1)
        #expect(index.entries[0].number == 1)
        #expect(index.entries[0].validated)
        #expect(index.publishedVersion == 1)
        #expect(index.lastKnownGood == 1)

        let digest = WorkspaceAppService.digest(for: versionData)
        #expect(fixture.app.latestVersionNumber == 1)
        #expect(fixture.app.publishedManifestDigest == digest)
        #expect(fixture.app.lastKnownGoodManifestDigest == digest)
    }

    private static func waitForExportedWorkspaceConfig(
        at url: URL,
        attempts: Int = 100
    ) async throws -> WorkspaceConfigManager.WorkspaceConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for _ in 0..<attempts {
            if let data = try? Data(contentsOf: url),
               let config = try? decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: data) {
                return config
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw WorkspaceAppServiceError.fileOperationFailed("Timed out waiting for workspace mirror export at \(url.path).")
    }

    @MainActor
    @Test("editing and re-publishing creates version 2 and preserves version 1")
    func editCreatesNewVersionTwo() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }

        try fixture.publish(fixture.manifest, validated: true, at: 1000)
        let v1Data = try Data(contentsOf: URL(fileURLWithPath: WorkspaceFileLayout.appVersionFile(
            workspacePath: fixture.workspace.primaryPath, appID: fixture.app.logicalID, versionNumber: 1
        )))

        var edited = fixture.manifest
        edited.app.name = "Groceries v2"
        let number = try fixture.publish(edited, validated: true, at: 2000)
        #expect(number == 2)

        let entries = fixture.service.listVersions(
            appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        )
        #expect(entries.map(\.number) == [1, 2])
        #expect(fixture.app.latestVersionNumber == 2)

        // v1 snapshot is untouched (history preserved); v2 carries the edit.
        let v1After = try Data(contentsOf: URL(fileURLWithPath: WorkspaceFileLayout.appVersionFile(
            workspacePath: fixture.workspace.primaryPath, appID: fixture.app.logicalID, versionNumber: 1
        )))
        let v2Data = try Data(contentsOf: URL(fileURLWithPath: WorkspaceFileLayout.appVersionFile(
            workspacePath: fixture.workspace.primaryPath, appID: fixture.app.logicalID, versionNumber: 2
        )))
        #expect(v1After == v1Data)
        #expect(String(data: v2Data, encoding: .utf8)?.contains("Groceries v2") == true)
    }

    @MainActor
    @Test("an unvalidated publish advances published but preserves last-known-good")
    func failedEditPreservesLastKnownGood() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }

        try fixture.publish(fixture.manifest, validated: true, at: 1000)
        let goodDigest = fixture.app.lastKnownGoodManifestDigest

        var edited = fixture.manifest
        edited.app.name = "Groceries broken"
        try fixture.publish(edited, validated: false, at: 2000)

        // published pointer advanced, but last-known-good stayed on v1.
        #expect(fixture.app.publishedManifestDigest != goodDigest)
        #expect(fixture.app.lastKnownGoodManifestDigest == goodDigest)

        let index = fixture.service.loadIndexOrEmpty(
            appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        )
        #expect(index.publishedVersion == 2)
        #expect(index.lastKnownGood == 1)
    }

    // MARK: - Revert

    @MainActor
    @Test("revert restores the prior published manifest and leaves storage intact")
    func revertRestoresPriorPublished() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }

        try fixture.publish(fixture.manifest, validated: true, at: 1000)
        let v1Data = try Data(contentsOf: fixture.manifestURL)
        let digestA = WorkspaceAppService.digest(for: v1Data)

        var edited = fixture.manifest
        edited.app.name = "Groceries v2"
        try fixture.publish(edited, validated: true, at: 2000)
        #expect(fixture.app.manifestDigest != digestA)  // active manifest is now B

        let databasePath = WorkspaceFileLayout.appDatabaseFile(
            workspacePath: fixture.workspace.primaryPath, appID: fixture.app.logicalID
        )
        let dbExistedBefore = FileManager.default.fileExists(atPath: databasePath)

        let restored = try fixture.service.revertToPreviousPublished(
            app: fixture.app, in: fixture.workspace, modelContext: fixture.context,
            now: Date(timeIntervalSince1970: 3000)
        )
        #expect(restored == 1)

        let activeAfter = try Data(contentsOf: fixture.manifestURL)
        #expect(activeAfter == v1Data)                      // bytes restored
        #expect(fixture.app.manifestDigest == digestA)
        #expect(fixture.app.lifecycleStatus == .published)

        let index = fixture.service.loadIndexOrEmpty(
            appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        )
        #expect(index.publishedVersion == 1)                // pointer moved back
        #expect(fixture.app.latestVersionNumber == 2)       // history not forked
        #expect(index.entries.count == 2)                   // no v3 minted

        // Storage is untouched by a manifest revert.
        #expect(FileManager.default.fileExists(atPath: databasePath) == dbExistedBefore)
    }

    @MainActor
    @Test("revert steps back through history and throws at the oldest version")
    func revertStepsBackThroughHistory() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }

        try fixture.publish(fixture.manifest, validated: true, at: 1000)
        var v2 = fixture.manifest; v2.app.name = "v2"
        try fixture.publish(v2, validated: true, at: 2000)
        var v3 = fixture.manifest; v3.app.name = "v3"
        try fixture.publish(v3, validated: true, at: 3000)

        // v3 -> v2 -> v1, then nothing prior to v1.
        #expect(try fixture.service.revertToPreviousPublished(
            app: fixture.app, in: fixture.workspace, modelContext: fixture.context, now: Date(timeIntervalSince1970: 4000)
        ) == 2)
        #expect(try fixture.service.revertToPreviousPublished(
            app: fixture.app, in: fixture.workspace, modelContext: fixture.context, now: Date(timeIntervalSince1970: 5000)
        ) == 1)
        #expect(throws: WorkspaceAppServiceError.self) {
            try fixture.service.revertToPreviousPublished(
                app: fixture.app, in: fixture.workspace, modelContext: fixture.context
            )
        }
    }

    @MainActor
    @Test("revert does NOT downgrade last-known-good (a newer validated version still exists)")
    func revertPreservesLastKnownGood() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }

        try fixture.publish(fixture.manifest, validated: true, at: 1000)
        var v2 = fixture.manifest; v2.app.name = "v2"
        try fixture.publish(v2, validated: true, at: 2000)
        let lkgBefore = fixture.app.lastKnownGoodManifestDigest  // == v2's digest

        try fixture.service.revertToPreviousPublished(
            app: fixture.app, in: fixture.workspace, modelContext: fixture.context, now: Date(timeIntervalSince1970: 3000)
        )
        // The model cache must keep mirroring the file-level source of truth, which revert
        // leaves at v2 (revert moves only the `published` pointer).
        #expect(fixture.app.lastKnownGoodManifestDigest == lkgBefore)
        let index = fixture.service.loadIndexOrEmpty(
            appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        )
        #expect(index.lastKnownGood == 2)
        #expect(index.publishedVersion == 1)
    }

    @MainActor
    @Test("logicalID dedup lets two apps from the same intent coexist without collision")
    func sameIntentDoesNotCollide() throws {
        let fixture = try Self.makeFixture()  // app #1, created from the grocery intent
        defer { Self.cleanup(fixture) }

        // Mirror publishWorkspaceApp: dedup the second app's id against the existing one.
        let deduped = WorkspaceAppStudioBuilder.manifestForPublishing(
            fixture.manifest, existingLogicalIDs: [fixture.app.logicalID]
        )
        #expect(deduped.app.id != fixture.manifest.app.id)

        let second = try WorkspaceAppService().createApp(
            manifest: deduped, in: fixture.workspace, modelContext: fixture.context, status: .published
        )
        #expect(second.app.logicalID != fixture.app.logicalID)

        let appsHere = try fixture.context.fetch(FetchDescriptor<WorkspaceApp>())
            .filter { $0.workspaceID == fixture.workspace.id }
        #expect(appsHere.count == 2)  // two distinct records, no overwrite, no duplicate id
    }

    @MainActor
    @Test("revert with no prior published version throws")
    func revertWithoutPriorThrows() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }

        try fixture.publish(fixture.manifest, validated: true, at: 1000)
        #expect(throws: WorkspaceAppServiceError.self) {
            try fixture.service.revertToPreviousPublished(
                app: fixture.app, in: fixture.workspace, modelContext: fixture.context
            )
        }
    }

    // MARK: - Last known good

    @MainActor
    @Test("markLastKnownGood promotes a version and validates its entry")
    func markLastKnownGoodPromotes() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }

        try fixture.publish(fixture.manifest, validated: false, at: 1000)
        var edited = fixture.manifest
        edited.app.name = "Groceries v2"
        try fixture.publish(edited, validated: false, at: 2000)

        var index = fixture.service.loadIndexOrEmpty(
            appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        )
        #expect(index.lastKnownGood == nil)  // nothing validated yet

        let digest = try fixture.service.markLastKnownGood(
            versionNumber: 1, appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        )
        index = fixture.service.loadIndexOrEmpty(
            appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        )
        #expect(index.lastKnownGood == 1)
        #expect(index.entries[0].validated)
        #expect(digest == index.entries[0].digest)
    }

    @MainActor
    @Test("listVersions is empty before the first publish")
    func listVersionsEmptyBeforePublish() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanup(fixture) }
        #expect(fixture.service.listVersions(
            appID: fixture.app.logicalID, workspacePath: fixture.workspace.primaryPath
        ).isEmpty)
    }

    // MARK: - Schema absorption

    @MainActor
    @Test("the new version fields round-trip through the V7 in-memory container")
    func versionFieldsRoundTripThroughV7Container() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let id = UUID()
        let app = WorkspaceApp(
            id: id,
            workspaceID: UUID(),
            logicalID: "demo",
            name: "Demo",
            manifestRelativePath: "p/manifest.json",
            appDirectoryRelativePath: "p",
            manifestDigest: "abc",
            publishedManifestDigest: "pub",
            lastKnownGoodManifestDigest: "good",
            latestVersionNumber: 7
        )
        context.insert(app)
        try context.save()

        let fetched = try #require(
            try context.fetch(FetchDescriptor<WorkspaceApp>()).first { $0.id == id }
        )
        #expect(fetched.publishedManifestDigest == "pub")
        #expect(fetched.lastKnownGoodManifestDigest == "good")
        #expect(fetched.latestVersionNumber == 7)
    }
}
