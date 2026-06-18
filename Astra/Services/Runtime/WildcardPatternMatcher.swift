import Foundation

final class WildcardPatternMatcher: @unchecked Sendable {
    static let shared = WildcardPatternMatcher()

    private let lock = NSLock()
    private var compiledPatterns: [String: NSRegularExpression] = [:]
    private var insertionOrder: [String] = []
    private let maxPatternLength: Int
    private let maxCachedPatterns: Int

    init(maxPatternLength: Int = 512, maxCachedPatterns: Int = 256) {
        self.maxPatternLength = maxPatternLength
        self.maxCachedPatterns = maxCachedPatterns
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
        guard maxCachedPatterns > 0 else {
            lock.unlock()
            return compiled
        }
        while compiledPatterns.count >= maxCachedPatterns, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            compiledPatterns.removeValue(forKey: oldest)
        }
        compiledPatterns[pattern] = compiled
        insertionOrder.append(pattern)
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
