import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// What survived the old catalog's presentation: brand icons (rail, Plugins
/// screen) and the scope of resource-editor persistence events.
@Suite("Capability icon presentation")
struct CapabilityIconPresentationTests {
    @Test("resource editor mutations retain workspace or global event scope")
    @MainActor
    func resourceEditorMutationScopeIsTyped() {
        let workspace = Workspace(name: "Scoped", primaryPath: "/tmp/scoped")
        #expect(CapabilityPersistence.resourceChange(for: workspace) == .workspace(workspace.id))
        #expect(CapabilityPersistence.resourceChange(for: nil) == .global)
        #expect(CapabilityPersistence.resourceChange(for: workspace, isGlobal: true) == .global)
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
