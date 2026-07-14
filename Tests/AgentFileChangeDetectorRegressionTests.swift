import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Agent file change ownership regressions")
@MainActor
struct AgentFileChangeDetectorRegressionTests {
    @Test("Pre-run dirty paths become a durable publication exclusion baseline")
    func preRunDirtyPathsBecomePublicationBaseline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-file-baseline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init"], at: root)
        let file = root.appendingPathComponent("App.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let runID = UUID()
        let baseline = try #require(AgentFileChangeDetector.publicationWorkspaceBaseline(
            runID: runID,
            workspacePath: root.path,
            beforeGitStatus: AgentFileChangeDetector.gitStatusSnapshot(workspacePath: root.path)
        ))

        #expect(baseline.runID == runID)
        #expect(baseline.dirtyPaths == [file.standardizedFileURL.path])
    }

    @Test("Git-backed runs retain every changed path beyond the old summary cap")
    func gitChangeOwnershipIsNotCapped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-file-ownership-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init"], at: root)

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Ownership", primaryPath: root.path)
        let task = AgentTask(title: "Generate files", goal: "Create the requested files", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let expected = Set(try (0..<60).map { index -> String in
            let url = root.appendingPathComponent(String(format: "file-%02d.txt", index))
            try "value \(index)".write(to: url, atomically: true, encoding: .utf8)
            return url.path
        })

        AgentFileChangeDetector.appendInferredFileChanges(
            to: run,
            task: task,
            modelContext: context,
            workspacePath: root.path,
            beforeGitStatus: [],
            beforeDirtyFingerprints: [:],
            runStart: Date().addingTimeInterval(-1)
        )

        #expect(Set(run.fileChanges.map(\.path)) == expected)
        #expect(Set(task.artifacts.map(\.path)) == expected)
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
