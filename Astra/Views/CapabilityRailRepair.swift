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
            guard let component = components.first(where: { $0.kind == .setup && $0.name == prerequisite.displayName })
            else { continue }
            if case .missingBinary = status {
                if let install = RepairAction.from(component, needsInstall: true) { return install }
                continue
            }
            if let repair = RepairAction.from(component) { return repair }
        }
        return nil
    }
}
