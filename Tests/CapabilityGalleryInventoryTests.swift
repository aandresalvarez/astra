import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability Gallery Inventory")
struct CapabilityGalleryInventoryTests {
    @Test("gallery excludes projected standalone resource capabilities")
    @MainActor
    func galleryExcludesProjectedStandaloneResources() {
        let workspace = Workspace(name: "Gallery", primaryPath: "/tmp/gallery")
        let skill = Skill(name: "Local Analyst", allowedTools: ["Read"])
        skill.workspace = workspace

        let projected = CapabilityCatalogInventory.packages(
            catalogPackages: [],
            capabilities: WorkspaceCapabilities(workspace: workspace)
        )
        let approved = makeGalleryPackage(id: "jira-workflow", name: "Jira Workflow", category: "Integrations")

        let packages = CapabilityGalleryInventory.packages(catalogPackages: projected + [approved])

        #expect(packages.map(\.id) == ["jira-workflow"])
        #expect(packages.map(\.category) == ["Integrations"])
    }

    @Test("management inventory includes active workspace capability packages")
    @MainActor
    func managementInventoryIncludesActiveWorkspaceCapabilities() {
        let workspace = Workspace(name: "Gallery", primaryPath: "/tmp/gallery")
        let skill = Skill(
            name: "Drive Docs For Jira Tickets",
            icon: "folder.badge.gearshape",
            skillDescription: "Read project docs",
            allowedTools: ["Read"]
        )
        skill.workspace = workspace
        let approved = makeGalleryPackage(id: "jira-workflow", name: "Jira Workflow", category: "Integrations")

        let packages = CapabilityGalleryInventory.managementPackages(
            catalogPackages: [approved],
            capabilities: WorkspaceCapabilities(workspace: workspace),
            workspace: workspace
        )

        #expect(packages.map(\.id).contains("jira-workflow"))
        #expect(packages.map(\.id).contains("skill.\(skill.id.uuidString.lowercased())"))
        #expect(packages.first { $0.id.hasPrefix("skill.") }?.name == "Drive Docs For Jira Tickets")
    }

    @Test("management inventory does not duplicate workspace resources already represented by a package")
    @MainActor
    func managementInventoryDoesNotDuplicatePackagedWorkspaceResources() {
        let workspace = Workspace(name: "Gallery", primaryPath: "/tmp/gallery")
        let skill = Skill(name: "Jira Agent", allowedTools: ["Read"])
        skill.workspace = workspace
        var approved = makeGalleryPackage(id: "jira-workflow", name: "Jira Workflow", category: "Integrations")
        approved.skills[0].name = "Jira Agent"

        let packages = CapabilityGalleryInventory.managementPackages(
            catalogPackages: [approved],
            capabilities: WorkspaceCapabilities(workspace: workspace),
            workspace: workspace
        )

        #expect(packages.map(\.id) == ["jira-workflow"])
    }

    @Test("gallery keeps real packages even when they only expose lower level resources")
    func galleryKeepsRealResourceBackedPackages() {
        var browser = makeGalleryPackage(id: "drive-browser", name: "Drive Browser", category: "Browser")
        browser.skills = []
        browser.browserAdapters = [BrowserSiteAdapterID.googleDrive]

        var connectorOnly = makeGalleryPackage(id: "jira-api", name: "Jira API", category: "Integrations")
        connectorOnly.skills = []
        connectorOnly.connectors = [
            PluginConnector(
                name: "Jira",
                serviceType: "jira",
                icon: "list.clipboard",
                description: "Jira API",
                baseURL: "https://jira.example.com",
                authMethod: "bearer",
                credentialHints: [],
                configHints: [],
                notes: ""
            )
        ]

        let packages = CapabilityGalleryInventory.packages(catalogPackages: [connectorOnly, browser])

        #expect(packages.map(\.id) == ["drive-browser", "jira-api"])
    }

    @Test("gallery deduplicates packages by id")
    func galleryDeduplicatesByID() {
        let first = makeGalleryPackage(id: "security-auditor", name: "Security Auditor", category: "Security")
        var duplicate = first
        duplicate.name = "Security Auditor Copy"

        let packages = CapabilityGalleryInventory.packages(catalogPackages: [first, duplicate])

        #expect(packages.map(\.name) == ["Security Auditor"])
    }

