import Foundation

// #region agent log
private func _gitDebugLog(_ location: String, _ message: String, _ data: [String: Any], _ hypothesis: String) {
    let payload: [String: Any] = [
        "sessionId": "57c8bc", "runId": "claude-hang", "hypothesisId": hypothesis,
        "location": location, "message": message, "data": data,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000)
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: payload),
          let line = (String(data: d, encoding: .utf8).map { $0 + "\n" })?.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/Users/alvaro1/Documents/Coral/Code/Astra/.cursor/debug-57c8bc.log")
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        try? h.write(contentsOf: line)
    } else {
        try? line.write(to: url)
    }
}
// #endregion

struct GitRepositoryInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
}

struct GitStatusFile: Identifiable, Hashable {
    let id = UUID()
    let relativePath: String
    let status: String // "M", "A", "D", "?", "R"
    let isStaged: Bool
}

class GitService {
    static let shared = GitService()

    private init() {}

    private let indexLock = NSLock()
    private var _indexBusy = false

    /// Acquires a logical lock so only one index-writing batch runs at a time.
    /// Returns false if another batch is already running.
    func acquireIndexGuard() -> Bool {
        indexLock.lock()
        defer { indexLock.unlock() }
        if _indexBusy { return false }
        _indexBusy = true
        return true
    }

    func releaseIndexGuard() {
        indexLock.lock()
        defer { indexLock.unlock() }
        _indexBusy = false
    }

