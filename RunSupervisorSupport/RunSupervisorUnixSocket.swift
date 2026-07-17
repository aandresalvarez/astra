import Darwin
import Foundation

public protocol RunSupervisorSocketServing: AnyObject, Sendable {
    var socketName: String { get }
    func start(handler: @escaping @Sendable (RunSupervisorControlAction) throws -> RunSupervisorControlResponse) throws
    /// Stops admission and does not return until every admitted request has
    /// finished or its connection has been terminated.
    func stop()
}

public protocol RunSupervisorSocketServerFactory: Sendable {
    func makeServer(
        directory: RunSupervisorRunDirectory,
        authenticator: RunSupervisorControlAuthenticator
    ) throws -> any RunSupervisorSocketServing
}

public struct DarwinRunSupervisorSocketServerFactory: RunSupervisorSocketServerFactory {
    public init() {}
    public func makeServer(
        directory: RunSupervisorRunDirectory,
        authenticator: RunSupervisorControlAuthenticator
    ) throws -> any RunSupervisorSocketServing {
        try DarwinRunSupervisorSocketServer(directory: directory, authenticator: authenticator)
    }
}

public final class DarwinRunSupervisorSocketServer: RunSupervisorSocketServing, @unchecked Sendable {
    private enum Lifecycle: Equatable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    public let socketName = "control.sock"
    private let directory: RunSupervisorRunDirectory
    private let authenticator: RunSupervisorControlAuthenticator
    private let acceptQueue: DispatchQueue
    private let clientQueue: DispatchQueue
    private let startReservationHook: @Sendable () -> Void
    private let postBindHook: @Sendable () throws -> Void
    private let stateLock = NSCondition()
    private let clientSlots = DispatchSemaphore(value: 16)
    private let acceptLoopGroup = DispatchGroup()
    private let clientGroup = DispatchGroup()
    private var listener: Int32 = -1
    private var lifecycle: Lifecycle = .idle
    private var activeClients: Set<Int32> = []
    private var boundDevice: dev_t?
    private var boundInode: ino_t?

    public convenience init(
        directory: RunSupervisorRunDirectory,
        authenticator: RunSupervisorControlAuthenticator,
        acceptQueue: DispatchQueue = DispatchQueue(
            label: "com.coral.astra.run-supervisor.control.accept",
            qos: .userInitiated
        ),
        clientQueue: DispatchQueue = DispatchQueue(
            label: "com.coral.astra.run-supervisor.control.clients",
            qos: .userInitiated,
            attributes: .concurrent
        )
    ) throws {
        try self.init(
            directory: directory,
            authenticator: authenticator,
            acceptQueue: acceptQueue,
            clientQueue: clientQueue,
            startReservationHook: {},
            postBindHook: {}
        )
    }

    package init(
        directory: RunSupervisorRunDirectory,
        authenticator: RunSupervisorControlAuthenticator,
        acceptQueue: DispatchQueue,
        clientQueue: DispatchQueue,
        startReservationHook: @escaping @Sendable () -> Void,
        postBindHook: @escaping @Sendable () throws -> Void = {}
    ) throws {
        self.directory = directory
        self.authenticator = authenticator
        self.acceptQueue = acceptQueue
        self.clientQueue = clientQueue
        self.startReservationHook = startReservationHook
        self.postBindHook = postBindHook
    }

