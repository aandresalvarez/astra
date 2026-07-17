import Darwin
import Foundation

public protocol RunSupervisorSocketServing: AnyObject, Sendable {
    var socketName: String { get }
    func start(handler: @escaping @Sendable (RunSupervisorControlAction) throws -> RunSupervisorControlResponse) throws
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
    public let socketName = "control.sock"
    private let directory: RunSupervisorRunDirectory
    private let authenticator: RunSupervisorControlAuthenticator
    private let stateLock = NSLock()
    private let clientSlots = DispatchSemaphore(value: 16)
    private var listener: Int32 = -1
    private var stopped = false
    private var boundDevice: dev_t?
    private var boundInode: ino_t?

    public init(
        directory: RunSupervisorRunDirectory,
        authenticator: RunSupervisorControlAuthenticator
    ) throws {
        self.directory = directory
        self.authenticator = authenticator
    }

    public func start(
        handler: @escaping @Sendable (RunSupervisorControlAction) throws -> RunSupervisorControlResponse
    ) throws {
        let socketPath = directory.path + "/" + socketName
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw RunSupervisorError.oversizedFrame(limit: MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1)
        }
        var preexisting = stat()
        if lstat(socketPath, &preexisting) == 0 || errno != ENOENT {
            throw RunSupervisorError.unsafeFilesystemEntry(socketName)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RunSupervisorError.systemCall("socket", errno) }
        do {
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = try makeRunSupervisorUnixAddress(socketPath)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw RunSupervisorError.systemCall("bind unix socket", errno) }
            guard chmod(socketPath, 0o600) == 0 else {
                throw RunSupervisorError.systemCall("chmod unix socket", errno)
            }
            var bound = stat()
            guard lstat(socketPath, &bound) == 0,
                  (bound.st_mode & S_IFMT) == S_IFSOCK,
                  bound.st_uid == geteuid(),
                  (bound.st_mode & 0o077) == 0 else {
                throw RunSupervisorError.unsafeFilesystemEntry(socketName)
            }
            guard listen(fd, 16) == 0 else { throw RunSupervisorError.systemCall("listen", errno) }
            boundDevice = bound.st_dev
            boundInode = bound.st_ino
        } catch {
            close(fd)
            removeSocketIfStillOwned(path: socketPath)
            throw error
        }
        stateLock.lock()
        listener = fd
        stopped = false
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop(handler: handler)
        }
    }

    public func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        let fd = listener
        listener = -1
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        removeSocketIfStillOwned(path: directory.path + "/" + socketName)
    }

    deinit { stop() }

    private func acceptLoop(
        handler: @escaping @Sendable (RunSupervisorControlAction) throws -> RunSupervisorControlResponse
    ) {
        while true {
            stateLock.lock()
            let fd = listener
            let shouldStop = stopped
            stateLock.unlock()
            if shouldStop || fd < 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            guard clientSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { close(client); return }
                defer { self.clientSlots.signal() }
                self.handle(client: client, handler: handler)
            }
        }
    }

    private func handle(
        client: Int32,
        handler: @escaping @Sendable (RunSupervisorControlAction) throws -> RunSupervisorControlResponse
    ) {
        defer { close(client) }
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
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFSOCK,
              status.st_dev == boundDevice,
              status.st_ino == boundInode else {
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
