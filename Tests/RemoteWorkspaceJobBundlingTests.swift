import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Packaged SSH helper discovery")
@MainActor
struct RemoteWorkspaceJobBundlingTests {
    @Test("The packaged helper wins over a stale shared copy", arguments: [true, false])
    func packagedHelper(macOSLayout: Bool) throws {
        let fixture = try Fixture(macOSLayout: macOSLayout)
        defer { fixture.cleanup() }
        #expect(RemoteWorkspaceJobShim.resolvedHelperPath(resourceBundle: fixture.bundle,
            applicationBundleURL: fixture.app, fallbackDirectory: fixture.fallback.path) == fixture.helper.resolvingSymlinksInPath().path)
    }

    @Test("A packaged app refuses a missing helper even when a shared copy exists")
    func missingPackagedHelper() throws {
        let fixture = try Fixture(macOSLayout: true, includeHelper: false)
        defer { fixture.cleanup() }
        #expect(RemoteWorkspaceJobShim.resolvedHelperPath(resourceBundle: fixture.bundle,
            applicationBundleURL: fixture.app, fallbackDirectory: fixture.fallback.path) == nil)
        #expect(RemoteWorkspaceJobShim.resolvedHelperPath(resourceBundle: fixture.bundle,
            applicationBundleURL: fixture.root, fallbackDirectory: fixture.fallback.path) != nil)
    }

    @Test("Launch grants only read the exact helper and existing owner receipt")
    func narrowReadGrants() {
        let helper = "/Applications/ASTRA Dev.app/Contents/Resources/ASTRA_ASTRA.bundle/Contents/Resources/Tools/astra-workspace-job"
        let receipt = "/Users/qa/Library/Application Support/AstraDev/runtime-owners/task.json"
        let grants = RemoteWorkspaceJobLaunchPolicy.readableGrants(helperPath: helper, receiptPath: receipt)
        #expect(grants.map(\.path) == [helper, receipt])
        #expect(grants.allSatisfy { $0.access == .read && $0.source == .controlPlane && $0.lifetime == .run })
        #expect(!grants.contains { $0.path == "/Applications" })
    }

    @Test("An isolated development store also isolates installed tools")
    func isolatedToolInstallation() throws {
        let base = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let isolated = base.appendingPathComponent("ASTRA SSH QA Unit/AstraDev")
        let environment = [AppChannelStoragePaths.developmentApplicationSupportOverrideEnvironmentKey: isolated.path]
        #expect(RuntimePathResolver.toolsDirectory(channel: .development, environment: environment)
            == isolated.resolvingSymlinksInPath().appendingPathComponent("Tools").path)
        #expect(RuntimePathResolver.toolsDirectory(channel: .production, environment: environment)
            == RuntimePathResolver.toolsDirectory(channel: .production, environment: [:]))
    }

    private struct Fixture {
        let root: URL, app: URL, fallback: URL, helper: URL, bundle: Bundle
        init(macOSLayout: Bool, includeHelper: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            app = root.appendingPathComponent("ASTRA QA.app")
            fallback = root.appendingPathComponent("shared-tools")
            let bundleURL = root.appendingPathComponent("ASTRA_ASTRA.bundle")
            let resources = macOSLayout ? bundleURL.appendingPathComponent("Contents/Resources") : bundleURL
            helper = resources.appendingPathComponent("Tools/astra-workspace-job")
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            let info = macOSLayout ? bundleURL.appendingPathComponent("Contents/Info.plist") : bundleURL.appendingPathComponent("Info.plist")
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.ssh." + UUID().uuidString,
                "CFBundleVersion": "1", "CFBundlePackageType": "BNDL"], format: .xml, options: 0).write(to: info)
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            for url in [fallback.appendingPathComponent("astra-workspace-job")] + (includeHelper ? [helper] : []) {
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            bundle = try #require(Bundle(url: bundleURL))
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
