import Foundation
import ASTRACore

enum TaskLaunchResourceResolver {
    typealias GitCredentialContextProvider = (String, AgentTask, String, String) -> GitCredentialSandboxContext
    typealias GCloudExecutablePathProvider = (FileManager) -> String?

    static func resolve(
        task: AgentTask,
        runID: UUID?,
        runtime: AgentRuntimeID,
        phase: String,
        prompt: String,
        contextText: String,
        workspacePath: String,
        executionEnvironment: WorkspaceExecutionEnvironment? = nil,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default,
        gcloudExecutablePathProvider: GCloudExecutablePathProvider = defaultGCloudExecutablePath,
        gitCredentialContextProvider: GitCredentialContextProvider = defaultGitCredentialContext
    ) -> TaskLaunchResourcePlan {
        let environment = executionEnvironment ?? DockerExecutionPlanner.resolveEnvironment(for: task)
        var hostPathGrants: [RuntimePathGrant] = []
        var containerMounts: [RuntimeContainerMountGrant] = []
        var environmentGrants: [RuntimeEnvironmentGrant] = []
        var credentialGrants: [RuntimeCredentialGrant] = []
        var providerRequirements: [RuntimeProviderRequirement] = []
        var diagnostics: [RuntimeResourceDiagnostic] = []

        appendWorkspacePathGrants(
            task: task,
            fileManager: fileManager,
            to: &hostPathGrants
        )
        appendAttachmentPathGrants(
            task: task,
            contextText: contextText,
            fileManager: fileManager,
            grants: &hostPathGrants,
            diagnostics: &diagnostics
        )

        let gitCredentialContext = gitCredentialContextProvider(prompt, task, contextText, workspacePath)
        let gitResource = gitCredentialContext.isEmpty ? nil : RuntimeGitCredentialResource(
            readablePaths: uniquePaths(gitCredentialContext.readablePaths),
            writablePaths: uniquePaths(gitCredentialContext.writablePaths),
            transports: gitCredentialContext.transports.map(\.rawValue),
            diagnostics: gitCredentialContext.diagnostics
        )
        appendGitCredentialGrants(
            gitCredentialContext,
            hostPathGrants: &hostPathGrants,
            credentialGrants: &credentialGrants
        )
        appendRemoteWorkspaceGrants(
            task: task,
            homeDirectoryPath: homeDirectoryPath,
            fileManager: fileManager,
            hostPathGrants: &hostPathGrants,
            credentialGrants: &credentialGrants,
            providerRequirements: &providerRequirements,
            diagnostics: &diagnostics
        )

        appendExecutionEnvironmentGrants(
            environment,
            task: task,
            runID: runID,
            fileManager: fileManager,
            hostPathGrants: &hostPathGrants,
            containerMounts: &containerMounts,
            environmentGrants: &environmentGrants,
            credentialGrants: &credentialGrants,
            providerRequirements: &providerRequirements,
            diagnostics: &diagnostics
        )

        appendCapabilityGrants(
            task: task,
            contextText: contextText,
            executionEnvironment: environment,
            homeDirectoryPath: homeDirectoryPath,
            fileManager: fileManager,
            gcloudExecutablePathProvider: gcloudExecutablePathProvider,
            hostPathGrants: &hostPathGrants,
            providerRequirements: &providerRequirements,
            environmentGrants: &environmentGrants,
            credentialGrants: &credentialGrants,
            diagnostics: &diagnostics
        )

        return TaskLaunchResourcePlan(
            taskID: task.id,
            runID: runID,
            runtime: runtime.rawValue,
            phase: phase,
            workspacePath: normalizedPath(workspacePath),
            executionEnvironmentID: environment.id,
            executionEnvironmentKind: environment.kind.rawValue,
            providerPlacement: environment.effectiveProviderPlacement.rawValue,
            workspaceCommandPlacement: environment.workspaceCommandPlacement,
            shellRoute: environment.workspaceShellRoute,
            hostPathGrants: uniqueHostPathGrants(hostPathGrants),
            containerMounts: uniqueContainerMounts(containerMounts),
            environmentGrants: uniqueEnvironmentGrants(environmentGrants),
            credentialGrants: uniqueCredentialGrants(credentialGrants),
            providerRequirements: uniqueProviderRequirements(providerRequirements),
            diagnostics: diagnostics,
            gitCredential: gitResource
        )
    }

