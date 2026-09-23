import Foundation
import Testing
@testable import ASTRA

/// The only deleter, against a real temp repository with a linked worktree.
/// Proves the spec's safety invariants: nothing outside a matched artifact is
/// touched, symlinks are never followed, busy artifacts are skipped, and a
/// reclaim is idempotent and resumable.
@Suite("Worktree Reclaimer")
struct WorktreeReclaimerTests {
    private static let old: TimeInterval = 3 * 60 * 60

    /// A repository plus a linked worktree on `feature`, whose `.build` holds
    /// artifacts and is backdated past the recent-write window.
    private struct Setup {
        let fixture: WorktreeStorageFixture
        let tmp: String
        let worktree: String
        let build: String
        var reclaimer: WorktreeReclaimer {
            WorktreeReclaimer(probe: WorktreeActivityProbe(
                temporaryDirectory: URL(fileURLWithPath: tmp, isDirectory: true),
                processName: { _ in nil }
            ))
        }
    }

    private func makeSetup() throws -> Setup {
        let fixture = try WorktreeStorageFixture("reclaimer")
        let repo = try WorktreeStorageGit.makeRepository(in: fixture)
        let worktree = fixture.path("wt-feature")
        let added = WorktreeStorageGit.run(["worktree", "add", "-q", "-b", "feature", worktree], in: repo)
        try #require(added.status == 0, "git worktree add failed: \(added.output)")
        try fixture.file("wt-feature/.build/out/Products/Debug/App", bytes: 300_000)
        try fixture.file("wt-feature/.build/workspace-state.json", bytes: 200)
        WorktreeStorageFixture.backdate("\(worktree)/.build", by: Self.old)
        return Setup(fixture: fixture, tmp: try fixture.directory("tmp"), worktree: worktree, build: "\(worktree)/.build")
    }

