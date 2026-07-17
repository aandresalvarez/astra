import Foundation

public enum ASTRACanonicalJSONError: Error, Equatable, Sendable {
    case invalidDate
}

/// Single canonical JSON representation used by durable CAS payloads and
/// cross-layer digests. Dates are finite signed Int64 milliseconds, never
/// floating-point seconds.
public enum ASTRACanonicalJSON {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = date.timeIntervalSince1970 * 1_000
            guard milliseconds.isFinite,
                  milliseconds >= Double(Int64.min),
                  milliseconds <= Double(Int64.max) else {
                throw ASTRACanonicalJSONError.invalidDate
            }
            var container = encoder.singleValueContainer()
            try container.encode(Int64(milliseconds.rounded(.towardZero)))
        }
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(
                timeIntervalSince1970: Double(try container.decode(Int64.self)) / 1_000
            )
        }
        return try decoder.decode(type, from: data)
    }
}
