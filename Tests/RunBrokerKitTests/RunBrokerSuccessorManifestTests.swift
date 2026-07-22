import CryptoKit
import Foundation
import Testing
@testable import RunBrokerClient

@Suite("RunBroker successor manifest")
struct RunBrokerSuccessorManifestTests {
    @Test("signed canonical successor manifest verifies and tampering fails closed")
    func signatureAndTamperBoundary() throws {
        let key = Curve25519.Signing.PrivateKey()
        let manifest = RunBrokerSuccessorManifest(
            channel: .production, bundleIdentifier: "com.coral.ASTRA", version: "1.2.3",
            build: "42", executableSHA256: String(repeating: "a", count: 64),
            brokerSHA256: String(repeating: "b", count: 64),
            supervisorSHA256: String(repeating: "c", count: 64))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let signature = try key.signature(for: data)
        #expect(try RunBrokerSuccessorManifestVerifier.verify(
            manifestData: data, signature: signature,
            publicKey: key.publicKey.rawRepresentation) == manifest)

        var tampered = data
        tampered[tampered.startIndex] ^= 1
        #expect(throws: RunBrokerSuccessorManifestError.invalidSignature) {
            try RunBrokerSuccessorManifestVerifier.verify(
                manifestData: tampered, signature: signature,
                publicKey: key.publicKey.rawRepresentation)
        }
        #expect(throws: RunBrokerSuccessorManifestError.invalidPublicKey) {
            try RunBrokerSuccessorManifestVerifier.verify(
                manifestData: data, signature: signature, publicKey: Data())
        }

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unexpected"] = true
        let expanded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let expandedSignature = try key.signature(for: expanded)
        #expect(throws: RunBrokerSuccessorManifestError.invalidManifest) {
            try RunBrokerSuccessorManifestVerifier.verify(
                manifestData: expanded, signature: expandedSignature,
                publicKey: key.publicKey.rawRepresentation)
        }
    }
}
