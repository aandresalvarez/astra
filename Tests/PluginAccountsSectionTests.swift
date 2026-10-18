import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Accounts no plugin row shows stay reachable on the Plugins surface:
/// Remove and an Update that drops a connector component keep the account
/// and its credentials, and Delete account is the only operation that
/// clears them. Fixtures are `PluginOperationsTests`'s.
@Suite("Plugin accounts section")
@MainActor
struct PluginAccountsSectionTests {
    typealias Fixtures = PluginOperationsTests

    private func unused(_ env: Fixtures.Environment, listing packages: [PluginPackage], query: String = "") -> [UUID] {
        let capabilities = WorkspaceCapabilities(workspace: env.workspace)
        return PluginsSurfacePresentation.unusedAccounts(
            workspaceConnectors: capabilities.workspaceConnectors,
            sharedConnectors: capabilities.enabledGlobalConnectors,
            listedPackages: packages,
            query: query
        ).map(\.id)
    }

    @Test("An account a listed plugin row shows under its component is not listed again")
    func boundAccountIsNotListed() throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let account = try #require(env.workspace.connectors.first)
        #expect(account.accountBindings.contains { !$0.isDeleted })

        #expect(unused(env, listing: [package]).isEmpty)
    }

    @Test("An account Remove keeps is listed, so Delete account can still clear it")
    func accountKeptByRemoveIsListed() throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let account = try #require(env.workspace.connectors.first)

        try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context)

        #expect(env.workspace.connectors.map(\.id) == [account.id])
        #expect(unused(env, listing: []) == [account.id])
        #expect(unused(env, listing: [], query: "tracker") == [account.id])
        #expect(unused(env, listing: [], query: "gmail").isEmpty)
        #expect(PluginsSurfacePresentation.accountSubtitle(account) == "Tracker · https://tracker.example.com")
    }

    @Test("An account whose component an Update dropped is listed, released or withheld")
    func accountDroppedByUpdateIsListed() throws {
        var v2 = Fixtures.package(version: "2.0.0")
        v2.connectors = []

        // Update released the component: the binding is gone.
        let released = try Fixtures.Environment()
        try released.install(Fixtures.package(version: "1.0.0"))
        let account = try #require(released.workspace.connectors.first)
        try released.importUpdate(v2)
        #expect(!account.accountBindings.contains { !$0.isDeleted })
        #expect(unused(released, listing: [v2]) == [account.id])

        // The automatic pass held the release back: still bound, but to a
        // component the row's definition no longer shows.
        let withheld = try Fixtures.Environment()
        try withheld.install(Fixtures.package(version: "1.0.0"))
        let kept = try #require(withheld.workspace.connectors.first)
        try withheld.importUpdate(v2, mode: .automatic)
        #expect(kept.accountBindings.contains { !$0.isDeleted })
        #expect(unused(withheld, listing: [v2]) == [kept.id])
    }
}
