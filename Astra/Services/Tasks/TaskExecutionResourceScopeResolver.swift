import Foundation
import ASTRAModels
import ASTRAPersistence

enum TaskExecutionResourceScopeResolver {
    static func resolve(
        task: AgentTask,
        acceptedTurn: String? = nil,
        attachmentPaths: [String] = [],
        gitAccessRequirement: TaskExecutionResourceScope.GitAccess? = nil
    ) -> TaskExecutionResourceScope {
        if let scope = task.acceptedResourceScope { return scope }
        let access = TaskWorkspaceAccess(task: task)
        let root = access.codeWorkingDirectory
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
            if task.isolationStrategy == .copy, canonical == TaskExecutionResourceScope.canonicalPath(root) { continue }
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
        let hasBoundStorage = (try? TaskStorageBinding.load(for: task)) != nil
        if !access.effectiveWorkspacePath.isEmpty || hasBoundStorage {
            append(access.canonicalTaskFolder, .exclusive, .taskStorage)
        }
        var environment = DockerExecutionPlanner.environmentForAcceptance(for: task)
        environment.mounts = environment.mounts.map { mount in
            var resolved = mount
            switch mount.role {
            case .workspace: resolved.hostPath = executionRoot
            case .taskFolder: resolved.hostPath = access.canonicalTaskFolder
            case .additionalPath, .input, .credential: break
            }
            return resolved
        }
        let explicitAttachments = Set(attachmentPaths + TaskAttachmentLedger.entries(
            in: task.events.map(TaskAttachmentLedger.EventFacts.init)).map(\.path))
        let promptInputs = task.inputs.map { input -> TaskExecutionResourceScope.PromptInput in
            let path = (input as NSString).expandingTildeInPath
            let explicitAttachment = explicitAttachments.contains(input) || explicitAttachments.contains(path)
            guard explicitAttachment || ((input.hasPrefix("/") || input.hasPrefix("~"))
                && FileManager.default.fileExists(atPath: path)) else {
                return .init(value: input, kind: .text)
            }
            return .init(value: path, kind: FileManager.default.fileExists(atPath: path) ? .path : .unavailablePath)
        }
        let approvedPaths = TaskLaunchResourceResolver.approvedSandboxReadablePaths(
            from: TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: task.resolvedRuntimeID),
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path)
        let availableAttachments = attachmentPaths.filter { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
        for path in promptInputs.filter({ $0.kind == .path }).map(\.value) + availableAttachments + approvedPaths {
            append(path, .shared, .input)
        }
        if environment.isContainerized {
            for mount in environment.mounts + environment.effectiveCredentialProjections.map(\.mount) {
                let writable = mount.access == .readWrite && (mode == .exclusive
                    || mount.role == .credential || mount.hostPath == access.canonicalTaskFolder)
                append(mount.hostPath, writable ? .exclusive : .shared, .environmentMount)
            }
        }
        var gitAccess = TaskExecutionGitRequirementResolver.resolve(task: task, requirement: gitAccessRequirement, writable: mode == .exclusive)
        let gitRoots = (task.isolationStrategy == .copy ? [] : [root]) + resources.filter {
            $0.role == .execution || $0.role == .additionalFolder
        }.map(\.path)
        for gitRoot in gitRoots {
            if let directory = TaskExecutionResourceClaimResolver.gitCommonDirectory(for: gitRoot) {
                append(directory, gitAccess == .readWrite ? .exclusive : .shared, .gitMetadata)
                if let worktree = TaskExecutionResourceClaimResolver.gitWorktreeRoot(for: gitRoot) {
                    append((worktree as NSString).appendingPathComponent(".git"),
                           gitAccess == .readWrite ? .exclusive : .shared, .gitMetadata)
                }
            }
        }
        if task.isolationStrategy == .copy {
            var isDirectory: ObjCBool = false
            let gitPath = (root as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory), isDirectory.boolValue {
                append((executionRoot as NSString).appendingPathComponent(".git"), gitAccess == .readWrite ? .exclusive : .shared, .gitMetadata)
            } else if let common {
                if gitAccess == .readWrite { gitAccess = .invalid }
                append(common, .shared, .gitMetadata)
                append((executionRoot as NSString).appendingPathComponent(".git"), .shared, .gitMetadata)
            }
        }
        return TaskExecutionResourceScope(
            workingDirectory: executionRoot,
            workspacePath: access.effectiveWorkspacePath,
            resources: resources,
            replacedCheckoutPaths: replaced,
            promptInputs: promptInputs,
            executionEnvironment: environment,
            gitAccess: gitAccess
        )
    }
}
