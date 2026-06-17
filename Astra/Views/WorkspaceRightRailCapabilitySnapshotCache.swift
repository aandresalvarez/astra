import Foundation
import ASTRACore

struct CapabilityRailSnapshotSignature: Hashable {
    let workspaceID: UUID
    let workspaceName: String
    let enabledCapabilityIDs: [String]
    let installedPluginIDs: [String]
    let installedPluginVersions: [String]
    let enabledGlobalSkillIDs: [String]
    let enabledGlobalConnectorIDs: [String]
    let enabledGlobalToolIDs: [String]
    let workspaceSkills: [CapabilityRailResourceSignature]
    let workspaceConnectors: [CapabilityRailResourceSignature]
    let workspaceTools: [CapabilityRailResourceSignature]
    let globalSkills: [CapabilityRailResourceSignature]
    let globalConnectors: [CapabilityRailResourceSignature]
    let globalTools: [CapabilityRailResourceSignature]
    let packages: [CapabilityRailPackageSignature]
    let approvalRecords: [CapabilityRailApprovalSignature]
    let prerequisiteStatuses: [CapabilityRailPrerequisiteStatusSignature]

    init(
        workspace: Workspace,
        globalSkills: [Skill],
        globalConnectors: [Connector],
        globalTools: [LocalTool],
        packages: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord],
        prerequisiteStatuses: [String: HealthStatus]
    ) {
        workspaceID = workspace.id
        workspaceName = workspace.name
        enabledCapabilityIDs = workspace.enabledCapabilityIDs.sorted()
        var installedPlugins: [(id: String, version: String)] = []
        for (index, id) in workspace.installedPluginIDs.enumerated() {
            let version = index < workspace.installedPluginVersions.count
                ? workspace.installedPluginVersions[index]
                : ""
            installedPlugins.append((id: id, version: version))
        }
        installedPlugins.sort { lhs, rhs in
            lhs.id == rhs.id ? lhs.version < rhs.version : lhs.id < rhs.id
        }
        installedPluginIDs = installedPlugins.map { $0.id }
        installedPluginVersions = installedPlugins.map { $0.version }
        enabledGlobalSkillIDs = workspace.enabledGlobalSkillIDs.sorted()
        enabledGlobalConnectorIDs = workspace.enabledGlobalConnectorIDs.sorted()
        enabledGlobalToolIDs = workspace.enabledGlobalToolIDs.sorted()
        workspaceSkills = workspace.skills.map(CapabilityRailResourceSignature.init(skill:)).sorted()
        workspaceConnectors = workspace.connectors.map(CapabilityRailResourceSignature.init(connector:)).sorted()
        workspaceTools = workspace.localTools.map(CapabilityRailResourceSignature.init(tool:)).sorted()
        self.globalSkills = globalSkills.map(CapabilityRailResourceSignature.init(skill:)).sorted()
        self.globalConnectors = globalConnectors.map(CapabilityRailResourceSignature.init(connector:)).sorted()
        self.globalTools = globalTools.map(CapabilityRailResourceSignature.init(tool:)).sorted()
        self.packages = packages.map(CapabilityRailPackageSignature.init(package:)).sorted()
        self.approvalRecords = approvalRecords.map(CapabilityRailApprovalSignature.init(record:)).sorted()
        self.prerequisiteStatuses = prerequisiteStatuses.map(CapabilityRailPrerequisiteStatusSignature.init(id:status:)).sorted()
    }
}

struct CapabilityRailResourceSignature: Hashable, Comparable {
    let id: UUID
    let kind: String
    let name: String
    let isGlobal: Bool
    let updatedAt: Date
    let relatedIDs: [UUID]
    let keySignature: [String]
    let originPackageID: String?
    let originPackageVersion: String?
    let originComponentID: String?

    init(skill: Skill) {
        id = skill.id
        kind = "skill"
        name = skill.name
        isGlobal = skill.isGlobal
        updatedAt = skill.updatedAt
        relatedIDs = (skill.connectors.map(\.id) + skill.localTools.map(\.id)).sorted { $0.uuidString < $1.uuidString }
        keySignature = (skill.allowedTools + skill.disallowedTools + skill.customTools + skill.environmentKeys).sorted()
        originPackageID = skill.originPackageID
        originPackageVersion = skill.originPackageVersion
        originComponentID = skill.originComponentID
    }

