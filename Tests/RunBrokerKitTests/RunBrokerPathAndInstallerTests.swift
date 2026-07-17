import Foundation
import Darwin
import Testing
import ASTRACore
@testable import RunBrokerKit

@Suite("RunBroker channel paths and LaunchAgent installer")
struct RunBrokerPathAndInstallerTests {
    @Test("Production and development identities are disjoint")
    func channelIsolation() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let prod = RunBrokerChannelIdentity(
            channel: .production,
            homeDirectory: home,
            channelApplicationSupportDirectory: home.appendingPathComponent("Library/Application Support/Astra")
        )
        let dev = RunBrokerChannelIdentity(
            channel: .development,
            homeDirectory: home,
            channelApplicationSupportDirectory: home.appendingPathComponent("Library/Application Support/AstraDev")
        )
        #expect(prod.launchAgentLabel != dev.launchAgentLabel)
        #expect(prod.socketURL != dev.socketURL)
        #expect(prod.capabilitySecretURL != dev.capabilitySecretURL)
        #expect(prod.installationIDURL != dev.installationIDURL)
        #expect(prod.launchAgentPlistURL != dev.launchAgentPlistURL)
    }

    @Test("Installed broker survives source app replacement and plist uses stable external paths")
    func survivesAppReplacement() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source = try fixture.sourceExecutable(name: "ASTRA.app/Contents/Resources/astra-run-broker", bytes: "v1")
        let payload = try fixture.payload(source: source, version: "1.0.0")

        let result = try fixture.installer.install(payload: payload, identity: fixture.identity)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ASTRA.app"))

        #expect(FileManager.default.isExecutableFile(atPath: result.executableURL.path))
        #expect(try String(contentsOf: result.executableURL) == "v1")
        let plist = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: fixture.identity.launchAgentPlistURL),
                format: nil
            ) as? [String: Any]
        )
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.first == fixture.identity.currentExecutableURL.path)
        #expect(!arguments.joined(separator: " ").contains("ASTRA.app"))
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
    }

    @Test("Upgrade atomically selects a new immutable version and retains rollback payload")
    func atomicUpgrade() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source1 = try fixture.sourceExecutable(name: "sources/v1", bytes: "one")
        let source2 = try fixture.sourceExecutable(name: "sources/v2", bytes: "two")
        _ = try fixture.installer.install(
            payload: try fixture.payload(source: source1, version: "1"),
            identity: fixture.identity
        )
        _ = try fixture.installer.install(
            payload: try fixture.payload(source: source2, version: "2"),
            identity: fixture.identity
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.identity.currentPayloadURL.path
            ) == "Versions/2"
        )
        #expect(FileManager.default.fileExists(
            atPath: fixture.identity.versionsDirectory.appendingPathComponent("1/astra-run-broker").path
        ))
        #expect(fixture.launchController.reloadCount == 2)
    }

    @Test("Failed post-reload health check rolls selector back and reloads prior payload")
    func healthRollback() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source1 = try fixture.sourceExecutable(name: "sources/v1", bytes: "one")
        let source2 = try fixture.sourceExecutable(name: "sources/v2", bytes: "two")
        _ = try fixture.installer.install(
            payload: try fixture.payload(source: source1, version: "1"),
            identity: fixture.identity
        )
        fixture.healthChecker.shouldFail = true

        #expect(throws: RunBrokerInstallationError.healthCheckFailed) {
            try fixture.installer.install(
                payload: try fixture.payload(source: source2, version: "2"),
                identity: fixture.identity
            )
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.identity.currentPayloadURL.path
            ) == "Versions/1"
        )
        #expect(fixture.launchController.reloadCount == 3)
    }

    @Test("Initial install health failure unloads the newly loaded service")
    func initialHealthFailureUnloads() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        fixture.healthChecker.shouldFail = true
        let source = try fixture.sourceExecutable(name: "sources/v1", bytes: "one")
        #expect(throws: RunBrokerInstallationError.healthCheckFailed) {
            try fixture.installer.install(
                payload: try fixture.payload(source: source, version: "1"),
                identity: fixture.identity
            )
        }
        #expect(fixture.launchController.reloadCount == 1)
        #expect(fixture.launchController.unloadCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.currentPayloadURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.launchAgentPlistURL.path))
    }

    @Test("Installer does not mutate permissions of an existing LaunchAgents directory")
    func preservesExternalParentPermissions() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let launchAgents = fixture.identity.launchAgentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchAgents.path)
        let source = try fixture.sourceExecutable(name: "sources/v1", bytes: "one")
        _ = try fixture.installer.install(
            payload: try fixture.payload(source: source, version: "1"),
            identity: fixture.identity
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: launchAgents.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o755)
    }

    @Test("Existing version symlink is rejected instead of followed")
    func existingVersionSymlink() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source = try fixture.sourceExecutable(name: "sources/v1", bytes: "one")
        _ = try fixture.secureStore.loadOrCreate(identity: fixture.identity)
        try fixture.secureStore.ensurePrivateDirectory(fixture.identity.versionsDirectory)
        let outside = fixture.root.appendingPathComponent("outside-version", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.identity.versionsDirectory.appendingPathComponent("1"),
            withDestinationURL: outside
        )
        #expect(throws: RunBrokerInstallationError.unsafeExistingPayload) {
            try fixture.installer.install(
                payload: try fixture.payload(source: source, version: "1"),
                identity: fixture.identity
            )
        }
    }

    @Test("Installer rejects symlink and digest-mismatched source payloads")
    func sourceValidation() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source = try fixture.sourceExecutable(name: "sources/real", bytes: "real")
        let link = fixture.root.appendingPathComponent("sources/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let digest = try RunBrokerInstaller.sha256(of: source)

        #expect(throws: RunBrokerInstallationError.sourceIsNotRegularExecutable) {
            try fixture.installer.install(
                payload: .init(
                    sourceExecutableURL: link,
                    version: try .init(rawValue: "link"),
                    expectedSHA256: digest
                ),
                identity: fixture.identity
            )
        }
        #expect(throws: RunBrokerInstallationError.sourceDigestMismatch) {
            try fixture.installer.install(
                payload: .init(
                    sourceExecutableURL: source,
                    version: try .init(rawValue: "bad-digest"),
                    expectedSHA256: try .init(rawValue: String(repeating: "0", count: 64))
                ),
                identity: fixture.identity
            )
        }
    }

    @Test("Capability material is regular 0600 and symlink substitution fails closed")
    func secureSecretFiles() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let store = RunBrokerSecureStore(
            expectedUserID: getuid(),
            random: FixedInstallerRandom()
        )
        _ = try store.loadOrCreate(identity: fixture.identity)
        var info = stat()
        #expect(lstat(fixture.identity.capabilitySecretURL.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFREG)
        #expect(UInt16(info.st_mode & 0o777) == 0o600)
        let secrets = try store.loadOrCreate(identity: fixture.identity)
        #expect(String(describing: secrets.capabilitySecret) == "<redacted run broker capability>")
        #expect(String(reflecting: secrets.capabilitySecret) == "<redacted run broker capability>")
        #expect(
            Mirror(reflecting: secrets.capabilitySecret).children
                .map { String(describing: $0.value) }
                == ["<redacted run broker capability>"]
        )

        try FileManager.default.removeItem(at: fixture.identity.capabilitySecretURL)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data(repeating: 1, count: 32).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.identity.capabilitySecretURL,
            withDestinationURL: outside
        )
        #expect(throws: (any Error).self) {
            try store.loadOrCreate(identity: fixture.identity)
        }
    }
}

