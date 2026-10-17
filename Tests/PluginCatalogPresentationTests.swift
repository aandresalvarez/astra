import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Plugin Catalog Presentation")
@MainActor
struct PluginCatalogPresentationTests {
    @Test("resource editor mutations retain workspace or global event scope")
    @MainActor
    func resourceEditorMutationScopeIsTyped() {
        let workspace = Workspace(name: "Scoped", primaryPath: "/tmp/scoped")
        #expect(CapabilityPersistence.resourceChange(for: workspace) == .workspace(workspace.id))
        #expect(CapabilityPersistence.resourceChange(for: nil) == .global)
        #expect(CapabilityPersistence.resourceChange(for: workspace, isGlobal: true) == .global)
    }

    @Test("catalog revision advances for every package replacement")
    @MainActor
    func catalogRevisionTracksSameCountAndContentReplacement() {
        let catalog = PluginCatalog()
        let initialRevision = catalog.revision
        catalog.packages = [makePresentationPackage(id: "one", name: "One", category: "Tests")]
        #expect(catalog.revision == initialRevision + 1)

        catalog.packages = [makePresentationPackage(id: "two", name: "Two", category: "Tests")]
        #expect(catalog.revision == initialRevision + 2)

        catalog.packages[0].description = "Changed in place"
        #expect(catalog.revision == initialRevision + 3)
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

    @Test("approval state builds policy and review from supplied records")
    func approvalStateBuildsPolicyAndReviewFromSuppliedRecords() throws {
        let workspace = Workspace(
            name: "Approval Snapshot",
            primaryPath: "/tmp/astra-approval-snapshot-\(UUID().uuidString)"
        )
        let package = makePresentationPackage(
            id: "draft-\(UUID().uuidString)",
            name: "Draft",
            category: "Security",
            governance: .localDraft()
        )
        let record = CapabilityApprovalRecord(
            packageID: package.id,
            packageVersion: package.version,
            status: .approved,
            approvedBy: "Security",
            approvedAt: Date(timeIntervalSince1970: 1_234),
            reviewNotes: "Reviewed",
            sourceDigest: try CapabilityApprovalDigest.digest(for: package)
        )

        let policyContext = PluginCatalogApprovalState.policyContext(
            workspace: workspace,
            approvalRecords: [record]
        )
        let decision = CapabilityCatalogPolicy.decision(for: package, context: policyContext)
        let reviewState = PluginCatalogApprovalState.adminReviewState(
            for: package,
            policyContext: policyContext,
            approvalRecords: [record]
        )

        #expect(decision.canEnable)
        #expect(!decision.requiresApproval)
        #expect(reviewState?.record == record)
        #expect(reviewState?.digestLabel == "Digest current")
        #expect(reviewState?.shouldShow == true)
    }
}

@MainActor
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
