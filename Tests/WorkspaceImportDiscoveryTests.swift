import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
import ASTRACore
@testable import ASTRA

private final class WorkspaceCapabilityEventRecorder: @unchecked Sendable {
    private(set) var changes: [CapabilityCatalogPersistenceChange] = []
    private var token: NSObjectProtocol?

    @MainActor
    func start() {
        token = NotificationCenter.default.addObserver(
            forName: .capabilityCatalogPersistenceChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let change = notification.object as? CapabilityCatalogPersistenceChange else { return }
            self?.changes.append(change)
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

@Suite("Workspace Import Discovery")
struct WorkspaceImportDiscoveryTests {
    @Test("Workspaces parent expands to direct child directories")
    func workspacesParentExpandsToDirectChildren() throws {
        let root = try makeTemporaryDirectory(named: "Workspaces")
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = try makeDirectory("alpha-project", in: root)
        try Data("{}".utf8).write(to: alpha.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName))

        let beta = try makeDirectory("beta-project", in: root)
        try Data("{}".utf8).write(to: beta.appendingPathComponent(WorkspaceImportDiscovery.legacyAgentFlowConfigFileName))

        let gamma = try makeDirectory("gamma-project", in: root)
        try FileManager.default.createDirectory(at: gamma.appendingPathComponent(".claude"), withIntermediateDirectories: true)

        _ = try makeDirectory("plain-project", in: root)
        try Data("note".utf8).write(to: root.appendingPathComponent("notes.txt"))
        _ = try makeDirectory(".hidden-project", in: root)

        let candidates = WorkspaceImportDiscovery.candidates(for: [root])

        #expect(candidates.map { $0.folderURL.lastPathComponent } == [
            "alpha-project",
            "beta-project",
            "gamma-project",
            "plain-project"
        ])
        #expect(candidates[0].configURL?.lastPathComponent == WorkspaceFileLayout.workspaceConfigFileName)
        #expect(candidates[1].configURL?.lastPathComponent == WorkspaceImportDiscovery.legacyAgentFlowConfigFileName)
        #expect(candidates[2].configURL == nil)
        #expect(candidates[3].configURL == nil)
        #expect(candidates.contains(where: { $0.folderURL.lastPathComponent == ".hidden-project" }) == false)
    }

    @Test("Workspaces parent ignores symlinked child directories")
    func workspacesParentIgnoresSymlinkedChildren() throws {
        let root = try makeTemporaryDirectory(named: "Workspaces")
        let outside = try makeTemporaryDirectory(named: "outside-workspace")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("{}".utf8).write(to: outside.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-outside", isDirectory: true),
            withDestinationURL: outside
        )

        let candidates = WorkspaceImportDiscovery.candidates(for: [root])

        #expect(candidates.isEmpty)
    }

    @Test("generic parent expands only marked child workspace directories")
    func genericParentExpandsMarkedChildrenOnly() throws {
        let root = try makeTemporaryDirectory(named: "Projects")
        defer { try? FileManager.default.removeItem(at: root) }

        let marked = try makeDirectory("marked", in: root)
        try Data("# Memory".utf8).write(to: marked.appendingPathComponent("memory.md"))

        _ = try makeDirectory("unmarked", in: root)

        let candidates = WorkspaceImportDiscovery.candidates(for: [root])

        #expect(candidates.map { $0.folderURL.lastPathComponent } == ["marked"])
        #expect(candidates.first?.configURL == nil)
    }

    @Test("automatic parent expansion skips privacy-sensitive child folders")
    func automaticParentExpansionSkipsPrivacySensitiveChildFolders() throws {
        let home = try makeTemporaryDirectory(named: "Home")
        defer { try? FileManager.default.removeItem(at: home) }

        let pictures = try makeDirectory("Pictures", in: home)
        try Data("{}".utf8).write(to: pictures.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName))

