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

    @Test("gallery uses one column in every presentation")
    func galleryUsesOneColumn() {
        #expect(CapabilityGalleryLayout.columnCount(for: .embedded) == 1)
        #expect(CapabilityGalleryLayout.columnCount(for: .modal) == 1)
    }
}

private func makeGalleryPackage(id: String, name: String, category: String) -> PluginPackage {
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
        templates: []
    )
}
