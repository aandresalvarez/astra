import Foundation
import ASTRACore
import ASTRAModels

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
    let categorySections: [CapabilityCatalogCategorySection]
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

struct CapabilityCatalogCategorySection {
    let category: String
    let packages: [PluginPackage]
    let statusGroups: [CapabilityCatalogPackageGroup]
}

enum CapabilityRowPresentation {
    /// Leading attention label for a capability row. Each branch reflects the
    /// concrete reason the row needs attention so we never claim "Setup
    /// required" for a draft that only needs approval or a package that only
    /// carries policy warnings. Returns `nil` when no attention is needed.
    static func attentionLabel(needsSetup: Bool, decision: CapabilityCatalogDecision) -> String? {
        if needsSetup {
            return "Setup required"
        }
        if decision.requiresApproval {
            return "Approval required"
        }
        if !decision.warnings.isEmpty {
            return "Policy warning"
        }
        return nil
    }
}

enum CapabilityBrandIcon: String, Equatable, CaseIterable {
    case github
    case jira
    case googleDrive
    case googleCloud
    case microsoft365

    init?(descriptorValue: String) {
        let normalized = CapabilityIconPresentation.normalized(descriptorValue)
        switch normalized {
        case "github":
            self = .github
        case "jira", "atlassian":
            self = .jira
        case "googledrive", "google-drive", "drive":
            self = .googleDrive
        case "googlecloud", "google-cloud", "gcloud":
            self = .googleCloud
        case "microsoft365", "microsoft-365", "office365", "graph":
            self = .microsoft365
        default:
            return nil
        }
    }
}

struct CapabilityIconPresentation: Equatable {
    enum Kind: Equatable {
        case systemSymbol(String)
        case brand(CapabilityBrandIcon)
        case asset(URL)
    }

    let kind: Kind
    let fallbackSystemName: String
    let monochromePreferred: Bool

    init(
        kind: Kind,
        fallbackSystemName: String,
        monochromePreferred: Bool = true
    ) {
        self.kind = kind
        self.fallbackSystemName = fallbackSystemName
        self.monochromePreferred = monochromePreferred
    }

    static func make(for package: PluginPackage) -> CapabilityIconPresentation {
        let explicitDescriptor = package.iconDescriptor == .systemSymbol(package.icon) ? nil : package.iconDescriptor
        return make(
            name: package.name,
            packageID: package.id,
            fallbackSystemName: package.icon,
            descriptor: explicitDescriptor,
            sourceURL: package.sourceMetadata?.url,
            tags: package.tags,
            browserAdapters: package.browserAdapters
        )
    }

    static func make(
        name: String,
        packageID: String? = nil,
        fallbackSystemName: String,
        descriptor: CapabilityIconDescriptor? = nil,
        sourceURL: URL? = nil,
        tags: [String] = [],
        browserAdapters: [String] = []
    ) -> CapabilityIconPresentation {
        let fallback = cleanSystemName(fallbackSystemName)
        if let descriptorPresentation = presentation(for: descriptor, fallback: fallback, sourceURL: sourceURL) {
            return descriptorPresentation
        }

        let normalizedName = normalized(name)
        let normalizedID = normalized(packageID ?? "")

        if isGitHubCapability(
            normalizedName: normalizedName,
            normalizedID: normalizedID,
            tags: tags,
            browserAdapters: browserAdapters
        ) {
            return CapabilityIconPresentation(kind: .brand(.github), fallbackSystemName: fallback)
        }
        if normalizedID == "jira-workflow" ||
            normalizedName.contains("jira") ||
            tags.contains(where: { normalized($0) == "jira" }) {
            return CapabilityIconPresentation(kind: .brand(.jira), fallbackSystemName: fallback)
        }
        if normalizedID == "google-drive-browser" ||
            normalizedName.contains("google drive") ||
            tags.contains(where: { normalized($0) == "googledrive" || normalized($0) == "drive" }) {
            return CapabilityIconPresentation(kind: .brand(.googleDrive), fallbackSystemName: fallback)
        }
        if normalizedID == "gcloud-workflow" ||
            normalizedName.contains("google cloud") ||
            tags.contains(where: { normalized($0) == "googlecloud" || normalized($0) == "gcloud" }) {
            return CapabilityIconPresentation(kind: .brand(.googleCloud), fallbackSystemName: fallback)
        }

        if normalizedName.contains("bigquery") {
            return CapabilityIconPresentation(kind: .systemSymbol("cylinder.split.1x2"), fallbackSystemName: fallback)
        }
        if normalizedName.contains("read-only") || normalizedName.contains("read only") {
            return CapabilityIconPresentation(kind: .systemSymbol("eye"), fallbackSystemName: fallback)
        }
        if normalizedName.contains("safe bash") {
            return CapabilityIconPresentation(kind: .systemSymbol("terminal"), fallbackSystemName: fallback)
        }

        return CapabilityIconPresentation(kind: .systemSymbol(fallback), fallbackSystemName: fallback)
    }

