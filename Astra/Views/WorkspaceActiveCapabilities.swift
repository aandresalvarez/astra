import Foundation
import ASTRACore
import ASTRAModels

/// The capabilities a workspace has on, as every screen that lists them must
/// show them: the right rail's Capabilities box and the workspace home's
/// Capabilities tab both read this one rule.
///
/// A capability is a catalog package (or a standalone skill shown as one),
/// listed when its activation says it is on. Reading the workspace's own
/// Skill, Connector and LocalTool rows instead misses a plugin that saves no
/// such row, such as GitHub, whose only component is a skill.
enum WorkspaceActiveCapabilities {
    struct Entry {
        let package: PluginPackage
        let state: CapabilityRailPackageSnapshotState
    }

    /// The enabled packages, in the catalog inventory's order. Callers sort.
    static func entries(
        workspace: Workspace,
        capabilities: WorkspaceCapabilities,
        catalogPackages: [PluginPackage],
        policyContext: CapabilityCatalogPolicyContext?
    ) -> [Entry] {
        let index = CapabilityRailWorkspaceResourceIndex(workspace: workspace, capabilities: capabilities)
        return CapabilityCatalogInventory.packages(
            catalogPackages: catalogPackages,
            capabilities: capabilities,
            policyContext: policyContext
        )
        .compactMap { package in
            let state = CapabilityRailPackageSnapshotState(package: package, index: index)
            return state.isEnabled ? Entry(package: package, state: state) : nil
        }
    }

    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveCompare("New Skill") == .orderedSame {
            return "Untitled Capability"
        }
        return trimmed
            .replacingOccurrences(of: " (Restored)", with: "")
            .replacingOccurrences(of: "(Restored)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One line of the workspace home's Capabilities tab.
struct WorkspaceHomeCapabilityRow: Equatable, Identifiable {
    let id: String
    let name: String
    let icon: String
    let summary: String

    /// The tab's rows from a catalog the caller loaded off the main actor
    /// (`ApprovedCapabilitiesSnapshot`, as the rail loads it), so nothing here
    /// reads the Capabilities or approvals folders.
    static func rows(
        workspace: Workspace,
        globalSkills: [Skill],
        globalConnectors: [Connector],
        globalTools: [LocalTool],
        catalog: ApprovedCapabilitiesSnapshot
    ) -> [WorkspaceHomeCapabilityRow] {
        let packages = catalog.packages.isEmpty ? PluginCatalog.builtInPackages : catalog.packages
        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools,
            packageDefinitions: packages,
            packPolicy: catalog.packPolicy
        )
        let policyContext = CapabilityCatalogPolicyContext.currentUser(
            workspace: workspace,
            approvalRecords: catalog.records,
            packPolicy: catalog.packPolicy
        )
        return rows(WorkspaceActiveCapabilities.entries(
            workspace: workspace,
            capabilities: capabilities,
            catalogPackages: packages,
            policyContext: policyContext
        ))
    }

    /// By name, as the rail's box orders its ready rows.
    static func rows(_ entries: [WorkspaceActiveCapabilities.Entry]) -> [WorkspaceHomeCapabilityRow] {
        entries
            .map { entry in
                WorkspaceHomeCapabilityRow(
                    id: entry.package.id,
                    name: WorkspaceActiveCapabilities.displayName(entry.package.name),
                    icon: entry.package.icon,
                    summary: CapabilityPackageResourceSummary(package: entry.package).contentSummary(separator: ", ")
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
