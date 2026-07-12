import CoreData
import Foundation
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Persistent Store Recovery")
struct PersistentStoreRecoveryTests {
    @Test("newer sidecar schema blocks without modifying store or metadata")
    func newerSidecarFailsClosedByteForByte() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("default.store")
        let storeBytes = Data("healthy-newer-store".utf8)
        try storeBytes.write(to: storeURL)
        let metadata = PersistentStoreCompatibilityMetadata(
            schemaVersion: 12,
            minimumReaderSchemaVersion: 12,
            channel: "dev",
            appVersion: "0.2.0",
            appBuild: "20",
            gitCommit: "newer",
            bundlePath: "/tmp/ASTRA Dev.app"
        )
        try PersistentStoreCompatibilityService.writeMetadata(metadata, for: storeURL)
        let metadataURL = PersistentStoreCompatibilityService.metadataURL(for: storeURL)
        let metadataBytes = try Data(contentsOf: metadataURL)

        #expect(PersistentStoreCompatibilityService.assess(
            storeURL: storeURL,
            latestSupportedSchemaVersion: 11
        ) == .requiresNewerReader(requiredSchemaVersion: 12))
        #expect(try Data(contentsOf: storeURL) == storeBytes)
        #expect(try Data(contentsOf: metadataURL) == metadataBytes)
    }

    @Test("matching sidecar schema is compatible")
    func matchingSidecarIsCompatible() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("default.store")
        try Data().write(to: storeURL)
        try PersistentStoreCompatibilityService.writeMetadata(
            PersistentStoreCompatibilityMetadata(
                schemaVersion: 12,
                minimumReaderSchemaVersion: 12,
                channel: "dev",
                appVersion: "0.2.0",
                appBuild: "20",
                gitCommit: "same",
                bundlePath: "/tmp/ASTRA Dev.app"
            ),
            for: storeURL
        )

        #expect(PersistentStoreCompatibilityService.assess(
            storeURL: storeURL,
            latestSupportedSchemaVersion: 12
        ) == .compatible(storeSchemaVersion: 12))
    }

    @Test("legacy Core Data metadata identifies a newer schema read only")
    func legacyMetadataIdentifiesNewerSchema() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("legacy.store")
        try Data("unchanged".utf8).write(to: storeURL)
        let before = try Data(contentsOf: storeURL)

        let result = PersistentStoreCompatibilityService.assess(
            storeURL: storeURL,
            latestSupportedSchemaVersion: 11,
            persistentStoreMetadata: [NSStoreModelVersionIdentifiersKey: ["12.0.0"]]
        )

        #expect(result == .requiresNewerReader(requiredSchemaVersion: 12))
        #expect(try Data(contentsOf: storeURL) == before)
    }

    @Test("unrecognized legacy metadata remains unknown")
    func unrecognizedLegacyMetadataFailsClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("legacy.store")
        try Data().write(to: storeURL)

        #expect(PersistentStoreCompatibilityService.assess(
            storeURL: storeURL,
            latestSupportedSchemaVersion: 11,
            persistentStoreMetadata: [:]
        ) == .unknown)
    }

    @Test("development incompatibility prefers a registered compatible build")
    func developmentPolicyPrefersCompatibleBuild() {
        let blocker = PersistentStoreRecoveryPolicy.incompatibleBlocker(
            requiredSchemaVersion: 12,
            supportedSchemaVersion: 11,
            channel: "dev",
            compatibleBundlePath: "/tmp/ASTRA Dev V12.app"
        )

        #expect(blocker.kind == .incompatible(required: 12, supported: 11))
        #expect(blocker.actions.first == .openCompatibleBuild(bundlePath: "/tmp/ASTRA Dev V12.app"))
        #expect(blocker.actions.contains(.chooseStore))
        #expect(blocker.actions.contains(.quit))
    }

    @Test("production incompatibility routes through the updater")
    func productionPolicyUsesUpdater() {
        let blocker = PersistentStoreRecoveryPolicy.incompatibleBlocker(
            requiredSchemaVersion: 12,
            supportedSchemaVersion: 11,
            channel: "prod",
            compatibleBundlePath: nil
        )
        #expect(blocker.actions.first == .checkForUpdates)
    }

    @Test("development incompatibility can locate a pre-registry build")
    func developmentPolicyCanLocateCompatibleBuild() {
        let blocker = PersistentStoreRecoveryPolicy.incompatibleBlocker(
            requiredSchemaVersion: 12,
            supportedSchemaVersion: 11,
            channel: "dev",
            compatibleBundlePath: nil
        )
        #expect(blocker.actions.first == .locateCompatibleBuild(requiredSchemaVersion: 12))
    }

    @Test("post-open fallback preserves the actual required schema")
    func postOpenFallbackPreservesRequiredSchema() {
        #expect(PersistentStoreRecoveryPolicy.requiredSchemaVersion(
            afterOpenFailure: .requiresNewerReader(requiredSchemaVersion: 15),
            supportedSchemaVersion: 11
        ) == 15)
        #expect(PersistentStoreRecoveryPolicy.requiredSchemaVersion(
            afterOpenFailure: .unknown,
            supportedSchemaVersion: 11
        ) == 12)
    }

    @Test("store selection failure preserves actionable compatibility detail")
    func storeSelectionFailurePreservesCompatibilityDetail() {
        let newerMessage = PersistentStoreRecoveryPolicy.storeSelectionFailureMessage(
            assessment: .requiresNewerReader(requiredSchemaVersion: 15),
            supportedSchemaVersion: 11
        )
        #expect(newerMessage?.contains("requires schema V15") == true)
        #expect(newerMessage?.contains("supports through V11") == true)
        #expect(PersistentStoreRecoveryPolicy.storeSelectionFailureMessage(
            assessment: .compatible(storeSchemaVersion: 11),
            supportedSchemaVersion: 11
        ) == nil)
    }

    @Test("contention retries are bounded")
    func contentionRetriesAreBounded() {
        #expect(PersistentStoreRetryPolicy.contentionDelays == [0.10, 0.25, 0.50])
        #expect(PersistentStoreRetryPolicy.contentionDelays.reduce(0, +) < 1)
    }

    @Test("registry returns a validated compatible bundle and rejects wrong channel")
    func registryValidatesCandidateBundles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("registry.json")
        let bundleURL = try makeBundle(
            root: root,
            name: "ASTRA Dev V12",
            identifier: "com.coral.ASTRA.dev",
            channel: "dev",
            schemaVersion: 12
        )
        let bundle = try #require(Bundle(url: bundleURL))
        let info = AppBuildInfo(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundlePath: bundleURL.path,
            executablePath: bundle.executableURL?.path ?? "unknown"
        )
        try CompatibleASTRABuildRegistry.registerCurrentBuild(
            appInfo: info,
            bundle: bundle,
            registryURL: registryURL,
            now: Date(timeIntervalSince1970: 100)
        )

        let candidate = CompatibleASTRABuildRegistry.compatibleBuild(
            requiredSchemaVersion: 12,
            channel: "dev",
            excludingBundlePath: "/tmp/current.app",
            registryURL: registryURL
        )
        #expect(candidate?.bundlePath == bundleURL.path)
        #expect(CompatibleASTRABuildRegistry.compatibleBuild(
            at: bundleURL,
            requiredSchemaVersion: 12,
            channel: "dev"
        )?.bundlePath == bundleURL.path)
        #expect(CompatibleASTRABuildRegistry.compatibleBuild(
            requiredSchemaVersion: 12,
            channel: "prod",
            excludingBundlePath: "/tmp/current.app",
            registryURL: registryURL
        ) == nil)
    }

    @Test("registry rejects a bundle that only claims the ASTRA channel")
    func registryRejectsSpoofedBundleIdentifier() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("registry.json")
        let bundleURL = try makeBundle(
            root: root,
            name: "Not ASTRA",
            identifier: "example.not-astra",
            channel: "dev",
            schemaVersion: 12
        )
        let bundle = try #require(Bundle(url: bundleURL))
        let info = AppBuildInfo(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundlePath: bundleURL.path,
            executablePath: bundle.executableURL?.path ?? "unknown"
        )
        try CompatibleASTRABuildRegistry.registerCurrentBuild(
            appInfo: info,
            bundle: bundle,
            registryURL: registryURL
        )

        #expect(CompatibleASTRABuildRegistry.compatibleBuild(
            requiredSchemaVersion: 12,
            channel: "dev",
            excludingBundlePath: "/tmp/current.app",
            registryURL: registryURL
        ) == nil)
    }

    @Test("registry canonicalizes a symlinked launch bundle before persisting")
    func registryCanonicalizesSymlinkedBundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("registry.json")
        let bundleURL = try makeBundle(
            root: root,
            name: "ASTRA Dev V12",
            identifier: "com.coral.ASTRA.dev",
            channel: "dev",
            schemaVersion: 12
        )
        let symlinkURL = root.appendingPathComponent("Current ASTRA Dev.app")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: bundleURL)
        let symlinkedBundle = try #require(Bundle(url: symlinkURL))
        let info = AppBuildInfo(
            infoDictionary: symlinkedBundle.infoDictionary ?? [:],
            bundlePath: symlinkURL.path,
            executablePath: symlinkedBundle.executableURL?.path ?? "unknown"
        )

        try CompatibleASTRABuildRegistry.registerCurrentBuild(
            appInfo: info,
            bundle: symlinkedBundle,
            registryURL: registryURL
        )

        let record = try #require(CompatibleASTRABuildRegistry.load(registryURL: registryURL).first)
        #expect(record.bundlePath == bundleURL.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(CompatibleASTRABuildRegistry.compatibleBuild(
            requiredSchemaVersion: 12,
            channel: "dev",
            excludingBundlePath: "/tmp/current.app",
            registryURL: registryURL
        )?.bundlePath == bundleURL.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-store-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(
        root: URL,
        name: String,
        identifier: String,
        channel: String,
        schemaVersion: Int
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let executableURL = macOSURL.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let plist: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "20",
            "CFBundlePackageType": "APPL",
            "ASTRAChannel": channel,
            "ASTRASchemaVersion": schemaVersion,
            "ASTRAGitCommit": "candidate",
            "ASTRABuildDate": "2026-07-11T00:00:00Z"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}