    var legacySystemName: String {
        switch kind {
        case .systemSymbol(let name):
            name
        case .brand, .asset:
            fallbackSystemName
        }
    }

    private static func isGitHubCapability(
        normalizedName: String,
        normalizedID: String,
        tags: [String],
        browserAdapters: [String]
    ) -> Bool {
        if normalizedID == "github-workflow" {
            return true
        }
        if normalizedName == "github" || normalizedName.contains("github ") || normalizedName.contains("github-") {
            return true
        }
        if tags.contains(where: { normalized($0) == "github" }) {
            return true
        }
        return browserAdapters.contains { normalized($0) == "github" }
    }

    private static func presentation(
        for descriptor: CapabilityIconDescriptor?,
        fallback: String,
        sourceURL: URL?
    ) -> CapabilityIconPresentation? {
        guard let descriptor else { return nil }
        let descriptorFallback = cleanSystemName(descriptor.fallbackSystemName)
        switch descriptor.kind {
        case .systemSymbol:
            return CapabilityIconPresentation(
                kind: .systemSymbol(cleanSystemName(descriptor.value)),
                fallbackSystemName: descriptorFallback
            )
        case .brand:
            guard let brand = CapabilityBrandIcon(descriptorValue: descriptor.value) else {
                return nil
            }
            return CapabilityIconPresentation(kind: .brand(brand), fallbackSystemName: descriptorFallback)
        case .asset:
            guard let assetURL = assetURL(relativePath: descriptor.value, sourceURL: sourceURL) else {
                return CapabilityIconPresentation(kind: .systemSymbol(descriptorFallback), fallbackSystemName: descriptorFallback)
            }
            return CapabilityIconPresentation(
                kind: .asset(assetURL),
                fallbackSystemName: descriptorFallback,
                monochromePreferred: descriptor.monochromePreferred
            )
        }
    }

