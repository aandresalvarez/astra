import Foundation
import ASTRACore
import ASTRAModels

struct WorkspaceCapabilities {
    let workspace: Workspace
    let globalSkills: [Skill]
    let globalConnectors: [Connector]
    let globalTools: [LocalTool]
    /// Preloaded catalog package definitions. When non-nil, package-derived
    /// resource resolution reads this in-memory list instead of scanning the
    /// Capabilities directory — this is what keeps SwiftUI `body` callers (the
    /// right rail) off the synchronous filesystem path on every re-evaluation.
    /// `nil` falls back to the filesystem-backed matcher cache for callers
    /// (runtime launch, tests) that have no preloaded list.
    let packageDefinitions: [PluginPackage]?
    let approvalRecords: [CapabilityApprovalRecord]?
    /// Optional pre-resolved pack policy paired with `packageDefinitions`.
    /// Body-path callers pass their cached policy here so capability resolution
    /// can apply pack visibility without triggering catalog I/O.
    let packPolicy: PackResolvedPolicy?

    init(
        workspace: Workspace,
        globalSkills: [Skill] = [],
        globalConnectors: [Connector] = [],
        globalTools: [LocalTool] = [],
        packageDefinitions: [PluginPackage]? = nil,
        approvalRecords: [CapabilityApprovalRecord]? = nil,
        packPolicy: PackResolvedPolicy? = nil
    ) {
        self.workspace = workspace
        self.globalSkills = globalSkills
        self.globalConnectors = globalConnectors
        self.globalTools = globalTools
        self.packageDefinitions = packageDefinitions
        self.approvalRecords = approvalRecords
        self.packPolicy = packPolicy
    }

    var workspaceSkills: [Skill] {
        sortedSkills(workspace.skills.filter { !$0.isGlobal && !$0.isSystemBuiltIn })
    }

    var enabledGlobalSkills: [Skill] {
        let enabledIDs = Set(workspace.enabledGlobalSkillIDs)
        return sortedSkills(globalSkills.filter {
            enabledIDs.contains($0.id.uuidString) && !$0.isSystemBuiltIn
        })
    }

    var availableGlobalSkills: [Skill] {
        sortedSkills(globalSkills.filter { globalSkill in
            !globalSkill.isSystemBuiltIn &&
            !workspaceSkills.contains { $0.id == globalSkill.id }
        })
    }

    /// A row an activation names as a component's override is on exactly
    /// while that activation is (the projection brings it in), so it never
    /// counts as one of the workspace's own. Lists still show it.
    var activeSkills: [Skill] {
        let overriding = WorkspaceCapabilityActivation.overridingRowIDs(of: workspace)
        return uniqueSkills(workspaceSkills.filter { !overriding.contains($0.id) } + enabledGlobalSkills + enabledPackageSkills)
    }

    var workspaceConnectors: [Connector] {
        sortedConnectors(workspace.connectors.filter { !$0.isGlobal })
    }

    var enabledGlobalConnectors: [Connector] {
        let enabledIDs = Set(workspace.enabledGlobalConnectorIDs)
        return sortedConnectors(globalConnectors.filter {
            enabledIDs.contains($0.id.uuidString)
        })
    }

    var availableGlobalConnectors: [Connector] {
        sortedConnectors(globalConnectors.filter { globalConnector in
            !workspaceConnectors.contains { $0.id == globalConnector.id }
        })
    }

    var activeConnectors: [Connector] {
        let enabledGlobalIDs = Set(workspace.enabledGlobalConnectorIDs)
        let attached = activeSkills.flatMap(\.connectors).filter { connector in
            if connector.isGlobal {
                return enabledGlobalIDs.contains(connector.id.uuidString)
            }
            return connector.workspace?.id == workspace.id
        }
        // An account bound to one of this workspace's plugins is in scope only
        // through its binding, so turning the plugin off takes it out.
        let boundAccountIDs = boundAccountIDs
        let authored = (workspaceConnectors + attached + enabledGlobalConnectors)
            .filter { !boundAccountIDs.contains($0.id) }
        return uniqueConnectors(authored + projection.connectors)
    }

    /// Connector rows bound as accounts to any of this workspace's
    /// activations, on or off.
    var boundAccountIDs: Set<UUID> {
        Set(WorkspaceCapabilityActivation.activations(of: workspace)
            .flatMap(\.bindings)
            .filter { !$0.isDeleted }
            .compactMap { $0.account?.id })
    }

    var workspaceTools: [LocalTool] {
        sortedTools(workspace.localTools.filter { !$0.isGlobal })
    }

    var enabledGlobalTools: [LocalTool] {
        let enabledIDs = Set(workspace.enabledGlobalToolIDs)
        return sortedTools(globalTools.filter {
            enabledIDs.contains($0.id.uuidString)
        })
    }

    var availableGlobalTools: [LocalTool] {
        sortedTools(globalTools.filter { globalTool in
            !workspaceTools.contains { $0.id == globalTool.id }
        })
    }

    var activeTools: [LocalTool] {
        let overriding = WorkspaceCapabilityActivation.overridingRowIDs(of: workspace)
        let ambient = (workspaceTools + activeSkills.flatMap(\.localTools)).filter { !overriding.contains($0.id) }
        return uniqueTools(ambient + enabledGlobalTools + projection.tools)
    }

    private var enabledPackages: [PluginPackage] {
        if let packageDefinitions {
            return CapabilityRuntimeResourceMatcher.enabledPackages(
                for: workspace,
                in: packageDefinitions,
                approvalRecords: approvalRecords,
                packPolicy: packPolicy
            )
        }
        return CapabilityRuntimeResourceMatcher.enabledPackages(
            for: workspace,
            approvalRecords: approvalRecords,
            packPolicy: packPolicy
        )
    }

    /// The enabled plugins' skills, tools and bound accounts, derived from
    /// this workspace's activations.
    var projection: PluginRuntimeProjection {
        PluginRuntimeProjection.project(workspace: workspace, packages: enabledPackages)
    }

    private var enabledPackageSkills: [Skill] {
        projection.skills
    }

    private func uniqueSkills(_ skills: [Skill]) -> [Skill] {
        var seen = Set<UUID>()
        return sortedSkills(skills.filter { seen.insert($0.id).inserted })
    }

    private func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        var seen = Set<UUID>()
        return sortedConnectors(connectors.filter { seen.insert($0.id).inserted })
    }

    private func uniqueTools(_ tools: [LocalTool]) -> [LocalTool] {
        var seen = Set<UUID>()
        return sortedTools(tools.filter { seen.insert($0.id).inserted })
    }

    private func sortedSkills(_ skills: [Skill]) -> [Skill] {
        skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortedConnectors(_ connectors: [Connector]) -> [Connector] {
        connectors.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortedTools(_ tools: [LocalTool]) -> [LocalTool] {
        tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