    static func defaultGitCredentialContext(
        prompt: String,
        task: AgentTask,
        contextText: String,
        workspacePath: String
    ) -> GitCredentialSandboxContext {
        GitCredentialContextResolver.runtimeSandboxContext(
            prompt: prompt,
            task: task,
            contextText: contextText,
            repositoryPath: workspacePath,
        )
    }

    private static func appendWorkspacePathGrants(
        task: AgentTask,
        fileManager: FileManager,
        to grants: inout [RuntimePathGrant]
    ) {
        guard let workspace = task.workspace else { return }
        for path in [workspace.primaryPath] + workspace.additionalPaths {
            guard let normalized = existingPath(path, fileManager: fileManager) else { continue }
            grants.append(RuntimePathGrant(
                path: normalized,
                access: .readWrite,
                source: .workspace,
                reason: "Workspace path selected by the user.",
                sensitivity: .normal,
                lifetime: .workspace,
                exists: true
            ))
        }
    }

    private static func appendAttachmentPathGrants(
        task: AgentTask,
        contextText: String,
        fileManager: FileManager,
        grants: inout [RuntimePathGrant],
        diagnostics: inout [RuntimeResourceDiagnostic]
    ) {
        for path in task.inputs {
            appendInputPathGrant(
                rawPath: path,
                source: .taskInput,
                reason: "Task input selected by the user.",
                fileManager: fileManager,
                grants: &grants,
                diagnostics: &diagnostics
            )
        }

        for path in AgentRuntimeAttachmentProjection.attachmentBlockPaths(in: contextText) {
            appendInputPathGrant(
                rawPath: path,
                source: .userAttachment,
                reason: "File attached by the user in the current message.",
                fileManager: fileManager,
                grants: &grants,
                diagnostics: &diagnostics
            )
        }
    }

    private static func appendInputPathGrant(
        rawPath: String,
        source: TaskLaunchResourceSource,
        reason: String,
        fileManager: FileManager,
        grants: inout [RuntimePathGrant],
        diagnostics: inout [RuntimeResourceDiagnostic]
    ) {
        let stripped = AgentRuntimeAttachmentProjection.stripPathDecoratorsForLaunchResources(rawPath)
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let normalized = existingPath(stripped, fileManager: fileManager) else {
            diagnostics.append(RuntimeResourceDiagnostic(
                severity: .warning,
                code: "input_path_missing",
                message: "ASTRA could not project attached path because it does not exist: \(stripped)",
                repairAction: "Attach the file again or move it back to the original path."
            ))
            return
        }
        grants.append(RuntimePathGrant(
            path: normalized,
            access: .read,
            source: source,
            reason: reason,
            sensitivity: .normal,
            lifetime: .run,
            exists: true
        ))
    }

    private static func appendGitCredentialGrants(
        _ context: GitCredentialSandboxContext,
        hostPathGrants: inout [RuntimePathGrant],
        credentialGrants: inout [RuntimeCredentialGrant]
    ) {
        guard !context.isEmpty else { return }
        for path in context.readablePaths {
            hostPathGrants.append(RuntimePathGrant(
                path: normalizedPath(path),
                access: .read,
                source: .gitCredential,
                reason: "Git operation requires external Git config or credential context.",
                sensitivity: .credential,
                lifetime: .run,
                exists: true
            ))
        }
        for path in context.writablePaths {
            hostPathGrants.append(RuntimePathGrant(
                path: normalizedPath(path),
                access: .readWrite,
                source: .gitCredential,
                reason: "Git operation requires a writable external Git metadata path.",
                sensitivity: .credential,
                lifetime: .run,
                exists: true
            ))
        }
        if context.needsExternalCredentialAccess {
            credentialGrants.append(RuntimeCredentialGrant(
                label: context.transports.map(\.rawValue).joined(separator: ","),
                source: .gitCredential,
                reason: "Git operation may need host SSH, HTTPS, or cloud credential helpers.",
                projectedAsEnvironment: false,
                projectedAsFile: true
            ))
        }
    }

