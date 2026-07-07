import Foundation
import Testing

@Suite("Keychain User Interaction Routing")
struct KeychainUserInteractionRoutingTests {
    @Test("Explicit credential entry paths request promptable Keychain saves")
    func explicitCredentialEntryPathsRequestPromptableSaves() throws {
        let connectorView = try source("Astra/Views/ConnectorsManagerView.swift")
        let skillView = try source("Astra/Views/SkillsManagerView.swift")
        let pluginView = try source("Astra/Views/PluginCatalogView.swift")
        let chatView = try source("Astra/Views/ChatPanelView.swift")
        let outlook = try source("Astra/Services/Capabilities/StanfordOutlookMail.swift")

        #expect(connectorView.contains("allowUserInteraction: true"))
        #expect(skillView.contains("allowUserInteraction: true"))
        #expect(pluginView.contains("allowCredentialUserInteraction: credentialValues.values.contains"))
        #expect(chatView.contains("allowCredentialUserInteraction: !credentials.isEmpty"))
        #expect(outlook.contains("allowUserInteraction: allowUserInteraction"))
    }

    @Test("Background Keychain paths remain non-interactive by default")
    func backgroundKeychainPathsRemainNonInteractiveByDefault() throws {
        let keychainService = try source("Astra/Services/Persistence/KeychainService.swift")
        let skill = try source("Astra/Models/Skill.swift")
        let outlook = try source("Astra/Services/Capabilities/StanfordOutlookMail.swift")

        #expect(keychainService.contains("allowUserInteraction: Bool = false"))
        #expect(skill.contains("allowUserInteraction: Bool = false"))
        #expect(outlook.contains("allowUserInteraction: Bool = false"))
    }

    private func source(_ relativePath: String) throws -> String {
        let testFile = URL(filePath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }
}
