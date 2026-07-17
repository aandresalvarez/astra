import Foundation

struct RuntimeSwitchDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum RuntimeSwitchStrictCoding {
    static func rejectUnknownKeys(
        in decoder: Decoder,
        allowed: Set<String>,
        typeName: String
    ) throws {
        let container = try decoder.container(keyedBy: RuntimeSwitchDynamicCodingKey.self)
        let unknown = container.allKeys
            .map(\.stringValue)
            .filter { !allowed.contains($0) }
            .sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported \(typeName) fields: \(unknown.joined(separator: ", "))"
            ))
        }
    }

    static func requireSchemaVersion<Key: CodingKey>(
        _ expected: Int,
        in container: KeyedDecodingContainer<Key>,
        key: Key,
        typeName: String
    ) throws {
        let version = try container.decode(Int.self, forKey: key)
        guard version == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Unsupported \(typeName) schema version: \(version)"
            )
        }
    }
}
