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
            let config = "sandbox_permissions=[\"disk-full-read-access\"]"
            guard !updatedArguments.contains(config) else { return self }
            let insertIndex = updatedArguments.firstIndex(of: "--skip-git-repo-check")
                ?? max(0, updatedArguments.count - 1)
            updatedArguments.insert(contentsOf: ["--config", config], at: insertIndex)
            plannedFields["git_provider_native_read_access"] = "codex_disk_full_read"
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

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }
}