private final class InstallerFixture {
    let root: URL
    let identity: RunBrokerChannelIdentity
    let launchController = FakeLaunchController()
    let healthChecker = FakeHealthChecker()
    let secureStore: RunBrokerSecureStore
    let installer: RunBrokerInstaller

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "astra-run-broker-installer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let appSupport = home.appendingPathComponent(
            "Library/Application Support/AstraDev",
            isDirectory: true
        )
        identity = RunBrokerChannelIdentity(
            channel: .development,
            homeDirectory: home,
            channelApplicationSupportDirectory: appSupport
        )
        secureStore = .init(expectedUserID: getuid(), random: FixedInstallerRandom())
        installer = RunBrokerInstaller(
            launchController: launchController,
            healthChecker: healthChecker,
            secureStore: secureStore,
            userID: getuid(),
            stagingIdentifier: { UUID().uuidString },
            diagnostics: NoOpRunBrokerDiagnostics()
        )
    }

    func sourceExecutable(name: String, bytes: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(bytes.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func payload(source: URL, version: String) throws -> RunBrokerPayload {
        .init(
            sourceExecutableURL: source,
            version: try .init(rawValue: version),
            expectedSHA256: try RunBrokerInstaller.sha256(of: source)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class FakeLaunchController: RunBrokerLaunchControlling, @unchecked Sendable {
    var reloadCount = 0
    var unloadCount = 0
    func reload(_ agent: RunBrokerLaunchAgent) throws { reloadCount += 1 }
    func unload(_ agent: RunBrokerLaunchAgent) throws { unloadCount += 1 }
}

private final class FakeHealthChecker: RunBrokerPostReloadHealthChecking, @unchecked Sendable {
    var shouldFail = false
    func waitUntilHealthy(
        identity: RunBrokerChannelIdentity,
        installationID: RunBrokerInstallationID,
        expectedVersion: RunBrokerPayloadVersion
    ) throws {
        if shouldFail { throw RunBrokerInstallationError.healthCheckFailed }
    }
}

private struct FixedInstallerRandom: RunBrokerRandomGenerating {
    func randomBytes(count: Int) throws -> Data { Data(repeating: 0x42, count: count) }
}
