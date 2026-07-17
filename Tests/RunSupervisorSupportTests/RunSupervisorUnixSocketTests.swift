import Darwin
import Foundation
import Testing
@testable import RunSupervisorSupport

@Suite("Run supervisor Unix control socket", .serialized)
struct RunSupervisorUnixSocketTests {
    @Test("socket authenticates a request and rejects nonce replay")
    func authenticatedRequest() throws {
        let fixture = try makeFixture()
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: fixture.payload.manifest.executionID,
            capability: fixture.payload.capability
        )
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator
        )
        try server.start { _ in .init(accepted: true, lastSequence: 0) }
        defer { server.stop() }
        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: fixture.payload.manifest.executionID,
            action: .init(kind: .status),
            capability: fixture.payload.capability
        )
        let client = DarwinRunSupervisorControlClient()
        #expect(try client.send(request, directory: fixture.directory).accepted)
        let replay = try client.send(request, directory: fixture.directory)
        #expect(!replay.accepted)
        #expect(replay.errorCode == "unauthenticated")
    }

    @Test("control requests execute on the supervisor-owned client queue")
    func controlRequestsUseOwnedQueue() throws {
        let fixture = try makeFixture()
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: fixture.payload.manifest.executionID,
            capability: fixture.payload.capability
        )
        let acceptQueue = DispatchQueue(label: "test.run-supervisor.control.accept")
        let clientQueue = DispatchQueue(label: "test.run-supervisor.control.client")
        let clientQueueKey = DispatchSpecificKey<Bool>()
        clientQueue.setSpecific(key: clientQueueKey, value: true)
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator,
            acceptQueue: acceptQueue,
            clientQueue: clientQueue
        )
        try server.start { _ in
            .init(
                accepted: DispatchQueue.getSpecific(key: clientQueueKey) == true,
                lastSequence: 0
            )
        }
        defer { server.stop() }

        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: fixture.payload.manifest.executionID,
            action: .init(kind: .status),
            capability: fixture.payload.capability
        )
        #expect(try DarwinRunSupervisorControlClient().send(
            request,
            directory: fixture.directory
        ).accepted)
    }

    @Test("stop terminates a stalled admitted client and drains its handler")
    func stopDrainsStalledClient() throws {
        let fixture = try makeFixture()
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: .init(
                executionID: fixture.payload.manifest.executionID,
                capability: fixture.payload.capability
            )
        )
        try server.start { _ in .init(accepted: true, lastSequence: 0) }
        let client = try connectRawClient(directory: fixture.directory)
        defer { close(client) }
        #expect(RunSupervisorTestSupport.waitUntil(timeout: 2) {
            server.activeClientCount == 1
        })

        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            server.stop()
            stopped.signal()
        }
        #expect(stopped.wait(timeout: .now() + 2) == .success)
        #expect(server.activeClientCount == 0)
        #expect(waitForPeerClosure(client, timeout: 1))
    }

    @Test("stop safely joins an accept loop that has not started accepting")
    func stopAcceptRace() throws {
        let fixture = try makeFixture()
        let acceptQueue = DispatchQueue(label: "test.run-supervisor.delayed-accept")
        acceptQueue.suspend()
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: .init(
                executionID: fixture.payload.manifest.executionID,
                capability: fixture.payload.capability
            ),
            acceptQueue: acceptQueue
        )
        try server.start { _ in .init(accepted: true, lastSequence: 0) }
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            server.stop()
            stopped.signal()
        }
        #expect(stopped.wait(timeout: .now() + 0.05) == .timedOut)
        acceptQueue.resume()
        #expect(stopped.wait(timeout: .now() + 2) == .success)
    }

    @Test("concurrent stop waits for a reserved start and then quiesces it")
    func concurrentStartAndStop() throws {
        let fixture = try makeFixture()
        let startReserved = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        let startError = SocketTestErrorBox()
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: .init(
                executionID: fixture.payload.manifest.executionID,
                capability: fixture.payload.capability
            ),
            acceptQueue: DispatchQueue(label: "test.run-supervisor.start-stop.accept"),
            clientQueue: DispatchQueue(label: "test.run-supervisor.start-stop.client"),
            startReservationHook: {
                startReserved.signal()
                allowStart.wait()
            }
        )
        DispatchQueue.global(qos: .utility).async {
            do {
                try server.start { _ in .init(accepted: true, lastSequence: 0) }
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }
        #expect(startReserved.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global(qos: .utility).async {
            server.stop()
            stopFinished.signal()
        }
        #expect(stopFinished.wait(timeout: .now() + 0.05) == .timedOut)
        allowStart.signal()
        #expect(startFinished.wait(timeout: .now() + 2) == .success)
        #expect(stopFinished.wait(timeout: .now() + 2) == .success)
        #expect(startError.value == nil)
        #expect(server.activeClientCount == 0)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.path + "/control.sock"
        ))
    }

    @Test("control admission remains bounded to sixteen stalled clients")
    func boundedClientAdmission() throws {
        let fixture = try makeFixture()
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: .init(
                executionID: fixture.payload.manifest.executionID,
                capability: fixture.payload.capability
            )
        )
        try server.start { _ in .init(accepted: true, lastSequence: 0) }
        defer { server.stop() }

        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0..<16 {
            clients.append(try connectRawClient(directory: fixture.directory))
        }
        #expect(RunSupervisorTestSupport.waitUntil(timeout: 2) {
            server.activeClientCount == 16
        })
        let rejected = try connectRawClient(directory: fixture.directory)
        clients.append(rejected)
        #expect(waitForPeerClosure(rejected, timeout: 2))
        #expect(server.activeClientCount == 16)
    }

    @Test("start refuses symlink and regular-file socket substitutions")
    func startRefusesSubstitutions() throws {
        let fixture = try makeFixture()
        let victim = URL(fileURLWithPath: fixture.directory.path).appendingPathComponent("victim")
        try Data("safe".utf8).write(to: victim)
        let socket = URL(fileURLWithPath: fixture.directory.path).appendingPathComponent("control.sock")
        #expect(symlink(victim.path, socket.path) == 0)
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: fixture.payload.manifest.executionID,
            capability: fixture.payload.capability
        )
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator
        )
        #expect(throws: RunSupervisorError.unsafeFilesystemEntry("control.sock")) {
            try server.start { _ in .init(accepted: true, lastSequence: 0) }
        }
        #expect(try String(contentsOf: victim) == "safe")
        #expect(throws: RunSupervisorError.unsafeFilesystemEntry("control.sock")) {
            try DarwinRunSupervisorFileSystem().removeControlSocket(in: fixture.directory)
        }
    }

    @Test("a failure after bind removes only the socket created by that start")
    func postBindFailureCleansSocketForRetry() throws {
        let fixture = try makeFixture()
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: fixture.payload.manifest.executionID,
            capability: fixture.payload.capability
        )
        let failing = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator,
            acceptQueue: DispatchQueue(label: "test.run-supervisor.bind-failure.accept"),
            clientQueue: DispatchQueue(label: "test.run-supervisor.bind-failure.client"),
            startReservationHook: {},
            postBindHook: { throw InjectedSocketStartFailure() }
        )
        #expect(throws: InjectedSocketStartFailure.self) {
            try failing.start { _ in .init(accepted: true, lastSequence: 0) }
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.path + "/control.sock"
        ))

        let retry = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator
        )
        try retry.start { _ in .init(accepted: true, lastSequence: 0) }
        retry.stop()
    }

    @Test("stop never unlinks a replacement path with a different inode")
    func stopPreservesReplacement() throws {
        let fixture = try makeFixture()
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: fixture.payload.manifest.executionID,
            capability: fixture.payload.capability
        )
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator
        )
        try server.start { _ in .init(accepted: true, lastSequence: 0) }
        let path = URL(fileURLWithPath: fixture.directory.path).appendingPathComponent("control.sock")
        #expect(unlink(path.path) == 0)
        try Data("replacement".utf8).write(to: path)
        server.stop()
        #expect(try String(contentsOf: path) == "replacement")
    }

    @Test("same-uid replacement socket cannot forge accepted terminal truth or liveness")
    func sameUIDForgedResponseIsRejected() throws {
        let fixture = try makeFixture()
        let forgedTerminal = RunSupervisorEvent(
            sequence: 1,
            id: RunSupervisorTestSupport.uuid(111),
            timestamp: RunSupervisorTestSupport.fixedDate,
            kind: .providerExited,
            payload: .init(exitCode: 0, terminationReason: .exited)
        )
        let forgedBody = try RunSupervisorWireCoding.encode(
            RunSupervisorControlResponse(
                accepted: true,
                events: [forgedTerminal],
                lastSequence: forgedTerminal.sequence
            )
        )
        let forgedEnvelope = try RunSupervisorAuthenticatedControlResponse(
            body: forgedBody,
            authentication: String(repeating: "0", count: 64)
        )
        let forgedWire = try RunSupervisorWireCoding.encode(forgedEnvelope)
        let server = try SameUIDForgedSocketServer(
            directory: fixture.directory,
            response: forgedWire,
            responseCount: 2
        )
        defer { server.stop() }

        let client = DarwinRunSupervisorControlClient()
        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: fixture.payload.manifest.executionID,
            action: .init(kind: .status),
            capability: fixture.payload.capability
        )
        #expect(throws: RunSupervisorError.responseAuthenticationFailed) {
            try client.send(request, directory: fixture.directory)
        }

        let discovery = RunSupervisorDiscoveryRecord(
            identity: fixture.payload.expectedIdentity,
            manifestSHA256: fixture.payload.manifestSHA256,
            launchAuthenticator: try RunSupervisorDigests.launchAuthenticator(
                payload: fixture.payload,
                capability: fixture.payload.capability
            ),
            capabilitySHA256: try RunSupervisorDigests.capability(fixture.payload.capability),
            createdAt: RunSupervisorTestSupport.fixedDate
        )
        #expect(!client.authenticate(
            discovery: discovery,
            directory: fixture.directory,
            capability: fixture.payload.capability
        ))
        #expect(server.waitUntilFinished(timeout: 2))
    }

    private func makeFixture() throws -> (
        root: RunSupervisorTrustedRoot,
        directory: RunSupervisorRunDirectory,
        payload: RunSupervisorBootstrapPayload
    ) {
        let url = try RunSupervisorTestSupport.temporaryDirectory("socket")
        let root = try RunSupervisorTrustedRoot(path: url.path)
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 30)
        let directory = try root.acquireExecutionDirectory(payload.manifest.executionID).directory
        return (root, directory, payload)
    }

    private func connectRawClient(directory: RunSupervisorRunDirectory) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RunSupervisorError.systemCall("raw client socket", errno) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = directory.path + "/control.sock"
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else {
                throw RunSupervisorError.oversizedFrame(limit: capacity - 1)
            }
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                    _ = strlcpy(destination, source, capacity)
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw RunSupervisorError.systemCall("connect raw client", errno) }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func waitForPeerClosure(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let milliseconds = Int32((timeout * 1_000).rounded(.up))
        guard poll(&pollDescriptor, 1, milliseconds) > 0 else { return false }
        var byte: UInt8 = 0
        return Darwin.recv(descriptor, &byte, 1, MSG_DONTWAIT) == 0
    }
}

