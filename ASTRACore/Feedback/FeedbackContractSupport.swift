import Foundation

/// Shared limits for the V1 feedback wire contract. These limits are part of the
/// compatibility surface and must not be changed without updating the V1 fixtures.
public enum FeedbackContractLimitsV1 {
    public static let identifierLength = 128
    public static let idempotencyKeyLength = 128
    public static let userStatementLength = 8_000
    public static let shortTextLength = 1_024
    public static let pathLength = 512
    public static let mediaTypeLength = 128
    public static let credentialLength = 512
    public static let maximumEvidenceItems = 128
    public static let maximumAssessmentItems = 64
    public static let maximumOmissions = 128
    public static let maximumWarnings = 128
    public static let maximumArtifactBytes: Int64 = 20 * 1_024 * 1_024
    public static let maximumEvidenceBytes: Int64 = 50 * 1_024 * 1_024
    public static let maximumRedactionCount = 1_000_000
    public static let maximumRuntimeCounter = 1_000_000
    public static let maximumUploadAttempts = 1_000
    public static let maximumEvidenceWindow: TimeInterval = 24 * 60 * 60
}

public enum FeedbackContractError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingRequiredVersion(document: String)
    case unsupportedVersion(document: String, actual: Int, supported: Int)
    case missingRequiredField(path: String)
    case exceedsMaximumLength(path: String, maximum: Int, actual: Int)
    case exceedsMaximumCount(path: String, maximum: Int, actual: Int)
    case valueOutOfRange(path: String, description: String)
    case invalidValue(path: String, description: String)
    case duplicateValue(path: String, value: String)
    case inconsistentValue(path: String, description: String)

    public var description: String {
        switch self {
        case let .missingRequiredVersion(document):
            "Missing required formatVersion for \(document)."
        case let .unsupportedVersion(document, actual, supported):
            "Unsupported formatVersion \(actual) for \(document); supported version is \(supported)."
        case let .missingRequiredField(path):
            "Missing required value at \(path)."
        case let .exceedsMaximumLength(path, maximum, actual):
            "Value at \(path) has length \(actual); maximum is \(maximum)."
        case let .exceedsMaximumCount(path, maximum, actual):
            "Collection at \(path) has \(actual) items; maximum is \(maximum)."
        case let .valueOutOfRange(path, description):
            "Value at \(path) is out of range: \(description)."
        case let .invalidValue(path, description):
            "Value at \(path) is invalid: \(description)."
        case let .duplicateValue(path, value):
            "Collection at \(path) contains duplicate value \(value)."
        case let .inconsistentValue(path, description):
            "Value at \(path) is inconsistent: \(description)."
        }
    }
}

public protocol FeedbackContractValidatableV1 {
    func validate() throws
}

public struct FeedbackReportIDV1: Codable, Equatable, Hashable, Sendable {
    public let uuid: UUID

    public init(_ uuid: UUID) { self.uuid = uuid }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard value == value.lowercased(), let uuid = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Report IDs must be lowercase RFC 4122 UUID strings."
            )
        }
        self.uuid = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString.lowercased())
    }
}

public enum FeedbackContractNormalizationV1 {
    /// Contract text normalization is deliberately lossless apart from newline
    /// and Unicode canonical-form normalization. Sanitization/redaction belongs
    /// to the evidence builder in PR 2, not this wire contract.
    public static func text(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }
}

public enum FeedbackCanonicalJSONV1 {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestampString(date))
        }
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        var output = String()
        try appendCanonical(object, to: &output)
        return Data(output.utf8)
    }

    public static func encodeValidated<T: Encodable & FeedbackContractValidatableV1>(
        _ value: T
    ) throws -> Data {
        try value.validate()
        return try encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 UTC timestamp."
                )
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }

    public static func sha256Hex(_ data: Data) -> String {
        FeedbackSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        guard value.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private static func appendCanonical(_ value: Any, to output: inout String) throws {
        switch value {
        case is NSNull:
            output += "null"
        case let value as String:
            appendCanonicalString(value, to: &output)
        case let value as NSNumber:
            let type = String(cString: value.objCType)
            if type == "c" {
                output += value.boolValue ? "true" : "false"
            } else if ["s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) {
                output += value.stringValue
            } else {
                throw FeedbackContractError.invalidValue(
                    path: "canonicalJSON",
                    description: "V1 permits integers only; floating-point JSON numbers are forbidden"
                )
            }
        case let value as [Any]:
            output += "["
            for (index, element) in value.enumerated() {
                if index > 0 { output += "," }
                try appendCanonical(element, to: &output)
            }
            output += "]"
        case let value as [String: Any]:
            output += "{"
            let keys = value.keys.sorted(by: utf16LessThan)
            for (index, key) in keys.enumerated() {
                if index > 0 { output += "," }
                appendCanonicalString(key, to: &output)
                output += ":"
                if let member = value[key] {
                    try appendCanonical(member, to: &output)
                }
            }
            output += "}"
        default:
            throw FeedbackContractError.invalidValue(
                path: "canonicalJSON",
                description: "unsupported JSON value type \(String(describing: type(of: value)))"
            )
        }
    }

    private static func appendCanonicalString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0a: output += "\\n"
            case 0x0c: output += "\\f"
            case 0x0d: output += "\\r"
            case 0x22: output += "\\\""
            case 0x5c: output += "\\\\"
            case 0x00...0x1f:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    private static func utf16LessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }
}

