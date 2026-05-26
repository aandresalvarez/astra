import Foundation
import ASTRACore

enum CapabilityAudit {
    static func packageFields(
        packageID: String,
        packageName: String,
        packageVersion: String,
        workspace: Workspace,
        source: String,
        skillsCount: Int,
        connectorsCount: Int,
        toolsCount: Int,
        templatesCount: Int = 0,
        governance: CapabilityGovernance? = nil
    ) -> [String: String] {
        var fields = [
            "source": source,
            "package_id": packageID,
            "package_name": packageName,
            "package_version": packageVersion,
            "workspace_id": workspace.id.uuidString,
            "skills_count": String(skillsCount),
            "connectors_count": String(connectorsCount),
            "tools_count": String(toolsCount),
            "templates_count": String(templatesCount)
        ]
        if let governance {
            fields.merge(governanceFields(governance), uniquingKeysWith: { _, new in new })
        }
        return fields
    }

    static func importJSONFailureFields(
        report: CapabilityPackageValidationReport,
        workspace: Workspace,
        traceID: String,
        result: String,
        errorType: String? = nil
    ) -> [String: String] {
        var fields = workspaceFields(workspace)
        fields["source"] = "import_json"
        fields["trace_id"] = traceID
        fields["result"] = result
        fields["blocker_count"] = String(report.blockers.count)
        fields["warning_count"] = String(report.warnings.count)
        if let sourceURL = report.sourceURL {
            fields["source_json_path"] = sourceURL.path
            fields["source_json_file"] = sourceURL.lastPathComponent
        }
        if let package = report.package {
            fields["package_id"] = package.id
            fields["package_name"] = package.name
            fields["package_version"] = package.version
            fields["skills_count"] = String(package.skills.count)
            fields["connectors_count"] = String(package.connectors.count)
            fields["tools_count"] = String(package.localTools.count)
            fields["templates_count"] = String(package.templates.count)
            fields.merge(governanceFields(package.governance), uniquingKeysWith: { _, new in new })
        }
        if let errorType {
            fields["error_type"] = errorType
        }
        return fields
    }

    static func governanceFields(_ governance: CapabilityGovernance) -> [String: String] {
        [
            "approval_status": governance.approvalStatus.rawValue,
            "risk_level": governance.riskLevel.rawValue,
            "visibility": governance.visibility.rawValue,
            "requires_admin_approval": String(governance.requiresAdminApproval),
            "requires_explicit_user_consent": String(governance.requiresExplicitUserConsent)
        ]
    }

    static func chatContextFields(
        source: String,
        workspace: Workspace?,
        availableSkills: [Skill],
        selectedSkills: [Skill],
        excludedSkillIDs: Set<UUID>
    ) -> [String: String] {
        var fields = workspaceFields(workspace)
        fields["source"] = source
        fields["available_skill_count"] = String(availableSkills.count)
        fields["selected_skill_count"] = String(selectedSkills.count)
        fields["excluded_skill_count"] = String(excludedSkillIDs.count)
        fields["available_skill_names"] = compactNames(availableSkills.map(\.name))
        fields["selected_skill_names"] = compactNames(selectedSkills.map(\.name))
        return fields
    }

    static func taskContextFields(source: String, task: AgentTask) -> [String: String] {
        let resolver = TaskCapabilityResolver(task: task)
        let connectors = resolver.allConnectors
        let tools = resolver.allLocalTools
        let skills = resolver.allBehaviorSkills
        var fields = workspaceFields(task.workspace)
        fields["source"] = source
        fields["runtime"] = task.resolvedRuntimeID.rawValue
        fields["task_skill_count"] = String(task.skills.count)
        fields["task_skill_snapshot_count"] = String(task.skillSnapshots.count)
        fields["resolved_skill_count"] = String(skills.count)
        fields["connector_count"] = String(connectors.count)
        fields["local_tool_count"] = String(tools.count)
        fields["skill_names"] = compactNames(task.skills.map(\.name))
        fields["resolved_skill_names"] = compactNames(skills.map(\.name))
        fields["connector_names"] = compactNames(connectors.map(\.name))
        fields["connector_service_types"] = compactNames(connectors.map(\.serviceType))
        fields["local_tool_names"] = compactNames(tools.map(\.name))
        return fields
    }

    static func workspaceFields(_ workspace: Workspace?) -> [String: String] {
        [
            "workspace_id": workspace?.id.uuidString ?? "none",
            "workspace_enabled_capabilities_count": String(workspace?.enabledCapabilityIDs.count ?? 0),
            "workspace_enabled_capability_ids": compactNames(workspace?.enabledCapabilityIDs ?? []),
            "workspace_enabled_global_skills_count": String(workspace?.enabledGlobalSkillIDs.count ?? 0),
            "workspace_enabled_global_connectors_count": String(workspace?.enabledGlobalConnectorIDs.count ?? 0),
            "workspace_enabled_global_tools_count": String(workspace?.enabledGlobalToolIDs.count ?? 0)
        ]
    }

    static func compactNames(_ names: [String], limit: Int = 8) -> String {
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "none" }
        let visible = cleaned.prefix(limit).joined(separator: ",")
        let hidden = cleaned.count - min(cleaned.count, limit)
        return hidden > 0 ? "\(visible),+\(hidden)" : visible
    }
}
