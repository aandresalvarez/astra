import Testing
@testable import ASTRA
import ASTRACore

@Suite("Plugin Catalog Presentation")
struct PluginCatalogPresentationTests {
    @Test("state preserves focused category order and counts before filtering")
    func statePreservesFocusedCategoryOrderAndCountsBeforeFiltering() {
        let packages = [
            makePresentationPackage(id: "jira", name: "Jira", category: "Integrations", tags: ["tickets"]),
            makePresentationPackage(id: "review", name: "Review", category: "Development", tags: ["code"]),
            makePresentationPackage(id: "drive", name: "Drive", category: "Integrations", tags: ["docs"])
        ]

        let state = PluginCatalogPresentation.makeState(
            packages: packages,
            focus: .all,
            selectedCategory: "Integrations",
            approvalFilter: .all,
            riskFilter: .all,
            showsNeedsAttentionOnly: false,
            showsEnabledOnly: false,
            searchText: "",
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            isEnabled: { _ in false },
            requiresSetup: { _ in false }
        )

        #expect(state.visibleCategories == ["Integrations", "Development"])
        #expect(state.categoryCounts == ["Integrations": 2, "Development": 1])
        #expect(state.focusedPackages.map(\.id) == ["jira", "review", "drive"])
        #expect(state.filteredPackages.map(\.id) == ["jira", "drive"])
        #expect(state.enabledCount == 0)
    }

    @Test("state applies approval risk attention enabled and search filters")
    func stateAppliesApprovalRiskAttentionEnabledAndSearchFilters() {
        let packages = [
            makePresentationPackage(
                id: "security-enabled",
                name: "Security Auditor",
                category: "Security",
                tags: ["audit"],
                governance: .builtInApproved(riskLevel: .high)
            ),
            makePresentationPackage(
                id: "security-disabled",
                name: "Security Notes",
                category: "Security",
                tags: ["audit"],
                governance: .builtInApproved(riskLevel: .high)
            ),
            makePresentationPackage(
                id: "draft-enabled",
                name: "Draft Auditor",
                category: "Security",
                tags: ["audit"],
                governance: .localDraft()
            ),
            makePresentationPackage(
                id: "medium-enabled",
                name: "Medium Auditor",
                category: "Security",
                tags: ["audit"],
                governance: .builtInApproved(riskLevel: .medium)
            )
        ]

        let state = PluginCatalogPresentation.makeState(
            packages: packages,
            focus: .all,
            selectedCategory: "Security",
            approvalFilter: .approved,
            riskFilter: .high,
            showsNeedsAttentionOnly: true,
            showsEnabledOnly: true,
            searchText: " auditor ",
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            isEnabled: { $0.id.hasSuffix("enabled") },
            requiresSetup: { $0.id == "medium-enabled" }
        )

        #expect(state.filteredPackages.map(\.id) == ["security-enabled"])
        #expect(state.enabledCount == 3)
    }

    @Test("focus narrows packages before filters and enabled summary")
    func focusNarrowsPackagesBeforeFiltersAndEnabledSummary() {
        let skill = makePresentationPackage(id: "skill-package", name: "Skill", category: "A")
        var connector = makePresentationPackage(id: "connector-package", name: "Connector", category: "B")
        connector.skills = []
        connector.connectors = [
            PluginConnector(
                name: "Connector",
                serviceType: "test",
                icon: "link",
                description: "Connector",
                baseURL: "https://example.com",
                authMethod: "none",
                credentialHints: [],
                configHints: [],
                notes: ""
            )
        ]

        let state = PluginCatalogPresentation.makeState(
            packages: [skill, connector],
            focus: .connectors,
            selectedCategory: nil,
            approvalFilter: .all,
            riskFilter: .all,
            showsNeedsAttentionOnly: false,
            showsEnabledOnly: false,
            searchText: "",
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            isEnabled: { $0.id == "skill-package" },
            requiresSetup: { _ in false }
        )

        #expect(state.focusedPackages.map(\.id) == ["connector-package"])
        #expect(state.filteredPackages.map(\.id) == ["connector-package"])
        #expect(state.enabledCount == 0)
    }
}

private func makePresentationPackage(
    id: String,
    name: String,
    category: String,
    tags: [String] = [],
    governance: CapabilityGovernance = .builtInApproved(riskLevel: .medium)
) -> PluginPackage {
    PluginPackage(
        id: id,
        name: name,
        icon: "puzzlepiece.extension",
        description: "\(name) package",
        author: "Tests",
        category: category,
        tags: tags,
        version: "1.0.0",
        skills: [
            PluginSkill(
                name: "\(name) Skill",
                icon: "puzzlepiece.extension",
                description: "Instructions",
                allowedTools: ["Read"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use the capability.",
                environmentKeys: [],
                environmentValues: []
            )
        ],
        connectors: [],
        localTools: [],
        templates: [],
        governance: governance
    )
}
