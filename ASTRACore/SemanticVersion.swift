import Foundation

public struct SemanticVersion: Comparable, Equatable, Codable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(string: String) {
        let parts = string
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: ".")
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
