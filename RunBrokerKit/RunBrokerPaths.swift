import Foundation
import ASTRACore

public struct RunBrokerChannelIdentity: Equatable, Sendable {
    public let channel: RunBrokerChannel
    public let launchAgentLabel: String
    public let channelApplicationSupportDirectory: URL
    public let supportDirectory: URL
    public let installerLockURL: URL
    public let versionsDirectory: URL
    public let currentPayloadURL: URL
    public let currentExecutableURL: URL
    public let currentSupervisorExecutableURL: URL
    public let socketDirectory: URL
    public let socketURL: URL
    public let authenticationDirectory: URL
    public let ledgerDirectoryURL: URL
    public let capabilitySecretURL: URL
    public let installationIDURL: URL
    public let launchAgentPlistURL: URL
    public let standardOutputURL: URL
    public let standardErrorURL: URL

    public init(
        channel: RunBrokerChannel,
        homeDirectory: URL,
        channelApplicationSupportDirectory: URL
    ) {
        self.channel = channel
        self.channelApplicationSupportDirectory = channelApplicationSupportDirectory
            .standardizedFileURL
        switch channel {
        case .production:
            self.launchAgentLabel = "com.coral.astra.run-broker"
        case .development:
            self.launchAgentLabel = "com.coral.astra.dev.run-broker"
        }

        let support = channelApplicationSupportDirectory
            .appendingPathComponent("RunBroker", isDirectory: true)
            .standardizedFileURL
        self.supportDirectory = support
        self.installerLockURL = support.appendingPathComponent("installer.lock", isDirectory: false)
        self.versionsDirectory = support.appendingPathComponent("Versions", isDirectory: true)
        self.currentPayloadURL = support.appendingPathComponent("Current", isDirectory: true)
        self.currentExecutableURL = currentPayloadURL
            .appendingPathComponent("astra-run-broker", isDirectory: false)
        self.currentSupervisorExecutableURL = currentPayloadURL
            .appendingPathComponent("astra-run-supervisor", isDirectory: false)
        self.socketDirectory = support.appendingPathComponent("IPC", isDirectory: true)
        self.socketURL = socketDirectory.appendingPathComponent("broker.sock", isDirectory: false)
        self.authenticationDirectory = support.appendingPathComponent("Authentication", isDirectory: true)
        self.ledgerDirectoryURL = support.appendingPathComponent("Ledger", isDirectory: true)
        self.capabilitySecretURL = authenticationDirectory
            .appendingPathComponent("capability.key", isDirectory: false)
        self.installationIDURL = authenticationDirectory
            .appendingPathComponent("installation-id", isDirectory: false)

        let library = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
        self.launchAgentPlistURL = library
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
        let logs = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(channel.appChannel.logsDirectoryName, isDirectory: true)
            .appendingPathComponent("RunBroker", isDirectory: true)
        self.standardOutputURL = logs.appendingPathComponent("broker.stdout.log")
        self.standardErrorURL = logs.appendingPathComponent("broker.stderr.log")
    }

    public static func live(
        channel: RunBrokerChannel,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Self {
        let appChannel = channel.appChannel
        return Self(
            channel: channel,
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            channelApplicationSupportDirectory: AppChannelStoragePaths.applicationSupportDirectory(
                for: appChannel,
                environment: environment,
                fileManager: fileManager
            )
        )
    }
}

public struct RunBrokerPayloadVersion: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              rawValue.unicodeScalars.allSatisfy(allowed.contains),
              rawValue != ".",
              rawValue != ".." else {
            throw RunBrokerInstallationError.invalidPayloadVersion
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    /// Numeric release precedence encoded by packaging as
    /// `<app-version>-<build>-<digest-prefix>`. Bare numeric revisions remain
    /// accepted for installer fixtures and pre-release development payloads.
    var monotonicBuild: UInt64? {
        if let direct = UInt64(rawValue) { return direct }
        let components = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count >= 3,
              let digest = components.last,
              digest.count >= 16,
              digest.allSatisfy({ $0.isHexDigit }),
              let build = UInt64(components[components.count - 2]) else {
            return nil
        }
        return build
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RunBrokerSHA256Digest: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.utf8.count == 64,
              normalized.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RunBrokerInstallationError.invalidDigest
        }
        self.rawValue = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
