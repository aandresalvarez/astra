import Foundation

enum MarkdownLinkifier {
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func markdownAttributed(_ text: String) -> AttributedString {
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
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
