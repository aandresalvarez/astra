import Foundation
import Darwin
import Testing
import ASTRACore
@testable import RunBrokerKit

@Suite("RunBroker Unix socket transport")
struct RunBrokerUnixTransportTests {
    @Test("Listener and accepted broker sockets are closed across exec")
    func socketDescriptorsAreCloseOnExec() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let listener = try RunBrokerUnixSocketListener(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid()
        )

        #expect(listener.hasCloseOnExec)
        let client = try connectRawSocket(to: fixture.identity.socketURL)
        defer { Darwin.close(client) }
        let connection = try #require(listener.accept() as? RunBrokerUnixSocketConnection)
        defer { connection.close() }
        #expect(connection.hasCloseOnExec)
    }

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
        let server = RunBrokerServer(
            listener: listener,
            endpoint: endpoint,
            responseAuthenticator: authenticator
        )
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

    @Test("A same-UID replacement socket cannot forge broker or scheduler truth")
    func sameUIDReplacementCannotForgeResponses() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let secrets = try fixture.secureStore.loadOrCreate(identity: fixture.identity)
        let authenticator = RunBrokerRequestAuthenticator(
            secret: secrets.capabilitySecret,
            random: SocketSequenceRandom()
        )
        let listener = try RunBrokerUnixSocketListener(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid()
        )
        let finished = DispatchSemaphore(value: 0)
        let serverResult = SocketServerResult()
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                let wire = RunBrokerWireCodec()
                for _ in 0..<3 {
                    let connection = try listener.accept()
                    defer { connection.close() }
                    let received = try connection.receiveFrame(using: wire.frameCodec)
                    let frame = try #require(received)
                    let request = try wire.decodeRequest(frame: frame)
                    let result: RunBrokerResponsePayload
                    switch request.command {
                    case .health:
                        result = .health(
                            .init(status: .healthy, brokerVersion: "forged", ledgerAvailable: true)
                        )
                    case .scheduler(.status):
                        result = .schedulerStatus([])
                    case .scheduler:
                        result = .accepted
                    default:
                        result = .accepted
                    }
                    let body = RunBrokerResponseEnvelope(
                        protocolVersion: .current,
                        requestID: request.requestID,
                        result: result
                    )
                    let forged = try RunBrokerAuthenticatedResponseEnvelope(
                        body: RunBrokerWireCodec.responseBodyData(body),
                        authentication: Data(
                            repeating: 0,
                            count: RunBrokerAuthenticationPolicy.macByteCount
                        )
                    )
                    try connection.send(frame: wire.encode(response: forged))
                }
            } catch {
                serverResult.error = error
            }
        }

        let client = fixture.client(secrets: secrets, authenticator: authenticator)
        for command in [
            RunBrokerCommand.health,
            .scheduler(.status),
            .scheduler(.wake)
        ] {
            #expect(throws: RunBrokerAuthenticationError.invalidResponseMAC) {
                try client.perform(command)
            }
        }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(serverResult.error == nil)
    }

    @Test("Client rejects an authenticated application response for another execution")
    func authenticatedApplicationResponseIsCommandCorrelated() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let secrets = try fixture.secureStore.loadOrCreate(identity: fixture.identity)
        let authenticator = RunBrokerRequestAuthenticator(
            secret: secrets.capabilitySecret,
            random: SocketSequenceRandom()
        )
        let listener = try RunBrokerUnixSocketListener(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid()
        )
        let finished = DispatchSemaphore(value: 0)
        let serverResult = SocketServerResult()
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                let connection = try listener.accept()
                defer { connection.close() }
                let wire = RunBrokerWireCodec()
                let received = try connection.receiveFrame(using: wire.frameCodec)
                let frame = try #require(received)
                let request = try wire.decodeRequest(frame: frame)
                let wrongExecution = RunBrokerExecutionID(
                    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
                )
                let body = RunBrokerResponseEnvelope(
                    protocolVersion: .current,
                    requestID: request.requestID,
                    result: .application(.executionStatus(.init(
                        executionID: wrongExecution,
                        authority: .init(
                            id: .init(rawValue: UUID(
                                uuidString: "00000000-0000-0000-0000-000000000103"
                            )!),
                            epoch: .initial
                        ),
                        state: .running,
                        lastSupervisorSequence: 2
                    )))
                )
                let response = try authenticator.authenticatedResponse(body, for: request)
                try connection.send(frame: wire.encode(response: response))
            } catch {
                serverResult.error = error
            }
        }

        let expectedExecution = RunBrokerExecutionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        )
        let client = fixture.client(secrets: secrets, authenticator: authenticator)
        #expect(throws: RunBrokerApplicationContractError.invalidExecutionStatus) {
            try client.perform(.application(.executionStatus(expectedExecution)))
        }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(serverResult.error == nil)
    }

    @Test("A stalled connection cannot block an independent broker request")
    func stalledConnectionDoesNotBlockIndependentRequest() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.runtime()
        let baseListener = try RunBrokerUnixSocketListener(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid()
        )
        let listener = SocketLimitedListener(base: baseListener, accepts: 2)
        let workerQueue = DispatchQueue(
            label: "com.coral.astra.run-broker.tests.connections",
            attributes: .concurrent
        )
        let queueKey = DispatchSpecificKey<String>()
        workerQueue.setSpecific(key: queueKey, value: "broker-worker")
        let queueObservation = SocketQueueObservation()
        let server = RunBrokerServer(
            listener: listener,
            endpoint: runtime.endpoint,
            responseAuthenticator: runtime.authenticator,
            now: {
                queueObservation.record(DispatchQueue.getSpecific(key: queueKey))
                return Date()
            },
            maximumConcurrentConnections: 2,
            workerQueue: workerQueue
        )
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                try server.runForever()
            } catch {
                // The bounded test listener ends the otherwise infinite loop.
            }
        }

        let stalledDescriptor = try connectRawSocket(to: fixture.identity.socketURL)
        defer { Darwin.close(stalledDescriptor) }
        var partialHeader: UInt8 = 0
        #expect(Darwin.send(stalledDescriptor, &partialHeader, 1, 0) == 1)

        let started = Date()
        let response = try fixture.client(
            secrets: runtime.secrets,
            authenticator: runtime.authenticator
        ).perform(.health)
        #expect(Date().timeIntervalSince(started) < 2)
        guard case .health(let health) = response.result else {
            Issue.record("Expected health response")
            return
        }
        #expect(health.brokerVersion == "transport-test")
        #expect(queueObservation.values == ["broker-worker"])
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    @Test("Connection capacity is bounded and excess clients fail closed")
    func connectionCapacityIsBounded() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.runtime()
        let diagnostics = SocketRecordingDiagnostics()
        let baseListener = try RunBrokerUnixSocketListener(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid()
        )
        let listener = SocketLimitedListener(base: baseListener, accepts: 2)
        let server = RunBrokerServer(
            listener: listener,
            endpoint: runtime.endpoint,
            responseAuthenticator: runtime.authenticator,
            diagnostics: diagnostics,
            maximumConcurrentConnections: 1
        )
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                try server.runForever()
            } catch {
                // The bounded test listener ends the otherwise infinite loop.
            }
        }

        let stalledDescriptor = try connectRawSocket(to: fixture.identity.socketURL)
        defer { Darwin.close(stalledDescriptor) }
        var partialHeader: UInt8 = 0
        #expect(Darwin.send(stalledDescriptor, &partialHeader, 1, 0) == 1)

        let client = fixture.client(
            secrets: runtime.secrets,
            authenticator: runtime.authenticator
        )
        #expect(throws: (any Error).self) {
            try client.perform(.health)
        }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(diagnostics.events.contains(.connectionSaturated))
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

    @Test("A duplicate broker fails ownership before recovery work")
    func duplicateListenerPreventsRecovery() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanup() }
        let listener = try RunBrokerUnixSocketListener(
            identity: fixture.identity,
            secureStore: fixture.secureStore,
            expectedUserID: getuid()
        )
        var original = stat()
        #expect(lstat(fixture.identity.socketURL.path, &original) == 0)
        var recoveryCount = 0

        func acquireOwnershipThenRecover() throws -> RunBrokerUnixSocketListener {
            let duplicate = try RunBrokerUnixSocketListener(
                identity: fixture.identity,
                secureStore: fixture.secureStore,
                expectedUserID: getuid()
            )
            recoveryCount += 1
            return duplicate
        }

        #expect(throws: RunBrokerTransportError.socketAlreadyActive) {
            try acquireOwnershipThenRecover()
        }
        #expect(recoveryCount == 0)

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

    func runtime() throws -> (
        secrets: RunBrokerInstallationSecrets,
        authenticator: RunBrokerRequestAuthenticator,
        endpoint: RunBrokerRequestEndpoint
    ) {
        let secrets = try secureStore.loadOrCreate(identity: identity)
        let authenticator = RunBrokerRequestAuthenticator(
            secret: secrets.capabilitySecret,
            random: SocketSequenceRandom()
        )
        let scheduler = RunBrokerMonitorScheduler(
            ledger: UnavailableRunBrokerMonitorLedger(),
            monitor: UnavailableRunBrokerExternalOperationMonitor(),
            timer: SocketFakeTimer()
        )
        return (
            secrets,
            authenticator,
            RunBrokerRequestEndpoint(
                channel: .development,
                installationID: secrets.installationID,
                brokerVersion: "transport-test",
                authenticator: authenticator,
                peerPolicy: .init(expectedUserID: getuid()),
                scheduler: scheduler
            )
        )
    }

    func client(
        secrets: RunBrokerInstallationSecrets,
        authenticator: RunBrokerRequestAuthenticator
    ) -> RunBrokerClient {
        RunBrokerClient(
            connector: RunBrokerUnixSocketConnector(
                socketURL: identity.socketURL,
                peerPolicy: .init(expectedUserID: getuid())
            ),
            authenticator: authenticator,
            channel: .development,
            installationID: secrets.installationID
        )
    }
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
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }
}

