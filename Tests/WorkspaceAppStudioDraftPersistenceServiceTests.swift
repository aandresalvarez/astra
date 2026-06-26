import Foundation
import SwiftData
import Testing
@testable import ASTRA

@MainActor
@Suite("Workspace App Studio Draft Persistence")
struct WorkspaceAppStudioDraftPersistenceServiceTests {
    @Test("autosave creates a durable draft app with its manifest and journal")
    func autosaveCreatesDurableDraftApp() throws {
        let fixture = try Fixture()
        let manifest = Self.manifest(named: "Lab Samples")
        let draft = Self.draft(manifest: manifest, workspace: fixture.workspace)
        let journal = try Self.journal(for: manifest, intent: "track lab samples")

        let result = try WorkspaceAppStudioDraftPersistenceService().saveDraft(
            draft,
            journal: journal,
            existingLogicalID: nil,
            sessionWorkspaceID: nil,
            preferredWorkspace: fixture.workspace,
            workspaces: [fixture.workspace],
            apps: [],
            modelContext: fixture.context
        )

        let saved = try #require(result?.app)
        #expect(saved.lifecycleStatus == .draft)
        #expect(saved.logicalID == manifest.app.id)
        #expect(FileManager.default.fileExists(atPath: result?.manifestURL.path ?? ""))

        let apps = try fixture.context.fetch(FetchDescriptor<WorkspaceApp>())
        #expect(apps.count == 1)
        #expect(apps.first?.lifecycleStatus == .draft)

        let savedJournal = WorkspaceAppStudioJournalService().load(
            appID: saved.logicalID,
            workspacePath: fixture.workspace.primaryPath
        )
        #expect(savedJournal.messages.map { $0.text }.contains("track lab samples"))
        #expect(savedJournal.events.first?.manifestDigest == journal.events.first?.manifestDigest)
    }

    @Test("autosave updates an existing draft in place instead of creating a sibling")
    func autosaveUpdatesExistingDraftInPlace() throws {
        let fixture = try Fixture()
        let service = WorkspaceAppService()
        let original = Self.manifest(named: "Lab Samples")
        let created = try service.createApp(
            manifest: original,
            in: fixture.workspace,
            modelContext: fixture.context,
            status: .draft
        )
        var edited = created.manifest
        edited.app.name = "Lab Samples Review"
        let draft = Self.draft(manifest: edited, workspace: fixture.workspace)
        let journal = try Self.journal(for: edited, intent: "rename the app")

        let result = try WorkspaceAppStudioDraftPersistenceService().saveDraft(
            draft,
            journal: journal,
            existingLogicalID: created.app.logicalID,
            sessionWorkspaceID: fixture.workspace.id,
            preferredWorkspace: fixture.workspace,
            workspaces: [fixture.workspace],
            apps: [created.app],
            modelContext: fixture.context
        )

        let saved = try #require(result?.app)
        #expect(saved.id == created.app.id)
        #expect(saved.lifecycleStatus == .draft)
        #expect(saved.name == "Lab Samples Review")
        #expect(try fixture.context.fetch(FetchDescriptor<WorkspaceApp>()).count == 1)

        let onDisk = try JSONDecoder().decode(
            WorkspaceAppManifest.self,
            from: Data(contentsOf: result?.manifestURL ?? URL(fileURLWithPath: "/missing"))
        )
        #expect(onDisk.app.name == "Lab Samples Review")
    }

    @Test("autosave ignores provisional drafts that do not have a matching accepted journal event")
    func autosaveIgnoresProvisionalDraftWithoutMatchingEvent() throws {
        let fixture = try Fixture()
        let manifest = Self.manifest(named: "Temporary Baseline")
        let draft = Self.draft(manifest: manifest, workspace: fixture.workspace)

        let result = try WorkspaceAppStudioDraftPersistenceService().saveDraft(
            draft,
            journal: WorkspaceAppStudioJournal(),
            existingLogicalID: nil,
            sessionWorkspaceID: nil,
            preferredWorkspace: fixture.workspace,
            workspaces: [fixture.workspace],
            apps: [],
            modelContext: fixture.context
        )

        #expect(result == nil)
        #expect(try fixture.context.fetch(FetchDescriptor<WorkspaceApp>()).isEmpty)
    }

    @Test("autosave never overwrites a published app while editing it in Studio")
    func autosaveSkipsPublishedEditTargets() throws {
        let fixture = try Fixture()
        let service = WorkspaceAppService()
        let original = Self.manifest(named: "Published Lab Samples")
        let created = try service.createApp(
            manifest: original,
            in: fixture.workspace,
            modelContext: fixture.context,
            status: .published
        )
        var edited = created.manifest
        edited.app.name = "Unpublished Edit"
        let draft = Self.draft(manifest: edited, workspace: fixture.workspace)
        let journal = try Self.journal(for: edited, intent: "rename published app")

        let result = try WorkspaceAppStudioDraftPersistenceService().saveDraft(
            draft,
            journal: journal,
            existingLogicalID: created.app.logicalID,
            sessionWorkspaceID: fixture.workspace.id,
            preferredWorkspace: fixture.workspace,
            workspaces: [fixture.workspace],
            apps: [created.app],
            modelContext: fixture.context
        )

        #expect(result == nil)
        #expect(created.app.lifecycleStatus == .published)
        let onDisk = try JSONDecoder().decode(
            WorkspaceAppManifest.self,
            from: Data(contentsOf: created.manifestURL)
        )
        #expect(onDisk.app.name == "Published Lab Samples")
    }

    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace

        @MainActor
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("workspace-app-draft-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            context = container.mainContext
            workspace = Workspace(name: "Drafts", primaryPath: root.path)
            context.insert(workspace)
        }
    }

    private static func manifest(named name: String) -> WorkspaceAppManifest {
        var manifest = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: name)
        manifest.app.name = name
        return manifest
    }

    private static func draft(
        manifest: WorkspaceAppManifest,
        workspace: Workspace
    ) -> WorkspaceAppStudioDraft {
        WorkspaceAppStudioDraft(
            id: UUID(),
            workspaceID: workspace.id,
            intent: manifest.app.name,
            manifest: manifest,
            validationReport: WorkspaceAppManifestValidator.validate(manifest)
        )
    }

    private static func journal(
        for manifest: WorkspaceAppManifest,
        intent: String
    ) throws -> WorkspaceAppStudioJournal {
        let data = try WorkspaceAppService.encodeManifest(manifest)
        let digest = WorkspaceAppService.digest(for: data)
        return WorkspaceAppStudioJournal(
            messages: [
                StudioMessage(role: .user, text: intent),
                StudioMessage(role: .assistant, kind: .summary, text: "Saved draft.")
            ],
            events: [
                StudioGenerationEvent(
                    kind: .generation,
                    intent: intent,
                    origin: "model",
                    accepted: true,
                    blockerCount: 0,
                    manifestDigest: digest
                )
            ]
        )
    }
}
