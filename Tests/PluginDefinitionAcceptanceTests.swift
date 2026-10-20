import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Plugin definition acceptance")
struct PluginDefinitionAcceptanceTests {
    @Test("Changing only the executable prerequisite contract invalidates accepted content")
    func prerequisiteExecutionChangesDigest() {
        var package = Self.package()
        package.prerequisites = [.init(binary: "gh", livenessArgs: ["auth", "status"], displayName: "GitHub", purpose: "Access")]
        let accepted = PluginDefinitionDigest.content(of: package)
        package.prerequisites[0].livenessArgs = ["api", "user"]
        #expect(PluginDefinitionDigest.content(of: package) != accepted)
        package.prerequisites[0].livenessArgs = ["auth", "status"]
        #expect(PluginDefinitionDigest.content(of: package) == accepted)
        package.prerequisites[0].authHint = "gh auth login --hostname github.example.com"
        #expect(PluginDefinitionDigest.content(of: package) != accepted)
    }

    @Test("Prerequisite badge text alone does not require accepting the definition again")
    func prerequisitePresentationDoesNotChangeDigest() {
        var package = Self.package()
        package.prerequisites = [.init(binary: "gh", displayName: "GitHub", purpose: "Access")]
        let accepted = PluginDefinitionDigest.content(of: package)
        package.prerequisites[0].displayName = "GitHub CLI"
        package.prerequisites[0].purpose = "Localized badge text"
        #expect(PluginDefinitionDigest.content(of: package) == accepted)
    }

    private static func package() -> PluginPackage {
        PluginPackage(id: "acceptance.fixture", name: "Accepted", icon: "checkmark", description: "Acceptance",
            author: "Tests", category: "Tests", tags: [], version: "1.0.0",
            skills: [.init(name: "Agent", icon: "terminal", description: "Agent", allowedTools: ["Read"],
                disallowedTools: [], customTools: [], behaviorInstructions: "Use the accepted definition.",
                environmentKeys: ["REGION"], environmentValues: ["us"])],
            connectors: [.init(name: "API", serviceType: "rest_api", icon: "network", description: "API",
                baseURL: "https://api.example.test", authMethod: "bearer", credentialHints: [], configHints: [], notes: "")],
            localTools: [], templates: [], governance: .builtInApproved(riskLevel: .low))
    }

}
