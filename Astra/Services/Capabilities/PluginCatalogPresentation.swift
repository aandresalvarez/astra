import Foundation
import ASTRACore

enum CatalogFocus: String {
    case all
    case skills
    case connectors
    case tools
    case templates

    var title: String {
        switch self {
        case .all: "Manage Capabilities"
        case .skills: "Manage Capabilities"
        case .connectors: "Manage Capabilities"
        case .tools: "Manage Capabilities"
        case .templates: "Manage Capabilities"
        }
    }

    var subtitle: String {
        switch self {
        case .all: "Approved capabilities for this workspace"
        case .skills: "Approved capabilities with skills"
        case .connectors: "Approved capabilities with connectors"
        case .tools: "Approved capabilities with tools"
        case .templates: "Approved capabilities with templates"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .all: "Search capabilities..."
        case .skills: "Search skill capabilities..."
        case .connectors: "Search connector capabilities..."
        case .tools: "Search tool capabilities..."
        case .templates: "Search template capabilities..."
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "No approved capabilities found"
        case .skills: "No approved skill capabilities found"
        case .connectors: "No approved connector capabilities found"
        case .tools: "No approved tool capabilities found"
        case .templates: "No approved template capabilities found"
        }
    }

    func matches(_ package: PluginPackage) -> Bool {
        switch self {
        case .all:
            true
        case .skills:
            !package.skills.isEmpty
        case .connectors:
            !package.connectors.isEmpty
        case .tools:
            !package.localTools.isEmpty
        case .templates:
            !package.templates.isEmpty
        }
    }
}

enum CapabilityManagementPresentation {
    case modal
    case embedded
}

enum CapabilityCatalogApprovalFilter: String, CaseIterable, Identifiable {
    case all
    case approved
    case draft
    case deprecated
    case blocked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Any approval"
        case .approved: "Approved"
        case .draft: "Draft"
        case .deprecated: "Deprecated"
        case .blocked: "Blocked"
        }
    }

    var status: CapabilityApprovalStatus? {
        switch self {
        case .all: nil
        case .approved: .approved
        case .draft: .draft
        case .deprecated: .deprecated
        case .blocked: .blocked
        }
    }
}

enum CapabilityCatalogRiskFilter: String, CaseIterable, Identifiable {
    case all
    case low
    case medium
    case high
    case restricted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Any risk"
        case .low: "Low risk"
        case .medium: "Medium risk"
        case .high: "High risk"
        case .restricted: "Restricted"
        }
    }

    var riskLevel: CapabilityRiskLevel? {
        switch self {
        case .all: nil
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .restricted: .restricted
        }
    }
}

struct CapabilityGalleryLayout {
    static func columnCount(for presentation: CapabilityManagementPresentation) -> Int {
        1
    }
}

struct PluginCatalogPresentationState {
    let focusedPackages: [PluginPackage]
    let filteredPackages: [PluginPackage]
    let groupedPackages: [CapabilityCatalogPackageGroup]
    let enabledCount: Int
    let categoryCounts: [String: Int]
    let visibleCategories: [String]
}

enum CapabilityCatalogPackageGroupKind: String, CaseIterable {
    case needsSetup
    case enabled
    case available
    case blocked

    var title: String {
        switch self {
        case .needsSetup: "Needs attention"
        case .enabled: "Enabled"
        case .available: "Available"
        case .blocked: "Blocked"
        }
    }

    var subtitle: String {
        switch self {
        case .needsSetup: "Configure or review before use"
        case .enabled: "Active in this workspace"
        case .available: "Ready to enable"
        case .blocked: "Unavailable until policy is resolved"
        }
    }
}

struct CapabilityCatalogPackageGroup {
    let kind: CapabilityCatalogPackageGroupKind
    let packages: [PluginPackage]
}

enum PluginCatalogSearch {
    static func matches(_ package: PluginPackage, query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return true }

        return package.name.lowercased().contains(normalizedQuery) ||
            package.description.lowercased().contains(normalizedQuery) ||
            package.contentSummary.lowercased().contains(normalizedQuery) ||
            package.tags.contains { $0.lowercased().contains(normalizedQuery) }
    }
}

enum CapabilityImportPresentation {
    static func overviewDescription(for package: PluginPackage, contentSummary _: String) -> String {
        let description = package.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "No description provided." : description
    }

