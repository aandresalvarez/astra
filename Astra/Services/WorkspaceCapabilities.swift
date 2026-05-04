import Foundation

struct WorkspaceCapabilities {
    let workspace: Workspace
    let globalSkills: [Skill]
    let globalConnectors: [Connector]
    let globalTools: [LocalTool]

    init(
        workspace: Workspace,
        globalSkills: [Skill] = [],
        globalConnectors: [Connector] = [],
        globalTools: [LocalTool] = []
    ) {
        self.workspace = workspace
        self.globalSkills = globalSkills
        self.globalConnectors = globalConnectors
        self.globalTools = globalTools
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
        uniqueSkills(workspaceSkills + enabledGlobalSkills)
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
        return uniqueConnectors(workspaceConnectors + attached + enabledGlobalConnectors)
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
        return uniqueTools(workspaceTools + attached + enabledGlobalTools)
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
