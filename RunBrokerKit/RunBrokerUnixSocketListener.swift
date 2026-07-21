import Foundation
import RunBrokerClient
import Darwin

public final class RunBrokerUnixSocketListener: RunBrokerListening, @unchecked Sendable {
    private let descriptor: Int32
    private let socketURL: URL
    private let boundDevice: dev_t
    private let boundInode: ino_t
    private let diagnostics: any RunBrokerDiagnosing

    public init(
        identity: RunBrokerChannelIdentity,
        secureStore: RunBrokerSecureStore = .init(),
        expectedUserID: UInt32 = getuid(),
        backlog: Int32 = 16,
        diagnostics: any RunBrokerDiagnosing = StandardErrorRunBrokerDiagnostics()
    ) throws {
        try secureStore.ensurePrivateDirectory(identity.socketDirectory)
        try Self.removeStaleSocketIfSafe(identity.socketURL, expectedUserID: expectedUserID)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RunBrokerTransportError.systemCall(operation: "socket", code: errno)
        }
        var createdSocketIdentity: (device: dev_t, inode: ino_t)?
        do {
            var address = try runBrokerUnixAddress(path: identity.socketURL.path)
            let bindStatus = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindStatus == 0 else {
                throw RunBrokerTransportError.systemCall(operation: "bind", code: errno)
            }
            guard chmod(identity.socketURL.path, 0o600) == 0 else {
                throw RunBrokerTransportError.systemCall(operation: "chmod", code: errno)
            }
            let boundIdentity = try Self.validateSocket(
                identity.socketURL,
                expectedUserID: expectedUserID
            )
            createdSocketIdentity = boundIdentity
            guard listen(descriptor, backlog) == 0 else {
                throw RunBrokerTransportError.systemCall(operation: "listen", code: errno)
            }
            self.descriptor = descriptor
            self.socketURL = identity.socketURL
            self.boundDevice = boundIdentity.device
            self.boundInode = boundIdentity.inode
            self.diagnostics = diagnostics
        } catch {
            Darwin.close(descriptor)
            if let createdSocketIdentity {
                Self.unlinkIfMatches(
                    identity.socketURL,
                    device: createdSocketIdentity.device,
                    inode: createdSocketIdentity.inode
                )
            }
            throw error
        }
    }

    public func accept() throws -> any RunBrokerConnection {
        while true {
            let accepted = Darwin.accept(descriptor, nil, nil)
            if accepted < 0, errno == EINTR { continue }
            guard accepted >= 0 else {
                throw RunBrokerTransportError.systemCall(operation: "accept", code: errno)
            }
            do {
                return try RunBrokerUnixSocketConnection(descriptor: accepted)
            } catch {
                Darwin.close(accepted)
                throw error
            }
        }
    }

    deinit {
        Darwin.close(descriptor)
        var info = stat()
        if lstat(socketURL.path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFSOCK,
               info.st_dev == boundDevice,
               info.st_ino == boundInode {
                unlink(socketURL.path)
            } else {
                diagnostics.record(
                    .socketCleanupSkipped,
                    error: RunBrokerTransportError.unsafeSocketPath
                )
            }
        }
    }

    private static func removeStaleSocketIfSafe(
        _ url: URL,
        expectedUserID: UInt32
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw RunBrokerTransportError.systemCall(operation: "lstat", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == expectedUserID,
              UInt16(info.st_mode & 0o777) == 0o600 else {
            throw RunBrokerTransportError.unsafeSocketPath
        }

        // A pathname alone cannot distinguish a socket abandoned by a crashed
        // process from the endpoint of a live broker. Probe before unlinking so
        // a duplicate launch cannot make the original broker unreachable and
        // create two independent schedulers. Only ECONNREFUSED proves that no
        // listener owns this socket; every ambiguous failure is fail-closed.
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RunBrokerTransportError.systemCall(operation: "socket-stale-probe", code: errno)
        }
        defer { Darwin.close(descriptor) }
        var address = try runBrokerUnixAddress(path: url.path)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if status == 0 {
            throw RunBrokerTransportError.socketAlreadyActive
        }
        let connectError = errno
        if connectError == ENOENT { return }
        guard connectError == ECONNREFUSED else {
            throw RunBrokerTransportError.systemCall(
                operation: "connect-stale-probe",
                code: connectError
            )
        }
        guard unlink(url.path) == 0 else {
            throw RunBrokerTransportError.systemCall(operation: "unlink", code: errno)
        }
    }

    private static func validateSocket(
        _ url: URL,
        expectedUserID: UInt32
    ) throws -> (device: dev_t, inode: ino_t) {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == expectedUserID,
              UInt16(info.st_mode & 0o777) == 0o600 else {
            throw RunBrokerTransportError.unsafeSocketPath
        }
        return (info.st_dev, info.st_ino)
    }

    private static func unlinkIfMatches(_ url: URL, device: dev_t, inode: ino_t) {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_dev == device,
              info.st_ino == inode else {
            return
        }
        unlink(url.path)
    }
}
