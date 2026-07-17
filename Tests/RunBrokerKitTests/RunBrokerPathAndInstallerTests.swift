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
        #expect(prod.installerLockURL != dev.installerLockURL)
        #expect(prod.ledgerDirectoryURL != dev.ledgerDirectoryURL)
        #expect(prod.launchAgentPlistURL != dev.launchAgentPlistURL)
    }

    @Test("Installer lock serializes independent OS processes")
    func installerLockSerializesProcesses() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try fixture.secureStore.ensurePrivateDirectory(fixture.identity.supportDirectory)
        let lock = try RunBrokerInstallationTransactionLock.acquire(
            at: fixture.identity.installerLockURL,
            expectedUserID: getuid()
        )
        let ready = fixture.root.appendingPathComponent("child-ready")
        let acquired = fixture.root.appendingPathComponent("child-acquired")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys
            fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOFOLLOW)
            with open(sys.argv[2], "w") as marker:
                marker.write("ready")
                marker.flush()
                os.fsync(marker.fileno())
            fcntl.flock(fd, fcntl.LOCK_EX)
            with open(sys.argv[3], "w") as marker:
                marker.write("acquired")
            """,
            fixture.identity.installerLockURL.path,
            ready.path,
            acquired.path
        ]
        try process.run()
        try waitForInstallerMarker(ready)
        #expect(process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: acquired.path))

        lock.release()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: acquired.path))
    }

    @Test("Older payload waiting behind a newer install cannot downgrade Current")
    func serializedRaceRejectsDowngrade() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let controller = ThreadSafeLaunchController()
        let health = BlockingHealthChecker()
        let installer = RunBrokerInstaller(
            launchController: controller,
            healthChecker: health,
            secureStore: fixture.secureStore,
            userID: getuid(),
            diagnostics: NoOpRunBrokerDiagnostics()
        )
        let newerSource = try fixture.sourceExecutable(name: "sources/v2", bytes: "newer")
        let olderSource = try fixture.sourceExecutable(name: "sources/v1", bytes: "older")
        let newer = try fixture.payload(source: newerSource, version: "2")
        let older = try fixture.payload(source: olderSource, version: "1")
        let results = ConcurrentInstallerResults()
        let newerFinished = DispatchSemaphore(value: 0)
        let olderFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            results.setNewer(Result { try installer.install(payload: newer, identity: fixture.identity) })
            newerFinished.signal()
        }
        #expect(health.entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            results.setOlder(Result { try installer.install(payload: older, identity: fixture.identity) })
            olderFinished.signal()
        }
        #expect(olderFinished.wait(timeout: .now() + 0.15) == .timedOut)
        #expect(controller.reloadCount == 1)

        health.proceed.signal()
        #expect(newerFinished.wait(timeout: .now() + 2) == .success)
        #expect(olderFinished.wait(timeout: .now() + 2) == .success)
        #expect(results.newerError == nil)
        #expect(
            results.olderError as? RunBrokerInstallationError
                == .payloadDowngradeRejected(current: "2", requested: "1")
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.identity.currentPayloadURL.path
            ) == "Versions/2"
        )
        #expect(controller.reloadCount == 1)
    }

    @Test("Installer lock is private and symlink substitution fails closed")
    func installerLockSecurity() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source = try fixture.sourceExecutable(name: "sources/v1", bytes: "one")
        _ = try fixture.installer.install(
            payload: try fixture.payload(source: source, version: "1"),
            identity: fixture.identity
        )
        var info = stat()
        #expect(lstat(fixture.identity.installerLockURL.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFREG)
        #expect(UInt16(info.st_mode & 0o777) == 0o600)
        #expect(info.st_nlink == 1)

        let hardLink = fixture.root.appendingPathComponent("installer-lock-hard-link")
        #expect(link(fixture.identity.installerLockURL.path, hardLink.path) == 0)
        #expect(throws: RunBrokerInstallationError.unsafeInstallerLock) {
            try fixture.installer.install(
                payload: try fixture.payload(source: source, version: "1"),
                identity: fixture.identity
            )
        }
        try FileManager.default.removeItem(at: hardLink)

        try FileManager.default.removeItem(at: fixture.identity.installerLockURL)
        let outside = fixture.root.appendingPathComponent("outside-lock")
        try Data().write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(
            at: fixture.identity.installerLockURL,
            withDestinationURL: outside
        )
        #expect(throws: (any Error).self) {
            try fixture.installer.install(
                payload: try fixture.payload(source: source, version: "1"),
                identity: fixture.identity
            )
        }
    }

    @Test("First install may be unorderable but later upgrade precedence must be orderable")
    func unorderableVersionPolicy() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source1 = try fixture.sourceExecutable(name: "sources/dev", bytes: "dev")
        let source2 = try fixture.sourceExecutable(name: "sources/release", bytes: "release")

        _ = try fixture.installer.install(
            payload: try fixture.payload(source: source1, version: "pre-release"),
            identity: fixture.identity
        )
        #expect(throws: RunBrokerInstallationError.unorderablePayloadVersion("pre-release")) {
            try fixture.installer.install(
                payload: try fixture.payload(
                    source: source2,
                    version: "1.0.0-2-22222222222222222222222222222222"
                ),
                identity: fixture.identity
            )
        }
    }

    @Test("Different payload versions cannot claim the same numeric build")
    func sameBuildCollision() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source1 = try fixture.sourceExecutable(name: "sources/build-a", bytes: "one")
        let source2 = try fixture.sourceExecutable(name: "sources/build-b", bytes: "two")
        let current = "1.0.0-42-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let requested = "1.0.1-42-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

        _ = try fixture.installer.install(
            payload: try fixture.payload(source: source1, version: current),
            identity: fixture.identity
        )
        #expect(throws: RunBrokerInstallationError.payloadBuildCollision(
            current: current,
            requested: requested
        )) {
            try fixture.installer.install(
                payload: try fixture.payload(source: source2, version: requested),
                identity: fixture.identity
            )
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.identity.currentPayloadURL.path
            ) == "Versions/\(current)"
        )
        #expect(fixture.launchController.reloadCount == 1)
    }

    @Test("Exact version reinstall requires the original full payload digest")
    func exactVersionDigestCollision() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source1 = try fixture.sourceExecutable(name: "sources/exact-a", bytes: "one")
        let source2 = try fixture.sourceExecutable(name: "sources/exact-b", bytes: "two")
        let version = "1.0.0-42-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        _ = try fixture.installer.install(
            payload: try fixture.payload(source: source1, version: version),
            identity: fixture.identity
        )
        #expect(throws: RunBrokerInstallationError.installedDigestMismatch) {
            try fixture.installer.install(
                payload: try fixture.payload(source: source2, version: version),
                identity: fixture.identity
            )
        }
        #expect(fixture.launchController.reloadCount == 1)
    }

    @Test("Exact version reinstall rejects hard-linked installed payloads before reload")
    func exactVersionHardLinkFailsClosed() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source = try fixture.sourceExecutable(name: "sources/hard-link", bytes: "one")
        let payload = try fixture.payload(
            source: source,
            version: "1.0.0-42-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        let result = try fixture.installer.install(payload: payload, identity: fixture.identity)
        let hardLink = fixture.root.appendingPathComponent("installed-broker-hard-link")
        #expect(link(result.executableURL.path, hardLink.path) == 0)

        #expect(throws: RunBrokerInstallationError.unsafeExistingPayload) {
            try fixture.installer.install(payload: payload, identity: fixture.identity)
        }
        #expect(fixture.launchController.reloadCount == 1)
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
        #expect(FileManager.default.isExecutableFile(atPath: result.supervisorExecutableURL.path))
        #expect(try String(contentsOf: result.executableURL) == "v1")
        #expect(try String(contentsOf: result.supervisorExecutableURL) == "supervisor")
        let resolved = try RunBrokerCohortResolver.resolve(
            brokerExecutableURL: fixture.identity.currentExecutableURL
        )
        #expect(resolved.brokerExecutableURL == result.executableURL)
        #expect(resolved.supervisorExecutableURL == result.supervisorExecutableURL)
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

    @Test("Runtime cohort resolution rejects an incomplete or permission-weakened pair")
    func runtimeCohortResolutionFailsClosed() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let source = try fixture.sourceExecutable(name: "sources/resolver", bytes: "broker")
        let result = try fixture.installer.install(
            payload: try fixture.payload(source: source, version: "1"),
            identity: fixture.identity
        )

        let cohortDirectory = result.executableURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: cohortDirectory.path
        )
        #expect(throws: RunBrokerInstallationError.installedCohortIncomplete) {
            try RunBrokerCohortResolver.resolve(
                brokerExecutableURL: fixture.identity.currentExecutableURL
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: cohortDirectory.path
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: result.supervisorExecutableURL.path
        )
        #expect(throws: RunBrokerInstallationError.installedCohortIncomplete) {
            try RunBrokerCohortResolver.resolve(
                brokerExecutableURL: fixture.identity.currentExecutableURL
            )
        }

        try FileManager.default.removeItem(at: result.supervisorExecutableURL)
        #expect(throws: RunBrokerInstallationError.installedCohortIncomplete) {
            try RunBrokerCohortResolver.resolve(
                brokerExecutableURL: fixture.identity.currentExecutableURL
            )
        }
    }

    @Test("Partial cohort staging is removed without activating or reloading")
    func partialCohortStagingRollsBack() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let broker = try fixture.sourceExecutable(name: "sources/partial-broker", bytes: "broker")
        let supervisor = try fixture.sourceExecutable(
            name: "sources/partial-supervisor",
            bytes: "supervisor"
        )
        let payload = try fixture.payload(
            source: broker,
            supervisorSource: supervisor,
            version: "1"
        )
        let installer = RunBrokerInstaller(
            launchController: fixture.launchController,
            healthChecker: fixture.healthChecker,
            secureStore: fixture.secureStore,
            userID: getuid(),
            stagingIdentifier: {
                _ = unlink(supervisor.path)
                return "partial-cohort"
            },
            diagnostics: NoOpRunBrokerDiagnostics()
        )

        #expect(throws: RunBrokerInstallationError.sourceIsNotRegularExecutable) {
            try installer.install(payload: payload, identity: fixture.identity)
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.identity.versionsDirectory.appendingPathComponent("1").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.identity.versionsDirectory
                .appendingPathComponent(".installing-partial-cohort").path
        ))
        #expect(!FileManager.default.fileExists(atPath: fixture.identity.currentPayloadURL.path))
        #expect(fixture.launchController.reloadCount == 0)
    }

    @Test("Exact version rejects a changed supervisor digest")
    func exactVersionSupervisorCollision() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let broker = try fixture.sourceExecutable(name: "sources/stable-broker", bytes: "broker")
        let supervisor1 = try fixture.sourceExecutable(name: "sources/supervisor-a", bytes: "one")
        let supervisor2 = try fixture.sourceExecutable(name: "sources/supervisor-b", bytes: "two")
        let version = "1.0.0-42-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        _ = try fixture.installer.install(
            payload: try fixture.payload(
                source: broker,
                supervisorSource: supervisor1,
                version: version
            ),
            identity: fixture.identity
        )
        #expect(throws: RunBrokerInstallationError.installedDigestMismatch) {
            try fixture.installer.install(
                payload: try fixture.payload(
                    source: broker,
                    supervisorSource: supervisor2,
                    version: version
                ),
                identity: fixture.identity
            )
        }
        #expect(fixture.launchController.reloadCount == 1)
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
        #expect(FileManager.default.fileExists(
            atPath: fixture.identity.versionsDirectory
                .appendingPathComponent("1/astra-run-supervisor").path
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
        let supervisor = try fixture.sourceExecutable(
            name: "sources/supervisor",
            bytes: "supervisor"
        )
        let supervisorDigest = try RunBrokerInstaller.sha256(of: supervisor)

        #expect(throws: RunBrokerInstallationError.sourceIsNotRegularExecutable) {
            _ = try fixture.installer.install(
                payload: try .init(
                    sourceExecutableURL: link,
                    sourceSupervisorExecutableURL: supervisor,
                    version: try .init(rawValue: "link"),
                    expectedSHA256: digest,
                    expectedSupervisorSHA256: supervisorDigest,
                    expectedCohortSHA256: try RunBrokerCohort.digest(
                        brokerSHA256: digest,
                        supervisorSHA256: supervisorDigest
                    )
                ),
                identity: fixture.identity
            )
        }
        #expect(throws: RunBrokerInstallationError.sourceDigestMismatch) {
            let wrongDigest = try RunBrokerSHA256Digest(
                rawValue: String(repeating: "0", count: 64)
            )
            _ = try fixture.installer.install(
                payload: try .init(
                    sourceExecutableURL: source,
                    sourceSupervisorExecutableURL: supervisor,
                    version: try .init(rawValue: "bad-digest"),
                    expectedSHA256: wrongDigest,
                    expectedSupervisorSHA256: supervisorDigest,
                    expectedCohortSHA256: try RunBrokerCohort.digest(
                        brokerSHA256: wrongDigest,
                        supervisorSHA256: supervisorDigest
                    )
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

    func payload(
        source: URL,
        supervisorSource: URL? = nil,
        version: String
    ) throws -> RunBrokerPayload {
        let supervisor: URL
        if let supervisorSource {
            supervisor = supervisorSource
        } else {
            supervisor = source.appendingPathExtension("supervisor")
            try Data("supervisor".utf8).write(to: supervisor)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: supervisor.path
            )
        }
        let brokerDigest = try RunBrokerInstaller.sha256(of: source)
        let supervisorDigest = try RunBrokerInstaller.sha256(of: supervisor)
        return try .init(
            sourceExecutableURL: source,
            sourceSupervisorExecutableURL: supervisor,
            version: try .init(rawValue: version),
            expectedSHA256: brokerDigest,
            expectedSupervisorSHA256: supervisorDigest,
            expectedCohortSHA256: try RunBrokerCohort.digest(
                brokerSHA256: brokerDigest,
                supervisorSHA256: supervisorDigest
            )
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

private final class ThreadSafeLaunchController: RunBrokerLaunchControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var reloads = 0
    var reloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reloads
    }
    func reload(_ agent: RunBrokerLaunchAgent) throws {
        lock.lock()
        reloads += 1
        lock.unlock()
    }
    func unload(_ agent: RunBrokerLaunchAgent) throws {}
}

private final class BlockingHealthChecker: RunBrokerPostReloadHealthChecking, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    func waitUntilHealthy(
        identity: RunBrokerChannelIdentity,
        installationID: RunBrokerInstallationID,
        expectedVersion: RunBrokerPayloadVersion
    ) throws {
        entered.signal()
        _ = proceed.wait(timeout: .now() + 5)
    }
}

private final class ConcurrentInstallerResults: @unchecked Sendable {
    private let lock = NSLock()
    private var newer: Result<RunBrokerInstallationResult, any Error>?
    private var older: Result<RunBrokerInstallationResult, any Error>?

    var newerError: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return newer?.failure
    }

    var olderError: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return older?.failure
    }

    func setNewer(_ result: Result<RunBrokerInstallationResult, any Error>) {
        lock.lock()
        newer = result
        lock.unlock()
    }

    func setOlder(_ result: Result<RunBrokerInstallationResult, any Error>) {
        lock.lock()
        older = result
        lock.unlock()
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

private func waitForInstallerMarker(_ url: URL) throws {
    let deadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: url.path) {
        guard Date() < deadline else {
            throw RunBrokerInstallationError.healthCheckFailed
        }
        usleep(10_000)
    }
}

private struct FixedInstallerRandom: RunBrokerRandomGenerating {
    func randomBytes(count: Int) throws -> Data { Data(repeating: 0x42, count: count) }
}
