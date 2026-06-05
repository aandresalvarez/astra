import Foundation
import Security

enum CardinalKeyClientCertificateProvider {
    static func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
              isStanfordHost(challenge.protectionSpace.host),
              let identity = cardinalKeyIdentity() else {
            return nil
        }

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            return nil
        }

        return URLCredential(
            identity: identity,
            certificates: [certificate],
            persistence: .forSession
        )
    }

    static func isStanfordHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "stanford.edu" || normalized.hasSuffix(".stanford.edu")
    }

    static func isCardinalKeySubject(_ subject: String) -> Bool {
        let normalized = subject.lowercased()
        return normalized.contains("/enrollment")
            || normalized.contains("enrollment-")
            || normalized.contains("cardinal key")
    }

    private static func cardinalKeyIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }

        let identities: [SecIdentity]
        guard let result else { return nil }

        if CFGetTypeID(result) == CFArrayGetTypeID(),
           let identityList = result as? [SecIdentity] {
            identities = identityList
        } else if CFGetTypeID(result) == SecIdentityGetTypeID() {
            identities = [result as! SecIdentity]
        } else {
            return nil
        }

        return identities.first { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate,
                  let summary = SecCertificateCopySubjectSummary(certificate) as String? else {
                return false
            }
            return isCardinalKeySubject(summary)
        }
    }
}
