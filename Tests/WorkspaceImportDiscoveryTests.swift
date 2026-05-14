import Foundation
import SwiftData
import Testing
@testable import ASTRA

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
