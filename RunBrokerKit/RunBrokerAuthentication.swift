import Foundation
import CryptoKit
import Darwin
import Security
import ASTRACore

public enum RunBrokerAuthenticationPolicy {
    public static let secretByteCount = 32
    public static let nonceByteCount = 16
    public static let macByteCount = 32
    public static let defaultMaximumClockSkew: TimeInterval = 5 * 60
    public static let defaultReplayCapacity = 4_096
}

public struct RunBrokerCapabilitySecret: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    fileprivate let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == RunBrokerAuthenticationPolicy.secretByteCount else {
            throw RunBrokerContractError.invalidCapabilitySecret
        }
        self.bytes = bytes
    }

    public var description: String { "<redacted run broker capability>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

public protocol RunBrokerRandomGenerating: Sendable {
    func randomBytes(count: Int) throws -> Data
}

public struct SystemRunBrokerRandomGenerator: RunBrokerRandomGenerating {
    public init() {}

    public func randomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw RunBrokerAuthenticationError.randomGenerationFailed(status)
        }
        return data
    }
}

public enum RunBrokerAuthenticationError: Error, Equatable, Sendable {
    case randomGenerationFailed(OSStatus)
    case expiredRequest
    case requestFromFuture
    case invalidMAC
    case invalidResponseMAC
    case replay
    case replayCapacityExceeded
    case wrongChannel
    case wrongInstallation
    case wrongPeerUID(expected: UInt32, actual: UInt32)
    case peerPIDUnavailable
    case peerCodeIdentityUnavailable
    case peerCodeIdentityRejected
}

public struct RunBrokerRequestAuthenticator: Sendable {
    private let secret: RunBrokerCapabilitySecret
    private let random: any RunBrokerRandomGenerating
    private let maximumClockSkew: TimeInterval

    public init(
        secret: RunBrokerCapabilitySecret,
        random: any RunBrokerRandomGenerating = SystemRunBrokerRandomGenerator(),
        maximumClockSkew: TimeInterval = RunBrokerAuthenticationPolicy.defaultMaximumClockSkew
    ) {
        self.secret = secret
        self.random = random
        self.maximumClockSkew = maximumClockSkew
    }

