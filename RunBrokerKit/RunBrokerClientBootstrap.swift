import Darwin
import Foundation
import ASTRACore

public enum RunBrokerClientBootstrapError: Error, Equatable, Sendable {
    case unsafeDirectory(String)
    case unsafeCredential(String)
    case unsafeSocket(String)
    case wrongOwner(expected: UInt32, actual: UInt32)
    case wrongPermissions(expected: UInt16, actual: UInt16)
    case invalidInstallationID
    case systemCall(operation: String, code: Int32)
}

public struct RunBrokerClientBootstrap: Sendable {
    public let installationID: RunBrokerInstallationID
    public let client: RunBrokerClient

    package init(installationID: RunBrokerInstallationID, client: RunBrokerClient) {
        self.installationID = installationID
        self.client = client
    }
}

/// Pure read-only bootstrap. It uses descriptor-relative, no-follow opens for
/// every broker-owned path component and has no mkdir/create/rename/write API.
public struct RunBrokerClientBootstrapLoader: Sendable {
    private let expectedUserID: UInt32
    private let homeDirectoryURL: URL
    private let trustedRootURL: URL

    public init(expectedUserID: UInt32 = getuid()) {
        self.expectedUserID = expectedUserID
        self.homeDirectoryURL = Self.loginHomeDirectory(expectedUserID: expectedUserID)
        self.trustedRootURL = URL(fileURLWithPath: "/", isDirectory: true)
    }

    package init(expectedUserID: UInt32, testingHomeDirectoryURL: URL) {
        self.expectedUserID = expectedUserID
        self.homeDirectoryURL = testingHomeDirectoryURL.standardizedFileURL
        self.trustedRootURL = testingHomeDirectoryURL
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    /// Filesystem and credential IO always runs away from the caller's actor.
    public func load(
        channel: RunBrokerChannel
    ) async throws -> RunBrokerClientBootstrap {
        let expectedUserID = self.expectedUserID
        let homeDirectoryURL = self.homeDirectoryURL
        let trustedRootURL = self.trustedRootURL
        return try await Task.detached(priority: .userInitiated) {
            try Self.loadSynchronously(
                homeDirectoryURL: homeDirectoryURL,
                trustedRootURL: trustedRootURL,
                channel: channel,
                expectedUserID: expectedUserID
            )
        }.value
    }

    private static func loadSynchronously(
        homeDirectoryURL: URL,
        trustedRootURL: URL,
        channel: RunBrokerChannel,
        expectedUserID: UInt32
    ) throws -> RunBrokerClientBootstrap {
        let material = try RunBrokerReadOnlyBootstrapPath.validateAndRead(
            homeDirectoryURL: homeDirectoryURL,
            trustedRootURL: trustedRootURL,
            channel: channel,
            expectedUserID: expectedUserID
        )
        let connector = RunBrokerReadOnlyBootstrapConnector(
            homeDirectoryURL: homeDirectoryURL,
            trustedRootURL: trustedRootURL,
            channel: channel,
            expectedUserID: expectedUserID
        )
        return .init(
            installationID: material.installationID,
            client: .init(
                connector: connector,
                authenticator: .init(secret: material.capabilitySecret),
                channel: channel,
                installationID: material.installationID
            )
        )
    }

    private static func loginHomeDirectory(expectedUserID: UInt32) -> URL {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let status = getpwuid_r(
            uid_t(expectedUserID),
            &record,
            &buffer,
            buffer.count,
            &result
        )
        guard status == 0, result != nil, let home = record.pw_dir else {
            // An invalid path fails closed in the descriptor walk. This
            // initializer intentionally performs no filesystem mutation.
            return URL(fileURLWithPath: "/.astra-invalid-home", isDirectory: true)
        }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .standardizedFileURL
    }
}

public extension RunBrokerClient {
    /// Every call performs its blocking socket exchange on a detached task.
    /// `perform` opens and closes a fresh authenticated socket per invocation.
    func performAsync(
        _ command: RunBrokerCommand,
        requestID: UUID = UUID(),
        idempotencyKey: UUID = UUID()
    ) async throws -> RunBrokerResponseEnvelope {
        try await Task.detached(priority: .userInitiated) {
            try perform(
                command,
                requestID: requestID,
                idempotencyKey: idempotencyKey
            )
        }.value
    }
}

private struct RunBrokerReadOnlyBootstrapMaterial: Sendable {
    let installationID: RunBrokerInstallationID
    let capabilitySecret: RunBrokerCapabilitySecret
}

private struct RunBrokerReadOnlyBootstrapConnector: RunBrokerConnecting {
    let homeDirectoryURL: URL
    let trustedRootURL: URL
    let channel: RunBrokerChannel
    let expectedUserID: UInt32

