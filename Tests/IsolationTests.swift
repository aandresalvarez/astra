import Testing
import Foundation
import ASTRAModels
@testable import ASTRA

@Suite("Workspace Isolation")
struct IsolationTests {

    private func runShell(_ cmd: String, in dir: String) -> (exitCode: Int, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try! p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (Int(p.terminationStatus), out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Git branch creation and checkout")
    func gitBranchIsolation() throws {
        let dir = "/tmp/astra-git-test-\(UUID().uuidString.prefix(8))"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        let (initCode, _) = runShell("git init && git -c commit.gpgsign=false -c user.name='ASTRA Tests' -c user.email='astra-tests@example.invalid' commit --allow-empty -m 'init'", in: dir)
        #expect(initCode == 0)

        let branch = "astra/test-branch"
        let (branchCode, _) = runShell("git checkout -b '\(branch)'", in: dir)
        #expect(branchCode == 0)

        let (_, current) = runShell("git branch --show-current", in: dir)
        #expect(current == branch)
    }

    @Test("Copy isolation creates independent copy")
    func copyIsolation() throws {
        let fm = FileManager.default
        let src = "/tmp/astra-copy-test-\(UUID().uuidString.prefix(8))"
        let dst = "\(src)-copy"
        try fm.createDirectory(atPath: src, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: src); try? fm.removeItem(atPath: dst) }

        fm.createFile(atPath: "\(src)/test.txt", contents: "hello".data(using: .utf8))
        try fm.copyItem(atPath: src, toPath: dst)

        #expect(fm.fileExists(atPath: "\(dst)/test.txt"))
        let content = try String(contentsOfFile: "\(dst)/test.txt", encoding: .utf8)
        #expect(content == "hello")

        // Modifying copy doesn't affect original
        try "modified".write(toFile: "\(dst)/test.txt", atomically: true, encoding: .utf8)
        let original = try String(contentsOfFile: "\(src)/test.txt", encoding: .utf8)
        #expect(original == "hello")
    }

    @Test("Copy isolation uses restricted app scratch and cleanup deletes it")
    func copyIsolationUsesRestrictedScratchAndDeletesOnCleanup() async throws {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copy-source-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("test.txt"))
        defer { try? fm.removeItem(at: src) }

        let workspace = Workspace(name: "Copy Isolation", primaryPath: src.path)
        let task = AgentTask(
            title: "Copy Isolation",
            goal: "Use a workspace copy",
            workspace: workspace,
            isolationStrategy: .copy
        )

        let copyPath = try await IsolationService.prepare(task: task)
        let copyURL = URL(fileURLWithPath: copyPath, isDirectory: true)
        let scratchRoot = IsolationService.copyScratchRoot(fileManager: fm)
        defer { try? fm.removeItem(at: copyURL) }

        #expect(copyURL.path.hasPrefix(scratchRoot.path + "/"))
        #expect(copyURL.deletingLastPathComponent().path != src.deletingLastPathComponent().path)
        #expect(fm.fileExists(atPath: copyURL.appendingPathComponent("test.txt").path))

        let attributes = try fm.attributesOfItem(atPath: scratchRoot.path)
        let permissions = try #require(attributes[FileAttributeKey.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o700)

        IsolationService.cleanup(task: task, executionPath: copyPath)
        #expect(!fm.fileExists(atPath: copyPath))
    }

    @Test("Non-git directory detected")
    func notAGitRepo() {
        let dir = "/tmp/astra-nogit-\(UUID().uuidString.prefix(8))"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let (code, _) = runShell("git rev-parse --is-inside-work-tree", in: dir)
        #expect(code != 0)
    }
}

// MARK: - Phase 3B: WorkspaceLockManager

@Suite("WorkspaceLockManager")
struct WorkspaceLockManagerTests {
    @Test("Lock keys normalize symlinked workspace paths")
    func lockKeysNormalizeSymlinkedWorkspacePaths() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-lock-root-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let link = root.appendingPathComponent("workspace-link", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: workspace)

        #expect(
            IsolationService.WorkspaceLockManager.lockKey(for: link.path)
                == IsolationService.WorkspaceLockManager.lockKey(for: workspace.path)
        )
    }

    @Test("Concurrent operations on same path are serialized")
    func concurrentSamePath() async {
        let manager = IsolationService.WorkspaceLockManager()
        var order: [Int] = []
        let orderLock = NSLock()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    manager.withLock(for: "/same/path") {
                        orderLock.lock()
                        order.append(i)
                        orderLock.unlock()
                        // Small delay to make interleaving detectable
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
        }

        // All 5 should have completed (lock didn't deadlock)
        #expect(order.count == 5)
    }

    @Test("Different paths do not block each other")
    func differentPathsParallel() async {
        let manager = IsolationService.WorkspaceLockManager()
        var path1Done = false
        var path2Done = false

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                manager.withLock(for: "/path/one") {
                    path1Done = true
                }
            }
            group.addTask {
                manager.withLock(for: "/path/two") {
                    path2Done = true
                }
            }
        }

        #expect(path1Done)
        #expect(path2Done)
    }
}
