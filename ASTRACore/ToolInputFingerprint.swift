import Foundation

/// A stable fingerprint of a tool call's whole input, for the repetition
/// breaker. Providers differ in how much of a call's input survives parsing:
/// Copilot's edit, view and create keep only the path, and Cursor drops the
/// file body, so a signature built from what remains cannot tell two different
/// edits apart. A parser that has the raw arguments stores their fingerprint
/// under `key`; the breaker uses it, and fingerprints the input itself when
/// there is none.
public enum ToolInputFingerprint {
    /// The parsed event's input key a parser stores the fingerprint under.
    /// Policy and display code ignore it.
    public static let key = "astra_args_fingerprint"

    /// A provider's own tool input without any argument that happens to be
    /// named like the fingerprint key. The key is ASTRA's, so a parser drops a
    /// provider-sent one before the input enters the event stream, where the
    /// monitor would otherwise trust its value as a fingerprint. (A parser that
    /// computes the fingerprint hashes the raw arguments, so the dropped value
    /// still counts toward it.)
    public static func removingReservedKey(from input: [String: Any]?) -> [String: Any]? {
        guard var input, input[key] != nil else { return input }
        input.removeValue(forKey: key)
        return input
    }

    /// FNV-1a over a canonical rendering, so key order does not matter and every
    /// character counts, unlike the prefix a readable signature keeps.
    public static func of(_ value: Any?) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in canonical(value).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func canonical(_ value: Any?) -> String {
        switch value {
        case nil:
            return "nil"
        case let text as String:
            return "s\(text.utf8.count):\(text)"
        case let dictionary as [String: Any]:
            let body = dictionary.keys.sorted().map { key in
                "\(key.utf8.count):\(key)=\(canonical(dictionary[key]))"
            }
            return "{" + body.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map { canonical($0) }.joined(separator: ",") + "]"
        case let number as NSNumber:
            // JSON booleans and numbers are both NSNumber, and would otherwise
            // render true as 1 and false as 0.
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "b\(number.boolValue)" : "n\(number)"
        default:
            return "v\(String(describing: value))"
        }
    }
}
