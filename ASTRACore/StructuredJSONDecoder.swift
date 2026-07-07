import Foundation

public struct StructuredJSONDecodeDiagnostic: Equatable, Sendable {
    public enum Status: String, Sendable {
        case decoded
        case emptyInput
        case decodeFailed
    }

    public var status: Status
    public var typeName: String
    public var byteCount: Int
    public var codingPath: String?
    public var errorDescription: String?

    public var didDecode: Bool {
        status == .decoded
    }

    public static func decoded<T>(_ type: T.Type, byteCount: Int) -> StructuredJSONDecodeDiagnostic {
        StructuredJSONDecodeDiagnostic(
            status: .decoded,
            typeName: String(describing: type),
            byteCount: byteCount,
            codingPath: nil,
            errorDescription: nil
        )
    }

    public static func empty<T>(_ type: T.Type) -> StructuredJSONDecodeDiagnostic {
        StructuredJSONDecodeDiagnostic(
            status: .emptyInput,
            typeName: String(describing: type),
            byteCount: 0,
            codingPath: nil,
            errorDescription: "JSON input was empty."
        )
    }

    public static func failed<T>(_ type: T.Type, byteCount: Int, error: Error) -> StructuredJSONDecodeDiagnostic {
        let details = decodeErrorDetails(error)
        return StructuredJSONDecodeDiagnostic(
            status: .decodeFailed,
            typeName: String(describing: type),
            byteCount: byteCount,
            codingPath: details.codingPath,
            errorDescription: details.description
        )
    }

    private static func decodeErrorDetails(_ error: Error) -> (codingPath: String?, description: String) {
        switch error {
        case let DecodingError.typeMismatch(type, context):
            return (
                codingPathDescription(context.codingPath),
                "Type mismatch for \(type): \(context.debugDescription)"
            )
        case let DecodingError.valueNotFound(type, context):
            return (
                codingPathDescription(context.codingPath),
                "Value not found for \(type): \(context.debugDescription)"
            )
        case let DecodingError.keyNotFound(key, context):
            let path = context.codingPath + [key]
            return (
                codingPathDescription(path),
                "Missing key \(key.stringValue): \(context.debugDescription)"
            )
        case let DecodingError.dataCorrupted(context):
            return (
                codingPathDescription(context.codingPath),
                "Data corrupted: \(context.debugDescription)"
            )
        default:
            return (nil, error.localizedDescription)
        }
    }

    private static func codingPathDescription(_ codingPath: [CodingKey]) -> String? {
        guard !codingPath.isEmpty else { return nil }
        return codingPath.map(\.stringValue).joined(separator: ".")
    }
}

public struct StructuredJSONDecodeResult<Value> {
    public var value: Value?
    public var diagnostic: StructuredJSONDecodeDiagnostic

    public var didDecode: Bool {
        value != nil && diagnostic.didDecode
    }

    public func map<NewValue>(_ transform: (Value) -> NewValue?) -> StructuredJSONDecodeResult<NewValue> {
        StructuredJSONDecodeResult<NewValue>(
            value: value.flatMap(transform),
            diagnostic: diagnostic
        )
    }
}

public enum StructuredJSONDecoder {
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from json: String
    ) -> StructuredJSONDecodeResult<T> {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return StructuredJSONDecodeResult(value: nil, diagnostic: .empty(type))
        }
        return decode(type, from: Data(trimmed.utf8))
    }

    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) -> StructuredJSONDecodeResult<T> {
        guard !data.isEmpty else {
            return StructuredJSONDecodeResult(value: nil, diagnostic: .empty(type))
        }

        do {
            let value = try JSONDecoder().decode(type, from: data)
            return StructuredJSONDecodeResult(
                value: value,
                diagnostic: .decoded(type, byteCount: data.count)
            )
        } catch {
            return StructuredJSONDecodeResult(
                value: nil,
                diagnostic: .failed(type, byteCount: data.count, error: error)
            )
        }
    }
}
