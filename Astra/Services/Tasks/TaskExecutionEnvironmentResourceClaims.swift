import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Claims for what a run reaches through its execution environment rather
/// than through its workspace folders: host folders a Docker environment
/// mounts into the container, and the remote folder a workspace SSH
/// connection works in.
///
/// Docker mounts follow the run's workspace access: a read-only run gets them
/// read-only, a write-capable run read-write. `TaskExecutionResourceAdmissionPolicy
/// .lockClaims` therefore derives them again from the access it finally
/// admits, so a request frozen as a reader and admitted as a writer (sandboxing
/// Off) holds what its launch will be granted.
///
/// A remote folder is always claimed as a writer's. Nothing enforces read-only
/// access over SSH: a run declared read-only still gets a shell on the host
/// with the login's own permissions, so two "readers" could both write.
extension TaskExecutionResourceClaimResolver {
    /// `readOnlyInputPaths` are the request's own read-only inputs beyond the
    /// task's (current-message attachments and sandbox paths approved for a
    /// retry), mounted into the container like task inputs.
    static func environmentClaims(
        for task: AgentTask,
        workspaceAccess: TaskExecutionResourceAccess,
        readOnlyInputPaths: [String] = []
    ) -> [TaskExecutionResourceClaim] {
        dockerMountClaims(for: task, workspaceAccess: workspaceAccess, readOnlyInputPaths: readOnlyInputPaths)
            + remoteDirectoryClaims(for: task, workspaceAccess: workspaceAccess)
    }

    /// One claim per distinct remote folder the workspace's SSH connections
    /// name. Read without migrating the connections file: admission asks
    /// often and must not move domain files as a side effect.
    static func remoteDirectoryClaims(
        for task: AgentTask,
        workspaceAccess: TaskExecutionResourceAccess
    ) -> [TaskExecutionResourceClaim] {
        guard let workspace = task.workspace, !workspace.primaryPath.isEmpty else { return [] }
        var seen = Set<String>()
        // `workspaceAccess` is deliberately not used: see the type comment.
        // During a launch this is the set the launch pinned, so its drift
        // check judges exactly the connections the launch goes on to use.
        return LaunchSSHConnectionSnapshot.connectionsWithoutMigrating(for: task).compactMap { connection in
            guard let key = RemoteDirectoryClaimKey.key(for: connection), seen.insert(key).inserted else { return nil }
            return TaskExecutionResourceClaim(kind: .remoteDirectory, key: key, access: .exclusive)
        }
    }

