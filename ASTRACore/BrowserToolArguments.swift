import Foundation

public enum BrowserToolCommandParser {
    public static let noOpGlobalValueFlags: Set<String> = [
        "--task",
        "--task-id"
    ]

    public static let knownOptionFlags: Set<String> = [
        "--absent",
        "--action",
        "--analysis",
        "--analysis-id",
        "--analysis-version",
        "--append",
        "--body",
        "--click",
        "--click-analysis",
        "--click-analysis-id",
        "--click-control",
        "--click-control-id",
        "--click-role",
        "--control",
        "--control-id",
        "--dangerous",
        "--debug",
        "--file",
        "--find",
        "--first",
        "--full",
        "--help",
        "--json",
        "--keep-open",
        "--key",
        "--kind",
        "--label",
        "--limit",
        "--mode",
        "--mod",
        "--modifier",
        "--name",
        "--no-wait-saved",
        "--old",
        "--placeholder",
        "--query",
        "--replacement",
        "--role",
        "--selector",
        "--set",
        "--set-analysis",
        "--set-analysis-id",
        "--set-control",
        "--set-control-id",
        "--test-id",
        "--testid",
        "--text",
        "--timeout",
        "--title",
        "--url",
        "--v2",
        "--verify",
        "--version",
        "--wait-saved",
        "--with",
        "--x",
        "--y"
    ]

    public static func sanitizedArguments(_ arguments: [String]) throws -> [String] {
        guard let command = arguments.first else { return [] }
        var sanitized = [command]
        var index = arguments.index(after: arguments.startIndex)

        while index < arguments.endIndex {
            let argument = arguments[index]
            if noOpGlobalValueFlags.contains(argument) {
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex,
                      !arguments[valueIndex].hasPrefix("--") else {
                    throw BrowserToolArgumentError.missingValue(argument)
                }
                index = arguments.index(after: valueIndex)
                continue
            }

            if argument.hasPrefix("--"), !knownOptionFlags.contains(argument) {
                throw BrowserToolArgumentError.unknownFlag(argument)
            }

            sanitized.append(argument)
            index = arguments.index(after: index)
        }

        return sanitized
    }

    public static func navigateTarget(from cursor: inout BrowserToolArgumentCursor) -> String? {
        cursor.value(after: "--url") ?? cursor.remainingText()
    }
}

public enum BrowserToolArgumentError: LocalizedError, Equatable {
    case unknownFlag(String)
    case missingValue(String)

    public var errorDescription: String? {
        switch self {
        case .unknownFlag(let flag):
            return "unknown_flag: \(flag)"
        case .missingValue(let flag):
            return "missing_value: \(flag)"
        }
    }
}

public struct BrowserToolArgumentCursor {
    private let arguments: [String]
    private var consumed: Set<Int> = []
    private var cursor = 0

    public init(_ arguments: [String]) {
        self.arguments = arguments
    }

    public mutating func next() -> String? {
        while cursor < arguments.count {
            defer { cursor += 1 }
            guard !consumed.contains(cursor) else { continue }
            consumed.insert(cursor)
            return arguments[cursor]
        }
        return nil
    }

    public mutating func nextValue() -> String? {
        while cursor < arguments.count {
            defer { cursor += 1 }
            guard !consumed.contains(cursor) else { continue }
            guard !arguments[cursor].hasPrefix("--") else { continue }
            consumed.insert(cursor)
            return arguments[cursor]
        }
        return nil
    }

    public mutating func contains(_ flag: String) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        consumed.insert(index)
        return true
    }

    public func has(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    public mutating func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("--") else {
            return nil
        }
        consumed.insert(index)
        consumed.insert(index + 1)
        return arguments[index + 1]
    }

    public mutating func values(after flag: String) -> [String] {
        var values: [String] = []
        for index in arguments.indices where arguments[index] == flag && arguments.indices.contains(index + 1) {
            guard !arguments[index + 1].hasPrefix("--") else { continue }
            consumed.insert(index)
            consumed.insert(index + 1)
            values.append(arguments[index + 1])
        }
        return values
    }

    public mutating func remainingText() -> String? {
        let rest = arguments.indices
            .filter { !consumed.contains($0) }
            .map { arguments[$0] }
            .filter { !$0.hasPrefix("--") }
        for index in arguments.indices where !consumed.contains(index) {
            consumed.insert(index)
        }
        let text = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
