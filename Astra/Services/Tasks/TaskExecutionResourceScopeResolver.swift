import Foundation
import ASTRAModels
import ASTRAPersistence

enum TaskExecutionResourceScopeResolver {
    static func resolve(
        task: AgentTask,
        acceptedTurn: String? = nil,
        attachmentPaths: [String] = []
    ) -> TaskExecutionResourceScope {
        if let scope = task.acceptedResourceScope { return scope }
        let access = TaskWorkspaceAccess(task: task)
        let root = task.executionRootPath.flatMap { $0.isEmpty ? nil : $0 }
            ?? access.codeWorkingDirectory
        let mode = TaskExecutionResourceClaimResolver.workspaceAccess(for: task)
        var resources: [TaskExecutionResourceScope.Resource] = []
        func append(_ path: String, _ access: TaskExecutionResourceAccess, _ role: TaskExecutionResourceScope.Role) {
            guard !path.isEmpty else { return }
            let resource = TaskExecutionResourceScope.Resource(path: path, access: access, role: role)
            if !resources.contains(resource) { resources.append(resource) }
        }
        let executionRoot = task.isolationStrategy == .copy
            ? IsolationService.copyPath(workspacePath: root, taskId: task.id) : root
        append(executionRoot, mode, .execution)
        if task.isolationStrategy == .copy { append(root, .shared, .isolationSource) }
        let common = TaskExecutionResourceClaimResolver.gitCommonDirectory(for: root)
        var replaced: [String] = []
        for path in task.workspace?.additionalPaths ?? [] {
            let canonical = TaskExecutionResourceScope.canonicalPath(path)
            let explicitWrite = task.constraints.contains("ASTRA_RESOURCE_WRITE_PATH=\(path)")
            if !explicitWrite, task.executionRootPath != nil,
               let common,
               canonical != TaskExecutionResourceScope.canonicalPath(root),
               TaskExecutionResourceClaimResolver.gitCommonDirectory(for: path) == common,
               TaskExecutionResourceClaimResolver.gitWorktreeRoot(for: path) == canonical {
                replaced.append(canonical)
                continue
            }
            append(path, mode, .additionalFolder)
        }
        if task.isolationStrategy == .gitBranch,
           let worktree = TaskExecutionResourceClaimResolver.gitWorktreeRoot(for: root) {
            append(worktree, .exclusive, .additionalFolder)
        }
        if !access.effectiveWorkspacePath.isEmpty {
            append(access.taskFolder, .exclusive, .taskStorage)
        }
        for path in access.runtimeReadOnlyInputPaths + attachmentPaths {
            append(path, .shared, .input)
        }
        let environment = DockerExecutionPlanner.resolveEnvironment(for: task)
        if environment.isContainerized {
            for mount in environment.mounts + environment.effectiveCredentialProjections.map(\.mount) {
                let writable = mount.access == .readWrite && (mode == .exclusive
                    || mount.role == .credential || mount.hostPath == access.taskFolder)
                append(mount.hostPath, writable ? .exclusive : .shared, .environmentMount)
            }
        }
        let mutatesGit = mode == .exclusive && (
            task.isolationStrategy == .gitBranch || task.validationStrategy == .runTests
                || GitOperationIntentDetector.detectsGitMutation(prompt: acceptedTurn ?? "", task: task)
        )
        let gitRoots = [root] + resources.filter {
            $0.role == .execution || $0.role == .additionalFolder
        }.map(\.path)
        for gitRoot in gitRoots {
            if let directory = TaskExecutionResourceClaimResolver.gitCommonDirectory(for: gitRoot) {
                append(directory, mutatesGit ? .exclusive : .shared, .gitMetadata)
            }
        }
        return TaskExecutionResourceScope(
            workingDirectory: executionRoot,
            workspacePath: access.effectiveWorkspacePath,
            resources: resources,
            replacedCheckoutPaths: replaced
        )
    }
}