    private static func appendRemoteWorkspaceGrants(
        task: AgentTask,
        homeDirectoryPath: String,
        fileManager: FileManager,
        hostPathGrants: inout [RuntimePathGrant],
        credentialGrants: inout [RuntimeCredentialGrant],
        providerRequirements: inout [RuntimeProviderRequirement],
        diagnostics: inout [RuntimeResourceDiagnostic]
    ) {
        guard let workspace = task.workspace else { return }
        let connections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
        guard !connections.isEmpty else { return }

        providerRequirements.append(RuntimeProviderRequirement(
            capability: "remote_workspace_ssh",
            source: .remoteWorkspace,
            reason: "Workspace has a configured remote SSH connection.",
            required: true
        ))

        let aliasConnections = connections.filter {
            !$0.configAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !aliasConnections.isEmpty {
            appendExistingRemoteWorkspacePathGrant(
                "~/.ssh/config",
                access: .read,
                reason: "Configured remote workspace SSH aliases require the user's SSH config.",
                homeDirectoryPath: homeDirectoryPath,
                fileManager: fileManager,
                hostPathGrants: &hostPathGrants,
                diagnostics: &diagnostics,
                missingCode: "ssh_config_missing"
            )
        }

        let keyPaths = uniqueRawPaths(connections.map(\.keyPath).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        for keyPath in keyPaths {
            appendExistingRemoteWorkspacePathGrant(
                keyPath,
                access: .read,
                reason: "Configured remote workspace SSH connection declares this identity file.",
                homeDirectoryPath: homeDirectoryPath,
                fileManager: fileManager,
                hostPathGrants: &hostPathGrants,
                diagnostics: &diagnostics,
                missingCode: "ssh_identity_file_missing"
            )
        }

        for knownHosts in ["~/.ssh/known_hosts", "~/.ssh/known_hosts2"] {
            appendOptionalRemoteWorkspacePathGrant(
                knownHosts,
                access: .readWrite,
                reason: "OpenSSH may atomically update known-host entries for the configured remote workspace.",
                homeDirectoryPath: homeDirectoryPath,
                fileManager: fileManager,
                hostPathGrants: &hostPathGrants
            )
        }
        appendOptionalRemoteWorkspacePathGrant(
            "~/.ssh",
            access: .write,
            reason: "OpenSSH replaces known-host files through temporary files in the parent SSH directory.",
            homeDirectoryPath: homeDirectoryPath,
            fileManager: fileManager,
            hostPathGrants: &hostPathGrants
        )

        credentialGrants.append(RuntimeCredentialGrant(
            label: "Remote workspace SSH",
            source: .remoteWorkspace,
            reason: "Remote workspace commands use SSH config, identity files, and known-host metadata.",
            projectedAsEnvironment: false,
            projectedAsFile: true
        ))
    }

    private static func appendExecutionEnvironmentGrants(
        _ environment: WorkspaceExecutionEnvironment,
        task: AgentTask,
        runID: UUID?,
        fileManager: FileManager,
        hostPathGrants: inout [RuntimePathGrant],
        containerMounts: inout [RuntimeContainerMountGrant],
        environmentGrants: inout [RuntimeEnvironmentGrant],
        credentialGrants: inout [RuntimeCredentialGrant],
        providerRequirements: inout [RuntimeProviderRequirement],
        diagnostics: inout [RuntimeResourceDiagnostic]
    ) {
        guard environment.isContainerized else { return }
        providerRequirements.append(RuntimeProviderRequirement(
            capability: environment.workspaceCommandsRunInsideContainer ? "docker_workspace_executor" : "docker_provider_runtime",
            source: .dockerEnvironment,
            reason: "Task is pinned to a Docker execution environment.",
            required: true
        ))

        if DockerWorkspaceMCPProjection.isEnabled(for: environment),
           let dockerConfigDirectory = DockerWorkspaceMCPProjection.taskScopedDockerConfigDirectory(
                task: task,
                runID: runID,
                fileManager: fileManager
           ) {
            hostPathGrants.append(RuntimePathGrant(
                path: normalizedPath(dockerConfigDirectory),
                access: .readWrite,
                source: .dockerEnvironment,
                reason: "Docker workspace MCP helper uses an ASTRA-managed Docker client config instead of the user's ~/.docker/config.json.",
                sensitivity: .normal,
                lifetime: .run,
                exists: true
            ))
            environmentGrants.append(RuntimeEnvironmentGrant(
                key: "DOCKER_CONFIG",
                source: .dockerEnvironment,
                reason: "Docker workspace MCP helper points Docker CLI at ASTRA's task-scoped client config.",
                sensitivity: .normal,
                valueProjected: true
            ))
            diagnostics.append(RuntimeResourceDiagnostic(
                severity: .info,
                code: "docker_client_config_task_scoped",
                message: "Docker workspace commands use an ASTRA-managed Docker client config; the real ~/.docker/config.json is not projected to the provider sandbox.",
                repairAction: nil
            ))
        }

        for mount in environment.mounts {
            containerMounts.append(RuntimeContainerMountGrant(
                hostPath: mount.hostPath,
                containerPath: mount.containerPath,
                access: mount.access.rawValue,
                role: mount.role.rawValue
            ))
        }

        for projection in environment.effectiveCredentialProjections {
            containerMounts.append(RuntimeContainerMountGrant(
                hostPath: projection.hostPath,
                containerPath: projection.containerPath,
                access: projection.access.rawValue,
                role: ExecutionEnvironmentMountRole.credential.rawValue
            ))
            credentialGrants.append(RuntimeCredentialGrant(
                label: projection.displayName,
                source: .dockerCredential,
                reason: "Docker workspace credential projection configured for this environment.",
                projectedAsEnvironment: !projection.environment.isEmpty,
                projectedAsFile: true
            ))
            for key in projection.environment.keys.sorted() {
                environmentGrants.append(RuntimeEnvironmentGrant(
                    key: key,
                    source: .dockerCredential,
                    reason: "Docker credential projection exposes this environment key inside container commands.",
                    sensitivity: .cloudAuth,
                    valueProjected: true
                ))
            }
        }

        if environment.effectiveCredentialProjections.isEmpty {
            diagnostics.append(RuntimeResourceDiagnostic(
                severity: .info,
                code: "docker_no_credential_projection",
                message: "Docker environment has no credential projection configured.",
                repairAction: "Connect credentials in the Container panel if this task needs cloud or private registry access."
            ))
        }
    }

    private static func appendCapabilityGrants(
        task: AgentTask,
        contextText: String,
        executionEnvironment: WorkspaceExecutionEnvironment,
        homeDirectoryPath: String,
        fileManager: FileManager,
        gcloudExecutablePathProvider: GCloudExecutablePathProvider,
        hostPathGrants: inout [RuntimePathGrant],
        providerRequirements: inout [RuntimeProviderRequirement],
        environmentGrants: inout [RuntimeEnvironmentGrant],
        credentialGrants: inout [RuntimeCredentialGrant],
        diagnostics: inout [RuntimeResourceDiagnostic]
    ) {
        if TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText) {
            providerRequirements.append(RuntimeProviderRequirement(
                capability: "browser_bridge",
                source: .browser,
                reason: "Task context requires access to ASTRA's browser bridge.",
                required: true
            ))
        }

        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: contextText)
        let hasGCloudConnector = scope.connectors.contains { connector in
            let normalized = connector.serviceType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized == "gcloud" ||
                normalized == "google_cloud" ||
                normalized == "googlecloud" ||
                normalized == "gcp"
        }
        if hasGCloudConnector, !executionEnvironment.isContainerized {
            appendHostGCloudCredentialGrant(
                homeDirectoryPath: homeDirectoryPath,
                fileManager: fileManager,
                executablePath: gcloudExecutablePathProvider(fileManager),
                hostPathGrants: &hostPathGrants,
                credentialGrants: &credentialGrants,
                diagnostics: &diagnostics
            )
        }

        for connector in scope.connectors {
            providerRequirements.append(RuntimeProviderRequirement(
                capability: "connector:\(connector.serviceType)",
                source: .connector,
                reason: "Task capability scope includes connector \(connector.name).",
                required: true
            ))
            for key in connector.credentialKeys {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                credentialGrants.append(RuntimeCredentialGrant(
                    label: "\(connector.name):\(trimmed)",
                    source: .connector,
                    reason: "Connector declares credential key \(trimmed).",
                    projectedAsEnvironment: true,
                    projectedAsFile: false
                ))
                environmentGrants.append(RuntimeEnvironmentGrant(
                    key: trimmed,
                    source: .connector,
                    reason: "Connector credential key is projected through ASTRA-managed runtime environment when available.",
                    sensitivity: .credential,
                    valueProjected: false
                ))
            }
            for key in connector.configKeys {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                environmentGrants.append(RuntimeEnvironmentGrant(
                    key: trimmed,
                    source: .connector,
                    reason: "Connector config key is projected through ASTRA-managed runtime environment when configured.",
                    sensitivity: .normal,
                    valueProjected: false
                ))
            }
        }
    }

