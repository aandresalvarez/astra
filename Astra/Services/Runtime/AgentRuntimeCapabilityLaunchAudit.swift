import Foundation
import ASTRACore

enum AgentRuntimeCapabilityLaunchAudit {
    @MainActor
    static func logResolution(
        for task: AgentTask,
        runtime: AgentRuntimeID,
        phase: String,
        contextText: String
    ) {
        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: contextText)
        let buildInfo = AppBuildInfo.current
        AppLogger.audit(.capabilityResolved, category: "Worker", taskID: task.id, fields: [
            "runtime": runtime.rawValue,
            "phase": phase,
            "app_build": buildInfo.build,
            "app_version": buildInfo.version,
            "app_git_commit": buildInfo.gitCommit,
            "app_build_date": buildInfo.buildDate,
            "scope_pruned": String(scope.prunedForBrowserTask),
            "scope_excluded_skill_names": CapabilityAudit.compactNames(scope.excludedSkillNames),
            "workspace_id": task.workspace?.id.uuidString ?? "none",
            "workspace_enabled_capabilities_count": String(task.workspace?.enabledCapabilityIDs.count ?? 0),
            "workspace_enabled_capability_ids": CapabilityAudit.compactNames(task.workspace?.enabledCapabilityIDs ?? []),
            "workspace_enabled_global_skills_count": String(task.workspace?.enabledGlobalSkillIDs.count ?? 0),
            "workspace_enabled_global_connectors_count": String(task.workspace?.enabledGlobalConnectorIDs.count ?? 0),
            "workspace_enabled_global_tools_count": String(task.workspace?.enabledGlobalToolIDs.count ?? 0),
            "task_skill_count": String(task.skills.count),
            "task_skill_snapshot_count": String(task.skillSnapshots.count),
            "resolved_skill_count": String(scope.behaviorSkills.count),
            "connector_count": String(scope.connectors.count),
            "local_tool_count": String(scope.localTools.count),
            "skill_names": CapabilityAudit.compactNames(task.skills.map(\.name)),
            "resolved_skill_names": CapabilityAudit.compactNames(scope.behaviorSkills.map(\.name)),
            "connector_names": CapabilityAudit.compactNames(scope.connectors.map(\.name)),
            "connector_service_types": CapabilityAudit.compactNames(scope.connectors.map(\.serviceType)),
            "local_tool_names": CapabilityAudit.compactNames(scope.localTools.map(\.name))
        ], level: .debug, fieldMaxLength: 240)
    }

    @MainActor
    static func logGitHubCLIPreflightIfNeeded(
        for task: AgentTask,
        runtime: AgentRuntimeID,
        phase: String,
        contextText: String
    ) async {
        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: contextText)
        let hasGitHubTool = scope.localTools.contains { tool in
            tool.command.trimmingCharacters(in: .whitespacesAndNewlines) == "gh"
        }
        let hasGitHubSkill = scope.behaviorSkills.contains { skill in
            let name = skill.name.lowercased()
            return name.contains("github") || name.contains("git hub")
        }
        guard hasGitHubTool || hasGitHubSkill else { return }

        let gh = RuntimePathResolver.detectExecutablePath(named: "gh")
        var fields: [String: String] = [
            "source": "task_preflight",
            "phase": phase,
            "command": "gh",
            "matched_tool": String(hasGitHubTool),
            "matched_skill": String(hasGitHubSkill),
            "runtime": runtime.rawValue
        ]

        guard !gh.isEmpty, FileManager.default.isExecutableFile(atPath: gh) else {
            fields["result"] = "executable_missing"
            AppLogger.audit(.localToolTested, category: "Worker", taskID: task.id, fields: fields, level: .warning)
            return
        }

        fields["executable_path"] = gh
        let runner = ProcessBinaryRunner()
        let version = await runner.run(path: gh, args: ["--version"], timeout: 3, environment: nil)
        fields["version_result"] = runResultLabel(version)
        if version.isSuccess,
           let firstLine = version.stdout.split(separator: "\n").first {
            fields["version_summary"] = String(firstLine)
        }

        let auth = await runner.run(
            path: gh,
            args: ["auth", "status", "--hostname", "github.com"],
            timeout: 5,
            environment: nil
        )
        fields["auth_result"] = runResultLabel(auth, nonZeroExitLabel: "auth_failed")
        fields["result"] = auth.isSuccess ? "authenticated" : runResultLabel(auth, nonZeroExitLabel: "auth_failed")
        AppLogger.audit(
            .localToolTested,
            category: "Worker",
            taskID: task.id,
            fields: fields,
            level: auth.isSuccess ? .debug : .warning,
            fieldMaxLength: 220
        )
    }

    static func runResultLabel(_ result: RunResult, nonZeroExitLabel: String? = nil) -> String {
        switch result.outcome {
        case .exited(code: 0):
            return "success"
        case .exited(let code):
            return nonZeroExitLabel ?? "exit_\(code)"
        case .timedOut:
            return "timeout"
        case .cancelled:
            return "cancelled"
        case .launchFailed:
            return "launch_failed"
        }
    }
}
