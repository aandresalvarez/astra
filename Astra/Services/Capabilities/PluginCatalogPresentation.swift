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
    let enabledCount: Int
    let categoryCounts: [String: Int]
    let visibleCategories: [String]
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

        return PluginCatalogPresentationState(
            focusedPackages: focused,
            filteredPackages: filtered,
            enabledCount: enabledCount,
            categoryCounts: categoryCounts,
            visibleCategories: visibleCategories
        )
    }
}
