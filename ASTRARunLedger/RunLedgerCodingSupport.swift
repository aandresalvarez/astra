import Foundation

private struct RunLedgerAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum RunLedgerStrictCoding {
    /// Swift's keyed decoding ignores unknown keys by default. Durable journal
    /// payloads must instead fail closed so an older reader cannot silently
    /// reinterpret a newer schema as an older event.
    static func requireExactKeys(
        _ decoder: Decoder,
        expected: Set<String>,
        typeName: String
    ) throws {
        let container = try decoder.container(keyedBy: RunLedgerAnyCodingKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted()
            let unknown = actual.subtracting(expected).sorted()
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\(typeName) has non-canonical keys; missing=\(missing), unknown=\(unknown)"
            ))
        }
    }
}
