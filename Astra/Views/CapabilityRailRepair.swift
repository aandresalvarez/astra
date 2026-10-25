import Foundation
import ASTRACore

/// The rail's readiness and repair for a capability package, kept out of
/// `WorkspaceRightRailView`, which is at its line budget.
enum CapabilityRailRepair {
    static func readiness(
        for package: PluginPackage,
        stateReadiness: CapabilityReadiness,
        prerequisiteStatuses: [String: HealthStatus]
    ) -> CapabilityReadiness {
        guard stateReadiness.level != .inactive else { return stateReadiness }
        let pending = package.prerequisites.filter { prerequisiteStatuses[$0.id] == nil }
            .map { "\($0.displayName): Checking prerequisite…" }
        let prerequisiteMessages = pending + CapabilityHealthService.readinessMessages(
            for: package,
            statuses: prerequisiteStatuses
        )
        guard !prerequisiteMessages.isEmpty else { return stateReadiness }
        let existingMessages = stateReadiness.level == .ready ? [] : stateReadiness.messages
        return CapabilityReadiness(
            level: .needsAttention,
            messages: existingMessages + prerequisiteMessages
        )
    }

    /// The repair for the package's first prerequisite that is checked and not
    /// usable: Install when its binary is missing, otherwise its sign-in or fix.
    /// Nil when every checked prerequisite works or none offers an action.
    static func repair(for package: PluginPackage, statuses: [String: HealthStatus]) -> RepairAction? {
        // Each prerequisite with its own component, by position: two may
        // share a check ID and still offer different repairs.
        for (prerequisite, component) in PluginManifestConverter.setupComponents(of: package) {
            // A check that never ran (`HealthCheckPolicy`) has nothing to repair.
            guard let status = statuses[prerequisite.id], !status.isUsable, !status.isNotChecked else { continue }
            // Repository access (SSO, an org grant) is repaired by the
            // contextual GitHub flow, not by signing in again.
            if GitHubRepositoryAccessRepairButton.supports(prerequisite, status: status) { continue }
            if let repair = RepairAction.from(component, status: status) { return repair }
        }
        return nil
    }

    /// True when a package's GitHub prerequisite fails its repository-access
    /// probe, which only the contextual repair (device sign-in for the
    /// repository, then its own probe) can fix.
    static func needsRepositoryAccessRepair(for package: PluginPackage, statuses: [String: HealthStatus]) -> Bool {
        package.prerequisites.contains { GitHubRepositoryAccessRepairButton.supports($0, status: statuses[$0.id]) }
    }
}
