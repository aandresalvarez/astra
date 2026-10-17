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
        let prerequisiteMessages = CapabilityHealthService.readinessMessages(
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
        let components = PluginManifestConverter.manifest(from: package).components
        for prerequisite in package.prerequisites {
            guard let status = statuses[prerequisite.id], !status.isUsable else { continue }
            // Repository access (SSO, an org grant) is repaired by the
            // contextual GitHub flow, not by signing in again.
            if GitHubRepositoryAccessRepairButton.supports(prerequisite, status: status) { continue }
            guard let component = components.first(where: { PluginManifestConverter.prerequisiteID(of: $0) == prerequisite.id })
            else { continue }
            if case .missingBinary = status {
                if let install = RepairAction.from(component, needsInstall: true) { return install }
                continue
            }
            if let repair = RepairAction.from(component) { return repair }
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