    @Test("gallery filters packages through policy context")
    func galleryFiltersPackagesThroughPolicyContext() {
        let approved = makeGalleryPackage(
            id: "approved",
            name: "Approved",
            category: "A",
            governance: .builtInApproved(riskLevel: .medium)
        )
        let draft = makeGalleryPackage(
            id: "draft",
            name: "Draft",
            category: "A",
            governance: .localDraft()
        )
        let blocked = makeGalleryPackage(
            id: "blocked",
            name: "Blocked",
            category: "A",
            governance: CapabilityGovernance(
                approvalStatus: .blocked,
                riskLevel: .high,
                visibility: .everyone,
                requiresAdminApproval: false,
                requiresExplicitUserConsent: false
            )
        )

        let userPackages = CapabilityGalleryInventory.packages(
            catalogPackages: [draft, approved, blocked],
            policyContext: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )
        let adminPackages = CapabilityGalleryInventory.packages(
            catalogPackages: [draft, approved, blocked],
            policyContext: CapabilityCatalogPolicyContext(
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(userPackages.map(\.id) == ["approved"])
        #expect(Set(adminPackages.map(\.id)) == ["approved", "blocked", "draft"])
    }

    @Test("management inventory excludes hidden packages even for admins")
    @MainActor
    func managementInventoryExcludesHiddenPackagesEvenForAdmins() {
        let workspace = Workspace(name: "Gallery", primaryPath: "/tmp/gallery")
        let visible = makeGalleryPackage(id: "visible", name: "Visible", category: "A")
        let hidden = makeGalleryPackage(
            id: "hidden",
            name: "Hidden",
            category: "A",
            governance: CapabilityGovernance(
                approvalStatus: .approved,
                riskLevel: .low,
                visibility: .hidden,
                requiresAdminApproval: false,
                requiresExplicitUserConsent: false
            )
        )

        let packages = CapabilityGalleryInventory.managementPackages(
            catalogPackages: [hidden, visible],
            capabilities: WorkspaceCapabilities(workspace: workspace),
            workspace: workspace,
            policyContext: CapabilityCatalogPolicyContext(
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(packages.map(\.id) == ["visible"])
    }

    @Test("gallery applies role and workspace tag policy context")
    func galleryAppliesRoleAndWorkspaceTagPolicyContext() {
        let researcher = makeGalleryPackage(
            id: "researcher-only",
            name: "Researcher",
            category: "A",
            governance: .builtInApproved(
                riskLevel: .medium,
                allowedRoles: ["researcher"],
                visibility: .roleScoped
            )
        )
        let clinical = makeGalleryPackage(
            id: "clinical-only",
            name: "Clinical",
            category: "A",
            governance: .builtInApproved(
                riskLevel: .medium,
                allowedWorkspaceTags: ["clinical-research"],
                visibility: .workspaceScoped
            )
        )

        let denied = CapabilityGalleryInventory.packages(
            catalogPackages: [researcher, clinical],
            policyContext: CapabilityCatalogPolicyContext(
                userRoleIDs: ["engineer"],
                workspaceTags: ["engineering"],
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )
        let allowed = CapabilityGalleryInventory.packages(
            catalogPackages: [researcher, clinical],
            policyContext: CapabilityCatalogPolicyContext(
                userRoleIDs: ["Researcher"],
                workspaceTags: ["Clinical-Research"],
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(denied.isEmpty)
        #expect(allowed.map(\.id) == ["clinical-only", "researcher-only"])
    }

    @Test("gallery uses one column in every presentation")
    func galleryUsesOneColumn() {
        #expect(CapabilityGalleryLayout.columnCount(for: .embedded) == 1)
        #expect(CapabilityGalleryLayout.columnCount(for: .modal) == 1)
    }
}

private func makeGalleryPackage(
    id: String,
    name: String,
    category: String,
    governance: CapabilityGovernance = .builtInApproved(riskLevel: .medium)
) -> PluginPackage {
    PluginPackage(
        id: id,
        name: name,
        icon: "puzzlepiece.extension",
        description: "Capability package",
        author: "Tests",
        category: category,
        tags: [],
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
