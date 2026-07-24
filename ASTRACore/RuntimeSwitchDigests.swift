import CryptoKit
import Foundation

public enum RuntimeSwitchDigests {
    public static func request(
        _ request: ActiveRuntimeSwitchRequest
    ) throws -> RuntimeSwitchRequestDigest {
        RuntimeSwitchRequestDigest(value: try digest(request))
    }

    public static func manifest(
        _ manifest: ExecutionLaunchManifest
    ) throws -> ExecutionLaunchArgumentsSHA256 {
        try digest(manifest)
    }

    public static func canonical<Value: Encodable>(
        _ value: Value
    ) throws -> ExecutionLaunchArgumentsSHA256 {
        try digest(value)
    }

    private static func digest<Value: Encodable>(
        _ value: Value
    ) throws -> ExecutionLaunchArgumentsSHA256 {
        let data = try ASTRACanonicalJSON.encode(value)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try .init(hexValue: hex)
    }
}