    private static func appendHostGCloudCredentialGrant(
        homeDirectoryPath: String,
        fileManager: FileManager,
        executablePath: String?,
        hostPathGrants: inout [RuntimePathGrant],
        credentialGrants: inout [RuntimeCredentialGrant],
        diagnostics: inout [RuntimeResourceDiagnostic]
    ) {
        let gcloudDirectory = ExecutionEnvironmentCredentialProjection
            .defaultGCPADCHostPath(homeDirectory: homeDirectoryPath)
        guard existingPath(gcloudDirectory, homeDirectoryPath: homeDirectoryPath, fileManager: fileManager) != nil else {
            diagnostics.append(RuntimeResourceDiagnostic(
                severity: .warning,
                code: "gcloud_config_missing",
                message: "Google Cloud connector is enabled, but ASTRA could not find the local gcloud config directory.",
                repairAction: "Run `gcloud auth login` and retry the task."
            ))
            return
        }

        hostPathGrants.append(RuntimePathGrant(
            path: normalizedPath(gcloudDirectory, homeDirectoryPath: homeDirectoryPath),
            access: .readWrite,
            source: .connector,
            reason: "Google Cloud connector uses local gcloud authentication and may refresh tokens during CLI calls.",
            sensitivity: .cloudAuth,
            lifetime: .run,
            exists: true
        ))
        credentialGrants.append(RuntimeCredentialGrant(
            label: "Google Cloud local gcloud config",
            source: .connector,
            reason: "Host-side gcloud commands require access to local gcloud authentication state.",
            projectedAsEnvironment: false,
            projectedAsFile: true
        ))

        for supportPath in gcloudExecutableSupportPaths(
            executablePath: executablePath,
            fileManager: fileManager
        ) {
            hostPathGrants.append(RuntimePathGrant(
                path: normalizedPath(supportPath),
                access: .read,
                source: .connector,
                reason: "Google Cloud connector uses the local gcloud CLI installation.",
                sensitivity: .normal,
                lifetime: .run,
                exists: true
            ))
        }
    }

