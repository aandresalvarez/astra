import Darwin
import Foundation
import Testing
import ASTRACore
@testable import RunBrokerClient

@Suite("RunBroker read-only client bootstrap", .serialized)
struct RunBrokerClientBootstrapTests {
    @Test("bootstrap reads exact private material without mutating the layout")
    func readOnlyBootstrapDoesNotMutate() async throws {
        let fixture = try ClientBootstrapFixture()
        defer { fixture.cleanup() }
        let before = try fixture.snapshot()

        let bootstrap = try await fixture.loader.load(channel: .development)

        #expect(bootstrap.installationID == fixture.installationID)
        #expect(try fixture.snapshot() == before)
    }

    @Test("every connection revalidates a replaced socket path")
    func freshConnectionRevalidatesSocketPath() async throws {
        let fixture = try ClientBootstrapFixture()
        defer { fixture.cleanup() }
        let bootstrap = try await fixture.loader.load(channel: .development)

        fixture.closeSocket()
        let socketURL = fixture.support
            .appendingPathComponent("IPC", isDirectory: true)
            .appendingPathComponent("broker.sock")
        try FileManager.default.removeItem(at: socketURL)
        try ClientBootstrapFixture.createPrivateFile(Data(), at: socketURL)

        await #expect(throws: RunBrokerClientBootstrapError.unsafeSocket("broker.sock")) {
            _ = try await bootstrap.client.performAsync(.health)
        }
    }

    @Test("production and development credentials never fall back across channels")
    func channelsAreIsolated() async throws {
        let development = try ClientBootstrapFixture(channel: .development)
        defer { development.cleanup() }
        let developmentBefore = try development.snapshot()
        #expect(
            try await development.loader.load(channel: .development).installationID
                == development.installationID
        )
        await #expect(throws: (any Error).self) {
            _ = try await development.loader.load(channel: .production)
        }
        #expect(try development.snapshot() == developmentBefore)

        let production = try ClientBootstrapFixture(channel: .production)
        defer { production.cleanup() }
        #expect(
            try await production.loader.load(channel: .production).installationID
                == production.installationID
        )
        await #expect(throws: (any Error).self) {
            _ = try await production.loader.load(channel: .development)
        }
    }

    @Test("development bootstrap uses the resolved channel Application Support directory")
    func resolvedDevelopmentApplicationSupportDirectory() async throws {
        let fixture = try ClientBootstrapFixture(
            channel: .development,
            applicationSupportSubdirectory: "Disposable/AstraDev"
        )
        defer { fixture.cleanup() }

        let bootstrap = try await fixture.loader.load(channel: .development)

        #expect(bootstrap.installationID == fixture.installationID)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home
                .appendingPathComponent("Library/Application Support/AstraDev/RunBroker")
                .path
        ))
    }

    @Test("missing and symlinked components fail closed without creation")
    func missingAndSymlinkedPathsFailClosed() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rbm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        guard chmod(root.path, 0o700) == 0, chmod(home.path, 0o700) == 0 else {
            throw ClientBootstrapFixtureError.systemCall("chmod-missing-root", errno)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try directorySnapshot(root: root)
        await #expect(throws: (any Error).self) {
            _ = try await RunBrokerClientBootstrapLoader(
                expectedUserID: getuid(),
                testingHomeDirectoryURL: home
            ).load(channel: .development)
        }
        #expect(try directorySnapshot(root: root) == before)

        let fixture = try ClientBootstrapFixture()
        defer { fixture.cleanup() }
        let library = fixture.home.appendingPathComponent("Library", isDirectory: true)
        let moved = fixture.root.appendingPathComponent("real-library", isDirectory: true)
        try FileManager.default.moveItem(
            at: library,
            to: moved
        )
        try FileManager.default.createSymbolicLink(
            at: library,
            withDestinationURL: moved
        )
        let symlinkBefore = try fixture.snapshot()
        await #expect(throws: (any Error).self) {
            _ = try await fixture.loader.load(channel: .development)
        }
        #expect(try fixture.snapshot() == symlinkBefore)
    }

    @Test("filesystem capability is ignored and non-socket endpoint fails closed")
    func modeAndEndpointTypeFailClosed() async throws {
        let credentialFixture = try ClientBootstrapFixture()
        defer { credentialFixture.cleanup() }
        let key = credentialFixture.support
            .appendingPathComponent("Authentication", isDirectory: true)
            .appendingPathComponent("capability.key")
        guard chmod(key.path, 0o644) == 0 else {
            throw ClientBootstrapFixtureError.systemCall("chmod-key", errno)
        }
        #expect(try await credentialFixture.loader.load(channel: .development).installationID
            == credentialFixture.installationID)

        let endpointFixture = try ClientBootstrapFixture()
        defer { endpointFixture.cleanup() }
        endpointFixture.closeSocket()
        let socketURL = endpointFixture.support
            .appendingPathComponent("IPC", isDirectory: true)
            .appendingPathComponent("broker.sock")
        try FileManager.default.removeItem(at: socketURL)
        #expect(FileManager.default.createFile(atPath: socketURL.path, contents: Data()))
        guard chmod(socketURL.path, 0o600) == 0 else {
            throw ClientBootstrapFixtureError.systemCall("chmod-fake-socket", errno)
        }
        await #expect(throws: RunBrokerClientBootstrapError.unsafeSocket("broker.sock")) {
            _ = try await endpointFixture.loader.load(channel: .development)
        }
    }

    @Test("hardlinked and oversized filesystem capabilities are never authority")
    func hardlinkAndOversizeFailClosed() async throws {
        let hardlinkFixture = try ClientBootstrapFixture()
        defer { hardlinkFixture.cleanup() }
        let key = hardlinkFixture.authentication.appendingPathComponent("capability.key")
        let alias = hardlinkFixture.authentication.appendingPathComponent("capability.alias")
        guard link(key.path, alias.path) == 0 else {
            throw ClientBootstrapFixtureError.systemCall("hardlink", errno)
        }
        #expect(try await hardlinkFixture.loader.load(channel: .development).installationID
            == hardlinkFixture.installationID)

        let oversizedFixture = try ClientBootstrapFixture()
        defer { oversizedFixture.cleanup() }
        let oversized = oversizedFixture.authentication.appendingPathComponent("capability.key")
        try FileManager.default.removeItem(at: oversized)
        try ClientBootstrapFixture.createPrivateFile(
            Data(repeating: 0xA5, count: RunBrokerAuthenticationPolicy.secretByteCount + 1),
            at: oversized
        )
        #expect(try await oversizedFixture.loader.load(channel: .development).installationID
            == oversizedFixture.installationID)
    }

    @Test("installation ID canonical form is exact and filesystem secret is ignored")
    func exactCredentialFormatsAreRequired() async throws {
        let identifierFixture = try ClientBootstrapFixture()
        defer { identifierFixture.cleanup() }
        let identifier = identifierFixture.authentication.appendingPathComponent("installation-id")
        try ClientBootstrapFixture.replacePrivateFile(
            Data((identifierFixture.installationID.rawValue.uuidString.lowercased() + "\n").utf8),
            at: identifier
        )
        await #expect(throws: RunBrokerClientBootstrapError.invalidInstallationID) {
            _ = try await identifierFixture.loader.load(channel: .development)
        }

        let secretFixture = try ClientBootstrapFixture()
        defer { secretFixture.cleanup() }
        let secret = secretFixture.authentication.appendingPathComponent("capability.key")
        try ClientBootstrapFixture.replacePrivateFile(
            Data(repeating: 0xA5, count: RunBrokerAuthenticationPolicy.secretByteCount - 1),
            at: secret
        )
        #expect(try await secretFixture.loader.load(channel: .development).installationID
            == secretFixture.installationID)
    }
}

