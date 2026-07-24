import Foundation
import RunBrokerClient
import Darwin
import ASTRACore

public enum RunBrokerInstallationError: Error, Equatable, Sendable {
    case invalidPayloadVersion
    case invalidDigest
    case invalidCohortDigest
    case sourceIsNotRegularExecutable
    case sourceDigestMismatch
    case installedDigestMismatch
    case installedCohortIncomplete
    case unsafeExistingPayload
    case unsafeExternalDirectory
    case currentSelectorIsUnsafe
    case invalidCurrentSelector
    case unsafeInstallerLock
    case unorderablePayloadVersion(String)
    case payloadDowngradeRejected(current: String, requested: String)
    case payloadBuildCollision(current: String, requested: String)
    case launchAgentSerializationFailed
    case healthCheckFailed
    case capabilityHandoffRequired
    case launchctlFailed(arguments: [String], status: Int32)
    case systemCall(operation: String, code: Int32)
}

public struct RunBrokerInstallationResult: Equatable, Sendable {
    public let installationID: RunBrokerInstallationID
    public let installedVersion: RunBrokerPayloadVersion
    public let executableURL: URL
    public let supervisorExecutableURL: URL

    public init(
        installationID: RunBrokerInstallationID,
        installedVersion: RunBrokerPayloadVersion,
        executableURL: URL,
        supervisorExecutableURL: URL
    ) {
        self.installationID = installationID
        self.installedVersion = installedVersion
        self.executableURL = executableURL
        self.supervisorExecutableURL = supervisorExecutableURL
    }
}

public struct RunBrokerInstaller: @unchecked Sendable {
    private let launchController: any RunBrokerLaunchControlling
    private let healthChecker: any RunBrokerPostReloadHealthChecking
    private let secureStore: RunBrokerSecureStore
    private let capabilityStore: any RunBrokerCapabilitySecretStoring
    let fileManager: FileManager
    let userID: UInt32
    let stagingIdentifier: @Sendable () -> String
    let durabilitySynchronizer: any RunBrokerInstallationDurabilitySynchronizing
    private let diagnostics: any RunBrokerDiagnosing
    private let successorAuthorizer: @Sendable (
        RunBrokerChannelIdentity, RunBrokerInstallationID
    ) throws -> Void
    private let pinnedUpdatePublicKey: Data?

    public init(
        launchController: any RunBrokerLaunchControlling,
        healthChecker: any RunBrokerPostReloadHealthChecking,
        secureStore: RunBrokerSecureStore = .init(),
        capabilityStore: any RunBrokerCapabilitySecretStoring = RunBrokerCapabilityKeychainStore(),
        fileManager: FileManager = .default,
        userID: UInt32 = getuid(),
        stagingIdentifier: @escaping @Sendable () -> String = { UUID().uuidString },
        durabilitySynchronizer: any RunBrokerInstallationDurabilitySynchronizing =
            SystemRunBrokerInstallationDurabilitySynchronizer(),
        diagnostics: any RunBrokerDiagnosing = StandardErrorRunBrokerDiagnostics(),
        successorAuthorizer: @escaping @Sendable (
            RunBrokerChannelIdentity, RunBrokerInstallationID
        ) throws -> Void = { identity, installationID in
            try RunBrokerSignedSuccessorClient().authorize(
                identity: identity, installationID: installationID)
        },
        pinnedUpdatePublicKey: Data? = RunBrokerInstaller.bundlePinnedUpdatePublicKey()
    ) {
        self.launchController = launchController
        self.healthChecker = healthChecker
        self.secureStore = secureStore
        self.capabilityStore = capabilityStore
        self.fileManager = fileManager
        self.userID = userID
        self.stagingIdentifier = stagingIdentifier
        self.durabilitySynchronizer = durabilitySynchronizer
        self.diagnostics = diagnostics
        self.successorAuthorizer = successorAuthorizer
        self.pinnedUpdatePublicKey = pinnedUpdatePublicKey
    }

    public func install(
        payload: RunBrokerPayload,
        identity: RunBrokerChannelIdentity
    ) throws -> RunBrokerInstallationResult {
        try secureStore.ensurePrivateDirectory(identity.supportDirectory)
        let transactionLock: RunBrokerInstallationTransactionLock
        do {
            transactionLock = try .acquire(
                at: identity.installerLockURL,
                expectedUserID: userID
            )
        } catch {
            diagnostics.record(.installerLockFailed, error: error)
            throw error
        }
        defer { transactionLock.release() }
        return try installWhileLocked(payload: payload, identity: identity)
    }

