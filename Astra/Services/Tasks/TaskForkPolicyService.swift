import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

struct TaskForkPolicy: Sendable, Equatable {
    let repository: TaskForkRepositorySnapshot?
    let eligibleFileCount: Int

    var isGitBacked: Bool { repository != nil }
    var allowedModes: [TaskForkMode] {
        isGitBacked
            ? [.conversationSharedFiles]
            : [.conversationSharedFiles, .conversationWithFileCopies]
    }
}

enum TaskForkPolicyService {
    struct GitCommandResult: Sendable, Equatable {
        let output: String
        let exitCode: Int32
    }

    typealias GitRunner = (_ workingPath: String, _ arguments: [String]) -> GitCommandResult

    @MainActor
    static func resolve(
        for task: AgentTask,
        fileManager: FileManager = .default,
        gitRunner: GitRunner = runGit
    ) -> TaskForkPolicy {
        let workingPath = TaskWorkspaceAccess(task: task).codeWorkingDirectory
        let repository = repositorySnapshot(workingPath: workingPath, gitRunner: gitRunner)
        return TaskForkPolicy(
            repository: repository,
            eligibleFileCount: eligibleFilePaths(for: task, fileManager: fileManager).count
        )
    }

    @MainActor
    static func activeSharedWorktreeBlocker(for task: AgentTask) -> AgentTask? {
        guard task.isForked,
              TaskForkManifestService.load(for: task)?.repository != nil,
              let workspace = task.workspace else {
            return nil
        }
        let taskRoot = standardized(TaskWorkspaceAccess(task: task).codeWorkingDirectory)
        guard !taskRoot.isEmpty else { return nil }
        return workspace.tasks.first { candidate in
            candidate.id != task.id
                && candidate.status == .running
                && standardized(TaskWorkspaceAccess(task: candidate).codeWorkingDirectory) == taskRoot
        }
    }

    @MainActor
    static func readOnlyReason(for task: AgentTask) -> String? {
        guard let blocker = activeSharedWorktreeBlocker(for: task) else { return nil }
        return "This conversation is read-only while \"\(blocker.title)\" is using the shared Git worktree. Wait for that run to finish or select another worktree in Git."
    }

    private static func repositorySnapshot(
        workingPath: String,
        gitRunner: GitRunner
    ) -> TaskForkRepositorySnapshot? {
        guard !workingPath.isEmpty else { return nil }
        let rootResult = gitRunner(workingPath, ["rev-parse", "--show-toplevel"])
        guard rootResult.exitCode == 0 else { return nil }
        let root = rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        let branchResult = gitRunner(root, ["rev-parse", "--abbrev-ref", "HEAD"])
        let headResult = gitRunner(root, ["rev-parse", "--short=8", "HEAD"])
        let statusResult = gitRunner(root, ["--no-optional-locks", "status", "--porcelain=v1"])
        return TaskForkRepositorySnapshot(
            rootPath: standardized(root),
            branch: normalizedValue(branchResult.output, fallback: "detached"),
            headSHA: normalizedValue(headResult.output, fallback: "unknown"),
            isDirty: statusResult.exitCode == 0
                && !statusResult.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private static func eligibleFilePaths(for task: AgentTask, fileManager: FileManager) -> [String] {
        var seen: Set<String> = []
        return (task.inputs + task.artifacts.map(\.path)).compactMap { rawPath in
            let path = (rawPath as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }
            let normalized = standardized(path)
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func normalizedValue(_ raw: String, fallback: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "HEAD" ? fallback : value
    }

    private static func standardized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func runGit(workingPath: String, arguments: [String]) -> GitCommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workingPath] + arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return GitCommandResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        } catch {
            return GitCommandResult(output: "", exitCode: -1)
        }
    }
}

@MainActor
enum TaskForkCreationCoordinator {
    static func create(
        source: AgentTask,
        targetRun: TaskRun,
        mode: TaskForkMode,
        policy: TaskForkPolicy,
        modelContext: ModelContext
    ) throws -> AgentTask {
        guard policy.allowedModes.contains(mode) else {
            throw AgentTaskForkError.repositoryFileCopyDenied
        }
        let forked = try AgentTask.fork(
            from: source,
            upToRun: targetRun,
            options: TaskForkOptions(mode: mode, repository: policy.repository),
            in: modelContext
        )
        do {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: source.workspace,
                modelContext: modelContext,
                taskID: forked.id,
                auditFields: [
                    "operation": "fork_conversation",
                    "fork_mode": mode.rawValue,
                    "git_backed": String(policy.isGitBacked)
                ]
            )
            return forked
        } catch {
            let folder = TaskWorkspaceAccess(task: forked).taskFolder
            modelContext.delete(forked)
            if !folder.isEmpty {
                try? FileManager.default.removeItem(atPath: folder)
            }
            try? WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: source.workspace,
                modelContext: modelContext,
                taskID: forked.id,
                auditFields: ["operation": "fork_conversation_rollback"]
            )
            throw error
        }
    }
}
