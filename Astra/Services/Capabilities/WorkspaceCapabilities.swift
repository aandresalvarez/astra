import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

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

    var activeSkills: [Skill] {
        uniqueSkills(workspaceSkills + enabledGlobalSkills + enabledPackageSkills)
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
                    || enabledPackageConnectorSpecs.contains {
                        CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector)
                    }
            }
            return connector.workspace?.id == workspace.id
        }
        return uniqueConnectors(workspaceConnectors + attached + enabledGlobalConnectors + enabledPackageConnectors)
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
        let attached = activeSkills.flatMap(\.localTools)
        return uniqueTools(workspaceTools + attached + enabledGlobalTools + enabledPackageTools)
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

    private var enabledPackageSkillSpecs: [PluginSkill] {
        enabledPackages.flatMap(\.skills)
    }

    private var enabledPackageConnectorSpecs: [PluginConnector] {
        enabledPackages.flatMap(\.connectors)
    }

    private var enabledPackageToolSpecs: [PluginLocalTool] {
        enabledPackages.flatMap(\.localTools)
    }

    private var enabledPackageSkills: [Skill] {
        let specs = enabledPackageSkillSpecs
        let candidates = workspaceSkills + availableGlobalSkills
        let directlyMatched = specs.isEmpty ? [] : candidates.filter { skill in
            specs.contains { CapabilityRuntimeResourceMatcher.skillMatches($0, skill: skill) }
        }
        let resourceOwners = (enabledPackageConnectors.compactMap(\.skill) + enabledPackageTools.compactMap(\.skill))
            .filter { skill in
                candidates.contains { $0.id == skill.id }
            }
        return uniqueSkills(directlyMatched + resourceOwners)
    }

    private var enabledPackageConnectors: [Connector] {
        let specs = enabledPackageConnectorSpecs
        guard !specs.isEmpty else { return [] }
        return sortedConnectors((workspaceConnectors + availableGlobalConnectors).filter { connector in
            specs.contains { CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector) }
        })
    }

    private var enabledPackageTools: [LocalTool] {
        let specs = enabledPackageToolSpecs
        guard !specs.isEmpty else { return [] }
        return sortedTools((workspaceTools + availableGlobalTools).filter { tool in
            specs.contains { CapabilityRuntimeResourceMatcher.toolMatches($0, tool: tool) }
        })
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
