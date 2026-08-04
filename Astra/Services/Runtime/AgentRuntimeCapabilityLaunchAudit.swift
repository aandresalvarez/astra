import Foundation
import ASTRACore
import ASTRAModels

enum AgentRuntimeCapabilityLaunchAudit {
    @MainActor
    static func logResolution(
        for task: AgentTask,
        runtime: AgentRuntimeID,
        phase: RunPhase,
        contextText: String,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil
    ) {
        let scope = capabilityResolutionSnapshot?.providerLaunch ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        ).providerLaunch
        let buildInfo = AppBuildInfo.current
        var fields = buildInfo.auditFields
        fields["runtime"] = runtime.rawValue
        fields["phase"] = phase.rawValue
        fields["scope_pruned"] = String(scope.prunedForBrowserTask)
        fields["scope_excluded_skill_names"] = CapabilityAudit.compactNames(scope.excludedSkillNames)
        fields["workspace_id"] = task.workspace?.id.uuidString ?? "none"
        fields["workspace_enabled_capabilities_count"] = String(task.workspace?.enabledCapabilityIDs.count ?? 0)
        fields["workspace_enabled_capability_ids"] = CapabilityAudit.compactNames(task.workspace?.enabledCapabilityIDs ?? [])
        fields["workspace_enabled_global_skills_count"] = String(task.workspace?.enabledGlobalSkillIDs.count ?? 0)
        fields["workspace_enabled_global_connectors_count"] = String(task.workspace?.enabledGlobalConnectorIDs.count ?? 0)
        fields["workspace_enabled_global_tools_count"] = String(task.workspace?.enabledGlobalToolIDs.count ?? 0)
        fields["task_skill_count"] = String(task.skills.count)
        fields["task_skill_snapshot_count"] = String(task.skillSnapshots.count)
        fields["resolved_skill_count"] = String(scope.behaviorSkills.count)
        fields["connector_count"] = String(scope.connectors.count)
        fields["local_tool_count"] = String(scope.localTools.count)
        fields["skill_names"] = CapabilityAudit.compactNames(task.skills.map(\.name))
        fields["resolved_skill_names"] = CapabilityAudit.compactNames(scope.behaviorSkills.map(\.name))
        fields["connector_names"] = CapabilityAudit.compactNames(scope.connectors.map(\.name))
        fields["connector_service_types"] = CapabilityAudit.compactNames(scope.connectors.map(\.serviceType))
        fields["local_tool_names"] = CapabilityAudit.compactNames(scope.localTools.map(\.name))
        AppLogger.audit(.capabilityResolved, category: "Worker", taskID: task.id, fields: fields, level: .debug, fieldMaxLength: 240)
    }

    @MainActor
    static func logGitHubCLIPreflightIfNeeded(
        for task: AgentTask,
        runtime: AgentRuntimeID,
        phase: RunPhase,
        contextText: String,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        repositoryStatus: HealthStatus?
    ) async {
        let scope = capabilityResolutionSnapshot?.providerLaunch ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        ).providerLaunch
        let hasGitHubTool = scope.localTools.contains { tool in
            tool.command.trimmingCharacters(in: .whitespacesAndNewlines) == "gh"
        }
        let hasGitHubSkill = scope.behaviorSkills.contains { skill in
            let name = skill.name.lowercased()
            return name.contains("github") || name.contains("git hub")
        }
        guard hasGitHubTool || hasGitHubSkill else { return }

        var fields: [String: String] = [
            "source": "task_preflight",
            "phase": phase.rawValue,
            "command": "gh",
            "matched_tool": String(hasGitHubTool),
            "matched_skill": String(hasGitHubSkill),
            "runtime": runtime.rawValue
        ]

        guard let repositoryStatus else {
            fields["result"] = "repository_status_not_checked"
            AppLogger.audit(.localToolTested, category: "Worker", taskID: task.id, fields: fields, level: .warning)
            return
        }

        let level: LogLevel
        switch repositoryStatus {
        case .healthy(let path, let summary):
            fields["executable_path"] = path
            fields["status_summary"] = summary
            fields["auth_result"] = "success"
            fields["result"] = "repository_ready"
            level = .debug
        case .unverified(let path, let detail):
            fields["executable_path"] = path
            fields["status_summary"] = detail
            fields["auth_result"] = "success"
            fields["result"] = detail.localizedCaseInsensitiveContains("no repository target")
                ? "authenticated_no_repository"
                : "repository_unverified"
            level = .warning
        case .unauthenticated(let detail):
            fields["status_summary"] = detail
            fields["auth_result"] = "auth_failed"
            fields["result"] = "auth_failed"
            level = .warning
        case .authorizationRequired(let detail, let authorizationURL):
            let requiresSAML = detail.localizedCaseInsensitiveContains("SAML")
            fields["status_summary"] = detail
            fields["auth_result"] = requiresSAML
                ? "saml_authorization_required"
                : "authorization_required"
            fields["result"] = requiresSAML
                ? "saml_authorization_required"
                : "repository_permission_required"
            fields["authorization_action_available"] = String(authorizationURL != nil)
            level = .warning
        case .unresponsive(let detail):
            fields["status_summary"] = detail
            fields["auth_result"] = "probe_failed"
            fields["result"] = "repository_probe_failed"
            level = .warning
        case .missingBinary:
            fields["auth_result"] = "not_checked"
            fields["result"] = "executable_missing"
            level = .warning
        }
        AppLogger.audit(
            .localToolTested,
            category: "Worker",
            taskID: task.id,
            fields: fields,
            level: level,
            fieldMaxLength: 220
        )
    }

    static func runResultLabel(_ result: RunResult, nonZeroExitLabel: String? = nil) -> String {
        switch result.outcome {
        case .exited(code: 0):
            "success"
        case .exited(let code):
            nonZeroExitLabel ?? "exit_\(code)"
        case .timedOut:
            "timeout"
        case .cancelled:
            "cancelled"
        case .launchFailed:
            "launch_failed"
        }
    }
}
