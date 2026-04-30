import Foundation
import ASTRACore

enum CapabilityReadinessLevel: Equatable {
    case inactive
    case ready
    case needsAttention
}

struct CapabilityReadiness: Equatable {
    var level: CapabilityReadinessLevel
    var messages: [String]

    static let inactive = CapabilityReadiness(level: .inactive, messages: ["Disabled"])
    static let ready = CapabilityReadiness(level: .ready, messages: ["Ready"])
}

struct CapabilityPackageState {
    let package: PluginPackage
    let workspace: Workspace
    let capabilities: WorkspaceCapabilities

    var linkedSkills: [Skill] {
        let packageSkillNames = Set(package.skills.map(\.name) + [package.name])
        return uniqueSkills((capabilities.workspaceSkills + capabilities.availableGlobalSkills).filter { skill in
            packageSkillNames.contains(skill.name)
        })
    }

    var linkedConnectors: [Connector] {
        let packageConnectorNames = Set(package.connectors.map(\.name))
        let packageConnectors = (capabilities.workspaceConnectors + capabilities.availableGlobalConnectors).filter { connector in
            packageConnectorNames.contains(connector.name)
        }
        return uniqueConnectors(packageConnectors + linkedSkills.flatMap(\.connectors))
    }

    var linkedTools: [LocalTool] {
        let packageToolNames = Set(package.localTools.map(\.name))
        let packageTools = (capabilities.workspaceTools + capabilities.availableGlobalTools).filter { tool in
            packageToolNames.contains(tool.name)
        }
        return uniqueTools(packageTools + linkedSkills.flatMap(\.localTools))
    }

    var isEnabled: Bool {
        if workspace.enabledCapabilityIDs.contains(package.id) {
            return true
        }

        if linkedSkills.contains(where: isSkillEnabled) {
            return true
        }

        if linkedConnectors.contains(where: isConnectorEnabled) {
            return true
        }

        if linkedTools.contains(where: isToolEnabled) {
            return true
        }

        return false
    }

    var skillIDStrings: Set<String> {
        Set(linkedSkills.map { $0.id.uuidString })
    }

    var connectorIDStrings: Set<String> {
        Set(linkedConnectors.map { $0.id.uuidString })
    }

    var toolIDStrings: Set<String> {
        Set(linkedTools.map { $0.id.uuidString })
    }

    var readiness: CapabilityReadiness {
        guard isEnabled else {
            return .inactive
        }

        let activeConnectorIDs = Set(capabilities.activeConnectors.map(\.id))
        let messages = linkedConnectors
            .filter { connector in
                activeConnectorIDs.contains(connector.id) || isConnectorEnabled(connector)
            }
            .flatMap(readinessMessages(for:))

        return messages.isEmpty
            ? .ready
            : CapabilityReadiness(level: .needsAttention, messages: messages)
    }

    private func isSkillEnabled(_ skill: Skill) -> Bool {
        skill.isGlobal
            ? workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString)
            : workspace.skills.contains { $0.id == skill.id }
    }

    private func isConnectorEnabled(_ connector: Connector) -> Bool {
        connector.isGlobal
            ? workspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString)
            : workspace.connectors.contains { $0.id == connector.id }
    }

    private func isToolEnabled(_ tool: LocalTool) -> Bool {
        tool.isGlobal
            ? workspace.enabledGlobalToolIDs.contains(tool.id.uuidString)
            : workspace.localTools.contains { $0.id == tool.id }
    }

    private func readinessMessages(for connector: Connector) -> [String] {
        guard connector.authMethod != "none" else { return [] }

        let name = connector.name.isEmpty ? "Connector" : connector.name
        let missing = connector.missingCredentialKeys()
        if !missing.isEmpty {
            return ["\(name): missing \(missing.joined(separator: ", "))"]
        }

        if connector.credentialKeys.isEmpty {
            return ["\(name): no credentials configured"]
        }

        return []
    }

    private func uniqueSkills(_ skills: [Skill]) -> [Skill] {
        var seen = Set<UUID>()
        return skills
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        var seen = Set<UUID>()
        return connectors
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueTools(_ tools: [LocalTool]) -> [LocalTool] {
        var seen = Set<UUID>()
        return tools
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
