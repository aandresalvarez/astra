import Foundation
import ASTRAModels
import ASTRAPersistence
import ASTRACore

enum IsolationError: Error, LocalizedError {
    case gitNotFound
    case gitFailed(String)
    case copyFailed(String)
    case notAGitRepo

    var errorDescription: String? {
        switch self {
        case .gitNotFound: return "Git not found"
        case .gitFailed(let msg): return "Git error: \(msg)"
        case .copyFailed(let msg): return "Copy error: \(msg)"
        case .notAGitRepo: return "Not a git repository"
        }
    }
}

enum IsolationService {

    /// Per-workspace lock to serialize git operations (checkout, branch create/delete)
    /// on the same repository. Prevents concurrent cleanup/prepare from interleaving.
    private static let workspaceLocks = WorkspaceLockManager()

    final class WorkspaceLockManager: @unchecked Sendable {
        private let lock = NSLock()
        private var locks: [String: NSLock] = [:]

        func withLock<T>(for path: String, body: () throws -> T) rethrows -> T {
            let key = Self.lockKey(for: path)
            let wsLock: NSLock = {
                lock.lock()
                defer { lock.unlock() }
                if let existing = locks[key] { return existing }
                let new = NSLock()
                locks[key] = new
                return new
            }()
            wsLock.lock()
            defer { wsLock.unlock() }
            return try body()
        }

        static func lockKey(for path: String) -> String {
            URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }
    }

    /// Prepare the workspace according to the isolation strategy.
    /// Returns the actual working directory path to use for execution.
    static func prepare(task: AgentTask) async throws -> String {
        let codeDir = TaskWorkspaceAccess(task: task).codeWorkingDirectory
        switch task.isolationStrategy {
        case .sameDirectory:
            return codeDir

        case .gitBranch:
            return try workspaceLocks.withLock(for: codeDir) {
                try createGitBranch(workspacePath: codeDir, taskTitle: task.title, taskId: task.id)
            }

        case .copy:
            return try copyWorkspace(workspacePath: codeDir, taskId: task.id)
        }
    }

    /// The deterministic execution path a RETAINED isolation artifact lives at
    /// (retained because the provider detached for durable external
    /// monitoring), for callers that need to clean it up outside the worker's
    /// own run lifecycle — e.g. when a cancelled task's suppressed terminal
    /// wake is the last event that will ever fire for it. Returns nil when
    /// there is nothing to clean (`.sameDirectory`, or no copy exists).
    static func retainedExecutionPath(task: AgentTask) -> String? {
        let codeDir = TaskWorkspaceAccess(task: task).codeWorkingDirectory
        guard !codeDir.isEmpty else { return nil }
        switch task.isolationStrategy {
        case .sameDirectory:
            return nil
        case .gitBranch:
            // cleanup() is a safe no-op unless the repo is currently on an
            // astra/* branch.
            return codeDir
        case .copy:
            let originalName = URL(fileURLWithPath: codeDir).lastPathComponent
            let copyName = "\(originalName)-astra-\(task.id.uuidString.prefix(8).lowercased())"
            let copyPath = copyScratchRoot().appendingPathComponent(copyName, isDirectory: true).path
            return FileManager.default.fileExists(atPath: copyPath) ? copyPath : nil
        }
    }

    /// Clean up isolation artifacts if needed (e.g., switch back from branch).
    /// Serialized per-workspace to prevent interleaved git operations.
    static func cleanup(task: AgentTask, executionPath: String) {
        switch task.isolationStrategy {
        case .gitBranch:
            workspaceLocks.withLock(for: executionPath) {
                let origBranch = runGitSync(args: ["rev-parse", "--abbrev-ref", "HEAD"], in: executionPath)
                if origBranch.stdout.hasPrefix("astra/") {
                    let mainResult = runGitSync(args: ["checkout", "main"], in: executionPath)
                    if mainResult.exitCode != 0 {
                        let _ = runGitSync(args: ["checkout", "master"], in: executionPath)
                    }
                }
            }
            AppLogger.audit(.isolationCleanedUp, category: "Isolation", taskID: task.id, fields: [
                "strategy": task.isolationStrategy.rawValue
            ])
        case .copy:
            _ = deleteCopy(path: executionPath)
            AppLogger.audit(.isolationCleanedUp, category: "Isolation", taskID: task.id, fields: [
                "strategy": task.isolationStrategy.rawValue,
                "copy_retained": "false"
            ])
        case .sameDirectory:
            break
        }
    }

    /// Delete an astra git branch. Serialized per-workspace.
    static func deleteBranch(name: String, workspacePath: String) -> Bool {
        workspaceLocks.withLock(for: workspacePath) {
            let result = runGitSync(args: ["branch", "-D", name], in: workspacePath)
            return result.exitCode == 0
        }
    }

    /// Delete a workspace copy directory
    static func deleteCopy(path: String) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            AppLogger.audit(.isolationFailed, category: "Isolation", fields: [
                "operation": "delete_copy",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return false
        }
    }