enum FeedbackContractValidationV1 {
    static func required(
        _ value: String,
        path: String,
        maximum: Int
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FeedbackContractError.missingRequiredField(path: path)
        }
        try bounded(value, path: path, maximum: maximum)
    }

    static func optional(
        _ value: String?,
        path: String,
        maximum: Int
    ) throws {
        guard let value else { return }
        try required(value, path: path, maximum: maximum)
    }

    static func bounded(_ value: String, path: String, maximum: Int) throws {
        guard value.count <= maximum else {
            throw FeedbackContractError.exceedsMaximumLength(
                path: path,
                maximum: maximum,
                actual: value.count
            )
        }
        let normalized = FeedbackContractNormalizationV1.text(value)
        guard value.unicodeScalars.elementsEqual(normalized.unicodeScalars) else {
            throw FeedbackContractError.invalidValue(
                path: path,
                description: "must use NFC Unicode and LF newlines"
            )
        }
    }

    static func count(_ actual: Int, path: String, maximum: Int) throws {
        guard actual <= maximum else {
            throw FeedbackContractError.exceedsMaximumCount(
                path: path,
                maximum: maximum,
                actual: actual
            )
        }
    }

    static func nonnegative<T: BinaryInteger>(_ value: T, path: String) throws {
        guard value >= 0 else {
            throw FeedbackContractError.valueOutOfRange(path: path, description: "must be nonnegative")
        }
    }

    static func sha256(_ value: String, path: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) ||
                  (scalar.value >= 97 && scalar.value <= 102)
              }) else {
            throw FeedbackContractError.invalidValue(
                path: path,
                description: "must be a lowercase 64-character SHA-256 hex digest"
            )
        }
    }

    static func version(
        in container: KeyedDecodingContainer<FeedbackFormatVersionCodingKey>,
        document: String,
        supported: Int
    ) throws -> Int {
        guard container.contains(.formatVersion) else {
            throw FeedbackContractError.missingRequiredVersion(document: document)
        }
        let value = try container.decode(Int.self, forKey: .formatVersion)
        guard value == supported else {
            throw FeedbackContractError.unsupportedVersion(
                document: document,
                actual: value,
                supported: supported
            )
        }
        return value
    }
}

enum FeedbackFormatVersionCodingKey: String, CodingKey {
    case formatVersion
}

/// Small, dependency-free SHA-256 implementation so the contract target stays
/// Foundation-only. The implementation is exercised against published vectors.
private enum FeedbackSHA256 {
    private static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var bytes = [UInt8](data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        bytes.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))

        var state = initial
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = UInt32(bytes[start]) << 24 |
                    UInt32(bytes[start + 1]) << 16 |
                    UInt32(bytes[start + 2]) << 8 |
                    UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], by: 7) ^
                    rotateRight(words[index - 15], by: 18) ^
                    (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], by: 17) ^
                    rotateRight(words[index - 2], by: 19) ^
                    (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]

            for index in 0..<64 {
                let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ ((~e) & g)
                let temporary1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
                let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }

            state[0] &+= a
            state[1] &+= b
            state[2] &+= c
            state[3] &+= d
            state[4] &+= e
            state[5] &+= f
            state[6] &+= g
            state[7] &+= h
        }

        return state.flatMap { word in
            let bigEndian = word.bigEndian
            return withUnsafeBytes(of: bigEndian, Array.init)
        }
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
