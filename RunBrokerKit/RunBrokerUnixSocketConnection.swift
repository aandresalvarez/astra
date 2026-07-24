import Foundation
import Darwin

public final class RunBrokerUnixSocketConnection: RunBrokerConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    package init(
        descriptor: Int32,
        ioTimeout: TimeInterval = RunBrokerTransportPolicy.defaultIOTimeout
    ) throws {
        precondition(ioTimeout > 0 && ioTimeout.isFinite)
        self.descriptor = descriptor
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw RunBrokerTransportError.systemCall(
                operation: "setsockopt-nosigpipe",
                code: errno
            )
        }
        try Self.configureIOTimeouts(descriptor, seconds: ioTimeout)
    }

    public var peerIdentity: RunBrokerPeerIdentity {
        get throws {
            let descriptor = try liveDescriptor()
            var effectiveUserID: uid_t = 0
            var effectiveGroupID: gid_t = 0
            guard getpeereid(descriptor, &effectiveUserID, &effectiveGroupID) == 0 else {
                throw RunBrokerTransportError.systemCall(operation: "getpeereid", code: errno)
            }

            var processID: pid_t = 0
            var processIDLength = socklen_t(MemoryLayout<pid_t>.size)
            let pidStatus = getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEERPID,
                &processID,
                &processIDLength
            )
            return RunBrokerPeerIdentity(
                effectiveUserID: effectiveUserID,
                processID: pidStatus == 0 ? processID : nil
            )
        }
    }

    public func send(frame: Data) throws {
        let descriptor = try liveDescriptor()
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw RunBrokerTransportError.systemCall(operation: "send", code: errno)
                }
                offset += count
            }
        }
    }

    public func receiveFrame(using codec: RunBrokerFrameCodec) throws -> Data? {
        guard let header = try receiveExactly(MemoryLayout<UInt32>.size, allowsEOF: true) else {
            return nil
        }
        let payloadLength = try codec.decodedPayloadLength(header: header)
        guard let payload = try receiveExactly(payloadLength, allowsEOF: false) else {
            throw RunBrokerContractError.truncatedFrame
        }
        var frame = header
        frame.append(payload)
        return frame
    }

    public func close() {
        lock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    deinit { close() }

    package var hasCloseOnExec: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return false }
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }

    private func liveDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else {
            throw RunBrokerTransportError.systemCall(operation: "closed-socket", code: EBADF)
        }
        return descriptor
    }

    private func receiveExactly(_ count: Int, allowsEOF: Bool) throws -> Data? {
        if count == 0 { return Data() }
        let descriptor = try liveDescriptor()
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { bytes in
                Darwin.recv(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    count - offset,
                    0
                )
            }
            if received < 0, errno == EINTR { continue }
            if received == 0 {
                if allowsEOF, offset == 0 { return nil }
                throw RunBrokerContractError.truncatedFrame
            }
            guard received > 0 else {
                throw RunBrokerTransportError.systemCall(operation: "recv", code: errno)
            }
            offset += received
        }
        return data
    }

    private static func configureIOTimeouts(_ descriptor: Int32, seconds: TimeInterval) throws {
        let wholeSeconds = floor(seconds)
        var timeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((seconds - wholeSeconds) * 1_000_000)
        )
        let receiveStatus = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard receiveStatus == 0 else {
            throw RunBrokerTransportError.systemCall(
                operation: "setsockopt-receive-timeout",
                code: errno
            )
        }
        let sendStatus = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard sendStatus == 0 else {
            throw RunBrokerTransportError.systemCall(
                operation: "setsockopt-send-timeout",
                code: errno
            )
        }
    }
}

public struct RunBrokerUnixSocketConnector: RunBrokerConnecting {
    private let socketURL: URL
    private let peerPolicy: RunBrokerPeerIdentityPolicy

    public init(socketURL: URL, peerPolicy: RunBrokerPeerIdentityPolicy) {
        self.socketURL = socketURL
        self.peerPolicy = peerPolicy
    }

    public func connect() throws -> any RunBrokerConnection {
        _ = try runBrokerUnixAddress(path: socketURL.path)
        var socketInfo = stat()
        guard lstat(socketURL.path, &socketInfo) == 0,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == peerPolicy.expectedUserID,
              UInt16(socketInfo.st_mode & 0o777) == 0o600 else {
            throw RunBrokerTransportError.unsafeSocketPath
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RunBrokerTransportError.systemCall(operation: "socket", code: errno)
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
                throw RunBrokerTransportError.systemCall(operation: "connect", code: errno)
            }
            let connection = try RunBrokerUnixSocketConnection(descriptor: descriptor)
            try peerPolicy.verify(connection.peerIdentity)
            return connection
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}

package func runBrokerUnixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else {
        throw RunBrokerTransportError.socketPathTooLong
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            for index in bytes.indices {
                destination[index] = bytes[index]
            }
        }
    }
    return address
}
