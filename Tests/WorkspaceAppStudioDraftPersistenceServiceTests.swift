import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

@MainActor
@Suite("Workspace App Studio Draft Persistence")
struct WorkspaceAppStudioDraftPersistenceServiceTests {
    @Test("autosave creates a durable draft app and leaves journal adoption to the session")
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
        #expect(savedJournal.isEmpty)
    }

    @Test("autosave coordinator saves the adopted journal once after app persistence")
    func autosaveCoordinatorSavesAdoptedJournalOnce() async throws {
        let fixture = try Fixture()
        let manifest = Self.manifest(named: "Lab Samples")
        let store = SpyJournalStore()
        let session = WorkspaceAppStudioSession(
            generate: { _, _, _, _, _, _, _, _ in Self.generationResult(manifest) },
            verify: Self.noVerify,
            journalStore: store
        )

        await session.submit(
            "track lab samples",
            workspace: fixture.workspace,
            runtimeID: TaskExecutionDefaults.runtime.rawValue,
            model: TaskExecutionDefaults.model,
            availableProviders: []
        )
        #expect(store.saveCount == 0)

        WorkspaceAppStudioDraftAutosaveCoordinator.autosave(
            session: session,
            preferredWorkspace: fixture.workspace,
            modelContext: fixture.context
        )

        let saved = try #require(store.saved)
        let digest = try Self.journalDigest(for: manifest)
        #expect(store.saveCount == 1)
        #expect(saved.appID == manifest.app.id)
        #expect(saved.workspacePath == fixture.workspace.primaryPath)
        #expect(saved.journal.messages.map(\.text).contains("track lab samples"))
        #expect(saved.journal.events.first?.manifestDigest == digest)
        #expect(session.editingAppLogicalID == manifest.app.id)
    }

    @Test("autosave create path lets app service dedupe identity without renaming the draft")
    func autosaveCreatePathUsesServiceIdentityDedupe() throws {
        let fixture = try Fixture()
        let manifest = Self.manifest(named: "Lab Samples")
        let existing = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: fixture.workspace,
            modelContext: fixture.context,
            status: .draft
        )
        let draft = Self.draft(manifest: manifest, workspace: fixture.workspace)
        let journal = try Self.journal(for: manifest, intent: "track duplicate lab samples")

        let result = try WorkspaceAppStudioDraftPersistenceService().saveDraft(
            draft,
            journal: journal,
            existingLogicalID: nil,
            sessionWorkspaceID: nil,
            preferredWorkspace: fixture.workspace,
            workspaces: [fixture.workspace],
            apps: [existing.app],
            modelContext: fixture.context
        )

        let saved = try #require(result?.app)
        #expect(saved.logicalID == "\(manifest.app.id)-2")
        #expect(saved.name == manifest.app.name)
        #expect(result?.manifest.app.id == saved.logicalID)
        #expect(result?.manifest.app.name == manifest.app.name)
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

    @Test("autosave coordinator scopes app fetches to the needed draft target")
    func autosaveCoordinatorScope() {
        let workspaceID = UUID()
        #expect(
            WorkspaceAppStudioDraftAutosaveScope(
                preferredWorkspaceID: workspaceID,
                editingLogicalID: nil
            ).appQuery == .preferredWorkspace(workspaceID)
        )
        #expect(
            WorkspaceAppStudioDraftAutosaveScope(
                preferredWorkspaceID: workspaceID,
                editingLogicalID: "lab-samples"
            ).appQuery == .editingLogicalID("lab-samples")
        )
        #expect(
            WorkspaceAppStudioDraftAutosaveScope(
                preferredWorkspaceID: workspaceID,
                editingLogicalID: "   "
            ).appQuery == .preferredWorkspace(workspaceID)
        )
    }

    @Test("autosave trigger only fires for one newly appended event")
    func autosaveTriggerOnlyFiresForSingleAppend() {
        #expect(WorkspaceAppStudioDraftAutosaveTrigger.shouldAutosave(previousRevision: 0, currentRevision: 1))
        #expect(WorkspaceAppStudioDraftAutosaveTrigger.shouldAutosave(previousRevision: 2, currentRevision: 3))
        #expect(!WorkspaceAppStudioDraftAutosaveTrigger.shouldAutosave(previousRevision: 0, currentRevision: 2))
        #expect(!WorkspaceAppStudioDraftAutosaveTrigger.shouldAutosave(previousRevision: 2, currentRevision: 2))
        #expect(!WorkspaceAppStudioDraftAutosaveTrigger.shouldAutosave(previousRevision: 3, currentRevision: 1))
    }

    @MainActor
    private final class Fixture {
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

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class SpyJournalStore: WorkspaceAppStudioJournalStoring {
        private(set) var saveCount = 0
        private(set) var saved: (journal: WorkspaceAppStudioJournal, appID: String, workspacePath: String)?

        func load(appID: String, workspacePath: String) -> WorkspaceAppStudioJournal {
            WorkspaceAppStudioJournal()
        }

        func save(_ journal: WorkspaceAppStudioJournal, appID: String, workspacePath: String) {
            saveCount += 1
            saved = (journal, appID, workspacePath)
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
        let digest = try journalDigest(for: manifest)
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

    private static func generationResult(_ manifest: WorkspaceAppManifest) -> WorkspaceAppStudioGenerationResult {
        WorkspaceAppStudioGenerationResult(
            manifest: manifest,
            validationReport: WorkspaceAppManifestValidator.validate(manifest),
            accepted: true,
            origin: .model,
            attemptCount: 1,
            providerFailure: nil,
            summary: "Saved draft."
        )
    }

    private static let noVerify: WorkspaceAppStudioVerify = { _, _, _, _ in
        WorkspaceAppStudioVerification(status: .notApplicable, headline: "", detail: "", autoExercise: nil, scenario: nil)
    }

    private static func journalDigest(for manifest: WorkspaceAppManifest) throws -> String {
        try WorkspaceAppService.digest(for: WorkspaceAppService.encodeManifest(manifest))
    }
}
