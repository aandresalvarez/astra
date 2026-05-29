import Foundation
import SwiftUI

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
        cache.countLimit = 1024
        cache.totalCostLimit = 4_000_000
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
        let sourceText = compactRawURLs(in: text)
        let syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax = switch whitespaceMode {
        case .normalized:
            .inlineOnly
        case .preserving:
            .inlineOnlyPreservingWhitespace
        }
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: sourceText,
            options: .init(interpretedSyntax: syntax)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(sourceText)
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
                attributed[start..<end].foregroundColor = Stanford.link
            }
        }

        return attributed
    }

    private static func compactRawURLs(in text: String) -> String {
        guard let detector = linkDetector else { return text }
        let matches = detector.matches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: text) else { continue }
            guard range.lowerBound >= cursor else { continue }

            let raw = String(text[range])
            guard raw.count >= 58, !isAlreadyMarkdownDestination(in: text, range: range) else {
                output.append(contentsOf: text[cursor..<range.upperBound])
                cursor = range.upperBound
                continue
            }

            output.append(contentsOf: text[cursor..<range.lowerBound])
            output.append("[")
            output.append(markdownEscapedTitle(displayTitle(for: url, raw: raw)))
            output.append("](<")
            output.append(markdownEscapedURL(url.absoluteString))
            output.append(">)")
            cursor = range.upperBound
        }
        output.append(contentsOf: text[cursor...])
        return output
    }

    private static func isAlreadyMarkdownDestination(in text: String, range: Range<String.Index>) -> Bool {
        guard range.lowerBound > text.startIndex else { return false }
        let previous = text[text.index(before: range.lowerBound)]
        if previous == "<" { return true }
        guard previous == "(" else { return false }
        let prefix = text[..<range.lowerBound]
        return prefix.lastIndex(of: "[") != nil || prefix.lastIndex(of: "]") != nil
    }

    private static func displayTitle(for url: URL, raw: String) -> String {
        let host = url.host ?? raw
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else {
            return shortened(raw: host, limit: 46)
        }

        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        let candidate = lastComponent.isEmpty
            ? "\(host)/\(path)"
            : "\(host)/.../\(lastComponent)"
        return shortened(raw: candidate, limit: 54)
    }

    private static func shortened(raw: String, limit: Int) -> String {
        guard raw.count > limit else { return raw }
        let headCount = max(12, (limit - 3) / 2)
        let tailCount = max(10, limit - headCount - 3)
        return "\(raw.prefix(headCount))...\(raw.suffix(tailCount))"
    }

    private static func markdownEscapedTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func markdownEscapedURL(_ url: String) -> String {
        url
            .replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: " ", with: "%20")
    }
}
