import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// With sandboxing Off a worktree task is not kept out of the checkout its
/// worktree replaced. ASTRA looks at that checkout before and after the run
/// and records what changed; it reverts nothing.
@Suite("A worktree's source checkout is watched when nothing fences it", .serialized)
@MainActor
struct TaskWorktreeSourceCheckoutWatchTests {
    /// A real repository with one commit, so `git status` and `HEAD` answer.
    private func repository() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-source-watch-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: url)
        try "one\n".write(to: url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try commit("init", in: url)
        return url
    }

    private func commit(_ message: String, in url: URL) throws {
        try git(["add", "-A"], in: url)
        try git(["-c", "commit.gpgsign=false", "-c", "user.name=ASTRA Tests", "-c", "user.email=astra-tests@example.invalid",
                 "commit", "-q", "-m", message], in: url)
    }

    private func git(_ arguments: [String], in url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", url.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    @Test("A run that leaves the source checkout alone records nothing; a new file, an edit and a moved commit are named")
    func namesWhatChanged() async throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo) }
        let before = try #require(await TaskWorktreeSourceCheckoutWatch.snapshot(of: repo.path))
        #expect(!before.head.isEmpty && before.status.isEmpty)
        #expect(await TaskWorktreeSourceCheckoutWatch.changes(since: [before]).isEmpty)

        try "stray\n".write(to: repo.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let dirty = try #require(await TaskWorktreeSourceCheckoutWatch.changes(since: [before]).first)
        #expect(dirty.appeared == [" M tracked.txt", "?? stray.txt"] && dirty.appearedCount == 2)
        #expect(dirty.headBefore == dirty.headAfter)
        let line = TaskWorktreeSourceCheckoutWatch.message(dirty)
        #expect(line.contains("tracked.txt") && line.contains("stray.txt") && line.contains("reverted nothing"))

        try commit("more", in: repo)
        let moved = try #require(await TaskWorktreeSourceCheckoutWatch.changes(since: [before]).first)
        #expect(moved.appeared.isEmpty && moved.headBefore != moved.headAfter)
        #expect(TaskWorktreeSourceCheckoutWatch.message(moved).contains("its commit moved"))
    }

    @Test("What was already dirty before the run is not attributed to it")
    func earlierDirtStaysOut() async throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo) }
        try "mine\n".write(to: repo.appendingPathComponent("already.txt"), atomically: true, encoding: .utf8)
        let before = try #require(await TaskWorktreeSourceCheckoutWatch.snapshot(of: repo.path))
        #expect(before.status == ["?? already.txt"])
        #expect(await TaskWorktreeSourceCheckoutWatch.changes(since: [before]).isEmpty)
        try "new\n".write(to: repo.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        #expect(await TaskWorktreeSourceCheckoutWatch.changes(since: [before]).first?.appeared == ["?? later.txt"])
    }

    @Test("A folder that is not a checkout, or one that is gone afterwards, reports nothing")
    func unreadableIsNotAChange() async throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("astra-source-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(await TaskWorktreeSourceCheckoutWatch.snapshot(of: plain.path) == nil)

        let repo = try repository()
        let before = try #require(await TaskWorktreeSourceCheckoutWatch.snapshot(of: repo.path))
        try FileManager.default.removeItem(at: repo)
        #expect(await TaskWorktreeSourceCheckoutWatch.changes(since: [before]).isEmpty)
    }

    @Test("Only a run with sandboxing Off is watched, and what it finds is recorded on the task")
    func capturesAndRecords() async throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo) }
        let linked = repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + "-side", isDirectory: true)
        try git(["worktree", "add", "--quiet", "-b", "side", linked.path], in: repo)
        defer { try? FileManager.default.removeItem(at: linked) }
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let workspace = Workspace(name: "App", primaryPath: repo.path)
        h.context.insert(workspace)
        let task = AgentTask(title: "Edit side", goal: "Edit", workspace: workspace)
        task.executionRootPath = linked.path
        h.context.insert(task)
        let run = TaskRun(task: task)
        h.context.insert(run)
        let changed = TaskEventTypes.Task.worktreeSourceChanged.rawValue

        #expect(await TaskWorktreeSourceCheckoutWatch.capture(for: task, sandboxEnforcement: .bestEffort).isEmpty)
        let before = await TaskWorktreeSourceCheckoutWatch.capture(for: task, sandboxEnforcement: .off)
        #expect(before.map(\.checkout) == [repo.path])

        // The run's own work, inside its worktree, is not the source checkout changing.
        try "own\n".write(to: linked.appendingPathComponent("own.txt"), atomically: true, encoding: .utf8)
        await TaskWorktreeSourceCheckoutWatch.record(since: before, task: task, run: run, modelContext: h.context)
        #expect(!task.events.contains { $0.type == changed })

        try "stray\n".write(to: repo.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        await TaskWorktreeSourceCheckoutWatch.record(since: before, task: task, run: run, modelContext: h.context)
        let event = try #require(task.events.first { $0.type == changed })
        let changes = try JSONDecoder().decode([TaskWorktreeSourceCheckoutWatch.Change].self, from: Data(event.payload.utf8))
        #expect(changes.map(\.appeared) == [["?? stray.txt"]] && event.run?.id == run.id)
        #expect(task.events.contains { $0.type == TaskEventTypes.System.info.rawValue && $0.payload.contains("stray.txt") })
    }

    @Test("Many changes are counted in full and listed up to the limit")
    func cappedList() async throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at: repo) }
        let before = try #require(await TaskWorktreeSourceCheckoutWatch.snapshot(of: repo.path))
        let count = TaskWorktreeSourceCheckoutWatch.Change.reportLimit + 7
        for index in 0..<count {
            try "x".write(to: repo.appendingPathComponent(String(format: "file-%03d.txt", index)), atomically: true, encoding: .utf8)
        }
        let change = try #require(await TaskWorktreeSourceCheckoutWatch.changes(since: [before]).first)
        #expect(change.appearedCount == count && change.appeared.count == TaskWorktreeSourceCheckoutWatch.Change.reportLimit)
        #expect(TaskWorktreeSourceCheckoutWatch.message(change).contains("and \(count - 5) more"))
    }
}