private final class SocketTestErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
        lock.unlock()
    }
}

private struct InjectedSocketStartFailure: Error {}

private final class SameUIDForgedSocketServer: @unchecked Sendable {
    private let path: String
    private let response: Data
    private let responseCount: Int
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listener: Int32

    init(
        directory: RunSupervisorRunDirectory,
        response: Data,
        responseCount: Int
    ) throws {
        path = directory.path + "/control.sock"
        self.response = response
        self.responseCount = responseCount
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw RunSupervisorError.systemCall("fake socket", errno) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else {
                throw RunSupervisorError.oversizedFrame(limit: capacity - 1)
            }
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                    _ = strlcpy(destination, source, capacity)
                }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0,
                  chmod(path, 0o600) == 0,
                  listen(listener, 2) == 0 else {
                throw RunSupervisorError.systemCall("bind fake socket", errno)
            }
        } catch {
            close(listener)
            listener = -1
            _ = unlink(path)
            throw error
        }
        DispatchQueue.global(qos: .utility).async { [self] in serve() }
    }

    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        completion.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        _ = unlink(path)
    }

    deinit { stop() }

    private func serve() {
        defer { completion.signal() }
        for _ in 0..<responseCount {
            lock.lock()
            let fd = listener
            lock.unlock()
            guard fd >= 0 else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            _ = try? RunSupervisorFrameIO.readFrame(
                from: client,
                maximumBytes: RunSupervisorProtocol.maximumControlFrameBytes
            )
            try? RunSupervisorFrameIO.writeFrame(
                response,
                to: client,
                maximumBytes: RunSupervisorProtocol.maximumControlFrameBytes
            )
            close(client)
        }
    }
}
