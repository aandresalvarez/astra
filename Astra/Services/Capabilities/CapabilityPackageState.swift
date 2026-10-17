import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

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
    var secretStore: SecretStore = KeychainSecretStore()

    var linkedSkills: [Skill] {
        uniqueSkills(directlyLinkedSkills + directlyLinkedConnectors.compactMap(\.skill) + directlyLinkedTools.compactMap(\.skill))
    }

    var linkedConnectors: [Connector] {
        uniqueConnectors(directlyLinkedConnectors + linkedSkills.flatMap(\.connectors))
    }

    var linkedTools: [LocalTool] {
        uniqueTools(directlyLinkedTools + linkedSkills.flatMap(\.localTools))
    }

    /// The workspace's activation of this package. When there is one, it
    /// alone says whether the package is on and which rows it uses: its
    /// projection and its bound accounts, never rows matched by name.
    private var activation: PluginActivation? {
        WorkspaceCapabilityActivation.activation(for: package.id, in: workspace)
    }

    private var projection: PluginRuntimeProjection {
        PluginRuntimeProjection.project(workspace: workspace, packages: [package])
    }

    var isEnabled: Bool {
        if let activation {
            return activation.isEnabled
        }
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

        let activeConnectors = activeLinkedConnectors
        let messages = missingPackageConnectorMessages(activeLinkedConnectors: activeConnectors)
            + activeConnectors.flatMap(readinessMessages(for:))

        return messages.isEmpty
            ? .ready
            : CapabilityReadiness(level: .needsAttention, messages: messages)
    }

    var connectorsNeedingAttention: [Connector] {
        linkedConnectors.filter { !attentionMessages(for: $0).isEmpty }
    }

    /// Connectors an added plugin requires that have no row at all (deleted
    /// since): a pending step with nothing to edit, so Add sets it up again.
    var missingConnectors: [PluginConnector] {
        guard isEnabled else { return [] }
        return package.connectors.filter { required in
            !linkedConnectors.contains { CapabilityRuntimeResourceMatcher.connectorMatches(required, connector: $0) }
        }
    }

    func attentionMessages(for connector: Connector) -> [String] {
        guard isEnabled else { return [] }

        let activeConnectors = activeLinkedConnectors
        let missingConnectorMessages = package.connectors.compactMap { requiredConnector -> String? in
            guard CapabilityRuntimeResourceMatcher.connectorMatches(requiredConnector, connector: connector),
                  !activeConnectors.contains(where: {
                      CapabilityRuntimeResourceMatcher.connectorMatches(requiredConnector, connector: $0)
                  }) else { return nil }
            return missingConnectorMessage(for: requiredConnector)
        }
        let credentialMessages = activeConnectors.contains(where: { $0.id == connector.id })
            ? readinessMessages(for: connector) : []
        return missingConnectorMessages + credentialMessages + authMethodMessages(for: connector)
    }

    /// An account this plugin created whose sign-in method the current
    /// definition no longer declares keeps working until the person
    /// reconnects it, but has no setup or repair path: it needs a step.
    private func authMethodMessages(for connector: Connector) -> [String] {
        // The account's own component, from its binding; a loose match only
        // when it has none (two components of one service differ).
        let boundComponent = activation?.bindings.first { !$0.isDeleted && $0.account?.id == connector.id }?.componentID
        let spec = boundComponent.flatMap { id in package.connectors.first { CapabilityResourceOrigin.componentID(for: $0) == id } }
            ?? package.connectors.first { CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector) }
        guard connector.originPackageID == package.id, let spec,
              !spec.authMethod.isEmpty, spec.authMethod != connector.authMethod else { return [] }
        return ["\(connector.name): this version signs in with \(spec.authMethod); reconnect the account"]
    }

    private var activeLinkedConnectors: [Connector] {
        let activeConnectorIDs = Set(capabilities.activeConnectors.map(\.id))
        let hasActivation = activation != nil
        return linkedConnectors.filter { connector in
            activeConnectorIDs.contains(connector.id) || (!hasActivation && isConnectorEnabled(connector))
        }
    }

    private func isSkillEnabled(_ skill: Skill) -> Bool {
        skill.isGlobal
            ? workspace.enabledGlobalSkillIDs.contains(skill.id.uuidString)
            : workspace.skills.contains { $0.id == skill.id }
    }

    private var directlyLinkedSkills: [Skill] {
        if activation != nil { return projection.skills }
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
        if let activation {
            return uniqueConnectors(activation.bindings.filter { !$0.isDeleted }.compactMap(\.account))
        }
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
        if activation != nil { return projection.tools }
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
            return messages
        }

        if connector.credentialKeys.isEmpty {
            return ["\(name): no credentials configured"]
        }
        let missingKeys = connector.missingCredentialKeys(store: secretStore)
        if !missingKeys.isEmpty {
            return ["\(name): missing Keychain value: \(missingKeys.joined(separator: ", "))"]
        }

        return []
    }

    private func missingPackageConnectorMessages(activeLinkedConnectors: [Connector]) -> [String] {
        package.connectors.compactMap { packageConnector in
            let hasActiveConnector = activeLinkedConnectors.contains { connector in
                CapabilityRuntimeResourceMatcher.connectorMatches(packageConnector, connector: connector)
            }
            guard !hasActiveConnector else { return nil }
            return missingConnectorMessage(for: packageConnector)
        }
    }

    private func missingConnectorMessage(for connector: PluginConnector) -> String {
        let name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? package.name : name): connector not active for this workspace"
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
