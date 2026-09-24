import Darwin
import Foundation
@testable import ASTRA

/// A throwaway directory tree for the worktree storage suites. Each fixture
/// lives under its own UUID folder; call `cleanUp()` in a `defer`.
struct WorktreeStorageFixture {
    let root: URL

    init(_ label: String = "worktree-storage") throws {
        // Resolve `/var` → `/private/var` up front so paths compare the way git
        // and `realpath` report them.
        let base = WorktreePath.realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
        root = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("astra-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ relative: String) -> String {
        relative.isEmpty ? root.path : root.appendingPathComponent(relative).path
    }

    @discardableResult
    func directory(_ relative: String) throws -> String {
        let path = path(relative)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 16, byte: UInt8 = 0x61) throws -> String {
        let path = path(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(repeating: byte, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }

    /// `Package.swift` plus a `.build` holding a little content, under
    /// `relative`. Returns the `.build` path.
    @discardableResult
    func swiftPackage(at relative: String = "", buildBytes: Int = 64 * 1024) throws -> String {
        let prefix = relative.isEmpty ? "" : relative + "/"
        try file(prefix + "Package.swift", bytes: 40)
        try file(prefix + ".build/out/Products/Debug/App", bytes: buildBytes)
        try file(prefix + ".build/workspace-state.json", bytes: 120)
        return path(prefix + ".build")
    }

    /// Moves the modification time of `path` and everything under it into the
    /// past, without following symlinks, so the recent-write heuristic stays
    /// quiet.
    static func backdate(_ path: String, by seconds: TimeInterval) {
        let when = Date().addingTimeInterval(-seconds).timeIntervalSince1970
        let stamp = timeval(tv_sec: Int(when), tv_usec: 0)
        var times = [stamp, stamp]
        var entries = [path]
        if WorktreeFileSystem.isRealDirectory(path),
           let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in enumerator {
                entries.append((path as NSString).appendingPathComponent(relative))
            }
        }
        // Children before parents: touching a child doesn't bump its parent,
        // but keep the parent last anyway.
        for entry in entries.reversed() {
            lutimes(entry, &times)
        }
    }

    /// Bytes currently allocated under `path`, measured independently of the
    /// code under test.
    static func duKilobytes(_ path: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Int(output.split(separator: "\t").first ?? "") ?? -1
    }
}

/// Git helpers for suites that need a real repository.
enum WorktreeStorageGit {
    @discardableResult
    static func run(_ arguments: [String], in directory: String, environment extra: [String: String] = [:]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "commit.gpgsign=false", "-c", "user.name=ASTRA Tests",
                             "-c", "user.email=astra-tests@example.invalid"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A repository on branch `main` with a committed SwiftPM package whose
    /// `.build` is ignored, like a real checkout. Returns the repository path.
    static func makeRepository(in fixture: WorktreeStorageFixture, name: String = "repo") throws -> String {
        let repo = try fixture.directory(name)
        try fixture.file("\(name)/Package.swift", bytes: 40)
        try fixture.file("\(name)/Sources/App/main.swift", bytes: 200)
        try ".build/\n".write(toFile: "\(repo)/.gitignore", atomically: true, encoding: .utf8)
        for step in [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "init"]] {
            let result = run(step, in: repo)
            guard result.status == 0 else {
                throw NSError(domain: "WorktreeStorageGit", code: Int(result.status), userInfo: [
                    NSLocalizedDescriptionKey: "git \(step.joined(separator: " ")) failed: \(result.output)"
                ])
            }
        }
        return repo
    }

    static func head(of repo: String) -> String {
        run(["rev-parse", "HEAD"], in: repo).output
    }
}

/// Scripted answers for the storage services' git reads. Records calls so
/// tests can prove what was — and wasn't — asked.
@MainActor
final class StubWorktreeGit: WorktreeStorageGitReading {
    var repositories: [GitRepositoryInfo] = []
    var worktrees: [GitWorktreeInfo] = []
    var defaultBranch = "origin/main"
    /// Keyed "ancestor>descendant"; missing pairs answer `.notAncestor`.
    var ancestry: [String: GitAncestry] = [:]
    var commitDates: [String: Date] = [:]
    var dirtyPaths: Set<String> = []
    /// Worktree-relative files in the index, keyed by worktree path.
    var trackedFiles: [String: [String]] = [:]
    /// Worktrees whose `ls-files` fails.
    var trackingFailures: Set<String> = []
    /// Overrides `trackedFiles`: gets the worktree and which query this is
    /// for it (1, 2, …), so a test can change the answer mid-pass.
    var trackedFilesProvider: ((String, Int) -> [String])?
    private var trackedQueries: [String: Int] = [:]
    /// Keyed by branch; missing branches answer `.none`.
    var mergedPullRequests: [String: GitMergedPullRequestLookupResult] = [:]
    private(set) var ancestryCalls: [String] = []
    private(set) var lookupCalls: [String] = []

    /// Discovery calls answer empty, as a failing `rev-parse` does, while
    /// this is above zero; each call uses one.
    var failingScans = 0

    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo] {
        guard failingScans == 0 else {
            failingScans -= 1
            return []
        }
        return repositories
    }

    func listWorktrees(at repoPath: String) async -> [GitWorktreeInfo] { worktrees }

    func getDefaultBaseBranch(at repoPath: String, remote: String?) async -> String { defaultBranch }

    func isAncestor(_ ancestor: String, of descendant: String, at repoPath: String) async -> GitAncestry {
        let key = "\(ancestor)>\(descendant)"
        ancestryCalls.append(key)
        return ancestry[key] ?? .notAncestor
    }

    func commitDate(of commit: String, at repoPath: String) async -> Date? { commitDates[commit] }

    func hasUncommittedChanges(at worktreePath: String) async -> Bool? { dirtyPaths.contains(worktreePath) }

    func trackedDirectories(among relativePaths: [String], at worktreePath: String) async -> Set<String>? {
        guard !trackingFailures.contains(worktreePath) else { return nil }
        let query = (trackedQueries[worktreePath] ?? 0) + 1
        trackedQueries[worktreePath] = query
        let files = trackedFilesProvider?(worktreePath, query) ?? trackedFiles[worktreePath] ?? []
        return Set(relativePaths.filter { directory in
            files.contains { $0 == directory || $0.hasPrefix(directory + "/") }
        })
    }

    func lookupMergedPullRequest(repoPath: String, head: String, ghPathOverride: String?) async -> GitMergedPullRequestLookupResult {
        lookupCalls.append(head)
        return mergedPullRequests[head] ?? .none
    }
}