    public func start(
        handler: @escaping @Sendable (RunSupervisorControlAction) throws -> RunSupervisorControlResponse
    ) throws {
        stateLock.lock()
        guard lifecycle == .idle || lifecycle == .stopped else {
            stateLock.unlock()
            throw RunSupervisorError.alreadyRunningOrInDoubt
        }
        lifecycle = .starting
        stateLock.unlock()
        startReservationHook()

        let socketPath = directory.path + "/" + socketName
        var fd: Int32 = -1
        var createdSocketIdentity: (device: dev_t, inode: ino_t)?
        do {
            guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
                throw RunSupervisorError.oversizedFrame(
                    limit: MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
                )
            }
            var preexisting = stat()
            if lstat(socketPath, &preexisting) == 0 || errno != ENOENT {
                throw RunSupervisorError.unsafeFilesystemEntry(socketName)
            }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw RunSupervisorError.systemCall("socket", errno) }
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = try makeRunSupervisorUnixAddress(socketPath)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw RunSupervisorError.systemCall("bind unix socket", errno) }
            var createdSocket = stat()
            guard lstat(socketPath, &createdSocket) == 0,
                  (createdSocket.st_mode & S_IFMT) == S_IFSOCK,
                  createdSocket.st_uid == geteuid() else {
                throw RunSupervisorError.unsafeFilesystemEntry(socketName)
            }
            createdSocketIdentity = (createdSocket.st_dev, createdSocket.st_ino)
            try postBindHook()
            guard chmod(socketPath, 0o600) == 0 else {
                throw RunSupervisorError.systemCall("chmod unix socket", errno)
            }
            var bound = stat()
            guard lstat(socketPath, &bound) == 0,
                  (bound.st_mode & S_IFMT) == S_IFSOCK,
                  bound.st_uid == geteuid(),
                  (bound.st_mode & 0o077) == 0,
                  bound.st_dev == createdSocketIdentity?.device,
                  bound.st_ino == createdSocketIdentity?.inode else {
                throw RunSupervisorError.unsafeFilesystemEntry(socketName)
            }
            guard listen(fd, 16) == 0 else { throw RunSupervisorError.systemCall("listen", errno) }
            let descriptorFlags = fcntl(fd, F_GETFL)
            guard descriptorFlags >= 0,
                  fcntl(fd, F_SETFL, descriptorFlags | O_NONBLOCK) == 0 else {
                throw RunSupervisorError.systemCall("set listener nonblocking", errno)
            }
            boundDevice = bound.st_dev
            boundInode = bound.st_ino
        } catch {
            if fd >= 0 { close(fd) }
            if let createdSocketIdentity {
                removeSocket(
                    path: socketPath,
                    device: createdSocketIdentity.device,
                    inode: createdSocketIdentity.inode
                )
            }
            stateLock.lock()
            lifecycle = .stopped
            stateLock.broadcast()
            stateLock.unlock()
            throw error
        }
        // Reserve the join before publishing `running`; a concurrent stop can
        // never observe a listener whose accept loop is absent from the group.
        acceptLoopGroup.enter()
        stateLock.lock()
        listener = fd
        lifecycle = .running
        stateLock.broadcast()
        stateLock.unlock()
        let acceptLoopGroup = self.acceptLoopGroup
        acceptQueue.async { [weak self] in
            defer { acceptLoopGroup.leave() }
            self?.acceptLoop(handler: handler)
        }
    }

    public func stop() {
        stateLock.lock()
        while lifecycle == .starting { stateLock.wait() }
        if lifecycle == .idle || lifecycle == .stopped {
            stateLock.unlock()
            return
        }
        if lifecycle == .stopping {
            while lifecycle == .stopping { stateLock.wait() }
            stateLock.unlock()
            return
        }
        lifecycle = .stopping
        let fd = listener
        // Wake accept without closing the descriptor. Closing here would let
        // another thread reuse the integer before accept() has returned.
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        for client in activeClients { shutdown(client, SHUT_RDWR) }
        stateLock.unlock()

        acceptLoopGroup.wait()
        clientGroup.wait()

        stateLock.lock()
        if listener == fd {
            if fd >= 0 { close(fd) }
            listener = -1
        }
        stateLock.unlock()
        removeSocketIfStillOwned(path: directory.path + "/" + socketName)
        stateLock.lock()
        lifecycle = .stopped
        stateLock.broadcast()
        stateLock.unlock()
    }

    deinit { stop() }

    private func acceptLoop(
        handler: @escaping @Sendable (RunSupervisorControlAction) throws -> RunSupervisorControlResponse
    ) {
        while true {
            stateLock.lock()
            let fd = listener
            let shouldStop = lifecycle != .running
            stateLock.unlock()
            if shouldStop || fd < 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    var candidate = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    _ = poll(&candidate, 1, 100)
                    continue
                }
                return
            }
            let clientFlags = fcntl(client, F_GETFL)
            if clientFlags >= 0 { _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) }
            guard clientSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            stateLock.lock()
            guard lifecycle == .running else {
                stateLock.unlock()
                clientSlots.signal()
                close(client)
                return
            }
            activeClients.insert(client)
            clientGroup.enter()
            stateLock.unlock()
            let clientGroup = self.clientGroup
            let clientSlots = self.clientSlots
            clientQueue.async { [weak self] in
                defer {
                    clientSlots.signal()
                    clientGroup.leave()
                }
                guard let self else { close(client); return }
                self.handle(client: client, handler: handler)
            }
        }
    }

    private func handle(
        client: Int32,
        handler: @escaping @Sendable (RunSupervisorControlAction) throws -> RunSupervisorControlResponse
    ) {
        defer {
            stateLock.lock()
            activeClients.remove(client)
            stateLock.unlock()
            close(client)
        }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        Self.configureIOTimeouts(client)
        var decodedRequest: RunSupervisorControlRequest?
        do {
            let data = try RunSupervisorFrameIO.readFrame(
                from: client,
                maximumBytes: RunSupervisorProtocol.maximumControlFrameBytes
            )
            let request = try RunSupervisorWireCoding.decode(RunSupervisorControlRequest.self, from: data)
            decodedRequest = request
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0 else {
                throw RunSupervisorError.systemCall("getpeereid", errno)
            }
            try authenticator.authenticate(request, peerUID: uid)
            let response = try handler(request.action)
            let envelope = try authenticator.makeResponse(response, for: request)
            let encoded = try RunSupervisorDigests.canonicalData(envelope)
            try RunSupervisorFrameIO.writeFrame(
                encoded,
                to: client,
                maximumBytes: RunSupervisorProtocol.maximumControlFrameBytes
            )
        } catch {
            guard let request = decodedRequest else { return }
            let response = RunSupervisorControlResponse(
                accepted: false,
                lastSequence: 0,
                errorCode: Self.errorCode(error)
            )
            if let envelope = try? authenticator.makeResponse(response, for: request),
               let encoded = try? RunSupervisorDigests.canonicalData(envelope) {
                try? RunSupervisorFrameIO.writeFrame(
                    encoded,
                    to: client,
                    maximumBytes: RunSupervisorProtocol.maximumControlFrameBytes
                )
            }
        }
    }

    package var activeClientCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeClients.count
    }

    private static func errorCode(_ error: Error) -> String {
        switch error as? RunSupervisorError {
        case .authenticationFailed, .peerUIDMismatch, .replayedNonce, .staleAuthentication:
            "unauthenticated"
        case .unsupportedProtocol:
            "unsupported_protocol"
        case .oversizedFrame:
            "oversized_frame"
        default:
            "invalid_request"
        }
    }

    private static func configureIOTimeouts(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    private func removeSocketIfStillOwned(path: String) {
        removeSocket(path: path, device: boundDevice, inode: boundInode)
    }

    private func removeSocket(path: String, device: dev_t?, inode: ino_t?) {
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFSOCK,
              status.st_dev == device,
              status.st_ino == inode else {
            return
        }
        _ = unlink(path)
    }
}

