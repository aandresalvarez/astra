import Foundation
import RunBrokerClient
import Darwin
import ASTRACore

public struct RunBrokerLaunchAgent: Equatable, Sendable {
    public let label: String
    public let plistURL: URL
    public let domain: String

    public init(label: String, plistURL: URL, domain: String) {
        self.label = label
        self.plistURL = plistURL
        self.domain = domain
    }

    public var serviceTarget: String { "\(domain)/\(label)" }
}

public protocol RunBrokerLaunchControlling: Sendable {
    func reload(_ agent: RunBrokerLaunchAgent) throws
    func unload(_ agent: RunBrokerLaunchAgent) throws
}

public protocol RunBrokerPostReloadHealthChecking: Sendable {
    func waitUntilHealthy(
        identity: RunBrokerChannelIdentity,
        installationID: RunBrokerInstallationID,
        expectedVersion: RunBrokerPayloadVersion
    ) throws
}

public struct SystemRunBrokerLaunchController: RunBrokerLaunchControlling {
    private let diagnostics: any RunBrokerDiagnosing

    public init(diagnostics: any RunBrokerDiagnosing = StandardErrorRunBrokerDiagnostics()) {
        self.diagnostics = diagnostics
    }

    public func reload(_ agent: RunBrokerLaunchAgent) throws {
        // Bootout is idempotent and may fail when the service was not loaded.
        do {
            try run(["bootout", agent.serviceTarget])
        } catch {
            diagnostics.record(.launchAgentBootoutFailed, error: error)
        }
        try run(["bootstrap", agent.domain, agent.plistURL.path])
        try run(["kickstart", "-k", agent.serviceTarget])
    }

    public func unload(_ agent: RunBrokerLaunchAgent) throws {
        try run(["bootout", agent.serviceTarget])
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RunBrokerInstallationError.launchctlFailed(
                arguments: arguments,
                status: process.terminationStatus
            )
        }
    }
}

extension RunBrokerInstaller {
    func atomicallySelect(
        version: RunBrokerPayloadVersion,
        identity: RunBrokerChannelIdentity
    ) throws {
        let temporary = identity.supportDirectory.appendingPathComponent(
            ".Current-\(stagingIdentifier())",
            isDirectory: false
        )
        defer { unlink(temporary.path) }
        let relativeTarget = "Versions/\(version.rawValue)"
        guard symlink(relativeTarget, temporary.path) == 0 else {
            throw RunBrokerInstallationError.systemCall(operation: "symlink", code: errno)
        }
        guard rename(temporary.path, identity.currentPayloadURL.path) == 0 else {
            throw RunBrokerInstallationError.systemCall(operation: "rename", code: errno)
        }
    }

    func currentSelectorTarget(_ selector: URL) throws -> String? {
        var info = stat()
        guard lstat(selector.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw RunBrokerInstallationError.systemCall(operation: "lstat", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else {
            throw RunBrokerInstallationError.currentSelectorIsUnsafe
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(selector.path, &buffer, Int(PATH_MAX))
        guard count > 0 else {
            throw RunBrokerInstallationError.invalidCurrentSelector
        }
        let target = String(decoding: buffer.prefix(count).map(UInt8.init), as: UTF8.self)
        guard target.hasPrefix("Versions/"), !target.hasPrefix("/") else {
            throw RunBrokerInstallationError.invalidCurrentSelector
        }
        let component = String(target.dropFirst("Versions/".count))
        let version = try RunBrokerPayloadVersion(rawValue: component)
        guard target == "Versions/\(version.rawValue)" else {
            throw RunBrokerInstallationError.invalidCurrentSelector
        }
        return target
    }

    func restoreSelector(
        _ previousTarget: String?,
        identity: RunBrokerChannelIdentity
    ) throws {
        guard let previousTarget else {
            if unlink(identity.currentPayloadURL.path) != 0, errno != ENOENT {
                throw RunBrokerInstallationError.systemCall(operation: "unlink", code: errno)
            }
            return
        }
        let version = String(previousTarget.dropFirst("Versions/".count))
        try atomicallySelect(
            version: RunBrokerPayloadVersion(rawValue: version),
            identity: identity
        )
    }

    func restorePlist(_ data: Data?, at url: URL) throws {
        guard let data else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func readExistingPlist(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw RunBrokerInstallationError.systemCall(operation: "lstat-plist", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == userID else {
            throw RunBrokerInstallationError.unsafeExternalDirectory
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RunBrokerInstallationError.systemCall(operation: "open-plist", code: errno)
        }
        defer { close(descriptor) }
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd()
    }

    func launchAgentPlist(
        identity: RunBrokerChannelIdentity,
        installationID: RunBrokerInstallationID
    ) throws -> Data {
        let dictionary: [String: Any] = [
            "Label": identity.launchAgentLabel,
            "ProgramArguments": [
                identity.currentExecutableURL.path,
                "--channel", identity.channel.rawValue,
                "--installation-id", installationID.rawValue.uuidString,
                "--support-directory", identity.supportDirectory.path
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": identity.standardOutputURL.path,
            "StandardErrorPath": identity.standardErrorURL.path
        ]
        guard PropertyListSerialization.propertyList(dictionary, isValidFor: .xml) else {
            throw RunBrokerInstallationError.launchAgentSerializationFailed
        }
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
    }

    func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// LaunchAgents is an external user directory, not broker-owned state. An
    /// existing directory is validated but its permissions are never changed.
    func ensureExternalDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == userID,
                  access(url.path, W_OK) == 0 else {
                throw RunBrokerInstallationError.unsafeExternalDirectory
            }
            return
        }
        guard errno == ENOENT else {
            throw RunBrokerInstallationError.systemCall(operation: "lstat-external", code: errno)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
