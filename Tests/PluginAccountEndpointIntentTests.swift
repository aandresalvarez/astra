import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin account endpoint intent")
struct PluginAccountEndpointIntentTests {
    @Test("Setup can explicitly reset a bound account to the definition's endpoint", arguments: [false, true])
    func explicitDefaultIsAnEdit(structureField: Bool) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        var package = PluginOperationsTests.package(version: "1.0.0")
        package.id = env.package.id
        package.skills = []; package.localTools = []
        package.connectors[0].credentialHints = []
        package.connectors[0].configHints = [.init(key: "SITE", hint: "Site", isList: false,
            storage: PluginConnector.ConfigHint.accountBaseURL)]
        try env.installer.install(package, into: env.workspace, modelContext: env.context)
        let spec = package.connectors[0]
        let component = spec.setupComponentID
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let account = try #require(activation.accounts(forComponent: component).first)
        account.baseURL = "https://custom.tracker.example.com"
        try env.context.save()
        let initial = CapabilitySetupPresentation.initialValues(for: package, in: env.workspace)
        try #require(initial.baseURLs[component] == account.baseURL)
        var inputs = initial.config
        var urls = initial.baseURLs
        if structureField {
            inputs[PluginSetupInputs.key("SITE", component: component)] = spec.baseURL
            // Structural endpoint is the one field this form submits.
            urls.removeValue(forKey: component)
        } else { urls[component] = spec.baseURL }
        try env.installer.enable(package, in: env.workspace, modelContext: env.context,
            configInputs: inputs, baseURLOverrides: urls)
        let current = try #require(activation.accounts(forComponent: component).first)
        #expect(current.id == account.id)
        #expect(current.baseURL == spec.baseURL)
        let reopened = try env.disk.reopen()
        let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first { $0.id == account.id })
        #expect(saved.baseURL == spec.baseURL)
    }
}
