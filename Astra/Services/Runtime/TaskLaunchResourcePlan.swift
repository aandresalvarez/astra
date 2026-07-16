import Foundation
import ASTRACore

enum TaskLaunchResourceAccess: String, Codable, Sendable {
    case read
    case write
    case readWrite = "read_write"
}

enum TaskLaunchResourceSource: String, Codable, Sendable {
    case userAttachment = "user_attachment"
    case taskInput = "task_input"
    case workspace
    case remoteWorkspace = "remote_workspace"
    case gitCredential = "git_credential"
    case dockerEnvironment = "docker_environment"
    case dockerCredential = "docker_credential"
    case controlPlane = "control_plane"
    case connector
    case browser
    case provider
    case sandboxApproval = "sandbox_approval"
}

enum TaskLaunchResourceSensitivity: String, Codable, Sendable {
    case normal
    case credential
    case token
    case keychain
    case cloudAuth = "cloud_auth"
}

enum TaskLaunchResourceLifetime: String, Codable, Sendable {
    case run
    case task
    case workspace
}

struct RuntimePathGrant: Codable, Equatable, Sendable {
    var path: String
    var access: TaskLaunchResourceAccess
    var source: TaskLaunchResourceSource
    var reason: String
    var sensitivity: TaskLaunchResourceSensitivity
    var lifetime: TaskLaunchResourceLifetime
    var exists: Bool
}

struct RuntimeEnvironmentGrant: Codable, Equatable, Sendable {
    var key: String
    var source: TaskLaunchResourceSource
    var reason: String
    var sensitivity: TaskLaunchResourceSensitivity
    var valueProjected: Bool
}

struct RuntimeCredentialGrant: Codable, Equatable, Sendable {
    var label: String
    var source: TaskLaunchResourceSource
    var reason: String
    var projectedAsEnvironment: Bool
    var projectedAsFile: Bool
}

struct RuntimeContainerMountGrant: Codable, Equatable, Sendable {
    var hostPath: String
    var containerPath: String
    var access: String
    var role: String
}

struct RuntimeProviderRequirement: Codable, Equatable, Sendable {
    var capability: String
    var source: TaskLaunchResourceSource
    var reason: String
    var required: Bool
}

struct RuntimeControlPlaneResource: Codable, Equatable, Sendable {
    enum Readiness: String, Codable, Sendable {
        case ready
        case missing
        case unavailable
        case configured
    }

    var capability: String
    var source: TaskLaunchResourceSource
    var placement: String
    var readiness: Readiness
    var reason: String
    var failureText: String?
    var repairAction: String?
}

struct RuntimeResourceDiagnostic: Codable, Equatable, Sendable {
    enum Severity: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    var severity: Severity
    var code: String
    var message: String
    var repairAction: String?
}

struct RuntimeGitCredentialResource: Codable, Equatable, Sendable {
    var readablePaths: [String]
    var writablePaths: [String]
    var transports: [String]
    var diagnostics: [String]

    var sandboxContext: GitCredentialSandboxContext {
        GitCredentialSandboxContext(
            readablePaths: readablePaths,
            writablePaths: writablePaths,
            transports: transports.compactMap(GitCredentialContextResolver.RemoteTransport.init(rawValue:)),
            diagnostics: diagnostics
        )
    }
}

struct TaskLaunchResourcePlan: Codable, Equatable, Sendable {
    static let currentVersion = 4

    var version: Int
    var taskID: UUID
    var runID: UUID?
    var runtime: String
    var phase: RunPhase
    var workspacePath: String
    var executionEnvironmentID: String
    var executionEnvironmentKind: String
    var providerPlacement: String
    var workspaceCommandPlacement: String
    var controlPlaneToolPlacement: String
    var shellRoute: String
    var generatedAt: Date
    var hostPathGrants: [RuntimePathGrant]
    var containerMounts: [RuntimeContainerMountGrant]
    var environmentGrants: [RuntimeEnvironmentGrant]
    var credentialGrants: [RuntimeCredentialGrant]
    var providerRequirements: [RuntimeProviderRequirement]
    var controlPlaneResources: [RuntimeControlPlaneResource]
    var diagnostics: [RuntimeResourceDiagnostic]
    var gitCredential: RuntimeGitCredentialResource?

