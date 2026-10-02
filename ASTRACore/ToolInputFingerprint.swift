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

    /// Where a provider-sent argument named like `key` is kept instead. Policy
    /// hides only `key`, which is ASTRA's, so this one is still validated as the
    /// provider-supplied input key it is.
    public static let providerValueKey = "provider_" + key

    /// A provider's own tool input where an argument happens to be named like
    /// the fingerprint key. The key is ASTRA's, so a provider-sent value must
    /// never be read back as a fingerprint: it moves to `providerValueKey`, and
    /// the key now holds the real fingerprint of the raw input, so the
    /// provider's value still tells calls apart. Input without such an argument
    /// is returned as is.
    public static func replacingReservedKey(in input: [String: Any]?) -> [String: Any]? {
        guard var input, let providerValue = input[key] else { return input }
        let fingerprint = of(input)
        input[providerValueKey] = providerValue
        input[key] = fingerprint
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