    /// Scans a workspace's primary path and additional paths for folders containing a `.git` subdirectory.
    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo] {
        var repos: [GitRepositoryInfo] = []
        let allPaths = [primaryPath] + additionalPaths
        
        for path in allPaths where !path.isEmpty {
            let expandedPath = NSString(string: path).expandingTildeInPath
            var isDir: ObjCBool = false
            let fm = FileManager.default
            
            if fm.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue {
                let gitPath = URL(fileURLWithPath: expandedPath).appendingPathComponent(".git")
                if fm.fileExists(atPath: gitPath.path, isDirectory: &isDir), isDir.boolValue {
                    let name = URL(fileURLWithPath: expandedPath).lastPathComponent
                    repos.append(GitRepositoryInfo(name: name, path: expandedPath))
                }
            }
        }
        return repos
    }
    
    /// Spawns a git subprocess and returns standard output or throws standard error.
    private func runGit(at repoPath: String, arguments: [String]) async throws -> String {
        let command = (["git"] + arguments).joined(separator: " ")
        AppLogger.debug("git \(arguments.joined(separator: " "))", category: "Git")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoPath] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // #region agent log
        _gitDebugLog("GitService.swift:runGit-enter", "git start", ["args": arguments], "P,R")
        // #endregion
        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            // Drain stdout and stderr concurrently while the process is still
            // running. Reading only after `waitUntilExit()` deadlocks whenever a
            // stream exceeds the OS pipe buffer (~64KB), because the child blocks
            // writing while the parent blocks waiting for exit. Concurrent reads
            // keep both pipes empty so the child can always make progress.
            let drainQueue = DispatchQueue(label: "com.coral.astra.git-drain", attributes: .concurrent)
            let group = DispatchGroup()
            var outData = Data()
            var errData = Data()

            group.enter()
            drainQueue.async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            drainQueue.async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            group.notify(queue: drainQueue) {
                process.waitUntilExit()
                // #region agent log
                _gitDebugLog("GitService.swift:runGit-exit", "git exit", ["args": arguments, "exitCode": Int(process.terminationStatus), "stdoutBytes": outData.count], "P,R")
                // #endregion

                if process.terminationStatus != 0 {
                    let errString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    AppLogger.error("git command failed: \(command) — \(errString)", category: "Git")
                    continuation.resume(throwing: NSError(domain: "GitError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errString]))
                } else {
                    let outString = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: outString)
                }
            }
        }
    }
    
    func getCurrentBranch(at repoPath: String) async -> String {
        do {
            let output = try await runGit(at: repoPath, arguments: ["branch", "--show-current"])
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }
    
    func getLocalBranches(at repoPath: String) async -> [String] {
        do {
            let output = try await runGit(at: repoPath, arguments: ["branch", "--format=%(refname:short)"])
            return output.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }
    
    func checkoutBranch(_ branch: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["checkout", branch])
    }
    
    func createBranch(_ branch: String, from base: String?, at repoPath: String) async throws {
        var args = ["checkout", "-b", branch]
        if let base = base {
            args.append(base)
        }
        _ = try await runGit(at: repoPath, arguments: args)
    }
    
    func getStatusFiles(at repoPath: String) async -> [GitStatusFile] {
        do {
            let output = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "status", "--porcelain"])
            return GitService.parseStatusPorcelain(output)
        } catch {
            return []
        }
    }

    static func parseStatusPorcelain(_ output: String) -> [GitStatusFile] {
        var files: [GitStatusFile] = []
        let lines = output.split(separator: "\n")

        for line in lines {
            guard line.count >= 3 else { continue }
            let xIndex = line.index(line.startIndex, offsetBy: 0)
            let yIndex = line.index(line.startIndex, offsetBy: 1)
            let x = String(line[xIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let y = String(line[yIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

            let fileStartIndex = line.index(line.startIndex, offsetBy: 3)
            let relativePath = String(line[fileStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if x == "?" && y == "?" {
                files.append(GitStatusFile(relativePath: relativePath, status: "?", isStaged: false))
            } else {
                if !x.isEmpty {
                    files.append(GitStatusFile(relativePath: relativePath, status: x, isStaged: true))
                }
                if !y.isEmpty {
                    files.append(GitStatusFile(relativePath: relativePath, status: y, isStaged: false))
                }
            }
        }
        return files
    }
    
    func stageFile(_ relativePath: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["add", relativePath])
    }
    
    func stageAll(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["add", "."])
    }
    
    func unstageFile(_ relativePath: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["reset", "HEAD", relativePath])
    }
    
    func unstageAll(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["reset", "HEAD"])
    }
    
    func commit(message: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["commit", "-m", message])
    }
    
    func pull(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["pull"])
    }
    
    func push(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["push"])
    }

    func pullRebase(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["pull", "--rebase"])
    }

    /// Returns ahead/behind counts vs. the upstream tracking branch. Returns nil when no upstream is configured.
    func getAheadBehind(at repoPath: String) async -> (ahead: Int, behind: Int)? {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["rev-list", "--left-right", "--count", "@{u}...HEAD"]
            )
            let parts = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2,
                  let behind = Int(parts[0]),
                  let ahead = Int(parts[1]) else { return nil }
            return (ahead, behind)
        } catch {
            return nil
        }
    }

    func hasUpstream(at repoPath: String) async -> Bool {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
            )
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// Returns the staged diff (for commit message generation). Truncated to `limit` bytes.
    func getStagedDiff(at repoPath: String, limit: Int = 8 * 1024) async -> String {
        do {
            let output = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "diff", "--cached"])
            if output.utf8.count <= limit { return output }
            let prefix = String(output.prefix(limit))
            return prefix + "\n…[truncated]"
        } catch {
            return ""
        }
    }

    /// Returns the most recent N commit subjects from HEAD for tone matching.
    func getRecentCommitSubjects(at repoPath: String, count: Int = 5) async -> [String] {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["log", "-n", "\(count)", "--pretty=%s"]
            )
            return output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    /// Returns the merge-base ref between two refs (typically `origin/main` and HEAD).
    func getMergeBase(at repoPath: String, refA: String, refB: String) async -> String? {
        do {
            let output = try await runGit(at: repoPath, arguments: ["merge-base", refA, refB])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// Returns the default upstream base branch, e.g. "origin/main", as detected from refs/remotes/origin/HEAD.
    func getDefaultBaseBranch(at repoPath: String) async -> String {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["symbolic-ref", "refs/remotes/origin/HEAD"]
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("refs/remotes/") {
                return String(trimmed.dropFirst("refs/remotes/".count))
            }
        } catch {
            // ignore
        }
        return "origin/main"
    }

    /// Returns the formatted log between `base..branch` for PR body generation.
    func getBranchLog(at repoPath: String, base: String, branch: String, limit: Int = 30) async -> String {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: [
                    "log",
                    "\(base)..\(branch)",
                    "-n", "\(limit)",
                    "--pretty=- %s%n%w(0,2,2)%b"
                ]
            )
            return output
        } catch {
            return ""
        }
    }

    /// Returns the diffstat of `base...branch` for PR body generation.
    func getBranchDiffStat(at repoPath: String, base: String, branch: String) async -> String {
        do {
            return try await runGit(
                at: repoPath,
                arguments: ["diff", "--stat", "\(base)...\(branch)"]
            )
        } catch {
            return ""
        }
    }
    
    func getDiffStats(at repoPath: String) async -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        
        do {
            let unstagedOutput = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "diff", "--numstat"])
            let stagedOutput = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "diff", "--cached", "--numstat"])
            
            let allLines = unstagedOutput.split(separator: "\n") + stagedOutput.split(separator: "\n")
            for line in allLines {
                // Split by spaces or tabs
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    .flatMap { $0.split(separator: "\t", omittingEmptySubsequences: true) }
                
                guard parts.count >= 2 else { continue }
                if let add = Int(parts[0]) {
                    additions += add
                }
                if let del = Int(parts[1]) {
                    deletions += del
                }
            }
        } catch {
            // Graceful fallback
        }
        return (additions, deletions)
    }
    
    func getRemoteOriginURL(at repoPath: String) async -> String? {
        do {
            let output = try await runGit(at: repoPath, arguments: ["config", "--get", "remote.origin.url"])
            let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty { return nil }
            
            var webURL = url
            if webURL.hasPrefix("git@github.com:") {
                webURL = webURL.replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
            }
            if webURL.hasSuffix(".git") {
                webURL = String(webURL.dropLast(4))
            }
            return webURL
        } catch {
            return nil
        }
    }
}