    init(connector: Connector) {
        id = connector.id
        kind = "connector"
        name = connector.name
        isGlobal = connector.isGlobal
        updatedAt = connector.updatedAt
        relatedIDs = connector.skill.map { [$0.id] } ?? []
        keySignature = ([connector.serviceType, connector.authMethod] + connector.credentialKeys + connector.configKeys).sorted()
        originPackageID = connector.originPackageID
        originPackageVersion = connector.originPackageVersion
        originComponentID = connector.originComponentID
    }

    init(tool: LocalTool) {
        id = tool.id
        kind = "tool"
        name = tool.name
        isGlobal = tool.isGlobal
        updatedAt = tool.updatedAt
        relatedIDs = tool.skill.map { [$0.id] } ?? []
        keySignature = [tool.toolType, tool.command, tool.arguments].sorted()
        originPackageID = tool.originPackageID
        originPackageVersion = tool.originPackageVersion
        originComponentID = tool.originComponentID
    }

    static func < (lhs: CapabilityRailResourceSignature, rhs: CapabilityRailResourceSignature) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct CapabilityRailPackageSignature: Hashable, Comparable {
    let id: String
    let version: String
    let name: String
    let category: String
    let sourceKind: String?
    let governanceStatus: String
    let resourceCounts: [Int]
    let requirementNames: [String]

    init(package: PluginPackage) {
        id = package.id
        version = package.version
        name = package.name
        category = package.category
        sourceKind = package.sourceMetadata?.kind
        governanceStatus = package.governance.approvalStatus.rawValue
        resourceCounts = [
            package.skills.count,
            package.connectors.count,
            package.localTools.count,
            package.templates.count,
            package.browserAdapters.count,
            package.prerequisites.count
        ]
        requirementNames = package.prerequisites.map(\.displayName).sorted()
    }

    static func < (lhs: CapabilityRailPackageSignature, rhs: CapabilityRailPackageSignature) -> Bool {
        lhs.id == rhs.id ? lhs.version < rhs.version : lhs.id < rhs.id
    }
}

struct CapabilityRailApprovalSignature: Hashable, Comparable {
    let id: String
    let status: String
    let approvedAt: Date

    init(record: CapabilityApprovalRecord) {
        id = record.id
        status = record.status.rawValue
        approvedAt = record.approvedAt
    }

    static func < (lhs: CapabilityRailApprovalSignature, rhs: CapabilityRailApprovalSignature) -> Bool {
        lhs.id == rhs.id ? lhs.approvedAt < rhs.approvedAt : lhs.id < rhs.id
    }
}

struct CapabilityRailPrerequisiteStatusSignature: Hashable, Comparable {
    let id: String
    let status: String

    init(id: String, status: HealthStatus) {
        self.id = id
        self.status = Self.statusSignature(status)
    }

    static func < (lhs: CapabilityRailPrerequisiteStatusSignature, rhs: CapabilityRailPrerequisiteStatusSignature) -> Bool {
        lhs.id < rhs.id
    }

    private static func statusSignature(_ status: HealthStatus) -> String {
        switch status {
        case .healthy(let path, let version):
            "healthy:\(path):\(version)"
        case .unauthenticated(let detail):
            "unauthenticated:\(detail)"
        case .unresponsive(let detail):
            "unresponsive:\(detail)"
        case .missingBinary:
            "missingBinary"
        }
    }
}

struct CapabilityRailSnapshotCache {
    private let capacity: Int
    private var snapshots: [CapabilityRailSnapshotSignature: CapabilityRailSnapshot] = [:]
    private var insertionOrder: [CapabilityRailSnapshotSignature] = []

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    func matches(_ signature: CapabilityRailSnapshotSignature) -> Bool {
        snapshots[signature] != nil
    }

    func snapshot(for signature: CapabilityRailSnapshotSignature) -> CapabilityRailSnapshot? {
        snapshots[signature]
    }

    mutating func store(_ snapshot: CapabilityRailSnapshot, for signature: CapabilityRailSnapshotSignature) {
        if snapshots[signature] == nil {
            insertionOrder.append(signature)
        }
        snapshots[signature] = snapshot
        while insertionOrder.count > capacity, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            snapshots.removeValue(forKey: oldest)
        }
    }
}

