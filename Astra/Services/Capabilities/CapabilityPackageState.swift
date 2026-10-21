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
        if isProjectedResourceCapability { return directlyLinkedSkills }
        return uniqueSkills(directlyLinkedSkills + directlyLinkedConnectors.compactMap(\.skill) + directlyLinkedTools.compactMap(\.skill))
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

    /// The activation's accounts by connector component, or nil without one.
    private var boundAccountIDs: [String: Set<UUID>]? {
        activation.map(Self.boundAccountIDs(of:))
    }

    static func boundAccountIDs(of activation: PluginActivation) -> [String: Set<UUID>] {
        var ids: [String: Set<UUID>] = [:]
        for binding in activation.bindings where !binding.isDeleted {
            guard let account = binding.account, !account.isDeleted else { continue }
            ids[binding.componentID, default: []].insert(account.id)
        }
        return ids
    }

    /// Whether `connector` serves the `required` component. With an
    /// activation only an account bound to that exact component does, as at
    /// runtime: two components of one service never share an account, and
    /// the projection leaves an unbound one out. Without one, any row of the
    /// same kind does.
    static func connector(
        _ connector: Connector,
        serves required: PluginConnector,
        boundAccountIDs: [String: Set<UUID>]?
    ) -> Bool {
        guard let boundAccountIDs else {
            return CapabilityRuntimeResourceMatcher.connectorMatches(required, connector: connector)
        }
        return boundAccountIDs[CapabilityResourceOrigin.componentID(for: required)]?.contains(connector.id) ?? false
    }

    var isEnabled: Bool {
        if let activation {
            return activation.isEnabled
        }
        // Explicit plugin enablement comes only from its activation or the
        // pending legacy membership. An authored namesake cannot turn it on.
        if !isProjectedResourceCapability {
            return WorkspaceCapabilityActivation.enabledPluginIDs(of: workspace).contains(package.id)
        }

        if isProjectedResourceCapability {
            return linkedSkills.contains(where: isSkillEnabled)
        }

        if linkedSkills.contains(where: isSkillEnabled) {
            return true
        }

        // A workspace's own account outlives its plugin (Remove keeps it), so
        // only a shared one turned on here says the package is on.
        if linkedConnectors.contains(where: { $0.isGlobal && isConnectorEnabled($0) }) {
            return true
        }

        if linkedTools.contains(where: isToolEnabled) {
            return true
        }

        return false
    }

    /// Whether this workspace's activation is on but accepted another
    /// definition than `package` (`PluginRuntimeProjection.awaitsUpdate`):
    /// the library holds one for every workspace, and until Add accepts this
    /// one nothing of the plugin runs here.
    var awaitsUpdate: Bool {
        guard let activation, activation.isEnabled else { return false }
        return PluginRuntimeProjection.awaitsUpdate(activation, to: package)
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
        if awaitsUpdate {
            return CapabilityReadiness(level: .needsAttention, messages: [PluginsSurfacePresentation.awaitsUpdateMessage])
        }

        let activeConnectors = activeLinkedConnectors
        // The same sign-in drift `attentionMessages` reports, so a component
        // that says reconnect never sits under a plugin that says ready.
        let messages = missingPackageConnectorMessages(activeLinkedConnectors: activeConnectors)
            + activeConnectors.flatMap(readinessMessages(for:))
            + linkedConnectors.flatMap(authMethodMessages(for:))

        return messages.isEmpty
            ? .ready
            : CapabilityReadiness(level: .needsAttention, messages: messages)
    }

    var connectorsNeedingAttention: [Connector] {
        linkedConnectors.filter { !attentionMessages(for: $0).isEmpty }
    }

    /// The account of `required`'s own component that needs attention, for
    /// that component's repair action. Matched by the component the account
    /// is bound to, never by service: two components of one service each
    /// get their own action (without an activation, any row of the kind).
    func connectorNeedingAttention(for required: PluginConnector) -> Connector? {
        let bound = boundAccountIDs
        return connectorsNeedingAttention.first { Self.connector($0, serves: required, boundAccountIDs: bound) }
    }

    /// Whether `required`'s component has no account at all (`missingConnectors`).
    func isMissing(_ required: PluginConnector) -> Bool {
        let componentID = CapabilityResourceOrigin.componentID(for: required)
        return missingConnectors.contains { CapabilityResourceOrigin.componentID(for: $0) == componentID }
    }

    /// Shared accounts among `connectorsNeedingAttention` that are off in
    /// this workspace: what they need first is turning on here, not a key.
    /// Credentials are checked once the account is active.
    var inactiveSharedConnectors: [Connector] {
        let active = Set(activeLinkedConnectors.map(\.id))
        return connectorsNeedingAttention.filter { $0.isGlobal && !active.contains($0.id) }
    }

    /// Connectors an added plugin requires that have no row at all (deleted
    /// since): a pending step with nothing to edit, so Add sets it up again.
    var missingConnectors: [PluginConnector] {
        guard isEnabled else { return [] }
        let bound = boundAccountIDs
        return package.connectors.filter { required in
            !linkedConnectors.contains { Self.connector($0, serves: required, boundAccountIDs: bound) }
        }
    }

    func attentionMessages(for connector: Connector) -> [String] {
        guard isEnabled else { return [] }

        let activeConnectors = activeLinkedConnectors
        let bound = boundAccountIDs
        let missingConnectorMessages = package.connectors.compactMap { requiredConnector -> String? in
            guard Self.connector(connector, serves: requiredConnector, boundAccountIDs: bound),
                  !activeConnectors.contains(where: {
                      Self.connector($0, serves: requiredConnector, boundAccountIDs: bound)
                  }) else { return nil }
            return missingConnectorMessage(for: requiredConnector)
        }
        let credentialMessages = activeConnectors.contains(where: { $0.id == connector.id })
            ? readinessMessages(for: connector) : []
        return missingConnectorMessages + credentialMessages + authMethodMessages(for: connector)
    }

    /// An account this plugin created whose sign-in method the current
    /// definition no longer declares stays bound but runs nothing until the
    /// person reconnects it (`PluginRuntimeProjection.signsInWithWithdrawnMethod`):
    /// it needs a step.
    private func authMethodMessages(for connector: Connector) -> [String] {
        // The account's own component, from its binding; a loose match only
        // when it has none (two components of one service differ).
        let boundComponents = Set(activation?.bindings.filter { !$0.isDeleted && $0.account?.id == connector.id }.map(\.componentID) ?? [])
        let specs = package.connectors.filter { spec in
            boundComponents.isEmpty ? CapabilityRuntimeResourceMatcher.connectorMatches(spec, connector: connector)
                : boundComponents.contains(CapabilityResourceOrigin.componentID(for: spec))
        }
        return specs.filter { PluginRuntimeProjection.signsInWithWithdrawnMethod(connector, spec: $0, package: package) }
            .map { "\(connector.name) (\($0.name)): this version signs in with \($0.authMethod); reconnect the account" }
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
        if isProjectedResourceCapability {
            guard let rowID = CapabilityInstaller.syntheticSkillRowID(of: package) else { return [] }
            return candidates.filter { $0.id == rowID }
        }
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
        if isProjectedResourceCapability { return [] }
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
        if isProjectedResourceCapability { return [] }
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
        let bound = boundAccountIDs
        return package.connectors.compactMap { packageConnector in
            let hasActiveConnector = activeLinkedConnectors.contains { connector in
                Self.connector(connector, serves: packageConnector, boundAccountIDs: bound)
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