    private static func assetURL(relativePath: String, sourceURL: URL?) -> URL? {
        guard let sourceURL,
              let normalized = CapabilityIconAssetPolicy.normalizedRelativePath(relativePath) else {
            return nil
        }
        let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let rootURL = isDirectory ? sourceURL : sourceURL.deletingLastPathComponent()
        let url = rootURL.appendingPathComponent(normalized, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func cleanSystemName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "puzzlepiece.extension" : trimmed
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
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
    static let actionTitle = "Import Capability"

    static func overviewDescription(for package: PluginPackage, contentSummary _: String) -> String {
        let description = package.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "No description provided." : description
    }

    static func shouldShowContentSummary(for package: PluginPackage) -> Bool {
        !package.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum CapabilityCreationPresentation {
    static let menuTitle = "New Capability"
    static let blankCapabilityTitle = "Blank Capability"
    static let mcpCapabilityTitle = "Create from MCP..."
    static let pasteSheetTitle = "Create from MCP"
    static let pasteSheetSubtitle = "Paste an MCP package command, registry target, server URL, or server JSON. ASTRA will prepare a draft capability for review."
    static let menuHelp = "Create a blank capability or start from an MCP package command, URL, or server JSON."
    static let primaryActionTitles = [CapabilityImportPresentation.actionTitle, menuTitle]
    static let mcpPasteSheetWidth = 560
    static let mcpPasteSheetMinimumHeight = 430
    static let mcpPasteTextEditorMinimumHeight = 150
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
        let categorySections = categoryCatalogSections(
            filtered,
            policyContext: policyContext,
            isEnabled: isEnabled,
            requiresSetup: requiresSetup
        )

        return PluginCatalogPresentationState(
            focusedPackages: focused,
            filteredPackages: filtered,
            groupedPackages: groupedPackages,
            categorySections: categorySections,
            enabledCount: enabledCount,
            categoryCounts: categoryCounts,
            visibleCategories: visibleCategories
        )
    }

    private static func categoryCatalogSections(
        _ packages: [PluginPackage],
        policyContext: CapabilityCatalogPolicyContext,
        isEnabled: (PluginPackage) -> Bool,
        requiresSetup: (PluginPackage) -> Bool
    ) -> [CapabilityCatalogCategorySection] {
        var buckets: [String: [PluginPackage]] = [:]
        var categories: [String] = []

        for package in packages {
            if buckets[package.category] == nil {
                categories.append(package.category)
            }
            buckets[package.category, default: []].append(package)
        }

        return categories.compactMap { category in
            guard let packages = buckets[category], !packages.isEmpty else { return nil }
            let statusGroups = groupedCatalogPackages(
                packages,
                policyContext: policyContext,
                isEnabled: isEnabled,
                requiresSetup: requiresSetup
            )
            return CapabilityCatalogCategorySection(
                category: category,
                packages: statusGroups.flatMap(\.packages),
                statusGroups: statusGroups
            )
        }
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
            if isEnabled(package) {
                kind = .enabled
            } else if decision.hasNonApprovalBlockers {
                // Only genuine, non-approval blockers count as "Blocked". Draft
                // and admin-approval packages set canEnable == false but are
                // actionable via approval, so they fall through to "Needs
                // attention" below instead of being misclassified here.
                kind = .blocked
            } else if requiresSetup(package) || decision.requiresApproval || !decision.warnings.isEmpty {
                kind = .needsSetup
            } else if !decision.canEnable {
                kind = .blocked
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

/// Memoizes the pure catalog presentation projection without becoming another
/// owner of catalog or workspace state. The small key contains presentation
/// controls and explicit durable-source revisions only. SwiftUI body
/// evaluation never fingerprints, sorts, serializes, or registers observers.
@MainActor
@Observable
final class PluginCatalogPresentationCache {
    struct Key: Equatable {
        let focus: CatalogFocus
        let selectedCategory: String?
        let approvalFilter: CapabilityCatalogApprovalFilter
        let riskFilter: CapabilityCatalogRiskFilter
        let showsNeedsAttentionOnly: Bool
        let showsEnabledOnly: Bool
        let searchText: String
        let source: SourceKey
    }

    /// Allocation-free identity and revision inputs owned by the production
    /// view. These cover state wrappers and replaceable references that cannot
    /// participate in the cache's Observation registration.
    struct SourceKey: Equatable {
        let workspaceIdentity: ObjectIdentifier
        let catalogIdentity: ObjectIdentifier
        let catalogRevision: Int
        let approvalRevision: Int
        let persistenceRevision: Int
    }

    private var cachedKey: Key?
    private var cachedState: PluginCatalogPresentationState?
    private(set) var buildCount = 0

    func state(
        for key: Key,
        build: () -> PluginCatalogPresentationState
    ) -> PluginCatalogPresentationState {
        if cachedKey == key, let cachedState {
            return cachedState
        }
        let state = build()
        cachedKey = key
        cachedState = state
        buildCount += 1
        return state
    }

    func invalidate() {
        cachedKey = nil
        cachedState = nil
    }
}

/// Typed scope for durable capability-resource mutations. A workspace-scoped
/// change must not invalidate another window; global resource changes affect
/// every workspace because global skills/connectors/tools participate in each
/// catalog projection.
struct CapabilityCatalogPersistenceChange: Equatable, Sendable {
    let workspaceID: UUID?

    static func workspace(_ id: UUID) -> Self { Self(workspaceID: id) }
    static let global = Self(workspaceID: nil)
}

extension Notification.Name {
    static let capabilityCatalogPersistenceChanged = Notification.Name("astra.capabilityCatalogPersistenceChanged")
}

enum CapabilityCatalogPersistenceEvents {
    @MainActor
    static func post(_ change: CapabilityCatalogPersistenceChange) {
        NotificationCenter.default.post(name: .capabilityCatalogPersistenceChanged, object: change)
    }
}

/// Bridges production lifecycle boundaries that do not participate in Swift
/// Observation into the catalog cache's scalar source key.
@MainActor
@Observable
final class PluginCatalogPresentationSourceRevision {
    private(set) var approvalRevision = 0
    private(set) var persistenceRevision = 0

    func approvalRecordsDidRefresh() {
        approvalRevision &+= 1
    }

    func persistenceDidSave() {
        persistenceRevision &+= 1
    }

    @discardableResult
    func receive(
        _ change: CapabilityCatalogPersistenceChange,
        workspaceID: UUID,
        reloadGlobal: () -> Void = {}
    ) -> Bool {
        guard change.workspaceID == nil || change.workspaceID == workspaceID else { return false }
        // Every window owns an independent catalog. A global library mutation
        // must refresh that read-side snapshot before its projection key is
        // invalidated, otherwise the rebuild deterministically reuses stale
        // packages until a later lifecycle refresh.
        if change.workspaceID == nil {
            reloadGlobal()
        }
        persistenceDidSave()
        return true
    }

    func key(
        workspace: Workspace,
        catalog: PluginCatalog
    ) -> PluginCatalogPresentationCache.SourceKey {
        PluginCatalogPresentationCache.SourceKey(
            workspaceIdentity: ObjectIdentifier(workspace),
            catalogIdentity: ObjectIdentifier(catalog),
            catalogRevision: catalog.revision,
            approvalRevision: approvalRevision,
            persistenceRevision: persistenceRevision
        )
    }
}
