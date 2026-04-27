import Foundation
import CryptoKit

public enum PluginSigning {
    public static func hash(pluginJSON data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sign(pluginJSON data: Data, privateKey: Curve25519.Signing.PrivateKey) -> Data {
        (try? privateKey.signature(for: data)) ?? Data()
    }

    public static func verify(pluginJSON data: Data, signature: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        publicKey.isValidSignature(signature, for: data)
    }

    public static func generateKeyPair() -> (privateKey: Curve25519.Signing.PrivateKey, publicKey: Curve25519.Signing.PublicKey) {
        let privateKey = Curve25519.Signing.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }
}