    static func shouldShowContentSummary(for package: PluginPackage) -> Bool {
        !package.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum CapabilitySetupPresentation {
    static func fieldLabel(for key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = normalizedTokens(from: trimmed)
        guard !tokens.isEmpty else { return trimmed }

        let labelTokens = dropServicePrefix(from: tokens)
        guard !labelTokens.isEmpty else { return trimmed }

        return labelTokens.enumerated()
            .map { displayToken($0.element, position: $0.offset) }
            .joined(separator: " ")
    }

    static func fieldHelper(for key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return fieldLabel(for: trimmed) == trimmed ? nil : trimmed
    }

    static func baseURLLabel(for connector: PluginConnector) -> String {
        let service = connector.serviceType.lowercased()
        let name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.lowercased()
        if service.contains("jira") || normalizedName.contains("jira") {
            return "Jira site URL"
        }
        if service.contains("github") || normalizedName.contains("github") {
            return "GitHub API URL"
        }
        if service.contains("redcap") || normalizedName.contains("redcap") {
            return "REDCap API URL"
        }
        if service.contains("gcloud") || service.contains("google") || normalizedName.contains("google") {
            return "Google Cloud endpoint"
        }
        return name.isEmpty ? "Service URL" : "\(name) URL"
    }

    static func authMethodLabel(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "none":
            return "No auth"
        case "api_key", "apikey":
            return "API key"
        case "basic":
            return "Basic auth"
        case "bearer":
            return "Bearer token"
        case "oauth", "oauth2":
            return "OAuth"
        default:
            return fieldLabel(for: rawValue)
        }
    }

    static func credentialPlaceholder(for hint: PluginConnector.CredentialHint) -> String {
        let key = hint.key.lowercased()
        if key.contains("email") {
            return "name@company.com"
        }
        if key.contains("token") || key.contains("key") {
            return "Paste API token"
        }
        return hint.hint
    }

    static func configPlaceholder(for hint: PluginConnector.ConfigHint) -> String {
        let key = hint.key.lowercased()
        if hint.isList || key.contains("projects") {
            return "ENG, OPS"
        }
        if key.contains("region") {
            return "us-central1"
        }
        if key.contains("project") {
            return "Project ID"
        }
        return hint.hint
    }

    private static func normalizedTokens(from key: String) -> [String] {
        key.replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .split(separator: "_")
            .map { String($0).lowercased() }
    }

    private static func dropServicePrefix(from tokens: [String]) -> [String] {
        guard tokens.count > 1, servicePrefixes.contains(tokens[0]) else {
            return tokens
        }
        return Array(tokens.dropFirst())
    }

    private static func displayToken(_ token: String, position: Int) -> String {
        switch token {
        case "api":
            return "API"
        case "url", "uri":
            return "URL"
        case "id":
            return "ID"
        case "oauth":
            return "OAuth"
        case "ssh":
            return "SSH"
        case "sso":
            return "SSO"
        case "mfa":
            return "MFA"
        case "email":
            return "Email"
        case "token":
            return position == 0 ? "Token" : "token"
        case "key":
            return position == 0 ? "Key" : "key"
        default:
            return position == 0 ? token.capitalized : token
        }
    }

    private static let servicePrefixes: Set<String> = [
        "jira",
        "github",
        "gitlab",
        "google",
        "gcp",
        "gcloud",
        "redcap",
        "slack",
        "stanford",
        "microsoft",
        "graph",
        "azure",
        "aws",
        "openai"
    ]
}

enum PluginCatalogPresentation {
    static func makeState(
        packages: [PluginPackage],
        focus: CatalogFocus,
        selectedCategory: String?,
        approvalFilter: CapabilityCatalogApprovalFilter,
        riskFilter: CapabilityCatalogRiskFilter,
        showsNeedsAttentionOnly: Bool,
        showsEnabledOnly: Bool,
        searchText: String,
        policyContext: CapabilityCatalogPolicyContext,
        isEnabled: (PluginPackage) -> Bool,
        requiresSetup: (PluginPackage) -> Bool
    ) -> PluginCatalogPresentationState {
        let focused = packages.filter { focus.matches($0) }
        var categoryCounts: [String: Int] = [:]
        var visibleCategories: [String] = []
        for package in focused {
            categoryCounts[package.category, default: 0] += 1
            if categoryCounts[package.category] == 1 {
                visibleCategories.append(package.category)
            }
        }

        var filtered = focused
        if let selectedCategory {
            filtered = filtered.filter { $0.category == selectedCategory }
        }
        if let status = approvalFilter.status {
            filtered = filtered.filter { package in
                CapabilityCatalogPolicy.decision(for: package, context: policyContext).governance.approvalStatus == status
            }
        }
        if let riskLevel = riskFilter.riskLevel {
            filtered = filtered.filter { package in
                CapabilityCatalogPolicy.decision(for: package, context: policyContext).governance.riskLevel == riskLevel
            }
        }
        if showsNeedsAttentionOnly {
            filtered = filtered.filter { package in
                let decision = CapabilityCatalogPolicy.decision(for: package, context: policyContext)
                return !decision.blockers.isEmpty || !decision.warnings.isEmpty || requiresSetup(package)
            }
        }
        if showsEnabledOnly {
            filtered = filtered.filter { isEnabled($0) }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = filtered.filter { PluginCatalogSearch.matches($0, query: searchText) }
        }

        let enabledCount = focused.reduce(0) { count, package in
            count + (isEnabled(package) ? 1 : 0)
        }
        let groupedPackages = groupedCatalogPackages(
            filtered,
            policyContext: policyContext,
            isEnabled: isEnabled,
            requiresSetup: requiresSetup
        )

        return PluginCatalogPresentationState(
            focusedPackages: focused,
            filteredPackages: filtered,
            groupedPackages: groupedPackages,
            enabledCount: enabledCount,
            categoryCounts: categoryCounts,
            visibleCategories: visibleCategories
        )
    }

    private static func groupedCatalogPackages(
        _ packages: [PluginPackage],
        policyContext: CapabilityCatalogPolicyContext,
        isEnabled: (PluginPackage) -> Bool,
        requiresSetup: (PluginPackage) -> Bool
    ) -> [CapabilityCatalogPackageGroup] {
        var buckets: [CapabilityCatalogPackageGroupKind: [PluginPackage]] = [:]

        for package in packages {
            let decision = CapabilityCatalogPolicy.decision(for: package, context: policyContext)
            let kind: CapabilityCatalogPackageGroupKind
            if !decision.canEnable && !isEnabled(package) {
                kind = .blocked
            } else if isEnabled(package) {
                kind = .enabled
            } else if requiresSetup(package) || decision.requiresApproval || !decision.warnings.isEmpty {
                kind = .needsSetup
            } else {
                kind = .available
            }
            buckets[kind, default: []].append(package)
        }

        return CapabilityCatalogPackageGroupKind.allCases.compactMap { kind in
            guard let packages = buckets[kind], !packages.isEmpty else { return nil }
            return CapabilityCatalogPackageGroup(kind: kind, packages: packages)
        }
    }
}
