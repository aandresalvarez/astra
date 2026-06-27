import CryptoKit
import Foundation

enum GoogleOAuthPKCE {
    struct Material: Equatable, Sendable {
        var codeVerifier: String
        var codeChallenge: String
        var state: String
    }

    enum Error: LocalizedError, Equatable {
        case invalidVerifier
        case secureRandomUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidVerifier:
                return "Google OAuth PKCE verifier is invalid."
            case .secureRandomUnavailable:
                return "Secure random generation is unavailable for Google OAuth PKCE."
            }
        }
    }

    static func generate(
        byteCount: Int = 48,
        randomBytes: (Int) throws -> [UInt8] = secureRandomBytes
    ) throws -> Material {
        let verifier = try randomBase64URL(byteCount: byteCount, randomBytes: randomBytes)
        let state = try randomBase64URL(byteCount: 24, randomBytes: randomBytes)
        let codeChallenge = try challenge(for: verifier)
        return Material(codeVerifier: verifier, codeChallenge: codeChallenge, state: state)
    }

    static func challenge(for verifier: String) throws -> String {
        let trimmed = verifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 43,
              trimmed.count <= 128,
              trimmed.range(of: #"^[A-Za-z0-9\-._~]+$"#, options: .regularExpression) != nil else {
            throw Error.invalidVerifier
        }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return base64URL(Data(digest))
    }

    static func validate(returnedState: String, expectedState: String) -> Bool {
        !returnedState.isEmpty && returnedState == expectedState
    }

    private static func randomBase64URL(
        byteCount: Int,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> String {
        try base64URL(Data(randomBytes(byteCount)))
    }

    private static func secureRandomBytes(byteCount: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Error.secureRandomUnavailable(status)
        }
        return bytes
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
