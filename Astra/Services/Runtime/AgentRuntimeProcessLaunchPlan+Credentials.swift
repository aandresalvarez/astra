import Foundation
import ASTRACore

extension AgentRuntimeProcessLaunchPlan {
    func addingGitCredentialContext(_ context: GitCredentialSandboxContext) -> AgentRuntimeProcessLaunchPlan {
        guard !context.isEmpty else { return self }
        var readable = sandboxReadablePaths
        readable.append(contentsOf: context.readablePaths)
        readable = Self.uniqueNonEmpty(readable)

        var plannedFields = commandPlannedFields
        plannedFields["git_credential_context"] = "true"
        plannedFields["git_credential_readable_path_count"] = String(context.readablePaths.count)
        plannedFields["git_credential_writable_path_count"] = String(context.writablePaths.count)
        plannedFields["git_credential_transports"] = context.transports.map(\.rawValue).joined(separator: ",")
        if !context.diagnostics.isEmpty {
            plannedFields["git_credential_diagnostics"] = context.diagnostics.joined(separator: ",")
        }

        return AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: parsesJSONLines,
            directoriesToCreate: directoriesToCreate,
            sandboxReadablePaths: readable,
            sandboxHomeStateAccess: sandboxHomeStateAccess,
            sandboxProtectedWriteDenyPaths: sandboxProtectedWriteDenyPaths,
            providerDetectedFields: providerDetectedFields,
            commandPlannedFields: plannedFields,
            interactiveAsk: interactiveAsk,
            pathMapper: pathMapper,
            executionEnvironment: executionEnvironment
        )
    }

    func enablingProviderNativeGitCredentialReads(
        for context: GitCredentialSandboxContext,
        permissionPolicy: PermissionPolicy
    ) -> AgentRuntimeProcessLaunchPlan {
        guard context.needsExternalCredentialAccess,
              permissionPolicy != .autonomous else {
            return self
        }

        var updatedArguments = arguments
        var plannedFields = commandPlannedFields
        switch runtime {
        case .codexCLI:
            return self
        case .copilotCLI:
            guard commandPlannedFields["supports_allow_all_paths"] == "true",
                  !updatedArguments.contains("--allow-all-paths") else {
                return self
            }
            updatedArguments.append("--allow-all-paths")
            plannedFields["git_provider_native_read_access"] = "copilot_allow_all_paths"
        default:
            return self
        }

        return AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: executablePath,
            arguments: updatedArguments,
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: parsesJSONLines,
            directoriesToCreate: directoriesToCreate,
            sandboxReadablePaths: sandboxReadablePaths,
            sandboxHomeStateAccess: sandboxHomeStateAccess,
            sandboxProtectedWriteDenyPaths: sandboxProtectedWriteDenyPaths,
            providerDetectedFields: providerDetectedFields,
            commandPlannedFields: plannedFields,
            interactiveAsk: interactiveAsk,
            pathMapper: pathMapper,
            executionEnvironment: executionEnvironment
        )
    }

    func unsupportedProviderNativeCredentialReadBlock(
        for launchResourcePlan: TaskLaunchResourcePlan,
        permissionPolicy: PermissionPolicy,
        workspaceCommandsRunInsideManagedExecutor: Bool
    ) -> AgentProcessResult? {
        guard launchResourcePlan.needsProviderNativeCredentialReadAccess,
              permissionPolicy != .autonomous,
              runtime == .codexCLI,
              !workspaceCommandsRunInsideManagedExecutor else {
            return nil
        }

        let message = """
        ASTRA blocked this Codex run because the task needs external Git or SSH credentials, but Codex restricted mode does not expose a read-only native path grant for those files. Switch to a runtime with supported path-scoped credential access, use autonomous mode only for a trusted workspace, or move the required credential material into an approved workspace-scoped setup before retrying.
        """
        return AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: "credential_native_access_unavailable",
            runtimeStopMessage: message
        )
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }
}
