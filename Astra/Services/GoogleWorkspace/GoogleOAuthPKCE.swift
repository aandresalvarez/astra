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

        var errorDescription: String? {
            switch self {
            case .invalidVerifier:
                return "Google OAuth PKCE verifier is invalid."
            }
        }
    }

    static func generate(byteCount: Int = 48) -> Material {
        let verifier = randomBase64URL(byteCount: byteCount)
        let state = randomBase64URL(byteCount: 24)
        let codeChallenge = (try? challenge(for: verifier)) ?? verifier
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

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