public struct DarwinRunSupervisorControlClient: RunSupervisorLivenessProbing, Sendable {
    public init() {}

    public func authenticate(
        discovery: RunSupervisorDiscoveryRecord,
        directory: RunSupervisorRunDirectory,
        capability: RunSupervisorCapability
    ) -> Bool {
        guard discovery.protocolMinimumVersion <= RunSupervisorProtocol.maximumVersion,
              discovery.protocolMaximumVersion >= RunSupervisorProtocol.minimumVersion,
              let request = try? RunSupervisorControlAuthentication.makeRequest(
                executionID: discovery.identity.executionID,
                action: .init(kind: .handshake),
                capability: capability
              ),
              let response = try? send(request, directory: directory) else {
            return false
        }
        return response.accepted
    }

    public func send(
        _ request: RunSupervisorControlRequest,
        directory: RunSupervisorRunDirectory
    ) throws -> RunSupervisorControlResponse {
        guard let capability = request.responseVerificationCapability else {
            throw RunSupervisorError.responseAuthenticationFailed
        }
        let path = directory.path + "/control.sock"
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw RunSupervisorError.oversizedFrame(limit: MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1)
        }
        var socketStatus = stat()
        guard lstat(path, &socketStatus) == 0,
              (socketStatus.st_mode & S_IFMT) == S_IFSOCK,
              socketStatus.st_uid == geteuid(),
              (socketStatus.st_mode & 0o077) == 0 else {
            throw RunSupervisorError.unsafeFilesystemEntry("control.sock")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RunSupervisorError.systemCall("socket client", errno) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        var address = try makeRunSupervisorUnixAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw RunSupervisorError.systemCall("connect unix socket", errno) }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            throw RunSupervisorError.peerUIDMismatch
        }
        let encoded = try RunSupervisorDigests.canonicalData(request)
        try RunSupervisorFrameIO.writeFrame(
            encoded,
            to: fd,
            maximumBytes: RunSupervisorProtocol.maximumControlFrameBytes
        )
        let response = try RunSupervisorFrameIO.readFrame(
            from: fd,
            maximumBytes: RunSupervisorProtocol.maximumControlFrameBytes
        )
        let envelope = try RunSupervisorWireCoding.decode(
            RunSupervisorAuthenticatedControlResponse.self,
            from: response
        )
        return try RunSupervisorControlAuthentication.verifyResponse(
            envelope,
            for: request,
            capability: capability
        )
    }
}

private func makeRunSupervisorUnixAddress(_ path: String) throws -> sockaddr_un {
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
    return address
}