    public func authenticatedRequest(
        protocolVersion: RunBrokerProtocolVersion = .current,
        requestID: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID,
        command: RunBrokerCommand,
        now: Date
    ) throws -> RunBrokerRequestEnvelope {
        let nonce = try random.randomBytes(count: RunBrokerAuthenticationPolicy.nonceByteCount)
        guard nonce.count == RunBrokerAuthenticationPolicy.nonceByteCount else {
            throw RunBrokerContractError.invalidNonce
        }
        let issuedAt = Int64((now.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let transcript = try RunBrokerWireCodec.authenticationTranscript(
            protocolVersion: protocolVersion,
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            channel: channel,
            installationID: installationID,
            command: command,
            issuedAtMilliseconds: issuedAt,
            nonce: nonce
        )
        let mac = Self.mac(for: transcript, secret: secret)
        return try RunBrokerRequestEnvelope(
            protocolVersion: protocolVersion,
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            channel: channel,
            installationID: installationID,
            command: command,
            authentication: .init(
                issuedAtMilliseconds: issuedAt,
                nonce: nonce,
                mac: mac
            )
        )
    }

    public func verify(
        _ request: RunBrokerRequestEnvelope,
        expectedChannel: RunBrokerChannel,
        expectedInstallationID: RunBrokerInstallationID,
        now: Date
    ) throws {
        guard request.channel == expectedChannel else {
            throw RunBrokerAuthenticationError.wrongChannel
        }
        guard request.installationID == expectedInstallationID else {
            throw RunBrokerAuthenticationError.wrongInstallation
        }
        let issuedAt = Date(
            timeIntervalSince1970: TimeInterval(request.authentication.issuedAtMilliseconds) / 1_000
        )
        let age = now.timeIntervalSince(issuedAt)
        guard age <= maximumClockSkew else {
            throw RunBrokerAuthenticationError.expiredRequest
        }
        guard age >= -maximumClockSkew else {
            throw RunBrokerAuthenticationError.requestFromFuture
        }
        let transcript = try RunBrokerWireCodec.authenticationTranscript(
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey,
            channel: request.channel,
            installationID: request.installationID,
            command: request.command,
            issuedAtMilliseconds: request.authentication.issuedAtMilliseconds,
            nonce: request.authentication.nonce
        )
        let expected = Self.mac(for: transcript, secret: secret)
        guard Self.constantTimeEqual(expected, request.authentication.mac) else {
            throw RunBrokerAuthenticationError.invalidMAC
        }
    }

    public func authenticatedResponse(
        _ response: RunBrokerResponseEnvelope,
        for request: RunBrokerRequestEnvelope
    ) throws -> RunBrokerAuthenticatedResponseEnvelope {
        let body = try RunBrokerWireCodec.responseBodyData(response)
        let transcript = try RunBrokerWireCodec.responseAuthenticationTranscript(
            request: request,
            responseBody: body
        )
        return try RunBrokerAuthenticatedResponseEnvelope(
            body: body,
            authentication: Self.mac(for: transcript, secret: secret)
        )
    }

    /// Authenticates the exact response bytes before decoding any claimed
    /// health, acceptance, scheduler, or error truth from them.
    public func verify(
        _ response: RunBrokerAuthenticatedResponseEnvelope,
        for request: RunBrokerRequestEnvelope,
        using wireCodec: RunBrokerWireCodec = .init()
    ) throws -> RunBrokerResponseEnvelope {
        let transcript = try RunBrokerWireCodec.responseAuthenticationTranscript(
            request: request,
            responseBody: response.body
        )
        let expected = Self.mac(for: transcript, secret: secret)
        guard Self.constantTimeEqual(expected, response.authentication) else {
            throw RunBrokerAuthenticationError.invalidResponseMAC
        }
        return try wireCodec.decodeResponseBody(response.body)
    }

    private static func mac(for transcript: Data, secret: RunBrokerCapabilitySecret) -> Data {
        let key = SymmetricKey(data: secret.bytes)
        return Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
    }

    /// Compares every byte for equal-length inputs without data-dependent early
    /// return. This is logic-level constant-time structure; unit tests verify
    /// full-length comparison behavior, not hardware timing guarantees.
    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

public final class RunBrokerReplayProtector: @unchecked Sendable {
    private struct Entry {
        let nonce: Data
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let capacity: Int
    private let retention: TimeInterval
    private var entries: [Entry] = []
    private var nonceSet: Set<Data> = []

    public init(
        capacity: Int = RunBrokerAuthenticationPolicy.defaultReplayCapacity,
        retention: TimeInterval = RunBrokerAuthenticationPolicy.defaultMaximumClockSkew * 2
    ) {
        precondition(capacity > 0)
        precondition(retention > 0)
        self.capacity = capacity
        self.retention = retention
    }

    public func consume(nonce: Data, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        removeExpired(at: now)
        guard !nonceSet.contains(nonce) else {
            throw RunBrokerAuthenticationError.replay
        }
        // Every remaining entry is live after removeExpired. Evicting one
        // would let its nonce be replayed inside the authentication window.
        guard entries.count < capacity else {
            throw RunBrokerAuthenticationError.replayCapacityExceeded
        }
        entries.append(Entry(nonce: nonce, expiresAt: now.addingTimeInterval(retention)))
        nonceSet.insert(nonce)
    }

    private func removeExpired(at now: Date) {
        while let first = entries.first, first.expiresAt <= now {
            entries.removeFirst()
            nonceSet.remove(first.nonce)
        }
    }
}

public struct RunBrokerPeerIdentity: Equatable, Sendable {
    public let effectiveUserID: UInt32
    public let processID: Int32?

    public init(effectiveUserID: UInt32, processID: Int32?) {
        self.effectiveUserID = effectiveUserID
        self.processID = processID
    }
}

public enum RunBrokerPeerCodeIdentityResult: Equatable, Sendable {
    case verified
    case unavailable
    case rejected
}

public protocol RunBrokerPeerCodeIdentityVerifying: Sendable {
    func verify(processID: Int32) -> RunBrokerPeerCodeIdentityResult
}

/// This release does not pretend that a partial code-signature lookup is a
/// security boundary. Deployments may inject a complete verifier; requesting
/// one while it is unavailable fails closed.
public struct UnavailableRunBrokerPeerCodeIdentityVerifier: RunBrokerPeerCodeIdentityVerifying {
    public init() {}
    public func verify(processID: Int32) -> RunBrokerPeerCodeIdentityResult { .unavailable }
}

struct RunBrokerCodeSigningIdentity: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String
}

/// Validates a live peer against ASTRA's Developer-ID team and exact app
/// identifiers. Ad-hoc builds have no TeamIdentifier and therefore fail closed
/// instead of treating same-UID possession of a readable secret as identity.
public struct DarwinRunBrokerPeerCodeIdentityVerifier: RunBrokerPeerCodeIdentityVerifying {
    private let trustedTeamIdentifier: String?
    private let allowedIdentifiers: Set<String>
    private let identity: @Sendable (Int32) -> RunBrokerCodeSigningIdentity?

    public init(
        allowedIdentifiers: Set<String> = ["com.coral.ASTRA", "com.coral.ASTRA.dev"]
    ) {
        trustedTeamIdentifier = Self.signingIdentity(processID: getpid())?.teamIdentifier
        self.allowedIdentifiers = allowedIdentifiers
        identity = { processID in Self.signingIdentity(processID: processID) }
    }

    init(
        trustedTeamIdentifier: String?,
        allowedIdentifiers: Set<String>,
        identity: @escaping @Sendable (Int32) -> RunBrokerCodeSigningIdentity?
    ) {
        self.trustedTeamIdentifier = trustedTeamIdentifier
        self.allowedIdentifiers = allowedIdentifiers
        self.identity = identity
    }

    public func verify(processID: Int32) -> RunBrokerPeerCodeIdentityResult {
        guard let trustedTeamIdentifier, !trustedTeamIdentifier.isEmpty else {
            return .unavailable
        }
        guard let candidate = identity(processID),
              candidate.teamIdentifier == trustedTeamIdentifier,
              allowedIdentifiers.contains(candidate.identifier) else {
            return .rejected
        }
        return .verified
    }

    private static func signingIdentity(processID: Int32) -> RunBrokerCodeSigningIdentity? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: processID] as CFDictionary
        let strictValidation = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate))
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, strictValidation, nil) == errSecSuccess else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              !identifier.isEmpty,
              !teamIdentifier.isEmpty else {
            return nil
        }
        return .init(identifier: identifier, teamIdentifier: teamIdentifier)
    }
}

