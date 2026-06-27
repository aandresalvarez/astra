import Foundation

// Defined in F1 because `WorkspaceAppManifest` (action gate values) depends on
// it. When F2 re-lands `WorkspaceAppStorageService.swift`, that file must NOT
// redefine this enum — it references the definition here instead.
enum WorkspaceAppStorageValue: Codable, Sendable, Equatable {
    case null
    case text(String)
    case integer(Int64)
    case real(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let real = try? container.decode(Double.self) {
            self = .real(real)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .text(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .real(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}
