import Foundation
import Darwin
import Testing
import ASTRACore
@testable import RunBrokerKit

@Suite("RunBroker Unix socket transport")
struct RunBrokerUnixTransportTests {
    @Test("Authenticated client and server exchange a framed health request")
    func endToEndHealth() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let secrets = try fixture.secureStore.loadOrCreate(identity: fixture.identity)
        let authenticator = RunBrokerRequestAuthenticator(
            secret: secrets.capabilitySecret,
            random: SocketSequenceRandom()
        )
        let scheduler = RunBrokerMonitorScheduler(
            ledger: UnavailableRunBrokerMonitorLedger(),
            monitor: UnavailableRunBrokerExternalOperationMonitor(),
            timer: SocketFakeTimer()
        )
        let endpoint = RunBrokerRequestEndpoint(
            channel: .development,
            installationID: secrets.installationID,
            brokerVersion: "transport-test",
            authenticator: authenticator,
            peerPolicy: .init(expectedUserID: getuid()),
            scheduler: scheduler
        )
        let listener = try RunBrokerUnixSocketListener(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid()
        )
        let server = RunBrokerServer(listener: listener, endpoint: endpoint)
        let finished = DispatchSemaphore(value: 0)
        let serverResult = SocketServerResult()
        DispatchQueue.global().async {
            do {
                try server.serveOnce()
            } catch {
                serverResult.error = error
            }
            finished.signal()
        }

        let client = RunBrokerClient(
            connector: RunBrokerUnixSocketConnector(
                socketURL: fixture.identity.socketURL,
                peerPolicy: .init(expectedUserID: getuid())
            ),
            authenticator: authenticator,
            channel: .development,
            installationID: secrets.installationID
        )
        let response = try client.perform(.health)
        guard case .health(let health) = response.result else {
            Issue.record("Expected health response")
            return
        }
        #expect(health.brokerVersion == "transport-test")
        #expect(health.status == .degraded)
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(serverResult.error == nil)
    }

    @Test("Listener rejects a symlinked socket directory")
    func symlinkedSocketDirectory() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        try fixture.secureStore.ensurePrivateDirectory(fixture.identity.supportDirectory)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(
            at: fixture.identity.socketDirectory,
            withDestinationURL: outside
        )

        #expect(throws: (any Error).self) {
            try RunBrokerUnixSocketListener(
                identity: fixture.identity,
                secureStore: fixture.secureStore,
                expectedUserID: getuid()
            )
        }
    }

    @Test("Listener refuses to unlink a regular file at the socket path")
    func regularSocketSubstitution() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        try fixture.secureStore.ensurePrivateDirectory(fixture.identity.supportDirectory)
        try fixture.secureStore.ensurePrivateDirectory(fixture.identity.socketDirectory)
        try Data("do not unlink".utf8).write(to: fixture.identity.socketURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.identity.socketURL.path
        )
        #expect(throws: RunBrokerTransportError.unsafeSocketPath) {
            try RunBrokerUnixSocketListener(
                identity: fixture.identity,
                secureStore: fixture.secureStore,
                expectedUserID: getuid()
            )
        }
        #expect(FileManager.default.fileExists(atPath: fixture.identity.socketURL.path))
    }

    @Test("Listener deinit does not unlink a path that replaced its bound socket inode")
    func cleanupPreservesReplacement() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let diagnostics = SocketRecordingDiagnostics()
        var listener: RunBrokerUnixSocketListener? = try .init(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid(),
            diagnostics: diagnostics
        )
        #expect(listener != nil)
        try FileManager.default.removeItem(at: fixture.identity.socketURL)
        try Data("replacement".utf8).write(to: fixture.identity.socketURL)
        listener = nil
        #expect(try String(contentsOf: fixture.identity.socketURL) == "replacement")
        #expect(diagnostics.events == [.socketCleanupSkipped])
    }

    @Test("A second listener refuses to unlink the active broker socket")
    func duplicateListenerPreservesActiveSocket() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let listener = try RunBrokerUnixSocketListener(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid()
        )
        var original = stat()
        #expect(lstat(fixture.identity.socketURL.path, &original) == 0)

        #expect(throws: RunBrokerTransportError.socketAlreadyActive) {
            try RunBrokerUnixSocketListener(
                identity: fixture.identity,
                secureStore: fixture.secureStore,
                expectedUserID: getuid()
            )
        }

        var afterRejectedDuplicate = stat()
        #expect(lstat(fixture.identity.socketURL.path, &afterRejectedDuplicate) == 0)
        #expect(afterRejectedDuplicate.st_dev == original.st_dev)
        #expect(afterRejectedDuplicate.st_ino == original.st_ino)
        withExtendedLifetime(listener) {}
    }

    @Test("Connector rejects paths exceeding sockaddr_un capacity")
    func socketPathBound() {
        let connector = RunBrokerUnixSocketConnector(
            socketURL: URL(fileURLWithPath: "/" + String(repeating: "x", count: 200)),
            peerPolicy: .init(expectedUserID: getuid())
        )
        #expect(throws: RunBrokerTransportError.socketPathTooLong) {
            try connector.connect()
        }
    }
}

private final class SocketFixture {
    let root: URL
    let identity: RunBrokerChannelIdentity
    let secureStore: RunBrokerSecureStore

    init() throws {
        root = URL(fileURLWithPath: "/tmp/astra-rb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        identity = RunBrokerChannelIdentity(
            channel: .development,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            channelApplicationSupportDirectory: root.appendingPathComponent("AstraDev", isDirectory: true)
        )
        secureStore = RunBrokerSecureStore(
            expectedUserID: getuid(),
            random: SocketFixedRandom()
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct SocketFixedRandom: RunBrokerRandomGenerating {
    func randomBytes(count: Int) throws -> Data { Data(repeating: 0x77, count: count) }
}

private final class SocketSequenceRandom: RunBrokerRandomGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var byte: UInt8 = 0
    func randomBytes(count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        byte &+= 1
        return Data(repeating: byte, count: count)
    }
}

private final class SocketFakeDeadline: RunBrokerScheduledDeadline, @unchecked Sendable {
    func cancel() {}
}

private struct SocketFakeTimer: RunBrokerOneShotTimer {
    func schedule(
        at deadline: Date,
        _ action: @escaping @Sendable () -> Void
    ) -> any RunBrokerScheduledDeadline {
        SocketFakeDeadline()
    }
}

private final class SocketServerResult: @unchecked Sendable {
    var error: Error?
}

private final class SocketRecordingDiagnostics: RunBrokerDiagnosing, @unchecked Sendable {
    var events: [RunBrokerDiagnosticEvent] = []
    func record(_ event: RunBrokerDiagnosticEvent, error: any Error) { events.append(event) }
}
