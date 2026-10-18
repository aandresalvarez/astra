import Foundation
import ASTRACore

/// Permission diagnostics must not add an undeclared shell dependency to valid
/// minimal provider images. Probe the planned filesystem with read-only mounts,
/// no network, no capabilities, and no image entrypoint. The provider runs once.
enum RuntimeHomeAccessContainerPreflight {
    @MainActor
    static func prepare(
        _ original: AgentRuntimeProcessLaunchPlan,
        resumeSessionID: String?,
        runner: any BinaryRunner = ProcessBinaryRunner()
    ) async -> AgentRuntimeProcessLaunchPlan {
        guard !Task.isCancelled, original.executionEnvironment.providerRunsInsideContainer,
              let index = original.containerProviderCommandIndex,
              original.arguments.indices.contains(index), index > 0 else { return original }
        let image = original.arguments[index - 1]
        var probeArguments = ["run", "--rm", "--pull", "never", "--network", "none", "--read-only", "--cap-drop", "ALL",
                              "--security-opt", "no-new-privileges", "--workdir", "/", "--entrypoint", "/bin/sh"]
        if let user = original.executionEnvironment.user, !user.isEmpty { probeArguments += ["--user", user] }
        // A bare image can have /bin/sh while the actual mount plan hides it
        // (or a linked interpreter elsewhere). Use the validated final mounts,
        // without giving this observational probe any host write access.
        for mount in original.executionEnvironment.mounts {
            probeArguments += ["--mount", readOnlyBind(mount)]
        }
        let policy = AgentRuntimeAdapterRegistry.homeAccessPolicy(for: original.runtime)
        let needsOwnershipCheck = policy.roots.contains { $0.stateFiles.contains(where: \.requiresPrivateOwner) }
        let probe = needsOwnershipCheck ? "[ -O /proc/self ] && [ -r /proc/self/status ]" : "exit 0"
        probeArguments += ["--", image, "-c", probe]
        let path = original.executablePath, environment = original.environment
        let arguments = probeArguments
        let work = Task.detached(priority: .utility) {
            await runner.run(path: path, args: arguments, timeout: 5, environment: environment)
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        var plan = original
        guard result.isSuccess else {
            // A diagnostic cannot make a previously supported image unusable.
            // Preserve direct execution, and record that access was NOT verified.
            plan.commandPlannedFields["provider_home_access_check"] = "not_checked_shell_probe_failed"
            plan.commandPlannedFields["provider_home_access_probe_outcome"] = String(describing: result.outcome)
            AppLogger.audit(.runtimeCommandPlanned, category: "Runtime", fields: [
                "runtime": original.runtime.rawValue, "operation": "provider_home_access",
                "state": "not_checked_shell_probe_failed", "image": image
            ], level: .warning)
            return plan
        }
        plan.arguments = Array(original.arguments.prefix(index)) + RuntimeHomeAccessContainerCommand.command(
            runtime: original.runtime, executable: original.arguments[index],
            arguments: Array(original.arguments.dropFirst(index + 1)), resumeSessionID: resumeSessionID
        )
        plan.commandPlannedFields["provider_home_access_check"] = "container"
        plan.commandPlannedFields["docker_argument_count"] = String(plan.arguments.count)
        return plan
    }

    private static func readOnlyBind(_ mount: ExecutionEnvironmentMount) -> String {
        // Docker --mount is CSV; quoting the whole field preserves commas and
        // quotes in paths. Unlike --volume, it cannot create a missing host path.
        ["type=bind", "source=\(mount.hostPath)", "target=\(mount.containerPath)", "readonly"].map { field in
            field.contains(where: { ",\"\r\n".contains($0) })
                ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: ",")
    }
}
