import Foundation
import ASTRACore

/// Builds a compact, always-present roster of the capabilities enabled for a
/// workspace.
///
/// Launch-time pruning trims a capability's verbose skill instructions from a
/// task's prompt when the task wording doesn't obviously call for it (focus).
/// The roster is the counterweight: it keeps the agent AWARE that the capability
/// exists and how to invoke it, even when the detailed instructions were pruned —
/// so the agent never silently concludes a capability is unavailable and gives up.
///
/// This is awareness only, not authorization. Actually running a capability's
/// command still goes through the normal permission/approval and sandbox layer,
/// which is where least privilege is enforced.
enum CapabilityRosterBuilder {
    static func roster(for workspace: Workspace?) -> String? {
        let packages = CapabilityRuntimeResourceMatcher.enabledPackages(for: workspace)
        guard !packages.isEmpty else { return nil }
        let lines = packages
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(line(for:))
        return """
        Workspace capabilities (enabled for this workspace — use when the task needs them):
        \(lines.joined(separator: "\n"))

        Use a capability whenever the task calls for it (running it may prompt for approval). If a capability you need is missing or not authenticated on this machine, tell the user how to fix it and stop — do not silently skip it or claim the work is impossible.
        """
    }

    private static func line(for package: PluginPackage) -> String {
        let purpose = package.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = invocationHint(for: package).map { " Invoke via \($0)." } ?? ""
        return "- \(package.name): \(purpose)\(suffix)"
    }

    private static func invocationHint(for package: PluginPackage) -> String? {
        if HostControlPlaneMCPProjection.packageUsesHostControlRuntime(package),
           let skill = package.skills.first {
            return "the \(skill.name) skill through ASTRA host-control MCP"
        }
        if let command = package.localTools.first(where: { !$0.command.isEmpty })?.command {
            return "`\(command)` (via the Bash tool)"
        }
        if let server = package.mcpServers.first {
            return "the \(server.displayName) MCP tools"
        }
        if let skill = package.skills.first {
            return "the \(skill.name) skill"
        }
        return nil
    }
}
