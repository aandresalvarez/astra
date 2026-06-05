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
        uniqueSkills(directlyLinkedSkills + directlyLinkedConnectors.compactMap(\.skill) + directlyLinkedTools.compactMap(\.skill))
    }

    var linkedConnectors: [Connector] {
        uniqueConnectors(directlyLinkedConnectors + linkedSkills.flatMap(\.connectors))
    }

    var linkedTools: [LocalTool] {
        uniqueTools(directlyLinkedTools + linkedSkills.flatMap(\.localTools))
    }

    var isEnabled: Bool {
        if workspace.enabledCapabilityIDs.contains(package.id) {
            return true
        }

        if isProjectedResourceCapability {
            return linkedSkills.contains(where: isSkillEnabled)
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

    private var isProjectedResourceCapability: Bool {
        guard package.id.hasPrefix("skill.") else { return false }
        let kind = package.sourceMetadata?.kind
        return kind == "workspace" || kind == "shared"
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
        let activeLinkedConnectors = linkedConnectors
            .filter { connector in
                activeConnectorIDs.contains(connector.id) || isConnectorEnabled(connector)
            }
        let messages = missingPackageConnectorMessages(activeLinkedConnectors: activeLinkedConnectors)
            + activeLinkedConnectors.flatMap(readinessMessages(for:))

        return messages.isEmpty
            ? .ready
            : CapabilityReadiness(level: .needsAttention, messages: messages)
    }

    private func isSkillEnabled(_ skill: Skill) -> Bool {
        skill.isGlobal
            ? workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString)
            : workspace.skills.contains { $0.id == skill.id }
    }

    private var directlyLinkedSkills: [Skill] {
        let candidates = capabilities.workspaceSkills + capabilities.availableGlobalSkills
        let originMatches = candidates.filter {
            CapabilityResourceOrigin.isOwnedBy($0, packageID: package.id)
        }
        if !originMatches.isEmpty {
            return uniqueSkills(originMatches)
        }

        let packageSkillNames = Set(
            package.skills.map { CapabilityRuntimeResourceMatcher.normalizedName($0.name) }
                + [CapabilityRuntimeResourceMatcher.normalizedName(package.name)]
        )
        return uniqueSkills(candidates.filter { skill in
            packageSkillNames.contains(CapabilityRuntimeResourceMatcher.normalizedName(skill.name))
        })
    }

    private var directlyLinkedConnectors: [Connector] {
        let candidates = capabilities.workspaceConnectors + capabilities.availableGlobalConnectors
        let originMatches = candidates.filter {
            CapabilityResourceOrigin.isOwnedBy($0, packageID: package.id)
        }
        if !originMatches.isEmpty {
            return uniqueConnectors(originMatches)
        }

        let packageConnectorSpecs = package.connectors
        guard !packageConnectorSpecs.isEmpty else { return [] }
        return uniqueConnectors(candidates.filter { connector in
            packageConnectorSpecs.contains { CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector) }
        })
    }

    private var directlyLinkedTools: [LocalTool] {
        let candidates = capabilities.workspaceTools + capabilities.availableGlobalTools
        let originMatches = candidates.filter {
            CapabilityResourceOrigin.isOwnedBy($0, packageID: package.id)
        }
        if !originMatches.isEmpty {
            return uniqueTools(originMatches)
        }

        let packageToolSpecs = package.localTools
        guard !packageToolSpecs.isEmpty else { return [] }
        return uniqueTools(candidates.filter { tool in
            packageToolSpecs.contains { CapabilityRuntimeResourceMatcher.toolMatches($0, tool: tool) }
        })
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
        if connector.isStanfordOutlookMail {
            var messages: [String] = []
            if connector.outlookClientID.isEmpty {
                messages.append("\(name): missing Microsoft client ID")
            }
            if !connector.hasConfiguredOutlookTenantDomain {
                messages.append("\(name): missing tenant domain")
            }
            if !connector.hasOutlookRefreshToken {
                messages.append("\(name): not signed in")
            }
            return messages
        }

        let missing = connector.missingCredentialKeys()
        if !missing.isEmpty {
            return ["\(name): missing \(missing.joined(separator: ", "))"]
        }

        if connector.credentialKeys.isEmpty {
            return ["\(name): no credentials configured"]
        }

        return []
    }

    private func missingPackageConnectorMessages(activeLinkedConnectors: [Connector]) -> [String] {
        package.connectors.compactMap { packageConnector in
            let hasActiveConnector = activeLinkedConnectors.contains { connector in
                CapabilityRuntimeResourceMatcher.connectorMatches(packageConnector, connector: connector)
            }
            guard !hasActiveConnector else { return nil }
            let name = packageConnector.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name.isEmpty ? package.name : name): connector not active for this workspace"
        }
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