private enum ClientBootstrapFixtureError: Error {
    case systemCall(String, Int32)
}

private final class ClientBootstrapFixture {
    let root: URL
    let home: URL
    let channel: RunBrokerChannel
    let applicationSupport: URL
    let support: URL
    let authentication: URL
    let installationID: RunBrokerInstallationID
    private var socketDescriptor: Int32 = -1

    var loader: RunBrokerClientBootstrapLoader {
        .init(
            expectedUserID: getuid(),
            testingHomeDirectoryURL: home,
            testingDevelopmentApplicationSupportDirectoryURL:
                channel == .development ? applicationSupport : nil,
            testingProductionApplicationSupportDirectoryURL:
                channel == .production ? applicationSupport : nil,
            testingCapabilitySecret: try? RunBrokerCapabilitySecret(
                bytes: Data(repeating: 0xA5, count: RunBrokerAuthenticationPolicy.secretByteCount)
            )
        )
    }

    init(
        channel: RunBrokerChannel = .development,
        applicationSupportSubdirectory: String? = nil
    ) throws {
        guard let installationUUID = UUID(
            uuidString: "A0000000-0000-0000-0000-000000000001"
        ) else {
            throw ClientBootstrapFixtureError.systemCall("invalid-fixture-uuid", EINVAL)
        }
        self.channel = channel
        installationID = .init(rawValue: installationUUID)
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rbc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        let applicationSupportBase = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        applicationSupport = applicationSupportBase
            .appendingPathComponent(
                applicationSupportSubdirectory ?? channel.appChannel.appSupportDirectoryName,
                isDirectory: true
            )
        support = applicationSupport
            .appendingPathComponent("RunBroker", isDirectory: true)
        authentication = support.appendingPathComponent("Authentication", isDirectory: true)
        let ipc = support.appendingPathComponent("IPC", isDirectory: true)
        try FileManager.default.createDirectory(at: authentication, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ipc, withIntermediateDirectories: false)
        for directory in [root, home, support, authentication, ipc] {
            guard chmod(directory.path, 0o700) == 0 else {
                throw ClientBootstrapFixtureError.systemCall("chmod-directory", errno)
            }
        }
        try Self.createPrivateFile(
            Data((installationID.rawValue.uuidString + "\n").utf8),
            at: authentication.appendingPathComponent("installation-id")
        )
        try Self.createPrivateFile(
            Data(repeating: 0xA5, count: RunBrokerAuthenticationPolicy.secretByteCount),
            at: authentication.appendingPathComponent("capability.key")
        )
        socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw ClientBootstrapFixtureError.systemCall("socket", errno)
        }
        var address = try runBrokerUnixAddress(
            path: ipc.appendingPathComponent("broker.sock").path
        )
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindStatus == 0 else {
            throw ClientBootstrapFixtureError.systemCall("bind", errno)
        }
        let socketURL = ipc.appendingPathComponent("broker.sock")
        guard chmod(socketURL.path, 0o600) == 0 else {
            throw ClientBootstrapFixtureError.systemCall("chmod-socket", errno)
        }
    }

    func closeSocket() {
        guard socketDescriptor >= 0 else { return }
        Darwin.close(socketDescriptor)
        socketDescriptor = -1
    }

    func cleanup() {
        closeSocket()
        try? FileManager.default.removeItem(at: root)
    }

    func snapshot() throws -> [String: String] {
        try directorySnapshot(root: root)
    }

    static func createPrivateFile(_ data: Data, at url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data),
              chmod(url.path, 0o600) == 0 else {
            throw ClientBootstrapFixtureError.systemCall("create-private-file", errno)
        }
    }

    static func replacePrivateFile(_ data: Data, at url: URL) throws {
        try FileManager.default.removeItem(at: url)
        try createPrivateFile(data, at: url)
    }
}

private func directorySnapshot(root: URL) throws -> [String: String] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
    ) else { return [:] }
    var result: [String: String] = [:]
    for case let url as URL in enumerator {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw ClientBootstrapFixtureError.systemCall("lstat-snapshot", errno)
        }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        let kind = info.st_mode & S_IFMT
        let data: Data = kind == S_IFREG ? try Data(contentsOf: url) : Data()
        result[relative] = "\(kind):\(info.st_mode & 0o777):\(info.st_size):\(data.base64EncodedString())"
    }
    return result
}
