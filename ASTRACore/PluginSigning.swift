import Foundation
import CryptoKit

public enum PluginSigningError: Error, Equatable {
    case emptySignature
}

public protocol PluginSignatureProvider {
    func signature(for data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> Data
}

public struct CryptoKitPluginSignatureProvider: PluginSignatureProvider {
    public init() {}

    public func signature(for data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        try privateKey.signature(for: data)
    }
}

public enum PluginSigning {
    public static func hash(pluginJSON data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sign(pluginJSON data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        try sign(pluginJSON: data, privateKey: privateKey, signer: CryptoKitPluginSignatureProvider())
    }

    public static func sign(
        pluginJSON data: Data,
        privateKey: Curve25519.Signing.PrivateKey,
        signer: any PluginSignatureProvider
    ) throws -> Data {
        let signature = try signer.signature(for: data, privateKey: privateKey)
        guard !signature.isEmpty else {
            throw PluginSigningError.emptySignature
        }
        return signature
    }

    public static func verify(pluginJSON data: Data, signature: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        publicKey.isValidSignature(signature, for: data)
    }

    public static func generateKeyPair() -> (privateKey: Curve25519.Signing.PrivateKey, publicKey: Curve25519.Signing.PublicKey) {
        let privateKey = Curve25519.Signing.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }
}