    private static func defaultGCloudExecutablePath(fileManager: FileManager) -> String? {
        let candidates = [
            "/usr/local/bin/gcloud",
            "/opt/homebrew/bin/gcloud",
            "/usr/bin/gcloud"
        ]
        return candidates.first { path in
            fileManager.fileExists(atPath: path)
        }
    }

    private static func gcloudExecutableSupportPaths(
        executablePath: String?,
        fileManager: FileManager
    ) -> [String] {
        guard let executablePath,
              let executable = existingPath(executablePath, fileManager: fileManager) else {
            return []
        }
        var paths = [(executable as NSString).deletingLastPathComponent]

        if let target = resolvedSymlinkTarget(for: executable, fileManager: fileManager),
           let resolvedTarget = existingPath(target, fileManager: fileManager) {
            paths.append((resolvedTarget as NSString).deletingLastPathComponent)
            if let sdkRoot = googleCloudSDKRoot(for: resolvedTarget) {
                paths.append(sdkRoot)
            }
        }
        if let sdkRoot = googleCloudSDKRoot(for: executable) {
            paths.append(sdkRoot)
        }
        return uniquePaths(paths)
    }

    private static func resolvedSymlinkTarget(for path: String, fileManager: FileManager) -> String? {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: path),
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if target.hasPrefix("/") { return target }
        let base = (path as NSString).deletingLastPathComponent
        return (base as NSString).appendingPathComponent(target)
    }

    private static func googleCloudSDKRoot(for path: String) -> String? {
        let marker = "/google-cloud-sdk/"
        guard let range = path.range(of: marker) else { return nil }
        return String(path[..<path.index(before: range.upperBound)])
    }

    private static func appendExistingRemoteWorkspacePathGrant(
        _ rawPath: String,
        access: TaskLaunchResourceAccess,
        reason: String,
        homeDirectoryPath: String,
        fileManager: FileManager,
        hostPathGrants: inout [RuntimePathGrant],
        diagnostics: inout [RuntimeResourceDiagnostic],
        missingCode: String
    ) {
        guard let normalized = existingPath(rawPath, homeDirectoryPath: homeDirectoryPath, fileManager: fileManager) else {
            diagnostics.append(RuntimeResourceDiagnostic(
                severity: .warning,
                code: missingCode,
                message: "ASTRA could not project remote workspace SSH path because it does not exist: \(rawPath)",
                repairAction: "Review the workspace SSH connection settings or create the missing SSH file."
            ))
            return
        }
        hostPathGrants.append(RuntimePathGrant(
            path: normalized,
            access: access,
            source: .remoteWorkspace,
            reason: reason,
            sensitivity: .credential,
            lifetime: .run,
            exists: true
        ))
    }

    private static func appendOptionalRemoteWorkspacePathGrant(
        _ rawPath: String,
        access: TaskLaunchResourceAccess,
        reason: String,
        homeDirectoryPath: String,
        fileManager: FileManager,
        hostPathGrants: inout [RuntimePathGrant]
    ) {
        guard let normalized = existingPath(rawPath, homeDirectoryPath: homeDirectoryPath, fileManager: fileManager) else {
            return
        }
        hostPathGrants.append(RuntimePathGrant(
            path: normalized,
            access: access,
            source: .remoteWorkspace,
            reason: reason,
            sensitivity: .credential,
            lifetime: .run,
            exists: true
        ))
    }

    private static func existingPath(
        _ rawPath: String,
        homeDirectoryPath: String? = nil,
        fileManager: FileManager
    ) -> String? {
        let expanded = expandPath(rawPath, homeDirectoryPath: homeDirectoryPath)
        guard expanded.hasPrefix("/") else { return nil }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: isDirectory.boolValue).standardizedFileURL.path
    }

    private static func normalizedPath(_ path: String, homeDirectoryPath: String? = nil) -> String {
        URL(fileURLWithPath: expandPath(path, homeDirectoryPath: homeDirectoryPath)).standardizedFileURL.path
    }

    private static func expandPath(_ path: String, homeDirectoryPath: String?) -> String {
        guard let homeDirectoryPath else {
            return (path as NSString).expandingTildeInPath
        }
        if path == "~" { return homeDirectoryPath }
        if path.hasPrefix("~/") {
            return (homeDirectoryPath as NSString)
                .appendingPathComponent(String(path.dropFirst(2)))
        }
        return (path as NSString).expandingTildeInPath
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.map { normalizedPath($0) }.filter { seen.insert($0).inserted }
    }

    private static func uniqueRawPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }

    private static func uniqueHostPathGrants(_ grants: [RuntimePathGrant]) -> [RuntimePathGrant] {
        var seen: Set<String> = []
        return grants.filter { grant in
            seen.insert("\(grant.source.rawValue)|\(grant.access.rawValue)|\(grant.path)").inserted
        }
    }

    private static func uniqueContainerMounts(_ grants: [RuntimeContainerMountGrant]) -> [RuntimeContainerMountGrant] {
        var seen: Set<String> = []
        return grants.filter { grant in
            seen.insert("\(grant.hostPath)|\(grant.containerPath)|\(grant.access)|\(grant.role)").inserted
        }
    }

    private static func uniqueEnvironmentGrants(_ grants: [RuntimeEnvironmentGrant]) -> [RuntimeEnvironmentGrant] {
        var seen: Set<String> = []
        return grants.filter { grant in
            seen.insert("\(grant.source.rawValue)|\(grant.key)").inserted
        }
    }

    private static func uniqueCredentialGrants(_ grants: [RuntimeCredentialGrant]) -> [RuntimeCredentialGrant] {
        var seen: Set<String> = []
        return grants.filter { grant in
            seen.insert("\(grant.source.rawValue)|\(grant.label)").inserted
        }
    }

    private static func uniqueProviderRequirements(_ grants: [RuntimeProviderRequirement]) -> [RuntimeProviderRequirement] {
        var seen: Set<String> = []
        return grants.filter { grant in
            seen.insert("\(grant.source.rawValue)|\(grant.capability)").inserted
        }
    }
}
