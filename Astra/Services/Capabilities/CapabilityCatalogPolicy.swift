import Foundation
import ASTRACore

struct CapabilityCatalogPolicyContext: Equatable, Sendable {
    var userRoleIDs: Set<String>
    var workspaceTags: Set<String>
    var isAdmin: Bool
    var currentAppVersion: SemanticVersion
    var installedPackageIDs: Set<String>
    var enabledPackageIDs: Set<String>
    var approvalRecords: [CapabilityApprovalRecord]

    init(
        userRoleIDs: Set<String> = [],
        workspaceTags: Set<String> = [],
        isAdmin: Bool = false,
        currentAppVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0),
        installedPackageIDs: Set<String> = [],
        enabledPackageIDs: Set<String> = [],
        approvalRecords: [CapabilityApprovalRecord] = []
    ) {
        self.userRoleIDs = Self.normalizedSet(userRoleIDs)
        self.workspaceTags = Self.normalizedSet(workspaceTags)
        self.isAdmin = isAdmin
        self.currentAppVersion = currentAppVersion
        self.installedPackageIDs = installedPackageIDs
        self.enabledPackageIDs = enabledPackageIDs
        self.approvalRecords = approvalRecords
    }

    private static func normalizedSet(_ values: Set<String>) -> Set<String> {
        Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    /// Policy context for the person using this ASTRA install. ASTRA is a
    /// single-user app today: the local user owns the machine and the
    /// approval store, so they are the admin of their own catalog. This is
    /// the ONLY place that assumption lives — a future multi-user or
    /// MDM-managed mode changes admin resolution here, not at call sites.
    /// Do not construct contexts with a literal `isAdmin: true` outside
    /// this factory (enforced by an architecture fitness test).
    static func currentUser(
        workspace: Workspace,
        currentAppVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0),
        approvalRecords: [CapabilityApprovalRecord]
    ) -> CapabilityCatalogPolicyContext {
        workspaceUser(
            workspace: workspace,
            isAdmin: true,
            currentAppVersion: currentAppVersion,
            approvalRecords: approvalRecords
        )
    }

    static func workspaceUser(
        workspace: Workspace,
        userRoleIDs: Set<String> = [],
        workspaceTags: Set<String> = [],
        isAdmin: Bool = false,
        currentAppVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0),
        approvalRecords: [CapabilityApprovalRecord] = []
    ) -> CapabilityCatalogPolicyContext {
        CapabilityCatalogPolicyContext(
            userRoleIDs: userRoleIDs,
            workspaceTags: workspaceTags,
            isAdmin: isAdmin,
            currentAppVersion: currentAppVersion,
            installedPackageIDs: workspace.installedPluginIDSet,
            enabledPackageIDs: Set(workspace.enabledCapabilityIDs),
            approvalRecords: approvalRecords
        )
    }

    static func currentUser(
        enabledPackageIDs: Set<String>,
        installedPackageIDs: Set<String>,
        currentAppVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0),
        approvalRecords: [CapabilityApprovalRecord]
    ) -> CapabilityCatalogPolicyContext {
        CapabilityCatalogPolicyContext(
            isAdmin: true,
            currentAppVersion: currentAppVersion,
            installedPackageIDs: installedPackageIDs,
            enabledPackageIDs: enabledPackageIDs,
            approvalRecords: approvalRecords
        )
    }
}

enum CapabilityCatalogBlocker: Equatable {
    case blockedApprovalStatus
    case draftRequiresApproval
    case adminApprovalRequired
    case hiddenFromUser
    case adminOnly
    case missingRole([String])
    case missingWorkspaceTag([String])
    case deprecatedForNewEnablement
    case appTooOld(required: String, current: String)
    case missingDependency(String)
    case conflictsWith(String)
    case approvalDigestMismatch
    case unsafeLocalTool(name: String, reason: String)
    case unsafeConnector(name: String, reason: String)
    case unsafeMCPServer(name: String, reason: String)

    var message: String {
        switch self {
        case .blockedApprovalStatus:
            return "Capability is blocked by catalog policy."
        case .draftRequiresApproval:
            return "Capability is still in draft review and requires approval."
        case .adminApprovalRequired:
            return "Capability requires admin approval."
        case .hiddenFromUser:
            return "Capability is hidden from this user."
        case .adminOnly:
            return "Capability is available to admins only."
        case .missingRole(let roles):
            return "Capability requires one of these roles: \(roles.joined(separator: ", "))."
        case .missingWorkspaceTag(let tags):
            return "Capability requires one of these workspace tags: \(tags.joined(separator: ", "))."
        case .deprecatedForNewEnablement:
            return "Capability is deprecated and cannot be newly enabled."
        case .appTooOld(let required, let current):
            return "Capability requires ASTRA \(required) or newer. Current version is \(current)."
        case .missingDependency(let dependency):
            return "Capability requires \(dependency) to be installed or enabled first."
        case .conflictsWith(let conflict):
            return "Capability conflicts with \(conflict)."
        case .approvalDigestMismatch:
            return "Capability contents changed after approval and require review again."
        case .unsafeLocalTool(let name, let reason):
            return "Local tool \(name) is unsafe: \(reason)."
        case .unsafeConnector(let name, let reason):
            return "Connector \(name) is unsafe: \(reason)."
        case .unsafeMCPServer(let name, let reason):
            return "MCP server \(name) is unsafe: \(reason)."
        }
    }
}

