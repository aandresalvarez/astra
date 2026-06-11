import Foundation

final class WildcardPatternMatcher: @unchecked Sendable {
    static let shared = WildcardPatternMatcher()

    private let lock = NSLock()
    private var compiledPatterns: [String: NSRegularExpression] = [:]
    private let maxPatternLength: Int

    init(maxPatternLength: Int = 512) {
        self.maxPatternLength = maxPatternLength
    }

    var compiledPatternCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return compiledPatterns.count
    }

    func matches(_ value: String, pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern.count <= maxPatternLength else { return false }
        if pattern == "*" { return true }
        guard let compiled = compiledPattern(for: pattern) else { return false }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return compiled.firstMatch(in: value, range: range) != nil
    }

    private func compiledPattern(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        if let existing = compiledPatterns[pattern] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let regex = Self.regexSource(for: pattern)
        guard let compiled = try? NSRegularExpression(pattern: regex) else { return nil }

        lock.lock()
        if let existing = compiledPatterns[pattern] {
            lock.unlock()
            return existing
        }
        compiledPatterns[pattern] = compiled
        lock.unlock()
        return compiled
    }

    private static func regexSource(for pattern: String) -> String {
        var regex = "^"
        for scalar in pattern.unicodeScalars {
            switch scalar {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            default:
                regex += NSRegularExpression.escapedPattern(for: String(scalar))
            }
        }
        regex += "$"
        return regex
    }
}