    func connect() throws -> any RunBrokerConnection {
        // Revalidate the complete broker-controlled directory/socket chain for
        // every fresh connection; bootstrap validation cannot authorize a
        // later path replacement.
        try RunBrokerReadOnlyBootstrapPath.validateSocket(
            homeDirectoryURL: homeDirectoryURL,
            trustedRootURL: trustedRootURL,
            channel: channel,
            expectedUserID: expectedUserID
        )
        let supportDirectoryURL = RunBrokerReadOnlyBootstrapPath.supportDirectoryURL(
            homeDirectoryURL: homeDirectoryURL,
            channel: channel
        )
        return try RunBrokerUnixSocketConnector(
            socketURL: supportDirectoryURL
                .appendingPathComponent("IPC", isDirectory: true)
                .appendingPathComponent("broker.sock", isDirectory: false),
            peerPolicy: .init(expectedUserID: expectedUserID)
        ).connect()
    }
}

private enum RunBrokerReadOnlyBootstrapPath {
    private static let authentication = "Authentication"
    private static let ipc = "IPC"
    private static let installationID = "installation-id"
    private static let capability = "capability.key"
    private static let socket = "broker.sock"

    static func validateAndRead(
        homeDirectoryURL: URL,
        trustedRootURL: URL,
        channel: RunBrokerChannel,
        expectedUserID: UInt32
    ) throws -> RunBrokerReadOnlyBootstrapMaterial {
        let support = try openSupportDirectory(
            homeDirectoryURL: homeDirectoryURL,
            trustedRootURL: trustedRootURL,
            channel: channel,
            expectedUserID: expectedUserID
        )
        defer { close(support) }
        let authentication = try openDirectory(
            at: support,
            name: authentication,
            expectedUserID: expectedUserID
        )
        defer { close(authentication) }
        let ipc = try openDirectory(
            at: support,
            name: ipc,
            expectedUserID: expectedUserID
        )
        defer { close(ipc) }
        try validateSocket(at: ipc, expectedUserID: expectedUserID)

        let installationData = try readFile(
            at: authentication,
            name: installationID,
            expectedByteCount: nil,
            maximumByteCount: 64,
            expectedUserID: expectedUserID
        )
        guard let installationText = String(data: installationData, encoding: .utf8),
              installationText.last == "\n",
              let uuid = UUID(uuidString: String(installationText.dropLast())),
              installationText == uuid.uuidString + "\n" else {
            throw RunBrokerClientBootstrapError.invalidInstallationID
        }
        let capabilityData = try readFile(
            at: authentication,
            name: capability,
            expectedByteCount: RunBrokerAuthenticationPolicy.secretByteCount,
            maximumByteCount: RunBrokerAuthenticationPolicy.secretByteCount,
            expectedUserID: expectedUserID
        )
        return try .init(
            installationID: .init(rawValue: uuid),
            capabilitySecret: .init(bytes: capabilityData)
        )
    }

    static func validateSocket(
        homeDirectoryURL: URL,
        trustedRootURL: URL,
        channel: RunBrokerChannel,
        expectedUserID: UInt32
    ) throws {
        let support = try openSupportDirectory(
            homeDirectoryURL: homeDirectoryURL,
            trustedRootURL: trustedRootURL,
            channel: channel,
            expectedUserID: expectedUserID
        )
        defer { close(support) }
        let ipc = try openDirectory(at: support, name: ipc, expectedUserID: expectedUserID)
        defer { close(ipc) }
        try validateSocket(at: ipc, expectedUserID: expectedUserID)
    }

    static func supportDirectoryURL(
        homeDirectoryURL: URL,
        channel: RunBrokerChannel
    ) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(channel.appChannel.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("RunBroker", isDirectory: true)
    }

