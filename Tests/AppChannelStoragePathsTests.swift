import Foundation
import Testing
import ASTRACore
import ASTRAPersistence
@testable import ASTRA

@Suite("App Channel Storage Paths")
struct AppChannelStoragePathsTests {
    private let overrideKey =
        AppChannelStoragePaths.developmentApplicationSupportOverrideEnvironmentKey

    @Test("Development override isolates ASTRA state without replacing provider identity home")
    func developmentOverridePreservesProviderIdentityHome() {
        let isolatedAppSupport = "/tmp/astra-profile/Library/Application Support/AstraDev"
        let environment = [overrideKey: isolatedAppSupport]
        let userHome = "/Users/example"

        #expect(AppChannelStoragePaths.applicationSupportDirectory(
            for: .development,
            environment: environment
        ).path == isolatedAppSupport)
        #expect(WorkspaceRecoveryService.resolvedApplicationSupportDirectory(
            channel: .development,
            environment: environment
        ).path == isolatedAppSupport)
        #expect(CopilotCLIRuntime.channelHome(
            channel: .development,
            environment: environment
        ) == isolatedAppSupport + "/Copilot")

        let copilotAuthPaths = CopilotCLIRuntime.authReadablePaths(userHome: userHome)
        #expect(copilotAuthPaths.contains(userHome + "/.config/gh"))
        #expect(copilotAuthPaths.contains(userHome + "/Library/Keychains/login.keychain-db"))
        #expect(!copilotAuthPaths.contains { $0.hasPrefix(isolatedAppSupport) })

        let codexAuthPaths = CodexCLIRuntime.sandboxReadablePaths(
            providerHomeDirectory: "",
            environment: ["HOME": userHome],
            processHomeDirectory: userHome
        )
        #expect(codexAuthPaths.contains(userHome + "/.codex"))
        #expect(!codexAuthPaths.contains { $0.hasPrefix(isolatedAppSupport) })
    }

    @Test("Every ASTRA-owned Application Support consumer shares the development override")
    func consumersShareDevelopmentOverride() {
        let isolatedAppSupport = "/tmp/astra-profile/Library/Application Support/AstraDev"
        let environment = [overrideKey: isolatedAppSupport]

        #expect(CapabilityApprovalStore.approvalsDirectory(
            for: .development,
            environment: environment
        ).path == isolatedAppSupport + "/CapabilityApprovals")
        #expect(CapabilityLibrary.capabilitiesDirectory(
            for: .development,
            environment: environment
        ).path == isolatedAppSupport + "/Capabilities")
        #expect(AstraPackCatalog.localStorageRoot(
            for: .development,
            environment: environment
        ).path == isolatedAppSupport + "/Packs")
        #expect(IsolationService.copyScratchRoot(
            channel: .development,
            environment: environment
        ).path == isolatedAppSupport + "/WorkspaceCopies")
    }

    @Test("Production and beta ignore the development override")
    func nonDevelopmentChannelsIgnoreOverride() {
        let isolatedAppSupport = "/tmp/astra-profile/Library/Application Support/AstraDev"
        let environment = [overrideKey: isolatedAppSupport]

        let production = AppChannelStoragePaths.applicationSupportDirectory(
            for: .production,
            environment: environment
        )
        let beta = AppChannelStoragePaths.applicationSupportDirectory(
            for: .beta,
            environment: environment
        )

        #expect(production.lastPathComponent == AppChannel.production.appSupportDirectoryName)
        #expect(beta.lastPathComponent == AppChannel.beta.appSupportDirectoryName)
        #expect(production.path != isolatedAppSupport)
        #expect(beta.path != isolatedAppSupport)
    }

    @Test("Development override rejects relative and broad roots")
    func developmentOverrideRejectsUnsafePaths() {
        #expect(AppChannelStoragePaths.developmentApplicationSupportOverride(
            for: .development,
            environment: [overrideKey: "relative/AstraDev"]
        ) == nil)
        #expect(AppChannelStoragePaths.developmentApplicationSupportOverride(
            for: .development,
            environment: [overrideKey: "/tmp"]
        ) == nil)
        #expect(AppChannelStoragePaths.developmentApplicationSupportOverride(
            for: .development,
            environment: [overrideKey: "/tmp/Astra"]
        ) == nil)
    }
}