public struct RunBrokerPeerIdentityPolicy: Sendable {
    public let expectedUserID: UInt32
    public let requiresCodeIdentity: Bool
    public let codeIdentityVerifier: any RunBrokerPeerCodeIdentityVerifying

    public init(
        expectedUserID: UInt32,
        requiresCodeIdentity: Bool = false,
        codeIdentityVerifier: any RunBrokerPeerCodeIdentityVerifying =
            UnavailableRunBrokerPeerCodeIdentityVerifier()
    ) {
        self.expectedUserID = expectedUserID
        self.requiresCodeIdentity = requiresCodeIdentity
        self.codeIdentityVerifier = codeIdentityVerifier
    }

    public func verify(_ peer: RunBrokerPeerIdentity) throws {
        guard peer.effectiveUserID == expectedUserID else {
            throw RunBrokerAuthenticationError.wrongPeerUID(
                expected: expectedUserID,
                actual: peer.effectiveUserID
            )
        }
        guard requiresCodeIdentity else { return }
        guard let processID = peer.processID else {
            throw RunBrokerAuthenticationError.peerPIDUnavailable
        }
        switch codeIdentityVerifier.verify(processID: processID) {
        case .verified:
            return
        case .unavailable:
            throw RunBrokerAuthenticationError.peerCodeIdentityUnavailable
        case .rejected:
            throw RunBrokerAuthenticationError.peerCodeIdentityRejected
        }
    }
}