    /// List all astra/* branches in a workspace
    static func listAstraBranches(workspacePath: String) -> [String] {
        let result = runGitSync(args: ["branch", "--list", "astra/*"], in: workspacePath)
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "* ", with: "") }
            .filter { !$0.isEmpty }
    }

    // MARK: - Git Branch

    private static func createGitBranch(workspacePath: String, taskTitle: String, taskId: UUID) throws -> String {
        // Verify it's a git repo
        let checkResult = runGitSync(args: ["rev-parse", "--is-inside-work-tree"], in: workspacePath)
        guard checkResult.exitCode == 0 else {
            throw IsolationError.notAGitRepo
        }

        // Create a branch name from task title
        let safeName = taskTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            .prefix(40)
        let branchName = "astra/\(safeName)-\(taskId.uuidString.prefix(8).lowercased())"

        AppLogger.audit(.gitBranchCreated, category: "Isolation", fields: [
            "branch_prefix": "astra",
            "task_id": taskId.uuidString
        ])

        // The branch name is deterministic per task, and a task that detached
        // for durable external monitoring RETAINS its isolation artifact (the
        // detached job keeps using it). The eventual wake continuation
        // re-prepares isolation on adapters that prepare on resume; `-b` would
        // fail against the already-existing branch and acknowledge the only
        // wake without ever starting the provider. Reuse the retained branch
        // by checking it out instead.
        let existsResult = runGitSync(
            args: ["rev-parse", "--verify", "--quiet", "refs/heads/\(branchName)"],
            in: workspacePath
        )
        let createResult = existsResult.exitCode == 0
            ? runGitSync(args: ["checkout", branchName], in: workspacePath)
            : runGitSync(args: ["checkout", "-b", branchName], in: workspacePath)
        guard createResult.exitCode == 0 else {
            throw IsolationError.gitFailed("Failed to create branch '\(branchName)': \(createResult.stderr)")
        }

        AppLogger.audit(.isolationPrepared, category: "Isolation", fields: [
            "strategy": "git_branch",
            "task_id": taskId.uuidString
        ])
        return workspacePath  // Same directory, different branch
    }

    /// Synchronous git runner for callers that can't be async (cleanup, deleteBranch, listBranches).
    /// Git commands are fast (milliseconds) so blocking is acceptable here.
    private static func runGitSync(args: [String], in directory: String) -> (exitCode: Int, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (Int(process.terminationStatus), stdout.trimmingCharacters(in: .whitespacesAndNewlines), stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Async git runner using AsyncProcessRunner — used from async contexts.
    private static func runGit(args: [String], in directory: String) async -> (exitCode: Int, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: stderrPipe)
        return (result.exitCode, result.stdout, result.stderr)
    }

    // MARK: - Copy

    static func copyScratchRoot(
        channel: AppChannel = .current,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        AppChannelStoragePaths.applicationSupportDirectory(
            for: channel,
            environment: environment,
            fileManager: fileManager
        )
            .appendingPathComponent("WorkspaceCopies", isDirectory: true)
    }

    private static func copyWorkspace(workspacePath: String, taskId: UUID) throws -> String {
        let fm = FileManager.default
        let originalName = URL(fileURLWithPath: workspacePath).lastPathComponent
        let copyName = "\(originalName)-astra-\(taskId.uuidString.prefix(8).lowercased())"
        let scratchRoot = copyScratchRoot(fileManager: fm)
        let copyPath = scratchRoot.appendingPathComponent(copyName, isDirectory: true).path

        // The copy destination is deterministic per task, and a task that
        // detached for durable external monitoring RETAINS its copy (the
        // detached job's mount). The eventual wake continuation re-prepares
        // isolation on adapters that prepare on resume; `copyItem` would fail
        // against the existing directory and acknowledge the only wake without
        // ever starting the provider. Reuse the retained copy instead.
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: copyPath, isDirectory: &isDirectory), isDirectory.boolValue {
            AppLogger.audit(.isolationPrepared, category: "Isolation", fields: [
                "strategy": "copy",
                "task_id": taskId.uuidString,
                "phase": "copy_reused"
            ])
            return copyPath
        }

        AppLogger.audit(.isolationPrepared, category: "Isolation", fields: [
            "strategy": "copy",
            "task_id": taskId.uuidString,
            "phase": "copy_started"
        ])

        do {
            try fm.createDirectory(
                at: scratchRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratchRoot.path)
            try fm.copyItem(atPath: workspacePath, toPath: copyPath)
        } catch {
            throw IsolationError.copyFailed("Failed to copy '\(workspacePath)' to '\(copyPath)': \(error.localizedDescription)")
        }

        AppLogger.audit(.isolationPrepared, category: "Isolation", fields: [
            "strategy": "copy",
            "task_id": taskId.uuidString,
            "phase": "copy_completed"
        ])
        return copyPath
    }
}
