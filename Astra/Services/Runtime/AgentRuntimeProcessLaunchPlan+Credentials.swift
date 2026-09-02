import Foundation
import ASTRACore

extension AgentRuntimeProcessLaunchPlan {
    /// Removes broker-owned credentials from the environment the child process
    /// will actually be given.
    ///
    /// `scopedEnvironmentVariables` already strips them, but it strips the
    /// *capability overlay*, and no runtime launches the overlay. Every adapter
    /// merges it into `RuntimeProcessEnvironment.enriched(...)`, which starts
    /// from `ProcessInfo.processInfo.environment` — so a developer build started
    /// from a shell that exports `JIRA_API_TOKEN` handed the agent the live
    /// token the broker exists to keep from it. Removing a key from the overlay
    /// says nothing about a key that was never in the overlay.
    ///
    /// Applied here, on the assembled plan, because this is the last point at
    /// which every runtime agrees: six adapters build environments six ways and
    /// all of them arrive at `AgentRuntimeProcessRunner` as one
    /// `AgentRuntimeProcessLaunchPlan`. Doing it per adapter would be six copies
    /// of a containment rule, and the seventh adapter would not have it.
    ///
    /// Idempotent, so applying it after the overlay strip costs a dictionary
    /// walk and changes nothing when the inherited environment is clean.
    @MainActor
    func strippingBrokeredConnectorEnvironment(
        capabilityScope: TaskCapabilityPromptScope
    ) -> AgentRuntimeProcessLaunchPlan {
        var strippedEnvironment = environment
        BrokeredConnectorEnvironment.strip(from: &strippedEnvironment, capabilityScope: capabilityScope)
        guard strippedEnvironment != environment else { return self }

        var plannedFields = commandPlannedFields
        plannedFields["brokered_env_keys_stripped_at_launch"] = String(
            environment.keys.filter { strippedEnvironment[$0] == nil }.count
        )

        var plan = AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: strippedEnvironment,
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
        plan.readOnlyBoundaryReceipt = readOnlyBoundaryReceipt
        plan.executionSandboxBoundaryReceipt = executionSandboxBoundaryReceipt
        return plan
    }

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

        var plan = AgentRuntimeProcessLaunchPlan(
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
        plan.readOnlyBoundaryReceipt = readOnlyBoundaryReceipt
        plan.executionSandboxBoundaryReceipt = executionSandboxBoundaryReceipt
        return plan
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

    func unsupportedProviderNativeReadOnlyFileBlock(
        permissionPolicy: PermissionPolicy,
        workspaceCommandsRunInsideManagedExecutor: Bool
    ) -> AgentProcessResult? {
        let count = Int(commandPlannedFields["provider_native_unreachable_read_only_file_count"] ?? "0") ?? 0
        guard count > 0,
              permissionPolicy != .autonomous,
              runtime == .codexCLI,
              !workspaceCommandsRunInsideManagedExecutor else {
            return nil
        }

        let message = """
        ASTRA blocked this Codex run because it needs an exact external file, but Codex restricted mode accepts only directory-level native grants. Granting the parent directory would expose sibling files that were never authorized. Attach the containing folder if every file in it is intended to be readable, use a Docker execution environment with the advertised container path, or switch to a runtime that supports exact-file reads.
        """
        return AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: "provider_native_file_read_unavailable",
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
