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

    @Test("A repeated credential declaration is rejected before the account editor sees it")
    func duplicateCredentialKeysAreRejected() {
        var package = Self.package()
        package.connectors[0].credentialHints = [.init(key: "API_TOKEN", hint: "First"), .init(key: "API_TOKEN", hint: "Second")]
        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
        #expect(!report.canInstall)
        #expect(report.issues.contains { $0.title == "Duplicate credential key" })
    }

    @Test("A repeated skill setting is rejected instead of creating two rows for one value")
    func duplicateSkillKeysAreRejected() {
        var package = Self.package()
        package.skills[0].environmentKeys = ["REGION", "REGION"]
        package.skills[0].environmentValues = ["us", "eu"]
        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
        #expect(!report.canInstall)
        #expect(report.issues.contains { $0.title == "Duplicate setting name" })
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