private final class SocketRecordingDiagnostics: RunBrokerDiagnosing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [RunBrokerDiagnosticEvent] = []
    var events: [RunBrokerDiagnosticEvent] { lock.withLock { storedEvents } }
    func record(_ event: RunBrokerDiagnosticEvent, error: any Error) {
        lock.withLock { storedEvents.append(event) }
    }
}

private final class SocketQueueObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String?] = []
    var values: [String?] { lock.withLock { storedValues } }
    func record(_ value: String?) { lock.withLock { storedValues.append(value) } }
}

private final class SocketLimitedListener: RunBrokerListening, @unchecked Sendable {
    private let base: any RunBrokerListening
    private let lock = NSLock()
    private var remaining: Int

    init(base: any RunBrokerListening, accepts: Int) {
        self.base = base
        self.remaining = accepts
    }

    func accept() throws -> any RunBrokerConnection {
        let mayAccept = lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        guard mayAccept else {
            throw RunBrokerTransportError.connectionCapacityExhausted
        }
        return try base.accept()
    }
}

private func connectRawSocket(to socketURL: URL) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw RunBrokerTransportError.systemCall(operation: "socket-test", code: errno)
    }
    do {
        var address = try runBrokerUnixAddress(path: socketURL.path)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard status == 0 else {
            throw RunBrokerTransportError.systemCall(operation: "connect-test", code: errno)
        }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}
