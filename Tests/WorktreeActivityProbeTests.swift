import Foundation
import Testing
@testable import ASTRA

/// "Is something building here right now?" — SwiftPM's real lock, its PID
/// breadcrumb, and the recent-write fallback, as verified against Swift 6.4.
@Suite("Worktree Activity Probe")
struct WorktreeActivityProbeTests {
    private static let old: TimeInterval = 3 * 60 * 60

    private func probe(tmp: String, processName: @escaping @Sendable (Int32) -> String? = { _ in nil }) -> WorktreeActivityProbe {
        WorktreeActivityProbe(temporaryDirectory: URL(fileURLWithPath: tmp, isDirectory: true), processName: processName)
    }

    @Test("Lock file names follow SwiftPM: slashes become underscores")
    func lockFileName() {
        #expect(SwiftPMWorkspaceLock.lockFileName(forCanonicalScratchPath: "/Users/me/proj/.build") == "_Users_me_proj_.build.lock")
        #expect(SwiftPMWorkspaceLock.lockFileName(
            forCanonicalScratchPath: "/Users/me/proj/.build/index-build"
        ) == "_Users_me_proj_.build_index-build.lock")
    }

    @Test("Long lock file names keep their last 255 bytes")
    func longLockFileName() {
        let path = "/private/tmp/" + String(repeating: "a", count: 200) + "/" + String(repeating: "b", count: 200) + "/.build"
        let full = path.replacingOccurrences(of: "/", with: "_") + ".lock"
        let name = SwiftPMWorkspaceLock.lockFileName(forCanonicalScratchPath: path)
        #expect(name.utf8.count == 255)
        #expect(full.hasSuffix(name))
    }

    @Test("A symlinked parent resolves to the same lock file")
    func symlinkedParentLock() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.directory("real")
        try fixture.symlink("alias", to: fixture.path("real"))
        let tmp = URL(fileURLWithPath: "/tmp-root", isDirectory: true)
        #expect(
            SwiftPMWorkspaceLock.lockFileURL(forScratchPath: fixture.path("alias/.build"), temporaryDirectory: tmp)
                == SwiftPMWorkspaceLock.lockFileURL(forScratchPath: fixture.path("real/.build"), temporaryDirectory: tmp)
        )
    }

    @Test("A held SwiftPM lock means a build is in progress; releasing it clears the signal")
    func heldLock() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let tmp = try fixture.directory("tmp")
        let build = try fixture.swiftPackage(at: "wt")
        WorktreeStorageFixture.backdate(fixture.path("wt"), by: Self.old)
        let probe = probe(tmp: tmp)

        let lockFile = SwiftPMWorkspaceLock.lockFileURL(forScratchPath: build, temporaryDirectory: probe.temporaryDirectory)
        let lock = try #require(SwiftPMWorkspaceLock.tryAcquire(lockFile: lockFile))
        #expect(probe.buildSignal(forArtifactAt: build, rule: .swiftPM, now: Date()) == .swiftPMLockHeld(lockPath: lockFile.path))

        lock.release()
        #expect(probe.buildSignal(forArtifactAt: build, rule: .swiftPM, now: Date()) == nil)
        // The lock file itself stays behind, exactly like SwiftPM's.
        #expect(FileManager.default.fileExists(atPath: lockFile.path))
    }

    @Test("sourcekit-lsp's index-build lock also counts")
    func indexBuildLock() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let tmp = try fixture.directory("tmp")
        let build = try fixture.swiftPackage(at: "wt")
        let indexBuild = try fixture.directory("wt/.build/index-build")
        WorktreeStorageFixture.backdate(fixture.path("wt"), by: Self.old)
        let probe = probe(tmp: tmp)

        let lockFile = SwiftPMWorkspaceLock.lockFileURL(forScratchPath: indexBuild, temporaryDirectory: probe.temporaryDirectory)
        let lock = try #require(SwiftPMWorkspaceLock.tryAcquire(lockFile: lockFile))
        defer { lock.release() }
        #expect(probe.buildSignal(forArtifactAt: build, rule: .swiftPM, now: Date()) == .swiftPMLockHeld(lockPath: lockFile.path))
    }

    @Test("Probing never creates a lock file")
    func probingDoesNotCreateLockFile() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let tmp = try fixture.directory("tmp")
        let build = try fixture.swiftPackage(at: "wt")
        WorktreeStorageFixture.backdate(fixture.path("wt"), by: Self.old)
        #expect(probe(tmp: tmp).buildSignal(forArtifactAt: build, rule: .swiftPM, now: Date()) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp).isEmpty)
    }

    @Test(".build/.lock counts only when it names a live SwiftPM process")
    func pidBreadcrumb() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let tmp = try fixture.directory("tmp")
        let build = try fixture.swiftPackage(at: "wt")
        try "4242".write(toFile: "\(build)/.lock", atomically: true, encoding: .utf8)
        WorktreeStorageFixture.backdate(fixture.path("wt"), by: Self.old)

        let building = probe(tmp: tmp) { $0 == 4242 ? "swift-package" : nil }
        #expect(building.buildSignal(forArtifactAt: build, rule: .swiftPM, now: Date()) == .swiftPMProcessAlive(pid: 4242))

        let reused = probe(tmp: tmp) { $0 == 4242 ? "Safari" : nil }
        #expect(reused.buildSignal(forArtifactAt: build, rule: .swiftPM, now: Date()) == nil)

        let dead = probe(tmp: tmp)
        #expect(dead.buildSignal(forArtifactAt: build, rule: .swiftPM, now: Date()) == nil)
    }

    @Test("A write in the last 15 minutes counts for every ecosystem")
    func recentWrite() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let tmp = try fixture.directory("tmp")
        try fixture.file("web/package.json")
        let modules = fixture.path("web/node_modules")
        try fixture.file("web/node_modules/pkg/index.js")
        WorktreeStorageFixture.backdate(modules, by: Self.old)
        let probe = probe(tmp: tmp)
        #expect(probe.buildSignal(forArtifactAt: modules, rule: .node, now: Date()) == nil)

        try fixture.file("web/node_modules/pkg/fresh.js")
        guard case .recentlyModified = probe.buildSignal(forArtifactAt: modules, rule: .node, now: Date()) else {
            Issue.record("A fresh write must read as a build in progress")
            return
        }
    }

    @Test("Writes deeper than the shallow scan don't count")
    func deepWritesIgnored() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        let tmp = try fixture.directory("tmp")
        let build = try fixture.swiftPackage(at: "wt")
        WorktreeStorageFixture.backdate(fixture.path("wt"), by: Self.old)
        // Depth 5 from `.build`; creating it bumps only its parent (depth 4).
        try fixture.file("wt/.build/a/b/c/d/deep.o")
        WorktreeStorageFixture.backdate(fixture.path("wt/.build/a/b/c"), by: Self.old)
        WorktreeStorageFixture.backdate(fixture.path("wt/.build/a/b"), by: Self.old)
        WorktreeStorageFixture.backdate(fixture.path("wt/.build/a"), by: Self.old)
        WorktreeStorageFixture.backdate(build, by: Self.old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fixture.path("wt/.build/a/b/c/d")
        )
        #expect(probe(tmp: tmp).buildSignal(forArtifactAt: build, rule: .swiftPM, now: Date()) == nil)
    }

    @Test("The git directory comes from .git itself or a linked worktree's gitdir line")
    func gitDirectory() throws {
        let fixture = try WorktreeStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.directory("primary/.git")
        #expect(WorktreeActivityProbe.gitDirectory(forWorktree: fixture.path("primary")) == fixture.path("primary/.git"))

        try fixture.directory("linked")
        try "gitdir: /repos/app/.git/worktrees/linked\n".write(toFile: fixture.path("linked/.git"), atomically: true, encoding: .utf8)
        #expect(WorktreeActivityProbe.gitDirectory(forWorktree: fixture.path("linked")) == "/repos/app/.git/worktrees/linked")

        try fixture.directory("relative")
        try "gitdir: ../primary/.git/worktrees/relative\n".write(toFile: fixture.path("relative/.git"), atomically: true, encoding: .utf8)
        #expect(WorktreeActivityProbe.gitDirectory(forWorktree: fixture.path("relative")) == fixture.path("primary/.git/worktrees/relative"))
    }

    @Test("The live process name comes from the kernel")
    func liveProcessName() {
        #expect(WorktreeActivityProbe.liveProcessName(ProcessInfo.processInfo.processIdentifier) != nil)
        #expect(WorktreeActivityProbe.liveProcessName(Int32.max) == nil)
    }
}
