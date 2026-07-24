import Darwin
import Foundation
import Security

/// Immutable code-signing identity for one executable image. The CDHash binds
/// ad-hoc builds to exact installed bytes; Developer ID builds additionally
/// carry their stable TeamIdentifier.
public struct DarwinProcessCodeIdentity: Equatable, Sendable {
    public let identifier: String
    public let teamIdentifier: String?
    public let cdHash: Data

    public init(identifier: String, teamIdentifier: String?, cdHash: Data) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.cdHash = cdHash
    }
}

public enum DarwinProcessCodeIdentityResolver {
    public static func resolve(processID: pid_t) -> DarwinProcessCodeIdentity? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        let attributes = [kSecGuestAttributePid as String: processID] as CFDictionary
        let strict = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate))
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, strict, nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        return signingIdentity(staticCode)
    }

    public static func resolve(executableURL: URL) -> DarwinProcessCodeIdentity? {
        var staticCode: SecStaticCode?
        let strict = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate))
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, strict, nil) == errSecSuccess else {
            return nil
        }
        return signingIdentity(staticCode)
    }

    private static func signingIdentity(_ code: SecStaticCode) -> DarwinProcessCodeIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
              let cdHash = fields[kSecCodeInfoUnique as String] as? Data,
              !identifier.isEmpty,
              !cdHash.isEmpty else {
            return nil
        }
        let teamIdentifier = fields[kSecCodeInfoTeamIdentifier as String] as? String
        return .init(
            identifier: identifier,
            teamIdentifier: teamIdentifier?.isEmpty == false ? teamIdentifier : nil,
            cdHash: cdHash
        )
    }
}
