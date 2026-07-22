import CryptoKit
import Darwin
import Foundation
import ASTRACore

public protocol RunBrokerSuccessorHandoffHandling: Sendable {
    func authorize(peer: RunBrokerPeerIdentity) throws
}

public enum RunBrokerSuccessorHandoffError: Error, Equatable, Sendable {
    case missingPeerPID, peerPathUnavailable, invalidBundle, identityMismatch, digestMismatch
}

public struct DarwinRunBrokerSuccessorHandoffHandler: RunBrokerSuccessorHandoffHandling {
    private let channel: RunBrokerChannel
    private let installationID: RunBrokerInstallationID
    private let currentBrokerExecutableURL: URL
    private let keychain: RunBrokerCapabilityKeychainStore

    public init(channel: RunBrokerChannel, installationID: RunBrokerInstallationID,
                currentBrokerExecutableURL: URL,
                keychain: RunBrokerCapabilityKeychainStore = .init()) {
        self.channel = channel
        self.installationID = installationID
        self.currentBrokerExecutableURL = currentBrokerExecutableURL
        self.keychain = keychain
    }

    public func authorize(peer: RunBrokerPeerIdentity) throws {
        guard let pid = peer.processID else { throw RunBrokerSuccessorHandoffError.missingPeerPID }
        let executable = try Self.executableURL(processID: pid)
        guard let liveIdentity = DarwinProcessCodeIdentityResolver.resolve(processID: pid),
              DarwinProcessCodeIdentityResolver.resolve(executableURL: executable) == liveIdentity else {
            throw RunBrokerSuccessorHandoffError.identityMismatch
        }
        guard let bundleURL = Self.enclosingBundle(executable),
              let bundle = Bundle(url: bundleURL),
              bundle.executableURL?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath(),
              bundle.bundleIdentifier == Self.bundleIdentifier(for: channel) else {
            throw RunBrokerSuccessorHandoffError.invalidBundle
        }
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let manifestData = try Data(contentsOf: resources.appendingPathComponent("RunBrokerSuccessorManifest.json"))
        let signature = try Data(contentsOf: resources.appendingPathComponent("RunBrokerSuccessorManifest.sig"))
        let publicKey = try keychain.loadPinnedUpdatePublicKey(channel: channel, installationID: installationID)
        let manifest = try RunBrokerSuccessorManifestVerifier.verify(
            manifestData: manifestData, signature: signature, publicKey: publicKey)
        guard manifest.channel == channel,
              manifest.bundleIdentifier == bundle.bundleIdentifier,
              manifest.version == bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              manifest.build == bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw RunBrokerSuccessorHandoffError.identityMismatch
        }
        let tools = resources.appendingPathComponent("Tools", isDirectory: true)
        let successorBroker = tools.appendingPathComponent(RunBrokerCohort.brokerExecutableName)
        let successorSupervisor = tools.appendingPathComponent(RunBrokerCohort.supervisorExecutableName)
        guard try Self.unsignedExecutableSHA256(executable) == manifest.executableSHA256,
              try Self.sha256(successorBroker) == manifest.brokerSHA256,
              try Self.sha256(successorSupervisor) == manifest.supervisorSHA256 else {
            throw RunBrokerSuccessorHandoffError.digestMismatch
        }
        // Re-resolve immediately before ACL construction so a process exit or
        // path replacement cannot turn a verified manifest into a TOCTOU grant.
        guard DarwinProcessCodeIdentityResolver.resolve(processID: pid) == liveIdentity,
              DarwinProcessCodeIdentityResolver.resolve(executableURL: executable) == liveIdentity,
              try Self.unsignedExecutableSHA256(executable) == manifest.executableSHA256,
              try Self.sha256(successorBroker) == manifest.brokerSHA256,
              try Self.sha256(successorSupervisor) == manifest.supervisorSHA256 else {
            throw RunBrokerSuccessorHandoffError.identityMismatch
        }
        let current = try RunBrokerCohortResolver.resolve(brokerExecutableURL: currentBrokerExecutableURL)
        let readers = [executable, successorBroker, successorSupervisor,
                       current.brokerExecutableURL, current.supervisorExecutableURL]
        let secret = try keychain.load(channel: channel, installationID: installationID)
        try keychain.provision(secret, channel: channel, installationID: installationID,
                               trustedApplicationURLs: readers)
        try keychain.provisionPinnedUpdatePublicKey(publicKey, channel: channel,
            installationID: installationID, trustedApplicationURLs: readers)
    }

    private static func executableURL(processID: Int32) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else {
            throw RunBrokerSuccessorHandoffError.peerPathUnavailable
        }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
    }

    private static func enclosingBundle(_ executable: URL) -> URL? {
        var cursor = executable.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" { return cursor }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private static func bundleIdentifier(for channel: RunBrokerChannel) -> String {
        switch channel {
        case .production: "com.coral.ASTRA"
        case .development: "com.coral.ASTRA.dev"
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Code signatures include the bundle resource seal, which necessarily
    /// changes when the signed manifest is added. Bind the release signature
    /// to immutable Mach-O content by hashing a private copy with only its
    /// LC_CODE_SIGNATURE payload removed.
    private static func unsignedExecutableSHA256(_ url: URL) throws -> String {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-successor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: url, to: temporary)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--remove-signature", temporary.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RunBrokerSuccessorHandoffError.digestMismatch
        }
        return try sha256(temporary)
    }
}

public struct RunBrokerSignedSuccessorClient: Sendable {
    public init() {}
    public func authorize(identity: RunBrokerChannelIdentity,
                          installationID: RunBrokerInstallationID) throws {
        let connector = RunBrokerUnixSocketConnector(
            socketURL: identity.socketURL,
            peerPolicy: .init(expectedUserID: getuid()))
        let request = try RunBrokerRequestEnvelope(
            protocolVersion: .current, requestID: UUID(), idempotencyKey: UUID(),
            channel: identity.channel, installationID: installationID,
            command: .authorizeSignedSuccessor,
            authentication: .init(issuedAtMilliseconds: 0,
                nonce: Data(repeating: 0, count: RunBrokerAuthenticationPolicy.nonceByteCount),
                mac: Data(repeating: 0, count: RunBrokerAuthenticationPolicy.macByteCount)))
        let connection = try connector.connect()
        defer { connection.close() }
        try connection.send(frame: RunBrokerWireCodec().encode(request: request))
        // The response is authenticated with the capability the successor can
        // read only after this call; successful completion is proven by reload.
        _ = try connection.receiveFrame(using: RunBrokerWireCodec().frameCodec)
    }
}
