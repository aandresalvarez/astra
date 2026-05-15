import Foundation

enum MarkdownLinkifier {
    private static let maximumCachedUTF16Length = 200_000
    enum WhitespaceMode: String {
        case normalized
        case preserving
    }

    private final class CacheEntry {
        let attributed: AttributedString

        init(_ attributed: AttributedString) {
            self.attributed = attributed
        }
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static let cache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.countLimit = 512
        cache.totalCostLimit = 2_000_000
        return cache
    }()

    static func markdownAttributed(
        _ text: String,
        whitespaceMode: WhitespaceMode = .normalized
    ) -> AttributedString {
        guard text.utf16.count <= maximumCachedUTF16Length else {
            return makeMarkdownAttributed(text, whitespaceMode: whitespaceMode)
        }

        let cacheKey = "\(whitespaceMode.rawValue):\(text)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.attributed
        }

        let attributed = makeMarkdownAttributed(text, whitespaceMode: whitespaceMode)
        cache.setObject(CacheEntry(attributed), forKey: cacheKey, cost: text.utf16.count)
        return attributed
    }

    static func clearCacheForTests() {
        cache.removeAllObjects()
    }

    private static func makeMarkdownAttributed(
        _ text: String,
        whitespaceMode: WhitespaceMode
    ) -> AttributedString {
        let syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax = switch whitespaceMode {
        case .normalized:
            .inlineOnly
        case .preserving:
            .inlineOnlyPreservingWhitespace
        }
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: syntax)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(text)
        }

        let plain = String(attributed.characters)
        guard let detector = linkDetector else { return attributed }

        let matches = detector.matches(
            in: plain,
            range: NSRange(location: 0, length: (plain as NSString).length)
        )

        for match in matches {
            guard let url = match.url,
                  let swiftRange = Range(match.range, in: plain) else { continue }
            let start = attributed.characters.index(
                attributed.startIndex,
                offsetBy: plain.distance(from: plain.startIndex, to: swiftRange.lowerBound)
            )
            let end = attributed.characters.index(
                start,
                offsetBy: plain.distance(from: swiftRange.lowerBound, to: swiftRange.upperBound)
            )
            if attributed[start..<end].runs.allSatisfy({ $0.link == nil }) {
                attributed[start..<end].link = url
            }
        }

        return attributed
    }
}
