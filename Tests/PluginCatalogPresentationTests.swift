import Foundation
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

    @Test("state groups filtered packages by capability management status")
    func stateGroupsFilteredPackagesByManagementStatus() {
        let needsSetup = makePresentationPackage(
            id: "jira",
            name: "Jira",
            category: "Integrations",
            governance: .builtInApproved(riskLevel: .high)
        )
        let enabled = makePresentationPackage(
            id: "mail",
            name: "Mail",
            category: "Integrations",
            governance: .localDraft()
        )
        let available = makePresentationPackage(
            id: "security",
            name: "Security",
            category: "Security",
            governance: .builtInApproved(riskLevel: .medium)
        )
        let blocked = makePresentationPackage(
            id: "blocked",
            name: "Blocked",
            category: "Security",
            governance: CapabilityGovernance(
                approvalStatus: .blocked,
                riskLevel: .restricted,
                visibility: .adminOnly,
                requiresAdminApproval: true,
                requiresExplicitUserConsent: true,
                policyNotes: ""
            )
        )

        let state = PluginCatalogPresentation.makeState(
            packages: [needsSetup, enabled, available, blocked],
            focus: .all,
            selectedCategory: nil,
            approvalFilter: .all,
            riskFilter: .all,
            showsNeedsAttentionOnly: false,
            showsEnabledOnly: false,
            searchText: "",
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            isEnabled: { $0.id == "mail" },
            requiresSetup: { $0.id == "jira" }
        )

        #expect(state.groupedPackages.map(\.kind) == [.needsSetup, .enabled, .available, .blocked])
        #expect(state.groupedPackages.map { $0.packages.map(\.id) } == [
            ["jira"],
            ["mail"],
            ["security"],
            ["blocked"]
        ])
    }

    @Test("state groups visible packages by category with status buckets inside each category")
    func stateGroupsVisiblePackagesByCategoryWithStatusBucketsInsideEachCategory() {
        let enabledIntegration = makePresentationPackage(
            id: "mail",
            name: "Mail",
            category: "Integrations",
            governance: .localDraft()
        )
        let needsIntegration = makePresentationPackage(
            id: "jira",
            name: "Jira",
            category: "Integrations",
            governance: .builtInApproved(riskLevel: .high)
        )
        let browser = makePresentationPackage(
            id: "drive-browser",
            name: "Drive Browser",
            category: "Browser",
            governance: .builtInApproved(riskLevel: .low)
        )

        let state = PluginCatalogPresentation.makeState(
            packages: [enabledIntegration, needsIntegration, browser],
            focus: .all,
            selectedCategory: nil,
            approvalFilter: .all,
            riskFilter: .all,
            showsNeedsAttentionOnly: false,
            showsEnabledOnly: false,
            searchText: "",
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            isEnabled: { $0.id == "mail" },
            requiresSetup: { $0.id == "jira" || $0.id == "drive-browser" }
        )

        #expect(state.categorySections.map(\.category) == ["Integrations", "Browser"])
        #expect(state.categorySections.map { $0.packages.map(\.id) } == [
            ["jira", "mail"],
            ["drive-browser"]
        ])
        #expect(state.categorySections[0].statusGroups.map(\.kind) == [.needsSetup, .enabled])
        #expect(state.categorySections[0].statusGroups.map { $0.packages.map(\.id) } == [
            ["jira"],
            ["mail"]
        ])
    }

    @Test("approval-required packages group under needs attention, not blocked")
    func approvalRequiredPackagesGroupUnderNeedsAttention() {
        // Regression: a draft / admin-approval package sets canEnable == false
        // but is actionable via approval, so it must land in "Needs attention".
        let draft = makePresentationPackage(
            id: "draft",
            name: "Draft Capability",
            category: "Integrations",
            governance: .localDraft()
        )
        // A genuinely blocked package (explicit blocked status) must remain
        // under "Blocked" even though it also flags requiresApproval.
        let blocked = makePresentationPackage(
            id: "blocked",
            name: "Blocked Capability",
            category: "Security",
            governance: CapabilityGovernance(
                approvalStatus: .blocked,
                riskLevel: .restricted,
                visibility: .adminOnly,
                requiresAdminApproval: true,
                requiresExplicitUserConsent: true,
                policyNotes: ""
            )
        )

        let state = PluginCatalogPresentation.makeState(
            packages: [draft, blocked],
            focus: .all,
            selectedCategory: nil,
            approvalFilter: .all,
            riskFilter: .all,
            showsNeedsAttentionOnly: false,
            showsEnabledOnly: false,
            searchText: "",
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            isEnabled: { _ in false },
            requiresSetup: { _ in false }
        )

        let kindByID = Dictionary(uniqueKeysWithValues: state.groupedPackages.flatMap { group in
            group.packages.map { ($0.id, group.kind) }
        })
        #expect(kindByID["draft"] == .needsSetup)
        #expect(kindByID["blocked"] == .blocked)
    }

    @Test("row attention label reflects the concrete reason for attention")
    func rowAttentionLabelReflectsConcreteReason() {
        let context = CapabilityCatalogPolicyContext(isAdmin: true)

        let draft = makePresentationPackage(
            id: "draft",
            name: "Draft",
            category: "A",
            governance: .localDraft()
        )
        let draftDecision = CapabilityCatalogPolicy.decision(for: draft, context: context)
        // Draft requires approval but no setup flow: must not claim setup.
        #expect(CapabilityRowPresentation.attentionLabel(needsSetup: false, decision: draftDecision) == "Approval required")
        #expect(CapabilityRowPresentation.attentionLabel(needsSetup: true, decision: draftDecision) == "Setup required")

        let highRisk = makePresentationPackage(
            id: "high",
            name: "High",
            category: "A",
            governance: .builtInApproved(riskLevel: .high)
        )
        let highRiskDecision = CapabilityCatalogPolicy.decision(for: highRisk, context: context)
        #expect(CapabilityRowPresentation.attentionLabel(needsSetup: false, decision: highRiskDecision) == "Policy warning")

        let clean = makePresentationPackage(
            id: "clean",
            name: "Clean",
            category: "A",
            governance: .builtInApproved(riskLevel: .medium)
        )
        let cleanDecision = CapabilityCatalogPolicy.decision(for: clean, context: context)
        #expect(CapabilityRowPresentation.attentionLabel(needsSetup: false, decision: cleanDecision) == nil)
    }

    @Test("capability icon presentation prefers brand mark for GitHub package")
    func capabilityIconPresentationPrefersBrandMarkForGitHubPackage() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let presentation = CapabilityIconPresentation.make(for: package)

        #expect(presentation.fallbackSystemName == package.icon)
        #expect(presentation.monochromePreferred)
        assertIconPresentation(presentation, resolvesTo: .github, assetName: "github.svg")
    }

    @Test("bundled Simple Icons assets use adaptive monochrome tint")
    func bundledSimpleIconsAssetsUseAdaptiveMonochromeTint() throws {
        let ids = [
            "gcloud-workflow",
            "github-workflow",
            "google-drive-browser",
            "jira-workflow"
        ]

        for id in ids {
            let package = try #require(PluginCatalog.builtInPackages.first { $0.id == id })

            #expect(CapabilityIconPresentation.make(for: package).monochromePreferred)
        }
    }

    @Test("capability icon presentation resolves curated brand marks")
    func capabilityIconPresentationResolvesCuratedBrandMarks() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let drive = try #require(PluginCatalog.builtInPackages.first { $0.id == "google-drive-browser" })
        let gcloud = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })

        assertIconPresentation(CapabilityIconPresentation.make(for: jira), resolvesTo: .jira, assetName: "jira.svg")
        assertIconPresentation(CapabilityIconPresentation.make(for: drive), resolvesTo: .googleDrive, assetName: "google-drive.svg")
        assertIconPresentation(CapabilityIconPresentation.make(for: gcloud), resolvesTo: .googleCloud, assetName: "google-cloud.svg")
    }

    @Test("import overview preserves package description and hides duplicate content summary")
    func importOverviewPreservesPackageDescriptionAndHidesDuplicateContentSummary() {
        let package = makePresentationPackage(
            id: "described",
            name: "Described",
            category: "A"
        )

        #expect(CapabilityImportPresentation.overviewDescription(for: package, contentSummary: "Ignored") == "Described package")
        #expect(CapabilityImportPresentation.shouldShowContentSummary(for: package))
    }

    @Test("import overview falls back when package description is blank")
    func importOverviewFallsBackWhenPackageDescriptionIsBlank() {
        var package = makePresentationPackage(
            id: "blank",
            name: "Blank",
            category: "A"
        )
        package.description = "   "

        #expect(CapabilityImportPresentation.overviewDescription(for: package, contentSummary: "A skill") == "No description provided.")
        #expect(!CapabilityImportPresentation.shouldShowContentSummary(for: package))
    }

    @Test("creation actions present MCP as a capability source")
    func creationActionsPresentMCPAsCapabilitySource() {
        #expect(CapabilityCreationPresentation.menuTitle == "New Capability")
        #expect(CapabilityCreationPresentation.blankCapabilityTitle == "Blank Capability")
        #expect(CapabilityCreationPresentation.mcpCapabilityTitle == "Create from MCP...")
        #expect(CapabilityCreationPresentation.pasteSheetTitle == "Create from MCP")
        #expect(CapabilityCreationPresentation.primaryActionTitles == ["Import Capability", "New Capability"])
        #expect(!CapabilityCreationPresentation.primaryActionTitles.contains("Add MCP Server"))
    }

    @Test("MCP creation paste sheet keeps enough vertical room for form controls")
    func mcpCreationPasteSheetKeepsEnoughVerticalRoomForFormControls() {
        #expect(CapabilityCreationPresentation.mcpPasteSheetMinimumHeight >= 430)
        #expect(CapabilityCreationPresentation.mcpPasteTextEditorMinimumHeight >= 150)
        #expect(
            CapabilityCreationPresentation.mcpPasteSheetMinimumHeight -
                CapabilityCreationPresentation.mcpPasteTextEditorMinimumHeight >= 280
        )
    }

    @Test("setup presentation makes connector fields readable while preserving keys")
    func setupPresentationMakesConnectorFieldsReadableWhilePreservingKeys() {
        let connector = PluginConnector(
            name: "Jira",
            serviceType: "jira",
            icon: "list.clipboard",
            description: "Tickets",
            baseURL: "https://yourcompany.atlassian.net",
            authMethod: "api_key",
            credentialHints: [],
            configHints: [],
            notes: ""
        )
        let credential = PluginConnector.CredentialHint(
            key: "JIRA_API_TOKEN",
            hint: "Atlassian API token"
        )
        let config = PluginConnector.ConfigHint(
            key: "JIRA_PROJECTS",
            hint: "Comma-separated project keys",
            isList: true
        )

        #expect(CapabilitySetupPresentation.fieldLabel(for: "JIRA_EMAIL") == "Email")
        #expect(CapabilitySetupPresentation.fieldLabel(for: "JIRA_API_TOKEN") == "API token")
        #expect(CapabilitySetupPresentation.fieldHelper(for: "JIRA_API_TOKEN") == "JIRA_API_TOKEN")
        #expect(CapabilitySetupPresentation.baseURLLabel(for: connector) == "Jira site URL")
        #expect(CapabilitySetupPresentation.authMethodLabel("api_key") == "API key")
        #expect(CapabilitySetupPresentation.credentialPlaceholder(for: credential) == "Paste API token")
        #expect(CapabilitySetupPresentation.configPlaceholder(for: config) == "ENG, OPS")
    }
}

private func assertIconPresentation(
    _ presentation: CapabilityIconPresentation,
    resolvesTo brand: CapabilityBrandIcon,
    assetName: String
) {
    switch presentation.kind {
    case .asset(let url):
        #expect(url.lastPathComponent == assetName)
        #expect(FileManager.default.fileExists(atPath: url.path))
    case .brand(let resolved):
        #expect(resolved == brand)
    case .systemSymbol:
        Issue.record("Expected \(brand.rawValue) brand or \(assetName) asset icon.")
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