        let project = try makeDirectory("Projects", in: home)
        try Data("{}".utf8).write(to: project.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName))

        let broker = HostFileAccessBroker(homeDirectory: home)
        let candidates = WorkspaceImportDiscovery.candidates(for: [home], hostFileAccess: broker)

        #expect(candidates.map { $0.folderURL.lastPathComponent } == ["Projects"])
    }

    @Test("folder with direct config imports as one configured workspace")
    func directConfigImportsAsSingleWorkspace() throws {
        let root = try makeTemporaryDirectory(named: "one-workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        try Data("{}".utf8).write(to: config)

        let candidates = WorkspaceImportDiscovery.candidates(for: [root])

        #expect(candidates.count == 1)
        #expect(candidates.first?.folderURL == root)
        #expect(candidates.first?.configURL == config)
    }

    @Test("duplicate selected child and parent are de-duplicated")
    func duplicateSelectionsAreDeduplicated() throws {
        let root = try makeTemporaryDirectory(named: "Workspaces")
        defer { try? FileManager.default.removeItem(at: root) }

        let child = try makeDirectory("alpha", in: root)
        try Data("{}".utf8).write(to: child.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName))

        let candidates = WorkspaceImportDiscovery.candidates(for: [root, child])

        #expect(candidates.count == 1)
        #expect(candidates.first?.folderURL.lastPathComponent == "alpha")
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-import-discovery-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDirectory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Workspace Import Orchestrator")
struct WorkspaceImportOrchestratorTests {
    @Test("import panel configuration accepts folders config files and multi-select")
    func importPanelConfigurationAcceptsSupportedSelections() {
        let configuration = WorkspaceImportPanelConfiguration.workspaceImport

        #expect(configuration.canChooseDirectories)
        #expect(configuration.canChooseFiles)
        #expect(configuration.allowsMultipleSelection)
        #expect(configuration.prompt == "Import")
        #expect(configuration.message.contains("workspace folders"))
        #expect(configuration.message.contains("config files"))
        #expect(configuration.message.contains("parent Workspaces folder"))
    }

    @Test("workspace action coordinator creates workspace from draft")
    @MainActor
    func workspaceActionCoordinatorCreatesWorkspaceFromDraft() throws {
        let root = try makeTemporaryDirectory(named: "ActionRoot")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let container = try makeWorkspaceImportContainer()
        let context = container.mainContext
        let coordinator = ContentWorkspaceActionCoordinator(
            modelContext: context,
            taskQueue: TaskQueue(),
            workspacesRoot: root.path
        )
        let draft = NewWorkspaceDraft(
            name: "  Research Hub  ",
            instructions: "  Keep current status concise.  "
        )

        let result = coordinator.createWorkspace(from: draft, source: "test")

        #expect(result?.workspace.name == "Research Hub")
        #expect(result?.workspace.instructions == "Keep current status concise.")
        #expect(result?.workspace.primaryPath == root.appendingPathComponent("research-hub").path)
        #expect(FileManager.default.fileExists(atPath: result?.workspace.primaryPath ?? ""))
        #expect(result?.hasCapabilityEnableFailures == false)
    }

    @Test("workspace creation capability batch emits one global mutation and one scoped reload")
    @MainActor
    func workspaceCreationCapabilityBatchEmitsExactlyOnceAndReloadsCatalogs() throws {
        let root = try makeTemporaryDirectory(named: "ActionRootCapabilityEvents")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let container = try makeWorkspaceImportContainer()
        let context = container.mainContext
        let coordinator = ContentWorkspaceActionCoordinator(
            modelContext: context,
            taskQueue: TaskQueue(),
            workspacesRoot: root.path
        )
        var draft = NewWorkspaceDraft(name: "Catalog Events")
        draft.selectedCapabilityIDs = [OnboardingCapabilitySetup.githubPackageID]
        let recorder = WorkspaceCapabilityEventRecorder()
        recorder.start()

        let result = coordinator.createWorkspace(from: draft, source: "test")

        let workspace = try #require(result?.workspace)
        #expect(result?.hasCapabilityEnableFailures == false)
        #expect(recorder.changes == [.global, .workspace(workspace.id)])
        let importingWindow = PluginCatalogPresentationSourceRevision()
        let otherWindow = PluginCatalogPresentationSourceRevision()
        var importingReloads = 0
        var otherReloads = 0
        for change in recorder.changes {
            _ = importingWindow.receive(change, workspaceID: workspace.id) { importingReloads += 1 }
            _ = otherWindow.receive(change, workspaceID: UUID()) { otherReloads += 1 }
        }
        #expect(importingReloads == 1)
        #expect(otherReloads == 1)
        #expect(importingWindow.persistenceRevision == 2)
        #expect(otherWindow.persistenceRevision == 1)
    }

    @Test("workspace action coordinator flags a failed quick-start capability credential save")
    @MainActor
    func workspaceActionCoordinatorFlagsFailedCapabilityCredential() throws {
        let root = try makeTemporaryDirectory(named: "ActionRootCredentialFail")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let container = try makeWorkspaceImportContainer()
        let context = container.mainContext
        let coordinator = ContentWorkspaceActionCoordinator(
            modelContext: context,
            taskQueue: TaskQueue(),
            workspacesRoot: root.path
        )
        var draft = NewWorkspaceDraft(name: "Research Hub")
        draft.selectedCapabilityIDs = [OnboardingCapabilitySetup.redcapPackageID]
        draft.capabilityConfiguration.redcapAPIToken = "secret-token"

        // No temp-keychain override is installed, so the real dedicated-keychain
        // path is blocked in this test process, deterministically simulating a
        // denied/failed Keychain write for the REDCap credential.
        let result = coordinator.createWorkspace(from: draft, source: "test")

        // The workspace itself is still created and usable — only the
        // credential save failed.
        #expect(result?.workspace.name == "Research Hub")
        #expect(result?.hasCapabilityEnableFailures == true)
    }

    @Test("importing discovered candidates saves them and selects the last import")
    @MainActor
    func importsDiscoveredCandidatesAndSelectsLast() throws {
        let root = try makeTemporaryDirectory(named: "Workspaces")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let configuredFolder = try makeDirectory("alpha-configured", in: root)
        try writeWorkspaceConfig(name: "Alpha Configured", primaryPath: configuredFolder.path, to: configuredFolder)

        let bareFolder = try makeDirectory("beta-bare", in: root)

        let container = try makeWorkspaceImportContainer()
        let context = container.mainContext
        let result = WorkspaceImportOrchestrator(modelContext: context, taskQueue: TaskQueue())
            .importWorkspaces(from: [root], existingWorkspaces: []) { _, _ in .skip }

        #expect(result.imported.map(\.name) == ["Alpha Configured", "Beta Bare"])
        #expect(result.imported.map { URL(fileURLWithPath: $0.primaryPath).standardizedFileURL.path } == [
            configuredFolder.standardizedFileURL.path,
            bareFolder.standardizedFileURL.path
        ])
        #expect(result.selectedWorkspace?.id == result.imported.last?.id)
        #expect(result.imported.last?.skills.count == 3)
    }

    @Test("duplicate imports use the supplied duplicate policy")
    @MainActor
    func duplicateImportsUseSuppliedPolicy() throws {
        let root = try makeTemporaryDirectory(named: "Duplicate")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try writeWorkspaceConfig(name: "Duplicate", primaryPath: root.path, to: root)

        let container = try makeWorkspaceImportContainer()
        let context = container.mainContext
        let existing = Workspace(name: "Duplicate", primaryPath: root.path)
        context.insert(existing)
        let existingTask = AgentTask(title: "Existing Task", goal: "Keep history", workspace: existing)
        context.insert(existingTask)
        try context.save()

        var promptedName: String?
        var promptedTaskCount: Int?
        let result = WorkspaceImportOrchestrator(modelContext: context, taskQueue: TaskQueue())
            .importWorkspaces(from: [root], existingWorkspaces: [existing]) { name, count in
                promptedName = name
                promptedTaskCount = count
                return .duplicate
            }

        #expect(promptedName == "Duplicate")
        #expect(promptedTaskCount == 1)
        #expect(result.imported.count == 1)
        #expect(result.imported.first?.name == "Duplicate (Imported)")
        #expect(result.imported.first?.tasks.first?.title == "Existing Task")
    }

    @Test("config import anchors primary path to selected folder")
    @MainActor
    func configImportAnchorsPrimaryPathToSelectedFolder() throws {
        let selected = try makeTemporaryDirectory(named: "Selected")
        let outside = try makeTemporaryDirectory(named: "Outside")
        defer {
            try? FileManager.default.removeItem(at: selected.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: outside.deletingLastPathComponent())
        }
        try writeWorkspaceConfig(name: "Path Mismatch", primaryPath: outside.path, to: selected)

        let container = try makeWorkspaceImportContainer()
        let context = container.mainContext
        let result = WorkspaceImportOrchestrator(modelContext: context, taskQueue: TaskQueue())
            .importWorkspaces(from: [selected], existingWorkspaces: []) { _, _ in .skip }

        #expect(result.imported.map(\.primaryPath) == [selected.standardizedFileURL.path])
    }

    @MainActor
    private func makeWorkspaceImportContainer() throws -> ModelContainer {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
    }

    @MainActor
    private func writeWorkspaceConfig(name: String, primaryPath: String, to folder: URL) throws {
        let sourceContainer = try makeWorkspaceImportContainer()
        let context = sourceContainer.mainContext
        let workspace = Workspace(name: name, primaryPath: primaryPath)
        context.insert(workspace)
        try context.save()
        try WorkspaceConfigManager.exportToFile(
            workspace: workspace,
            modelContext: context,
            url: folder.appendingPathComponent(WorkspaceFileLayout.workspaceConfigFileName)
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-import-orchestrator-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDirectory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