    private func installWhileLocked(
        payload: RunBrokerPayload,
        identity: RunBrokerChannelIdentity
    ) throws -> RunBrokerInstallationResult {
        try validateSource(payload)
        let installationID = try secureStore.loadOrCreateInstallationID(identity: identity)
        try secureStore.ensurePrivateDirectory(identity.versionsDirectory)
        try secureStore.ensurePrivateDirectory(identity.socketDirectory)
        try createPrivateDirectory(identity.standardOutputURL.deletingLastPathComponent())
        try ensureExternalDirectory(identity.launchAgentPlistURL.deletingLastPathComponent())

        let previousSelector = try currentSelectorTarget(identity.currentPayloadURL)
        try rejectDowngrade(requested: payload.version, previousSelector: previousSelector)

        let destinationDirectory = identity.versionsDirectory
            .appendingPathComponent(payload.version.rawValue, isDirectory: true)
        let destinationExecutable = destinationDirectory
            .appendingPathComponent(RunBrokerCohort.brokerExecutableName, isDirectory: false)
        let destinationSupervisorExecutable = destinationDirectory
            .appendingPathComponent(RunBrokerCohort.supervisorExecutableName, isDirectory: false)
        try stagePayloadIfNeeded(
            payload,
            destinationDirectory: destinationDirectory,
            destinationExecutable: destinationExecutable,
            destinationSupervisorExecutable: destinationSupervisorExecutable
        )
        let capabilitySecret: RunBrokerCapabilitySecret
        do {
            capabilitySecret = try capabilityStore.load(
                channel: identity.channel,
                installationID: installationID
            )
        } catch RunBrokerCapabilityKeychainError.unavailable {
            // A missing item is expected only for the first installation. Once
            // a payload selector exists, `unavailable` can instead mean that
            // an ad-hoc successor no longer satisfies the exact-code ACL. Do
            // not rotate authority from that untrusted process; the still-
            // trusted predecessor/broker must authorize the signed successor.
            if previousSelector != nil {
                do {
                    try successorAuthorizer(identity, installationID)
                    capabilitySecret = try capabilityStore.load(
                        channel: identity.channel,
                        installationID: installationID)
                } catch {
                    throw RunBrokerInstallationError.capabilityHandoffRequired
                }
            } else {
                capabilitySecret = try .init(bytes: randomCapabilityBytes())
            }
        }
        guard let appExecutableURL = Bundle.main.executableURL else {
            throw RunBrokerCapabilityKeychainError.provisioningFailed
        }
        var trustedCapabilityReaders = [
            appExecutableURL,
            destinationExecutable,
            destinationSupervisorExecutable,
        ]
        if let previousSelector {
            let previousDirectory = identity.supportDirectory
                .appendingPathComponent(previousSelector, isDirectory: true)
            let previousBroker = previousDirectory
                .appendingPathComponent(RunBrokerCohort.brokerExecutableName, isDirectory: false)
            if previousBroker.standardizedFileURL != destinationExecutable.standardizedFileURL {
                trustedCapabilityReaders.append(previousBroker)
            }
            let previousSupervisor = previousDirectory
                .appendingPathComponent(RunBrokerCohort.supervisorExecutableName, isDirectory: false)
            if previousSupervisor.standardizedFileURL != destinationSupervisorExecutable.standardizedFileURL {
                trustedCapabilityReaders.append(previousSupervisor)
            }
        }
        try capabilityStore.provision(
            capabilitySecret,
            channel: identity.channel,
            installationID: installationID,
            trustedApplicationURLs: trustedCapabilityReaders
        )
        if let pinnedUpdatePublicKey {
            try RunBrokerCapabilityKeychainStore().provisionPinnedUpdatePublicKey(
                pinnedUpdatePublicKey,
                channel: identity.channel,
                installationID: installationID,
                trustedApplicationURLs: trustedCapabilityReaders
            )
        }

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
                installationID: installationID
            )
            try plist.write(to: identity.launchAgentPlistURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: identity.launchAgentPlistURL.path
            )
            try synchronizePublishedFile(identity.launchAgentPlistURL)
            try launchController.reload(agent)
            do {
                try healthChecker.waitUntilHealthy(
                    identity: identity,
                    installationID: installationID,
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
            installationID: installationID,
            installedVersion: payload.version,
            executableURL: destinationExecutable,
            supervisorExecutableURL: destinationSupervisorExecutable
        )
    }

    private func randomCapabilityBytes() throws -> Data {
        try SystemRunBrokerRandomGenerator().randomBytes(
            count: RunBrokerAuthenticationPolicy.secretByteCount
        )
    }

    public static func bundlePinnedUpdatePublicKey(bundle: Bundle = .main) -> Data? {
        guard let encoded = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32 else { return nil }
        return data
    }

    private func rejectDowngrade(
        requested: RunBrokerPayloadVersion,
        previousSelector: String?
    ) throws {
        // A first install has no competing precedence to order. This keeps
        // pre-release and test payloads usable while requiring every real
        // upgrade decision to be deterministic.
        guard let previousSelector else { return }
        let currentRaw = String(previousSelector.dropFirst("Versions/".count))
        let current = try RunBrokerPayloadVersion(rawValue: currentRaw)
        // An exact version identity is an idempotent reinstall. The staging
        // integrity check still requires its full SHA-256 digest to match the
        // already installed executable.
        if requested == current { return }
        guard let requestedBuild = requested.monotonicBuild else {
            throw RunBrokerInstallationError.unorderablePayloadVersion(requested.rawValue)
        }
        guard let currentBuild = current.monotonicBuild else {
            throw RunBrokerInstallationError.unorderablePayloadVersion(current.rawValue)
        }
        guard requestedBuild >= currentBuild else {
            throw RunBrokerInstallationError.payloadDowngradeRejected(
                current: current.rawValue,
                requested: requested.rawValue
            )
        }
        guard requestedBuild != currentBuild else {
            throw RunBrokerInstallationError.payloadBuildCollision(
                current: current.rawValue,
                requested: requested.rawValue
            )
        }
    }
}