    init(
        version: Int = TaskLaunchResourcePlan.currentVersion,
        taskID: UUID,
        runID: UUID?,
        runtime: String,
        phase: RunPhase,
        workspacePath: String,
        executionEnvironmentID: String,
        executionEnvironmentKind: String,
        providerPlacement: String,
        workspaceCommandPlacement: String? = nil,
        controlPlaneToolPlacement: String? = nil,
        shellRoute: String? = nil,
        generatedAt: Date = Date(),
        hostPathGrants: [RuntimePathGrant] = [],
        containerMounts: [RuntimeContainerMountGrant] = [],
        environmentGrants: [RuntimeEnvironmentGrant] = [],
        credentialGrants: [RuntimeCredentialGrant] = [],
        providerRequirements: [RuntimeProviderRequirement] = [],
        controlPlaneResources: [RuntimeControlPlaneResource] = [],
        diagnostics: [RuntimeResourceDiagnostic] = [],
        gitCredential: RuntimeGitCredentialResource? = nil
    ) {
        self.version = version
        self.taskID = taskID
        self.runID = runID
        self.runtime = runtime
        self.phase = phase
        self.workspacePath = workspacePath
        self.executionEnvironmentID = executionEnvironmentID
        self.executionEnvironmentKind = executionEnvironmentKind
        self.providerPlacement = providerPlacement
        self.workspaceCommandPlacement = workspaceCommandPlacement
            ?? Self.defaultWorkspaceCommandPlacement(
                executionEnvironmentKind: executionEnvironmentKind
            )
        self.controlPlaneToolPlacement = controlPlaneToolPlacement
            ?? Self.defaultControlPlaneToolPlacement(
                executionEnvironmentKind: executionEnvironmentKind,
                providerPlacement: providerPlacement
            )
        self.shellRoute = shellRoute
            ?? Self.defaultShellRoute(
                executionEnvironmentKind: executionEnvironmentKind,
                providerPlacement: providerPlacement,
                workspaceCommandPlacement: self.workspaceCommandPlacement
            )
        self.generatedAt = generatedAt
        self.hostPathGrants = hostPathGrants
        self.containerMounts = containerMounts
        self.environmentGrants = environmentGrants
        self.credentialGrants = credentialGrants
        self.providerRequirements = providerRequirements
        self.controlPlaneResources = controlPlaneResources
        self.diagnostics = diagnostics
        self.gitCredential = gitCredential
    }

    var hostReadablePaths: [String] {
        uniquePaths(hostPathGrants.compactMap { grant in
            switch grant.access {
            case .read, .readWrite:
                grant.path
            case .write:
                nil
            }
        })
    }

    var hostWritablePaths: [String] {
        uniquePaths(hostPathGrants.compactMap { grant in
            switch grant.access {
            case .write, .readWrite:
                grant.path
            case .read:
                nil
            }
        })
    }

    var hostProtectedWriteDenyPaths: [String] {
        uniquePaths(hostPathGrants.compactMap { grant in
            grant.access == .read ? grant.path : nil
        })
    }

    var readOnlyResourceContract: ReadOnlyResourceContract {
        ReadOnlyResourceContract(grants: hostPathGrants)
    }

    var providerNativeCredentialReadablePaths: [String] {
        uniquePaths(hostPathGrants.compactMap { grant in
            guard requiresProviderNativeCredentialRead(for: grant) else { return nil }
            return grant.path
        })
    }

    var needsProviderNativeCredentialReadAccess: Bool {
        !providerNativeCredentialReadablePaths.isEmpty
    }