enum CapabilityCatalogWarning: Equatable {
    case deprecated
    case highRisk(CapabilityRiskLevel)
    case explicitUserConsentRequired

    var message: String {
        switch self {
        case .deprecated:
            return "Capability is deprecated. Existing use may continue, but new enablement is discouraged."
        case .highRisk(let risk):
            return "Capability is marked \(risk.rawValue) risk."
        case .explicitUserConsentRequired:
            return "Capability requires explicit user consent before use."
        }
    }
}

struct CapabilityCatalogDecision: Equatable {
    var governance: CapabilityGovernance
    var isVisible: Bool
    var canInstall: Bool
    var canEnable: Bool
    var canRun: Bool
    var requiresApproval: Bool
    var blockers: [CapabilityCatalogBlocker]
    var warnings: [CapabilityCatalogWarning]

    var blockerMessages: [String] {
        blockers.map(\.message)
    }

    /// Blockers that prevent enablement for reasons other than pending review.
    /// Draft / admin-approval / digest-mismatch gating is surfaced as
    /// "Needs attention" (an actionable approval step), so it must not be
    /// treated as a hard block. Any remaining blocker (explicitly blocked
    /// status, visibility scoping, unsafe tooling, version conflicts, etc.)
    /// genuinely prevents the user from acting and belongs in "Blocked".
    var hasNonApprovalBlockers: Bool {
        blockers.contains { blocker in
            switch blocker {
            case .draftRequiresApproval, .adminApprovalRequired, .approvalDigestMismatch:
                return false
            default:
                return true
            }
        }
    }
}

enum CapabilityCatalogPolicy {
    static func decision(
        for package: PluginPackage,
        context: CapabilityCatalogPolicyContext
    ) -> CapabilityCatalogDecision {
        let approvalEvaluation = effectiveGovernance(for: package, context: context)
        let governance = approvalEvaluation.governance
        let isEnabled = context.enabledPackageIDs.contains(package.id)
        var visibilityBlockers: [CapabilityCatalogBlocker] = []
        var operationalBlockers = approvalEvaluation.blockers
        var warnings: [CapabilityCatalogWarning] = []

        if governance.approvalStatus == .blocked {
            operationalBlockers.append(.blockedApprovalStatus)
            if !context.isAdmin {
                visibilityBlockers.append(.hiddenFromUser)
            }
        }

        switch governance.visibility {
        case .everyone:
            break
        case .hidden:
            visibilityBlockers.append(.hiddenFromUser)
        case .adminOnly:
            if !context.isAdmin {
                visibilityBlockers.append(.adminOnly)
            }
        case .roleScoped:
            let required = normalizedArray(governance.allowedRoles)
            if !context.isAdmin && !required.isEmpty && context.userRoleIDs.isDisjoint(with: Set(required)) {
                visibilityBlockers.append(.missingRole(required))
            }
        case .workspaceScoped:
            let required = normalizedArray(governance.allowedWorkspaceTags)
            if !context.isAdmin && !required.isEmpty && context.workspaceTags.isDisjoint(with: Set(required)) {
                visibilityBlockers.append(.missingWorkspaceTag(required))
            }
        }

        if governance.approvalStatus == .draft {
            operationalBlockers.append(.draftRequiresApproval)
        }

        if governance.requiresAdminApproval && !context.isAdmin {
            operationalBlockers.append(.adminApprovalRequired)
        }

        if governance.approvalStatus == .deprecated {
            warnings.append(.deprecated)
            if !isEnabled {
                operationalBlockers.append(.deprecatedForNewEnablement)
            }
        }

        if governance.riskLevel >= .high {
            warnings.append(.highRisk(governance.riskLevel))
        }
        if governance.requiresExplicitUserConsent {
            warnings.append(.explicitUserConsentRequired)
        }

        for blocker in package.installBlockers(
            appVersion: context.currentAppVersion,
            installedPluginIDs: context.installedPackageIDs.union(context.enabledPackageIDs)
        ) {
            switch blocker {
            case .appTooOld(let required, let current):
                operationalBlockers.append(.appTooOld(required: required, current: current))
            case .missingDependency(let dependency):
                operationalBlockers.append(.missingDependency(dependency))
            case .conflictsWith(let conflict):
                operationalBlockers.append(.conflictsWith(conflict))
            }
        }

        for tool in package.localTools {
            if let reason = LocalToolSecurityPolicy.unsafeInvocationReason(command: tool.command, arguments: tool.arguments) {
                operationalBlockers.append(.unsafeLocalTool(name: displayName(tool.name, fallback: tool.command), reason: reason))
            }
        }

        for connector in package.connectors {
            if let reason = ConnectorSecurityPolicy.credentialTransportViolation(
                baseURL: connector.baseURL,
                authMethod: connector.authMethod,
                credentialKeys: connector.credentialHints.map(\.key)
            ) {
                operationalBlockers.append(.unsafeConnector(name: displayName(connector.name, fallback: connector.serviceType), reason: reason))
            }
        }

        for server in package.mcpServers {
            if let reason = unsafeMCPServerReason(server) {
                operationalBlockers.append(.unsafeMCPServer(name: displayName(server.displayName, fallback: server.id), reason: reason))
            }
            if let nameReason = MCPEnvironmentKeyPolicy.invalidNameReason(server: server) {
                operationalBlockers.append(.unsafeMCPServer(
                    name: displayName(server.displayName, fallback: server.id),
                    reason: nameReason
                ))
            }
            let undeclared = MCPEnvironmentKeyPolicy.undeclaredKeys(server: server, package: package)
            if !undeclared.isEmpty {
                operationalBlockers.append(.unsafeMCPServer(
                    name: displayName(server.displayName, fallback: server.id),
                    reason: "requests environment keys the package does not declare (\(undeclared.joined(separator: ", ")))"
                ))
            }
        }

        let isVisible = visibilityBlockers.isEmpty
        let blockers = uniqueBlockers(visibilityBlockers + operationalBlockers)
        let canInstall = isVisible && blockers.isEmpty
        let canEnable = canInstall
        let runtimeBlockers = operationalBlockers.filter {
            if case .deprecatedForNewEnablement = $0 {
                return false
            }
            return true
        }
        let canRun = isVisible && isEnabled && runtimeBlockers.isEmpty
        let requiresApproval = governance.approvalStatus == .draft
            || governance.requiresAdminApproval
            || operationalBlockers.contains(.draftRequiresApproval)
            || operationalBlockers.contains(.adminApprovalRequired)
            || operationalBlockers.contains(.approvalDigestMismatch)

        return CapabilityCatalogDecision(
            governance: governance,
            isVisible: isVisible,
            canInstall: canInstall,
            canEnable: canEnable,
            canRun: canRun,
            requiresApproval: requiresApproval,
            blockers: blockers,
            warnings: uniqueWarnings(warnings)
        )
    }

