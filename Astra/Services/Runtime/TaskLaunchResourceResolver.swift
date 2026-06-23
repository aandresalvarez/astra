import Foundation
import ASTRACore

enum TaskLaunchResourceResolver {
    typealias GitCredentialContextProvider = (String, AgentTask, String, String) -> GitCredentialSandboxContext

    static func resolve(
        task: AgentTask,
        runID: UUID?,
        runtime: AgentRuntimeID,
        phase: String,
        prompt: String,
        contextText: String,
        workspacePath: String,
        executionEnvironment: WorkspaceExecutionEnvironment? = nil,
        fileManager: FileManager = .default,
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

        appendExecutionEnvironmentGrants(
            environment,
            containerMounts: &containerMounts,
            environmentGrants: &environmentGrants,
            credentialGrants: &credentialGrants,
            providerRequirements: &providerRequirements,
            diagnostics: &diagnostics
        )

        appendCapabilityGrants(
            task: task,
            contextText: contextText,
            providerRequirements: &providerRequirements,
            environmentGrants: &environmentGrants,
            credentialGrants: &credentialGrants
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

    private static func appendExecutionEnvironmentGrants(
        _ environment: WorkspaceExecutionEnvironment,
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
        providerRequirements: inout [RuntimeProviderRequirement],
        environmentGrants: inout [RuntimeEnvironmentGrant],
        credentialGrants: inout [RuntimeCredentialGrant]
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

    private static func existingPath(_ rawPath: String, fileManager: FileManager) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: isDirectory.boolValue).standardizedFileURL.path
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.map(normalizedPath).filter { seen.insert($0).inserted }
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