    private func snapshot(of worktree: String) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for relative in ["Package.swift", "Sources/App/main.swift", ".gitignore"] {
            files[relative] = try Data(contentsOf: URL(fileURLWithPath: "\(worktree)/\(relative)"))
        }
        return files
    }

    @Test("Reclaim deletes the artifact and leaves source and git status unchanged")
    func reclaimLeavesSourceAlone() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        let sourceBefore = try snapshot(of: setup.worktree)
        let statusBefore = WorktreeStorageGit.run(["status", "--porcelain", "--untracked-files=all"], in: setup.worktree).output

        let outcome = setup.reclaimer.reclaim(artifactPaths: [setup.build], inWorktree: setup.worktree)

        #expect(outcome.reclaimed.map(\.path) == [setup.build])
        #expect(outcome.freedBytes >= 300_000)
        #expect(!FileManager.default.fileExists(atPath: setup.build))
        #expect(try snapshot(of: setup.worktree) == sourceBefore)
        #expect(WorktreeStorageGit.run(["status", "--porcelain", "--untracked-files=all"], in: setup.worktree).output == statusBefore)
        // Nothing renamed aside is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.worktree)
            .allSatisfy { !$0.contains(WorktreeFileSystem.reclaimingMarker) })
    }

    @Test("A second reclaim is a no-op that frees nothing")
    func reclaimIsIdempotent() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        _ = setup.reclaimer.reclaim(artifactPaths: [setup.build], inWorktree: setup.worktree)
        let second = setup.reclaimer.reclaim(artifactPaths: [setup.build], inWorktree: setup.worktree)
        #expect(second.freedBytes == 0)
        #expect(second.reclaimed.isEmpty)
        #expect(second.failures.isEmpty)
    }

    @Test("An artifact symlinked out of the worktree is refused")
    func symlinkEscapeRefused() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        let outside = try WorktreeStorageFixture("outside")
        defer { outside.cleanUp() }
        let payload = try outside.file("keep/me.txt", bytes: 1024)
        try FileManager.default.removeItem(atPath: setup.build)
        try setup.fixture.symlink("wt-feature/.build", to: outside.path("keep"))

        let outcome = setup.reclaimer.reclaim(artifactPaths: [setup.build], inWorktree: setup.worktree)

        #expect(outcome.reclaimed.isEmpty)
        #expect(outcome.skipped.map(\.reason) == ["not a real directory"])
        #expect(FileManager.default.fileExists(atPath: payload))
    }

    @Test("An artifact reached through a symlinked parent outside the worktree is refused")
    func symlinkedParentRefused() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        let outside = try WorktreeStorageFixture("outside")
        defer { outside.cleanUp() }
        let outsideBuild = try outside.swiftPackage(at: "pkg")
        WorktreeStorageFixture.backdate(outside.path("pkg"), by: Self.old)
        try setup.fixture.symlink("wt-feature/vendor", to: outside.path("pkg"))

        let outcome = setup.reclaimer.reclaim(artifactPaths: ["\(setup.worktree)/vendor/.build"], inWorktree: setup.worktree)

        #expect(outcome.reclaimed.isEmpty)
        #expect(outcome.skipped.map(\.reason) == ["outside the worktree"])
        #expect(FileManager.default.fileExists(atPath: outsideBuild))
    }

    @Test("A leftover from an interrupted reclaim is swept on the next pass")
    func leftoverSwept() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        let leftover = "\(setup.worktree)/.build\(WorktreeFileSystem.reclaimingMarker)\(UUID().uuidString)"
        try FileManager.default.moveItem(atPath: setup.build, toPath: leftover)

        let report = WorktreeStorageInspector().inspect(worktreePath: setup.worktree)
        #expect(report.interruptedReclaims == [leftover])
        let outcome = setup.reclaimer.sweepLeftovers(report.interruptedReclaims, inWorktree: setup.worktree)

        #expect(outcome.reclaimed.count == 1)
        #expect(outcome.freedBytes >= 300_000)
        #expect(!FileManager.default.fileExists(atPath: leftover))
    }

    @Test("Sweeping ignores names that only look like leftovers")
    func sweepIgnoresLookalikes() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        let lookalike = try setup.fixture.directory("wt-feature/data.astra-reclaiming-\(UUID().uuidString)")
        let outcome = setup.reclaimer.sweepLeftovers([lookalike], inWorktree: setup.worktree)
        #expect(outcome.reclaimed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: lookalike))
    }

    @Test("Sweeping refuses a leftover name that isn't next to its manifest")
    func sweepRequiresManifest() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        // No Cargo.toml next to it: this is somebody's data, not a leftover.
        let userData = try setup.fixture.directory("wt-feature/data/target\(WorktreeFileSystem.reclaimingMarker)\(UUID().uuidString)")
        try "keep".write(toFile: "\(userData)/notes.txt", atomically: true, encoding: .utf8)

        let outcome = setup.reclaimer.sweepLeftovers([userData], inWorktree: setup.worktree)

        #expect(outcome.reclaimed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: "\(userData)/notes.txt"))
    }

    @Test("An artifact written in the last 15 minutes is skipped as a build in progress")
    func recentArtifactSkipped() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        try setup.fixture.file("wt-feature/.build/out/fresh.o", bytes: 100)

        let outcome = setup.reclaimer.reclaim(artifactPaths: [setup.build], inWorktree: setup.worktree)

        #expect(outcome.reclaimed.isEmpty)
        #expect(outcome.skipped.first?.reason.hasPrefix("build in progress") == true)
        #expect(FileManager.default.fileExists(atPath: setup.build))
    }

    @Test("Prepare can skip its own activity scan when the caller already ran it")
    func prepareWithoutScan() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        try setup.fixture.file("wt-feature/.build/out/fresh.o", bytes: 100)

        #expect(setup.reclaimer.prepare(artifactPaths: [setup.build], inWorktree: setup.worktree).prepared.isEmpty)
        let step = setup.reclaimer.prepare(artifactPaths: [setup.build], inWorktree: setup.worktree, probeBuildActivity: false)
        #expect(step.prepared.count == 1)
        _ = setup.reclaimer.finish(step.prepared)
        #expect(!FileManager.default.fileExists(atPath: setup.build))
    }

    @Test("A held SwiftPM lock skips the artifact and leaves it intact")
    func heldLockSkipped() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        let lockFile = SwiftPMWorkspaceLock.lockFileURL(
            forScratchPath: setup.build,
            temporaryDirectory: URL(fileURLWithPath: setup.tmp, isDirectory: true)
        )
        let lock = try #require(SwiftPMWorkspaceLock.tryAcquire(lockFile: lockFile))
        defer { lock.release() }

        let outcome = setup.reclaimer.reclaim(artifactPaths: [setup.build], inWorktree: setup.worktree)

        #expect(outcome.reclaimed.isEmpty)
        #expect(outcome.skipped.first?.reason == "build in progress (SwiftPM holds its lock)")
        #expect(FileManager.default.fileExists(atPath: setup.build))
    }

    @Test("sourcekit-lsp's index-build lock is honored even before its folder exists")
    func indexBuildLockWithoutDirectory() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        #expect(!FileManager.default.fileExists(atPath: "\(setup.build)/index-build"))
        let lockFile = SwiftPMWorkspaceLock.lockFileURL(
            forScratchPath: "\(setup.build)/index-build",
            temporaryDirectory: URL(fileURLWithPath: setup.tmp, isDirectory: true)
        )
        let lock = try #require(SwiftPMWorkspaceLock.tryAcquire(lockFile: lockFile))
        defer { lock.release() }

        let outcome = setup.reclaimer.reclaim(artifactPaths: [setup.build], inWorktree: setup.worktree)

        #expect(outcome.reclaimed.isEmpty)
        #expect(outcome.skipped.first?.reason == "build in progress (SwiftPM holds its lock)")
        #expect(FileManager.default.fileExists(atPath: setup.build))
    }

    @Test("Prepare renames aside without deleting; finish deletes")
    func prepareThenFinish() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }

        let step = setup.reclaimer.prepare(artifactPaths: [setup.build], inWorktree: setup.worktree)
        let prepared = try #require(step.prepared.first)
        #expect(!FileManager.default.fileExists(atPath: setup.build))
        #expect(FileManager.default.fileExists(atPath: prepared.asidePath))
        #expect(WorktreeFileSystem.reclaimLeftoverBaseName((prepared.asidePath as NSString).lastPathComponent) == ".build")

        let outcome = setup.reclaimer.finish(step.prepared)
        #expect(outcome.freedBytes >= 300_000)
        #expect(outcome.reclaimed.map(\.path) == [setup.build])
        #expect(!FileManager.default.fileExists(atPath: prepared.asidePath))
    }

    @Test("An artifact whose manifest disappeared is refused")
    func manifestGoneRefused() throws {
        let setup = try makeSetup()
        defer { setup.fixture.cleanUp() }
        try FileManager.default.removeItem(atPath: "\(setup.worktree)/Package.swift")
        let outcome = setup.reclaimer.reclaim(artifactPaths: [setup.build], inWorktree: setup.worktree)
        #expect(outcome.skipped.map(\.reason) == ["no longer next to its manifest"])
        #expect(FileManager.default.fileExists(atPath: setup.build))
    }
}