    /// Directories forwarded to a provider's own `--add-dir`-style native
    /// reachability grant (currently Codex only). This is intentionally
    /// scoped to `ReadOnlyResourceContract`'s read-only *input* sources, not
    /// every `.read` grant: Codex reads the filesystem ambiently regardless of
    /// `--add-dir` (read access cannot be restricted in its sandbox), but
    /// `--add-dir` grants that directory WRITE access. Forwarding a
    /// non-input read grant (e.g. a `.connector` support directory) here
    /// would make it Codex-writable without the read-only input boundary's
    /// forced Seatbelt wrap to deny that write back out.
    var providerNativeReadOnlyResourcePaths: [String] {
        uniquePaths(hostPathGrants.compactMap { grant in
            ReadOnlyResourceContract.isReadOnlyInputGrant(grant) ? grant.path : nil
        })
    }

    /// User-selected inputs remain a useful presentation subset, but execution
    /// enforcement is driven by `readOnlyResourceContract` above.
    var providerNativeReadOnlyInputPaths: [String] {
        uniquePaths(hostPathGrants.compactMap { grant in
            guard grant.access == .read,
                  grant.source == .taskInput || grant.source == .userAttachment else { return nil }
            return grant.path
        })
    }

    var gitCredentialSandboxContext: GitCredentialSandboxContext {
        gitCredential?.sandboxContext ?? .empty
    }

    var commandPlannedFields: [String: String] {
        var fields: [String: String] = [
            "launch_resource_manifest": "true",
            "launch_resource_host_readable_count": String(hostReadablePaths.count),
            "launch_resource_host_writable_count": String(hostWritablePaths.count),
            "launch_resource_container_mount_count": String(containerMounts.count),
            "launch_resource_environment_key_count": String(environmentGrants.count),
            "launch_resource_credential_label_count": String(credentialGrants.count),
            "launch_resource_provider_requirement_count": String(providerRequirements.count),
            "launch_resource_control_plane_count": String(controlPlaneResources.count),
            "launch_resource_diagnostic_count": String(diagnostics.count),
            "execution_environment": executionEnvironmentKind,
            "provider_placement": providerPlacement,
            "workspace_command_placement": workspaceCommandPlacement,
            "control_plane_tool_placement": controlPlaneToolPlacement,
            "shell_route": shellRoute
        ]

        fields["attachment_readable_path_count"] = String(uniquePaths(hostPathGrants.compactMap { grant in
            grant.source == .userAttachment || grant.source == .taskInput ? grant.path : nil
        }).count)
        fields["remote_workspace_readable_path_count"] = String(uniquePaths(hostPathGrants.compactMap { grant in
            guard grant.source == .remoteWorkspace else { return nil }
            switch grant.access {
            case .read, .readWrite:
                return grant.path
            case .write:
                return nil
            }
        }).count)
        fields["connector_readable_path_count"] = String(uniquePaths(hostPathGrants.compactMap { grant in
            guard grant.source == .connector else { return nil }
            switch grant.access {
            case .read, .readWrite:
                return grant.path
            case .write:
                return nil
            }
        }).count)
        fields["provider_native_credential_read_path_count"] = String(providerNativeCredentialReadablePaths.count)
        if let gitCredential {
            fields["git_credential_context"] = "true"
            fields["git_credential_readable_path_count"] = String(gitCredential.readablePaths.count)
            fields["git_credential_writable_path_count"] = String(gitCredential.writablePaths.count)
            fields["git_credential_transports"] = gitCredential.transports.joined(separator: ",")
            if !gitCredential.diagnostics.isEmpty {
                fields["git_credential_diagnostics"] = gitCredential.diagnostics.joined(separator: ",")
            }
        }
        if diagnostics.contains(where: { $0.severity == .error }) {
            fields["launch_resource_has_errors"] = "true"
        }
        return fields
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case taskID
        case runID
        case runtime
        case phase
        case workspacePath
        case executionEnvironmentID
        case executionEnvironmentKind
        case providerPlacement
        case workspaceCommandPlacement
        case controlPlaneToolPlacement
        case shellRoute
        case generatedAt
        case hostPathGrants
        case containerMounts
        case environmentGrants
        case credentialGrants
        case providerRequirements
        case controlPlaneResources
        case diagnostics
        case gitCredential
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        taskID = try container.decode(UUID.self, forKey: .taskID)
        runID = try container.decodeIfPresent(UUID.self, forKey: .runID)
        runtime = try container.decode(String.self, forKey: .runtime)
        phase = try container.decode(RunPhase.self, forKey: .phase)
        workspacePath = try container.decode(String.self, forKey: .workspacePath)
        executionEnvironmentID = try container.decode(String.self, forKey: .executionEnvironmentID)
        executionEnvironmentKind = try container.decode(String.self, forKey: .executionEnvironmentKind)
        providerPlacement = try container.decode(String.self, forKey: .providerPlacement)
        workspaceCommandPlacement = try container.decodeIfPresent(
            String.self,
            forKey: .workspaceCommandPlacement
        ) ?? Self.defaultWorkspaceCommandPlacement(
            executionEnvironmentKind: executionEnvironmentKind
        )
        controlPlaneToolPlacement = try container.decodeIfPresent(
            String.self,
            forKey: .controlPlaneToolPlacement
        ) ?? Self.defaultControlPlaneToolPlacement(
            executionEnvironmentKind: executionEnvironmentKind,
            providerPlacement: providerPlacement
        )
        shellRoute = try container.decodeIfPresent(String.self, forKey: .shellRoute)
            ?? Self.defaultShellRoute(
                executionEnvironmentKind: executionEnvironmentKind,
                providerPlacement: providerPlacement,
                workspaceCommandPlacement: workspaceCommandPlacement
            )
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        hostPathGrants = try container.decodeIfPresent([RuntimePathGrant].self, forKey: .hostPathGrants) ?? []
        containerMounts = try container.decodeIfPresent([RuntimeContainerMountGrant].self, forKey: .containerMounts) ?? []
        environmentGrants = try container.decodeIfPresent([RuntimeEnvironmentGrant].self, forKey: .environmentGrants) ?? []
        credentialGrants = try container.decodeIfPresent([RuntimeCredentialGrant].self, forKey: .credentialGrants) ?? []
        providerRequirements = try container.decodeIfPresent([RuntimeProviderRequirement].self, forKey: .providerRequirements) ?? []
        controlPlaneResources = try container.decodeIfPresent([RuntimeControlPlaneResource].self, forKey: .controlPlaneResources) ?? []
        diagnostics = try container.decodeIfPresent([RuntimeResourceDiagnostic].self, forKey: .diagnostics) ?? []
        gitCredential = try container.decodeIfPresent(RuntimeGitCredentialResource.self, forKey: .gitCredential)
    }

