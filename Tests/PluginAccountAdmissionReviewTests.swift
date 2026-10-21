import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Account definition and mutation admission")
@MainActor
struct PluginAccountAdmissionReviewTests {
    typealias Fixtures = PluginOperationsTests

    @Test("Same-version replacement cannot move component state before acceptance")
    func sameVersionRenameWaitsForUpdate() throws {
        let env = try Fixtures.Environment()
        let initial = Fixtures.package(version: "1.0.0")
        try env.install(initial)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: initial.id, in: env.workspace))
        let old = CapabilityResourceOrigin.componentID(for: initial.skills[0])
        WorkspaceCapabilityActivation.setConfigValue("saved-project", forKey: PluginActivation.settingKey(componentID: old, key: "PROJECT"), on: activation)
        try env.context.save()
        let before = PluginActivationRecord(activation)
        var changed = initial
        changed.skills[0].id = "renamed-agent"
        changed.skills[0].replaces = [old]
        try env.importUpdate(changed, mode: .automatic)
        #expect(activation.awaitingUpdate)
        #expect(activation.knownComponentIDs == before.knownComponentIDs)
        #expect(activation.configKeys == before.configKeys)
        #expect(activation.configValues == before.configValues)
        #expect(activation.secretSettingKeys == before.secretSettingKeys)
        #expect(activation.bindings.map(\.componentID).sorted() == before.bindings.map(\.componentID).sorted())
        try env.importUpdate(initial, mode: .automatic)
        #expect(activation.configuration(forComponent: old)["PROJECT"] == "saved-project")
    }

    @Test("Readiness requires the current declaration, keeping retired markers only as history")
    func retiredCredentialDoesNotBlockReadiness() throws {
        let env = try Fixtures.Environment()
        var initial = Fixtures.package(version: "1.0.0")
        initial.connectors[0].credentialHints.append(.init(key: "RETIRED_TOKEN", hint: "Old token"))
        try env.install(initial)
        let account = try #require(env.workspace.connectors.first)
        let store = MockSecretStore()
        store.save(key: "TRACKER_TOKEN", value: "configured-current-token",
            entityID: KeychainSecretStore.connectorEntityID(for: account.credentialNamespaceID ?? account.id), label: nil)
        var next = initial
        next.version = "2.0.0"
        next.connectors[0].credentialHints.removeAll { $0.key == "RETIRED_TOKEN" }
        try env.importUpdate(next)
        #expect(account.credentialKeys.contains("RETIRED_TOKEN"))
        let state = CapabilityPackageState(package: next, workspace: env.workspace,
            capabilities: WorkspaceCapabilities(workspace: env.workspace, packageDefinitions: [next]), secretStore: store)
        #expect(state.readiness.level == .ready)
        #expect(state.attentionMessages(for: account).isEmpty)
    }

    @Test("Every account carries package settings without duplicating account structure")
    func additionalAccountFieldLayout() throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        package.connectors[0].configHints = [
            .init(key: "ENDPOINT", hint: "Endpoint", isList: false, storage: .some(PluginConnector.ConfigHint.accountBaseURL)),
            .init(key: "ALIAS", hint: "Alias", isList: false, storage: .some(PluginConnector.ConfigHint.accountAlias))
        ]
        try env.install(package)
        let account = try PluginOperations.addAccount(for: package.connectors[0], of: package,
            in: env.workspace, modelContext: env.context)
        #expect(account.configKeys.contains("PROJECT"))
        #expect(!account.configKeys.contains("ENDPOINT"))
        #expect(!account.configKeys.contains("ALIAS"))
        #expect(account.configValue("PROJECT") == "default-project")
    }

    @Test("An unaccepted definition cannot change accounts before Update", arguments: ["add", "default"])
    func addAccountWaitsForDefinitionAcceptance(operation: String) throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        var changed = package
        changed.connectors[0].id = "renamed-tracker"
        changed.connectors[0].replaces = [CapabilityResourceOrigin.componentID(for: package.connectors[0])]
        let before = WorkspaceCapabilityActivation.snapshot(env.workspace)
        #expect(throws: PluginOperations.OperationError.updateRequired) {
            if operation == "add" {
                _ = try PluginOperations.addAccount(for: changed.connectors[0], of: changed,
                    in: env.workspace, modelContext: env.context)
            } else {
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
                let componentID = CapabilityResourceOrigin.componentID(for: package.connectors[0])
                let account = try #require(activation.accounts(forComponent: componentID).first)
                try PluginOperations.makeDefault(account, componentID: componentID, package: changed,
                    in: env.workspace, modelContext: env.context)
            }
        }
        #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == before)
        #expect(!env.context.hasChanges)
    }

    @Test("Account operations reject a stale activation saved by another context", arguments: ["add", "default"])
    func accountOperationsReadCurrentState(operation: String) throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let component = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        let first = try #require(activation.accounts(forComponent: component).first)
        let other = ModelContext(env.container)
        other.autosaveEnabled = false
        let workspaceID = env.workspace.id
        let descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == workspaceID })
        let fresh = try #require(other.fetch(descriptor).first)
        let freshActivation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: fresh))
        WorkspaceCapabilityActivation.setConfigValue("other", forKey: "skill:report-agent#PROJECT", on: freshActivation)
        try other.save()
        #expect(throws: (any Error).self) {
            if operation == "add" {
                _ = try PluginOperations.addAccount(for: package.connectors[0], of: package,
                    in: env.workspace, modelContext: env.context)
            } else {
                try PluginOperations.makeDefault(first, componentID: component, package: package,
                    in: env.workspace, modelContext: env.context)
            }
        }
        #expect(!env.context.hasChanges)
    }

    @Test("Add restores every retained account through an explicit connector rename")
    func retainedAccountsFollowRename() throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let second = try PluginOperations.addAccount(for: package.connectors[0], of: package,
            in: env.workspace, modelContext: env.context)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let originalIDs = Set(activation.bindings.compactMap { $0.account?.id })
        _ = try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context)
        var changed = package
        changed.connectors[0].id = "new-tracker"
        changed.connectors[0].replaces = [CapabilityResourceOrigin.componentID(for: package.connectors[0])]
        try env.install(changed)
        let restored = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let ids = Set(restored.accounts(forComponent: CapabilityResourceOrigin.componentID(for: changed.connectors[0])).map(\.id))
        #expect(ids == originalIDs)
        #expect(ids.contains(second.id))
    }

    @Test("A chosen file can override only a matching authored skill or tool")
    func importedConnectorCannotBecomeOverride() throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let connectorID = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        let skillID = CapabilityResourceOrigin.componentID(for: package.skills[0])
        let toolID = CapabilityResourceOrigin.componentID(for: package.localTools[0])
        let row = Skill(name: "Authored")
        env.context.insert(row)
        var config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        config.installedPlugins = [.init(id: package.id, version: package.version,
            overriddenComponentIDs: [connectorID, skillID, toolID],
            overridingRowIDs: [row.id.uuidString, row.id.uuidString, row.id.uuidString], digest: "test-digest")]
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(approvedPackageIDs: [package.id],
            installedPackageIDs: [package.id], availablePackIDs: [],
            declaredComponentIDs: [package.id: [connectorID, skillID, toolID]], installedDigests: [package.id: "test-digest"])
        WorkspaceConfigManager.restoreActivationDetails(from: config, into: env.workspace,
            connectorsByID: [:], skillsByID: [row.id.uuidString: row], toolsByID: [:], trust: .validate(verifier))
        #expect(activation.overriddenComponentIDs == [skillID])
        #expect(activation.overridingRowIDs == [row.id.uuidString])
    }

    @Test("Raising only the minimum app version invalidates an accepted definition")
    func minimumVersionIsExecutableContract() throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let digest = PluginDefinitionDigest.content(of: package)
        package.minAppVersion = "999.0.0"
        #expect(PluginDefinitionDigest.content(of: package) != digest)
        #expect(PluginRuntimeProjection.awaitsUpdate(activation, to: package))
        #expect(!CapabilityCatalogPolicy.decision(for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))).blockers.isEmpty)
    }

    @Test("An account bound twice reports every withdrawn authentication declaration")
    func multiBoundAuthenticationReadiness() throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        package.connectors[0].authMethod = "none"
        package.connectors[0].credentialHints = []
        var second = package.connectors[0]
        second.id = "second"
        package.connectors.append(second)
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let account = try #require(activation.accounts(forComponent: CapabilityResourceOrigin.componentID(for: package.connectors[0])).first)
        WorkspaceCapabilityActivation.bind(account, toComponent: CapabilityResourceOrigin.componentID(for: second), of: activation)
        try env.context.save()
        package.connectors[1].authMethod = "bearer"
        let state = CapabilityPackageState(package: package, workspace: env.workspace,
            capabilities: WorkspaceCapabilities(workspace: env.workspace, packageDefinitions: [package]), secretStore: MockSecretStore())
        #expect(state.attentionMessages(for: account).contains { $0.contains("reconnect") })
    }
}