    private static func openSupportDirectory(
        homeDirectoryURL: URL,
        trustedRootURL: URL,
        channel: RunBrokerChannel,
        expectedUserID: UInt32
    ) throws -> Int32 {
        let rootPath = trustedRootURL.standardizedFileURL.path
        let homePath = homeDirectoryURL.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard homePath.hasPrefix(prefix), homePath != rootPath else {
            throw RunBrokerClientBootstrapError.unsafeDirectory(homePath)
        }
        let relativeHome = String(homePath.dropFirst(prefix.count))
        let homeComponents = relativeHome.split(separator: "/").map(String.init)
        guard !homeComponents.isEmpty,
              homeComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RunBrokerClientBootstrapError.unsafeDirectory(homePath)
        }
        let controlled = [
            "Library", "Application Support",
            channel.appChannel.appSupportDirectoryName, "RunBroker",
        ]
        var descriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RunBrokerClientBootstrapError.systemCall(operation: "open-directory", code: errno)
        }
        do {
            try validateTrustedDirectory(
                descriptor: descriptor,
                displayName: rootPath,
                expectedUserID: expectedUserID,
                requiresUserOwner: rootPath != "/"
            )
            let components = homeComponents + controlled
            for (index, component) in components.enumerated() {
                let next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else {
                    throw RunBrokerClientBootstrapError.systemCall(
                        operation: "openat-directory",
                        code: errno
                    )
                }
                close(descriptor)
                descriptor = next
                let isBrokerControlled = index == components.count - 1
                if isBrokerControlled {
                    try validate(
                        descriptor: descriptor,
                        kind: S_IFDIR,
                        mode: 0o700,
                        displayName: component,
                        expectedUserID: expectedUserID,
                        unsafe: RunBrokerClientBootstrapError.unsafeDirectory
                    )
                } else {
                    try validateTrustedDirectory(
                        descriptor: descriptor,
                        displayName: component,
                        expectedUserID: expectedUserID,
                        requiresUserOwner: index >= homeComponents.count - 1
                    )
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validateTrustedDirectory(
        descriptor: Int32,
        displayName: String,
        expectedUserID: UInt32,
        requiresUserOwner: Bool
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw RunBrokerClientBootstrapError.systemCall(operation: "fstat", code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_nlink >= 2,
              info.st_mode & 0o022 == 0,
              requiresUserOwner
                ? info.st_uid == expectedUserID
                : (info.st_uid == 0 || info.st_uid == expectedUserID) else {
            throw RunBrokerClientBootstrapError.unsafeDirectory(displayName)
        }
    }

    private static func openDirectory(
        at parent: Int32,
        name: String,
        expectedUserID: UInt32
    ) throws -> Int32 {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RunBrokerClientBootstrapError.systemCall(operation: "openat-directory", code: errno)
        }
        do {
            try validate(
                descriptor: descriptor,
                kind: S_IFDIR,
                mode: 0o700,
                displayName: name,
                expectedUserID: expectedUserID,
                unsafe: RunBrokerClientBootstrapError.unsafeDirectory
            )
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func readFile(
        at parent: Int32,
        name: String,
        expectedByteCount: Int?,
        maximumByteCount: Int,
        expectedUserID: UInt32
    ) throws -> Data {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RunBrokerClientBootstrapError.systemCall(operation: "openat-credential", code: errno)
        }
        defer { close(descriptor) }
        let info = try validate(
            descriptor: descriptor,
            kind: S_IFREG,
            mode: 0o600,
            displayName: name,
            expectedUserID: expectedUserID,
            unsafe: RunBrokerClientBootstrapError.unsafeCredential
        )
        guard info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maximumByteCount,
              expectedByteCount.map({ info.st_size == $0 }) ?? true else {
            throw RunBrokerClientBootstrapError.unsafeCredential(name)
        }
        let count = Int(info.st_size)
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    count - offset
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else {
                throw RunBrokerClientBootstrapError.systemCall(operation: "read-credential", code: errno)
            }
            offset += readCount
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_dev == info.st_dev,
              final.st_ino == info.st_ino,
              final.st_size == info.st_size,
              final.st_nlink == 1 else {
            throw RunBrokerClientBootstrapError.unsafeCredential(name)
        }
        return data
    }

    private static func validateSocket(at ipc: Int32, expectedUserID: UInt32) throws {
        var info = stat()
        guard fstatat(ipc, socket, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw RunBrokerClientBootstrapError.systemCall(operation: "fstatat-socket", code: errno)
        }
        try validate(
            info: info,
            kind: S_IFSOCK,
            mode: 0o600,
            displayName: socket,
            expectedUserID: expectedUserID,
            unsafe: RunBrokerClientBootstrapError.unsafeSocket
        )
    }

    @discardableResult
    private static func validate(
        descriptor: Int32,
        kind: mode_t,
        mode: UInt16,
        displayName: String,
        expectedUserID: UInt32,
        unsafe: (String) -> RunBrokerClientBootstrapError
    ) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw RunBrokerClientBootstrapError.systemCall(operation: "fstat", code: errno)
        }
        try validate(
            info: info,
            kind: kind,
            mode: mode,
            displayName: displayName,
            expectedUserID: expectedUserID,
            unsafe: unsafe
        )
        return info
    }

    private static func validate(
        info: stat,
        kind: mode_t,
        mode: UInt16,
        displayName: String,
        expectedUserID: UInt32,
        unsafe: (String) -> RunBrokerClientBootstrapError
    ) throws {
        guard info.st_mode & S_IFMT == kind else { throw unsafe(displayName) }
        guard info.st_uid == expectedUserID else {
            throw RunBrokerClientBootstrapError.wrongOwner(
                expected: expectedUserID,
                actual: info.st_uid
            )
        }
        let actualMode = UInt16(info.st_mode & 0o777)
        guard actualMode == mode else {
            throw RunBrokerClientBootstrapError.wrongPermissions(
                expected: mode,
                actual: actualMode
            )
        }
    }
}