    private static func effectiveGovernance(
        for package: PluginPackage,
        context: CapabilityCatalogPolicyContext
    ) -> (governance: CapabilityGovernance, blockers: [CapabilityCatalogBlocker]) {
        var governance = package.governance
        var blockers: [CapabilityCatalogBlocker] = []
        let versionRecords = context.approvalRecords.filter {
            $0.packageID == package.id && $0.packageVersion == package.version
        }
        guard !versionRecords.isEmpty else {
            return (governance, blockers)
        }
        guard let digest = try? CapabilityApprovalDigest.digest(for: package) else {
            blockers.append(.approvalDigestMismatch)
            return (governance, blockers)
        }
        guard let record = versionRecords.last(where: { $0.sourceDigest == digest }) else {
            blockers.append(.approvalDigestMismatch)
            return (governance, blockers)
        }

        governance.approvalStatus = record.status
        switch record.status {
        case .approved:
            governance.visibility = .everyone
            governance.requiresAdminApproval = false
            governance.requiresExplicitUserConsent = false
            governance.approvedBy = record.approvedBy
            governance.approvedAt = record.approvedAt
            governance.policyNotes = record.reviewNotes
        case .deprecated:
            governance.visibility = .everyone
            governance.requiresAdminApproval = false
            governance.approvedBy = record.approvedBy
            governance.approvedAt = record.approvedAt
            governance.policyNotes = record.reviewNotes
        case .blocked:
            governance.visibility = .everyone
            governance.requiresAdminApproval = true
            governance.approvedBy = record.approvedBy
            governance.approvedAt = record.approvedAt
            governance.policyNotes = record.reviewNotes
        case .draft:
            governance.requiresAdminApproval = true
        }
        return (governance, blockers)
    }

    private static func normalizedArray(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private static func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unsafeMCPServerReason(_ server: PluginMCPServer) -> String? {
        switch server.transport {
        case .stdio:
            let command = (server.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = LocalToolSecurityPolicy.unsafeInvocationReason(
                command: command,
                arguments: server.arguments.joined(separator: " ")
            ) {
                return reason
            }
        case .http, .sse:
            guard let url = server.url,
                  let scheme = url.scheme?.lowercased() else {
                return "remote MCP URL is missing or invalid"
            }
            if scheme == "https" {
                return nil
            }
            if scheme == "http", isLoopbackHost(url.host) {
                return nil
            }
            return "remote MCP URL must use HTTPS, except loopback HTTP for local development"
        }
        return nil
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "::1"
    }

    private static func uniqueBlockers(_ blockers: [CapabilityCatalogBlocker]) -> [CapabilityCatalogBlocker] {
        var unique: [CapabilityCatalogBlocker] = []
        for blocker in blockers where !unique.contains(blocker) {
            unique.append(blocker)
        }
        return unique
    }

    private static func uniqueWarnings(_ warnings: [CapabilityCatalogWarning]) -> [CapabilityCatalogWarning] {
        var unique: [CapabilityCatalogWarning] = []
        for warning in warnings where !unique.contains(warning) {
            unique.append(warning)
        }
        return unique
    }
}
