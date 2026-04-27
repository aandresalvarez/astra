import Testing
import Foundation
@testable import ASTRA

@Suite("Artifact Versioning & Staleness")
struct ArtifactTests {

    @Test("Artifact default version is 1")
    func defaultVersion() {
        let task = AgentTask(title: "Test", goal: "test")
        let artifact = Artifact(task: task, type: "Write", path: "/tmp/test.swift")
        #expect(artifact.version == 1)
    }

    @Test("Artifact with explicit version")
    func explicitVersion() {
        let task = AgentTask(title: "Test", goal: "test")
        let artifact = Artifact(task: task, type: "Edit", path: "/tmp/test.swift", version: 3)
        #expect(artifact.version == 3)
    }

    @Test("isStale returns true for non-existent file")
    func staleForMissingFile() {
        let task = AgentTask(title: "Test", goal: "test")
        let artifact = Artifact(task: task, type: "Write", path: "/tmp/definitely-does-not-exist-\(UUID().uuidString).swift")
        #expect(artifact.isStale == true)
    }

    @Test("isStale returns false for existing file")
    func notStaleForExistingFile() {
        let tmpFile = "/tmp/artifact-test-\(UUID().uuidString.prefix(8)).txt"
        FileManager.default.createFile(atPath: tmpFile, contents: "test".data(using: .utf8))
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let task = AgentTask(title: "Test", goal: "test")
        let artifact = Artifact(task: task, type: "Write", path: tmpFile)
        #expect(artifact.isStale == false)
    }

    @Test("Version increment logic")
    func versionIncrement() {
        let task = AgentTask(title: "Test", goal: "test")
        let path = "/tmp/test.swift"

        // Simulate: first artifact for this path
        let a1 = Artifact(task: task, type: "Write", path: path, version: 1)
        task.artifacts.append(a1)

        // Second time same path: find max version + 1
        let existingMax = task.artifacts
            .filter { $0.path == path }
            .map(\.version)
            .max() ?? 0
        let a2 = Artifact(task: task, type: "Edit", path: path, version: existingMax + 1)
        task.artifacts.append(a2)
        #expect(a2.version == 2)

        // Third time
        let existingMax2 = task.artifacts
            .filter { $0.path == path }
            .map(\.version)
            .max() ?? 0
        let a3 = Artifact(task: task, type: "Edit", path: path, version: existingMax2 + 1)
        #expect(a3.version == 3)
    }

    @Test("Different paths get version 1")
    func differentPathsVersion1() {
        let task = AgentTask(title: "Test", goal: "test")
        let a1 = Artifact(task: task, type: "Write", path: "/tmp/a.swift", version: 1)
        task.artifacts.append(a1)

        let existingMax = task.artifacts
            .filter { $0.path == "/tmp/b.swift" }
            .map(\.version)
            .max() ?? 0
        let a2 = Artifact(task: task, type: "Write", path: "/tmp/b.swift", version: existingMax + 1)
        #expect(a2.version == 1)
    }
}

@Suite("Isolation Cleanup")
struct IsolationCleanupTests {

    @Test("listAstraBranches returns empty for non-git dir")
    func nonGitDir() {
        let tmpDir = "/tmp/iso-test-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let branches = IsolationService.listAstraBranches(workspacePath: tmpDir)
        #expect(branches.isEmpty)
    }

    @Test("deleteCopy removes directory")
    func deleteCopyWorks() {
        let tmpDir = "/tmp/iso-copy-test-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let result = IsolationService.deleteCopy(path: tmpDir)
        #expect(result == true)
        #expect(!FileManager.default.fileExists(atPath: tmpDir))
    }

    @Test("deleteCopy returns false for non-existent path")
    func deleteCopyFails() {
        let result = IsolationService.deleteCopy(path: "/tmp/definitely-does-not-exist-\(UUID().uuidString)")
        #expect(result == false)
    }
}