    private static func defaultWorkspaceCommandPlacement(
        executionEnvironmentKind: String
    ) -> String {
        executionEnvironmentKind == ExecutionEnvironmentKind.host.rawValue ? "host" : "docker"
    }

    private static func defaultShellRoute(
        executionEnvironmentKind: String,
        providerPlacement: String,
        workspaceCommandPlacement: String
    ) -> String {
        guard workspaceCommandPlacement == "docker" else { return "native_host" }
        return providerPlacement == ExecutionEnvironmentProviderPlacement.host.rawValue
            ? "astra_workspace_mcp"
            : "provider_inside_container"
    }

    private static func defaultControlPlaneToolPlacement(
        executionEnvironmentKind: String,
        providerPlacement: String
    ) -> String {
        guard executionEnvironmentKind != ExecutionEnvironmentKind.host.rawValue else {
            return "host"
        }
        return providerPlacement == ExecutionEnvironmentProviderPlacement.host.rawValue
            ? "host_capabilities"
            : "container"
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }

    private func requiresProviderNativeCredentialRead(for grant: RuntimePathGrant) -> Bool {
        switch grant.access {
        case .read, .readWrite:
            switch grant.source {
            case .gitCredential:
                return gitCredentialSandboxContext.needsExternalCredentialAccess
            case .remoteWorkspace:
                return true
            default:
                return false
            }
        case .write:
            return false
        }
    }
}
