import Foundation
import Darwin
import ASTRACore

public enum RunBrokerInstallationError: Error, Equatable, Sendable {
    case invalidPayloadVersion
    case invalidDigest
    case sourceIsNotRegularExecutable
    case sourceDigestMismatch
    case installedDigestMismatch
    case unsafeExistingPayload
    case unsafeExternalDirectory
    case currentSelectorIsUnsafe
    case invalidCurrentSelector
    case launchAgentSerializationFailed
    case healthCheckFailed
    case launchctlFailed(arguments: [String], status: Int32)
    case systemCall(operation: String, code: Int32)
}

public struct RunBrokerInstallationResult: Equatable, Sendable {
    public let installationID: RunBrokerInstallationID
    public let installedVersion: RunBrokerPayloadVersion
    public let executableURL: URL

    public init(
        installationID: RunBrokerInstallationID,
        installedVersion: RunBrokerPayloadVersion,
        executableURL: URL
    ) {
        self.installationID = installationID
        self.installedVersion = installedVersion
        self.executableURL = executableURL
    }
}

public struct RunBrokerInstaller: @unchecked Sendable {
    private let launchController: any RunBrokerLaunchControlling
    private let healthChecker: any RunBrokerPostReloadHealthChecking
    private let secureStore: RunBrokerSecureStore
    let fileManager: FileManager
    let userID: UInt32
    let stagingIdentifier: @Sendable () -> String
    private let diagnostics: any RunBrokerDiagnosing

    public init(
        launchController: any RunBrokerLaunchControlling,
        healthChecker: any RunBrokerPostReloadHealthChecking,
        secureStore: RunBrokerSecureStore = .init(),
        fileManager: FileManager = .default,
        userID: UInt32 = getuid(),
        stagingIdentifier: @escaping @Sendable () -> String = { UUID().uuidString },
        diagnostics: any RunBrokerDiagnosing = StandardErrorRunBrokerDiagnostics()
    ) {
        self.launchController = launchController
        self.healthChecker = healthChecker
        self.secureStore = secureStore
        self.fileManager = fileManager
        self.userID = userID
        self.stagingIdentifier = stagingIdentifier
        self.diagnostics = diagnostics
    }

    public func install(
        payload: RunBrokerPayload,
        identity: RunBrokerChannelIdentity
    ) throws -> RunBrokerInstallationResult {
        try validateSource(payload)
        let secrets = try secureStore.loadOrCreate(identity: identity)
        try secureStore.ensurePrivateDirectory(identity.versionsDirectory)
        try secureStore.ensurePrivateDirectory(identity.socketDirectory)
        try createPrivateDirectory(identity.standardOutputURL.deletingLastPathComponent())
        try ensureExternalDirectory(identity.launchAgentPlistURL.deletingLastPathComponent())

        let destinationDirectory = identity.versionsDirectory
            .appendingPathComponent(payload.version.rawValue, isDirectory: true)
        let destinationExecutable = destinationDirectory
            .appendingPathComponent("astra-run-broker", isDirectory: false)
        try stagePayloadIfNeeded(
            payload,
            destinationDirectory: destinationDirectory,
            destinationExecutable: destinationExecutable
        )

        let previousSelector = try currentSelectorTarget(identity.currentPayloadURL)
        let previousPlist = try readExistingPlist(identity.launchAgentPlistURL)
        let hadPriorService = previousSelector != nil && previousPlist != nil
        let agent = RunBrokerLaunchAgent(
            label: identity.launchAgentLabel,
            plistURL: identity.launchAgentPlistURL,
            domain: "gui/\(userID)"
        )

        do {
            try atomicallySelect(version: payload.version, identity: identity)
            let plist = try launchAgentPlist(
                identity: identity,
                installationID: secrets.installationID
            )
            try plist.write(to: identity.launchAgentPlistURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: identity.launchAgentPlistURL.path
            )
            try launchController.reload(agent)
            do {
                try healthChecker.waitUntilHealthy(
                    identity: identity,
                    installationID: secrets.installationID,
                    expectedVersion: payload.version
                )
            } catch {
                diagnostics.record(.healthCheckFailed, error: error)
                throw RunBrokerInstallationError.healthCheckFailed
            }
        } catch {
            diagnostics.record(.installFailed, error: error)
            do {
                try restoreSelector(previousSelector, identity: identity)
            } catch {
                diagnostics.record(.rollbackSelectorFailed, error: error)
            }
            do {
                try restorePlist(previousPlist, at: identity.launchAgentPlistURL)
            } catch {
                diagnostics.record(.rollbackPlistFailed, error: error)
            }
            do {
                if hadPriorService {
                    try launchController.reload(agent)
                } else {
                    try launchController.unload(agent)
                }
            } catch {
                diagnostics.record(.rollbackLaunchStateFailed, error: error)
            }
            throw error
        }

        return .init(
            installationID: secrets.installationID,
            installedVersion: payload.version,
            executableURL: destinationExecutable
        )
    }
}
