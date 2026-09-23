import Foundation
import Testing
@testable import ASTRA

/// What counts as a regenerable artifact, and how the inspector measures a
/// worktree without following symlinks or crossing into other checkouts.
@Suite("Worktree Artifact Rules and Inspector")
struct WorktreeStorageInspectorTests {
    private let inspector = WorktreeStorageInspector()

    @Test(".build next to Package.swift matches")
    func swiftPMMatches() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let build = try fixture.swiftPackage()
        #expect(WorktreeArtifactRule.swiftPM.matches(directoryAtPath: build))
        #expect(inspector.inspect(worktreePath: fixture.root.path).artifacts.map(\.relativePath) == [".build"])
    }

    @Test(".build without a manifest doesn't match")
    func buildWithoutManifest() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.file(".build/debug/App", bytes: 4096)
        #expect(!WorktreeArtifactRule.swiftPM.matches(directoryAtPath: fixture.path(".build")))
        let report = inspector.inspect(worktreePath: fixture.root.path)
        #expect(report.artifacts.isEmpty)
        #expect(report.artifactBytes == 0)
        #expect(report.totalBytes > 0)
    }

    @Test("A nested package's .build matches at depth")
    func nestedPackage() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.swiftPackage()
        try fixture.swiftPackage(at: "Tests/ArchitectureFitnessTests")
        let report = inspector.inspect(worktreePath: fixture.root.path)
        #expect(report.artifacts.map(\.relativePath) == [".build", "Tests/ArchitectureFitnessTests/.build"])
    }

    @Test("node_modules next to package.json and target next to Cargo.toml match")
    func otherEcosystems() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.file("web/package.json")
        try fixture.file("web/node_modules/left-pad/index.js", bytes: 512)
        try fixture.file("engine/Cargo.toml")
        try fixture.file("engine/target/debug/engine", bytes: 2048)
        let report = inspector.inspect(worktreePath: fixture.root.path)
        #expect(report.artifacts.map(\.relativePath) == ["engine/target", "web/node_modules"])
        #expect(report.artifacts.map(\.rule) == [.cargo, .node])
    }

    @Test("A symlinked .build is never a match and never traversed")
    func symlinkedBuild() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let outside = try WorktreeStorageFixture("outside")
        defer { outside.cleanUp() }
        try outside.file("big", bytes: 1_000_000)
        let worktree = try fixture.directory("wt")
        try fixture.file("wt/Package.swift")
        try fixture.symlink("wt/.build", to: outside.root.path)

        #expect(!WorktreeArtifactRule.swiftPM.matches(directoryAtPath: "\(worktree)/.build"))
        let report = inspector.inspect(worktreePath: worktree)
        #expect(report.artifacts.isEmpty)
        #expect(report.totalBytes < 100_000)
    }

    @Test("Sizes don't double-count through symlinks")
    func noDoubleCounting() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let outside = try WorktreeStorageFixture("outside")
        defer { outside.cleanUp() }
        try outside.file("big", bytes: 2_000_000)
        try fixture.file("Package.swift")
        try fixture.file(".build/real/payload", bytes: 200_000)
        try fixture.symlink(".build/alias", to: fixture.path(".build/real"))
        try fixture.symlink(".build/escape", to: outside.root.path)

        let report = inspector.inspect(worktreePath: fixture.root.path)
        let artifact = try #require(report.artifacts.first)
        #expect(artifact.bytes >= 200_000)
        #expect(artifact.bytes < 400_000)
        // Matches an independent `du`, which also counts each block once.
        #expect(abs(Int(artifact.bytes / 1024) - WorktreeStorageFixture.duKilobytes(artifact.path)) <= 8)
    }

    @Test("Nested checkouts and .git are skipped")
    func nestedCheckoutsSkipped() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.swiftPackage()
        // A linked worktree inside the primary, like `.claude/worktrees/*`.
        try fixture.file(".claude/worktrees/other/.git", bytes: 40)
        try fixture.swiftPackage(at: ".claude/worktrees/other", buildBytes: 500_000)
        try fixture.file(".git/objects/pack/big.pack", bytes: 500_000)

        let report = inspector.inspect(worktreePath: fixture.root.path)
        #expect(report.artifacts.map(\.relativePath) == [".build"])
        #expect(report.totalBytes < 300_000)
    }

    @Test("Interrupted reclaims are reported, not treated as artifacts")
    func interruptedReclaimsReported() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.file("Package.swift")
        let leftover = try fixture.file(".build\(WorktreeFileSystem.reclaimingMarker)\(UUID().uuidString)/debug/App", bytes: 4096)
        let report = inspector.inspect(worktreePath: fixture.root.path)
        #expect(report.artifacts.isEmpty)
        #expect(report.interruptedReclaims == [((leftover as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent])
    }

    @Test("A missing worktree reports as missing")
    func missingWorktree() {
        let report = inspector.inspect(worktreePath: "/nonexistent/\(UUID().uuidString)")
        #expect(!report.exists)
        #expect(report.totalBytes == 0)
    }

    @Test("Leftover names need a known base and a UUID suffix")
    func leftoverNames() {
        let uuid = UUID().uuidString
        #expect(WorktreeFileSystem.reclaimLeftoverBaseName(".build.astra-reclaiming-\(uuid)") == ".build")
        #expect(WorktreeFileSystem.reclaimLeftoverBaseName("node_modules.astra-reclaiming-\(uuid)") == "node_modules")
        #expect(WorktreeFileSystem.reclaimLeftoverBaseName(".build.astra-reclaiming-not-a-uuid") == nil)
        #expect(WorktreeFileSystem.reclaimLeftoverBaseName(".build") == nil)
    }
}
