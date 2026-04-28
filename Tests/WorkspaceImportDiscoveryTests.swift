import Foundation
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