struct CapabilityRailWorkspaceResourceIndex {
    let enabledCapabilityIDs: Set<String>
    let enabledGlobalSkillIDs: Set<String>
    let enabledGlobalConnectorIDs: Set<String>
    let enabledGlobalToolIDs: Set<String>
    let workspaceSkillIDs: Set<UUID>
    let workspaceConnectorIDs: Set<UUID>
    let workspaceToolIDs: Set<UUID>
    let activeConnectorIDs: Set<UUID>
    let workspaceSkills: [Skill]
    let availableGlobalSkills: [Skill]
    let workspaceConnectors: [Connector]
    let availableGlobalConnectors: [Connector]
    let workspaceTools: [LocalTool]
    let availableGlobalTools: [LocalTool]

    init(workspace: Workspace, capabilities: WorkspaceCapabilities) {
        enabledCapabilityIDs = Set(workspace.enabledCapabilityIDs)
        enabledGlobalSkillIDs = Set(workspace.enabledGlobalSkillIDs)
        enabledGlobalConnectorIDs = Set(workspace.enabledGlobalConnectorIDs)
        enabledGlobalToolIDs = Set(workspace.enabledGlobalToolIDs)
        workspaceSkills = capabilities.workspaceSkills
        availableGlobalSkills = capabilities.availableGlobalSkills
        workspaceConnectors = capabilities.workspaceConnectors
        availableGlobalConnectors = capabilities.availableGlobalConnectors
        workspaceTools = capabilities.workspaceTools
        availableGlobalTools = capabilities.availableGlobalTools
        workspaceSkillIDs = Set(workspaceSkills.map(\.id))
        workspaceConnectorIDs = Set(workspaceConnectors.map(\.id))
        workspaceToolIDs = Set(workspaceTools.map(\.id))
        activeConnectorIDs = Set(capabilities.activeConnectors.map(\.id))
    }
}

struct CapabilityRailPackageSnapshotState {
    let linkedSkills: [Skill]
    let linkedConnectors: [Connector]
    let linkedTools: [LocalTool]
    let isEnabled: Bool
    let readiness: CapabilityReadiness

    init(package: PluginPackage, index: CapabilityRailWorkspaceResourceIndex) {
        let directSkills = Self.directlyLinkedSkills(for: package, index: index)
        let directConnectors = Self.directlyLinkedConnectors(for: package, index: index)
        let directTools = Self.directlyLinkedTools(for: package, index: index)
        let resolvedLinkedSkills = Self.uniqueSkills(
            directSkills + directConnectors.compactMap(\.skill) + directTools.compactMap(\.skill)
        )
        let resolvedLinkedConnectors = Self.uniqueConnectors(
            directConnectors + resolvedLinkedSkills.flatMap(\.connectors)
        )
        let resolvedLinkedTools = Self.uniqueTools(
            directTools + resolvedLinkedSkills.flatMap(\.localTools)
        )
        let resolvedIsEnabled = Self.isPackageEnabled(
            package,
            linkedSkills: resolvedLinkedSkills,
            linkedConnectors: resolvedLinkedConnectors,
            linkedTools: resolvedLinkedTools,
            index: index
        )
        let resolvedReadiness = Self.readiness(
            for: package,
            isEnabled: resolvedIsEnabled,
            linkedConnectors: resolvedLinkedConnectors,
            index: index
        )
        linkedSkills = resolvedLinkedSkills
        linkedConnectors = resolvedLinkedConnectors
        linkedTools = resolvedLinkedTools
        isEnabled = resolvedIsEnabled
        readiness = resolvedReadiness
    }

    private static func directlyLinkedSkills(
        for package: PluginPackage,
        index: CapabilityRailWorkspaceResourceIndex
    ) -> [Skill] {
        let candidates = index.workspaceSkills + index.availableGlobalSkills
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

    private static func directlyLinkedConnectors(
        for package: PluginPackage,
        index: CapabilityRailWorkspaceResourceIndex
    ) -> [Connector] {
        let candidates = index.workspaceConnectors + index.availableGlobalConnectors
        let originMatches = candidates.filter {
            CapabilityResourceOrigin.isOwnedBy($0, packageID: package.id)
        }
        if !originMatches.isEmpty {
            return uniqueConnectors(originMatches)
        }

        let packageConnectorSpecs = package.connectors
        guard !packageConnectorSpecs.isEmpty else { return [] }
        return uniqueConnectors(candidates.filter { connector in
            packageConnectorSpecs.contains {
                CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector)
            }
        })
    }