    /// The environment the launch will run in. A task without a snapshot gets
    /// its workspace's active environment settled onto it at launch
    /// (`AgentRuntimeWorker`), so admission reads the same one rather than
    /// `DockerExecutionPlanner.resolveEnvironment`'s host fallback.
    static func launchEnvironment(for task: AgentTask) -> WorkspaceExecutionEnvironment {
        if let snapshot = task.executionEnvironmentSnapshotJSON,
           !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ExecutionEnvironmentStore.decode(snapshot)
        }
        return ExecutionEnvironmentStore.decode(task.workspace?.activeExecutionEnvironmentJSON)
    }

    /// Host folders the task's Docker environment itself projects into the
    /// container (`WorkspaceExecutionEnvironment.mounts` and its credential
    /// projections), with the access the launch gives them: a read-write
    /// mount is claimed exclusively, a read-only one shared. The access comes
    /// from `DockerExecutionPlanner.mountPlan`, the function the launch builds
    /// its `--volume` arguments from, so the two cannot drift apart.
    ///
    /// Left to the claims that already govern them: the task's own folder,
    /// the Git metadata of its worktree, and any mount at or inside a folder
    /// the task holds as a workspace claim with at least the access the
    /// mount needs.
    static func dockerMountClaims(
        for task: AgentTask,
        workspaceAccess: TaskExecutionResourceAccess,
        readOnlyInputPaths: [String] = [],
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [TaskExecutionResourceClaim] {
        let environment = launchEnvironment(for: task)
        guard environment.isContainerized else { return [] }
        let declared = Set((environment.mounts.map(\.hostPath)
            + environment.effectiveCredentialProjections.map(\.hostPath)).map(mountIdentity))
        let anticipated = anticipatedCredentialMount(for: environment, task: task, homeDirectoryPath: homeDirectoryPath)
        let access = TaskWorkspaceAccess(task: task)
        // Task inputs and the request's own inputs are mounted read-only from
        // wherever they live, often outside every workspace claim.
        let inputs = (access.runtimeReadOnlyInputPaths + readOnlyInputPaths).map(mountIdentity)
        guard !declared.isEmpty || anticipated != nil || !inputs.isEmpty else { return [] }
        let currentDirectory = access.codeWorkingDirectory.isEmpty
            ? access.effectiveWorkspacePath : access.codeWorkingDirectory
        guard !currentDirectory.isEmpty else { return [] }

        let ownFolders = ([access.taskFolder] + access.runtimeWorktreeGitMetadataPaths)
            .filter { !$0.isEmpty }.map(mountIdentity)
        let heldWritable = workspaceAccess == .exclusive ? workspaceClaimKeys(for: task).map(mountIdentity) : []
        let heldReadable = (workspaceClaimKeys(for: task) + readOnlyWorkspaceKeys(for: task)).map(mountIdentity)
        func isAtOrInside(_ path: String, _ roots: [String]) -> Bool {
            roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        var needed: [String: TaskExecutionResourceAccess] = [:]
        for mount in DockerExecutionPlanner.mountPlan(
            currentDirectory: currentDirectory, environment: environment, task: task, workspaceAccess: workspaceAccess,
            additionalReadOnlyInputPaths: readOnlyInputPaths
        ) {
            let host = mountIdentity(mount.hostPath)
            let isInput = mount.access == .readOnly && isAtOrInside(host, inputs)
            guard declared.contains(host) || isInput, !isAtOrInside(host, ownFolders) else { continue }
            let writable = mount.access == .readWrite
            guard !isAtOrInside(host, writable ? heldWritable : heldReadable) else { continue }
            needed[host] = writable || needed[host] == .exclusive ? .exclusive : .shared
        }
        // The gcloud credentials folder a launch's preflight may project
        // (`AgentRuntimeLaunchPreflight.autoProjectRequiredDockerCredentialsIfPossible`)
        // after this claim set is admitted. When the host has credentials the
        // environment does not project yet, it is claimed as a reader up front,
        // so that first run waits for a container writing it like any other.
        if let anticipated {
            let host = mountIdentity(anticipated)
            if !isAtOrInside(host, heldReadable), needed[host] == nil { needed[host] = .shared }
        }
        // Keyed the way the broker compares host folders, so one folder has
        // one spelling in a persisted claim set.
        return needed.sorted { $0.key < $1.key }.map {
            TaskExecutionResourceClaim(
                kind: .docker, key: TaskExecutionResourceBroker.canonicalKey(kind: .docker, key: $0.key), access: $0.value
            )
        }
    }

    /// Host folders the launch would mount that the admitted lease does not
    /// cover: a read-write mount needs a writer's claim at or above it, a
    /// read-only one any claim there, because a reader must still wait for a
    /// container writing the same folder. Empty when they agree, and for a
    /// launch with no lease to compare against. Anything here means the
    /// environment changed after admission; the launch must stop rather than
    /// use a folder nothing serializes.
    static func unadmittedMounts(
        lease: [TaskResourceLockClaim]?,
        task: AgentTask,
        workspaceAccess: TaskExecutionResourceAccess,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        guard let lease else { return [] }
        let held = lease.filter { $0.resourceKind == .docker }.map {
            (key: TaskExecutionResourceBroker.canonicalKey(kind: .docker, key: $0.resourceKey), writes: $0.accessMode == .write)
        }
        return dockerMountClaims(for: task, workspaceAccess: workspaceAccess, homeDirectoryPath: homeDirectoryPath).compactMap { claim in
            let path = TaskExecutionResourceBroker.canonicalKey(for: claim)
            let needsWrite = claim.access == .exclusive
            let covered = held.contains { (path == $0.key || path.hasPrefix($0.key + "/")) && ($0.writes || !needsWrite) }
            return covered ? nil : path
        }
    }

    /// Remote folders the launch would reach that the admitted lease does
    /// not cover, by the same rule as mounts. The connections file can change
    /// between admission and launch; a folder it now names that no claim
    /// covers must stop the launch, as a changed mount does.
    static func unadmittedRemoteDirectories(
        lease: [TaskResourceLockClaim]?,
        task: AgentTask,
        workspaceAccess: TaskExecutionResourceAccess
    ) -> [String] {
        guard let lease else { return [] }
        let held = lease.filter { $0.resourceKind == .remoteDirectory }
        return remoteDirectoryClaims(for: task, workspaceAccess: workspaceAccess).compactMap { claim in
            let needsWrite = claim.access == .exclusive
            let covered = held.contains {
                RemoteDirectoryClaimKey.covers($0.resourceKey, claim.key) && ($0.accessMode == .write || !needsWrite)
            }
            return covered ? nil : claim.key
        }
    }

    /// A resumed turn keeps the claims its originating turn accepted, plus
    /// what it mounts that the origin never did: a sandbox path approved for
    /// this retry, or this message's attachments. Claims the origin already
    /// holds are left as they were; unreadable origin claims are kept as they
    /// are, so admission still rejects them.
    static func mergingInputClaims(
        into origin: TaskTurnRequest,
        for task: AgentTask,
        readOnlyInputPaths: [String]
    ) -> String {
        guard !readOnlyInputPaths.isEmpty, let originClaims = origin.decodedResourceClaims else {
            return origin.resourceClaimsJSON
        }
        let held = Set(originClaims.filter { $0.kind == .docker }.map(TaskExecutionResourceBroker.canonicalKey(for:)))
        let added = dockerMountClaims(
            for: task, workspaceAccess: workspaceAccess(for: origin), readOnlyInputPaths: readOnlyInputPaths
        ).filter { !held.contains(TaskExecutionResourceBroker.canonicalKey(for: $0)) }
        guard !added.isEmpty else { return origin.resourceClaimsJSON }
        return TaskExecutionResourceClaimSet(claims: originClaims + added).encodedJSON() ?? origin.resourceClaimsJSON
    }

    /// The host gcloud folder the launch preflight would add as a read-only
    /// projection: host credentials exist and the environment projects none.
    static func anticipatedCredentialMount(
        for environment: WorkspaceExecutionEnvironment,
        task: AgentTask,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> String? {
        guard environment.isContainerized,
              !environment.effectiveCredentialProjections.contains(where: { $0.id == ExecutionEnvironmentCredentialProjection.gcpADCID })
        else { return nil }
        let folder = ExecutionEnvironmentCredentialProjection.defaultGCPADCHostPath(homeDirectory: homeDirectoryPath)
        let file = (folder as NSString).appendingPathComponent(ExecutionEnvironmentCredentialProjection.gcpADCFileName)
        return fileManager.fileExists(atPath: file) ? folder : nil
    }

    private static func mountIdentity(_ path: String) -> String {
        let standardized = WorkspacePathPresentation.standardizedPath(path)
        return ExecutionSandbox.canonicalize(standardized) ?? standardized
    }
}