    private static func directlyLinkedTools(
        for package: PluginPackage,
        index: CapabilityRailWorkspaceResourceIndex
    ) -> [LocalTool] {
        let candidates = index.workspaceTools + index.availableGlobalTools
        let originMatches = candidates.filter {
            CapabilityResourceOrigin.isOwnedBy($0, packageID: package.id)
        }
        if !originMatches.isEmpty {
            return uniqueTools(originMatches)
        }

        let packageToolSpecs = package.localTools
        guard !packageToolSpecs.isEmpty else { return [] }
        return uniqueTools(candidates.filter { tool in
            packageToolSpecs.contains {
                CapabilityRuntimeResourceMatcher.toolMatches($0, tool: tool)
            }
        })
    }

    private static func isPackageEnabled(
        _ package: PluginPackage,
        linkedSkills: [Skill],
        linkedConnectors: [Connector],
        linkedTools: [LocalTool],
        index: CapabilityRailWorkspaceResourceIndex
    ) -> Bool {
        if index.enabledCapabilityIDs.contains(package.id) {
            return true
        }

        if isProjectedResourceCapability(package) {
            return linkedSkills.contains { isSkillEnabled($0, index: index) }
        }

        return linkedSkills.contains { isSkillEnabled($0, index: index) }
            || linkedConnectors.contains { isConnectorEnabled($0, index: index) }
            || linkedTools.contains { isToolEnabled($0, index: index) }
    }

    private static func readiness(
        for package: PluginPackage,
        isEnabled: Bool,
        linkedConnectors: [Connector],
        index: CapabilityRailWorkspaceResourceIndex
    ) -> CapabilityReadiness {
        guard isEnabled else { return .inactive }
        let activeLinkedConnectors = linkedConnectors.filter { connector in
            index.activeConnectorIDs.contains(connector.id) || isConnectorEnabled(connector, index: index)
        }
        let messages = missingPackageConnectorMessages(
            for: package,
            activeLinkedConnectors: activeLinkedConnectors
        ) + activeLinkedConnectors.flatMap(readinessMessages(for:))

        return messages.isEmpty
            ? .ready
            : CapabilityReadiness(level: .needsAttention, messages: messages)
    }

    private static func isProjectedResourceCapability(_ package: PluginPackage) -> Bool {
        guard package.id.hasPrefix("skill.") else { return false }
        let kind = package.sourceMetadata?.kind
        return kind == "workspace" || kind == "shared"
    }

    private static func isSkillEnabled(_ skill: Skill, index: CapabilityRailWorkspaceResourceIndex) -> Bool {
        skill.isGlobal
            ? index.enabledGlobalSkillIDs.contains(skill.id.uuidString)
            : index.workspaceSkillIDs.contains(skill.id)
    }

    private static func isConnectorEnabled(_ connector: Connector, index: CapabilityRailWorkspaceResourceIndex) -> Bool {
        connector.isGlobal
            ? index.enabledGlobalConnectorIDs.contains(connector.id.uuidString)
            : index.workspaceConnectorIDs.contains(connector.id)
    }

    private static func isToolEnabled(_ tool: LocalTool, index: CapabilityRailWorkspaceResourceIndex) -> Bool {
        tool.isGlobal
            ? index.enabledGlobalToolIDs.contains(tool.id.uuidString)
            : index.workspaceToolIDs.contains(tool.id)
    }

    private static func readinessMessages(for connector: Connector) -> [String] {
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

        return []
    }

    private static func missingPackageConnectorMessages(
        for package: PluginPackage,
        activeLinkedConnectors: [Connector]
    ) -> [String] {
        package.connectors.compactMap { packageConnector in
            let hasActiveConnector = activeLinkedConnectors.contains { connector in
                CapabilityRuntimeResourceMatcher.connectorMatches(packageConnector, connector: connector)
            }
            guard !hasActiveConnector else { return nil }
            let name = packageConnector.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name.isEmpty ? package.name : name): connector not active for this workspace"
        }
    }

    private static func uniqueSkills(_ skills: [Skill]) -> [Skill] {
        var seen = Set<UUID>()
        return skills
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        var seen = Set<UUID>()
        return connectors
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func uniqueTools(_ tools: [LocalTool]) -> [LocalTool] {
        var seen = Set<UUID>()
        return tools
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
