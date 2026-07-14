import Foundation

/// Shared formatting utilities used across multiple views.
public enum Formatters {
    public struct SidebarTaskTitlePresentation: Equatable {
        public let prefix: String?
        public let primary: String
        public let fullTitle: String

        public var displayTitle: String {
            guard let prefix, !prefix.isEmpty else { return primary }
            return "\(prefix) · \(primary)"
        }

        /// Navigation rows can prioritize the task object while preserving the
        /// complete original title for hover help and accessibility. Surfaces
        /// with more room may continue to render `displayTitle`.
        public var primaryOnly: SidebarTaskTitlePresentation {
            SidebarTaskTitlePresentation(
                prefix: nil,
                primary: primary,
                fullTitle: fullTitle
            )
        }
    }

    /// Format a token count for display (e.g., 1500 -> "1.5k", 1500000 -> "1.5M").
    public static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    /// Compact, human-readable timestamp tuned for sidebar / card chrome.
    /// Matches the sidebar's "3d / 2h / now" style for recent dates and
    /// gracefully degrades to a short month-day format for older ones —
    /// avoids the sin of every Kanban card showing the same long
    /// "April 17, 2026" string when most cards are days old.
    ///
    /// Pair with `Formatters.fullDate(_:)` in a `.help()` so users can
    /// still hover for the absolute timestamp when they need it.
    public static func relativeShort(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        // 1 week to 1 year — show "Apr 17"
        if interval < 31_536_000 {
            return monthDayFormatter.string(from: date)
        }
        // Older — include the year.
        return monthDayYearFormatter.string(from: date)
    }

    /// Cached "MMM d" formatter for `relativeShort(_:)`. DateFormatter is
    /// expensive to allocate; reads are thread-safe once configured.
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Cached "MMM d, yyyy" formatter for `relativeShort(_:)` on older dates.
    private static let monthDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    /// Long-form timestamp suitable for a tooltip / accessibility hint
    /// when a UI surface only shows `relativeShort(_:)`.
    public static func fullDate(_ date: Date) -> String {
        return fullDateFormatter.string(from: date)
    }

    /// Cached long-date / short-time formatter for `fullDate(_:)` tooltips.
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    /// Middle-ellipsize identifier-like tokens (long, contain `. _ - /`) so
    /// compact rows preserve both the recognizable prefix and useful suffix.
    /// Normal prose is left alone.
    public static func shortenIdentifierTokens(
        _ text: String,
        maxTokenLength: Int = 28,
        keepEachSide: Int = 10
    ) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace })
            .map { rawToken -> String in
                let token = String(rawToken)
                guard token.count > maxTokenLength else { return token }
                let hasIdSeparator = token.contains(where: { "._-/".contains($0) })
                guard hasIdSeparator else { return token }
                let head = token.prefix(keepEachSide)
                let tail = token.suffix(keepEachSide)
                return "\(head)…\(tail)"
            }
            .joined(separator: " ")
    }

    /// Compact task-title presentation for navigation rows. Generic task verbs
    /// become a quiet prefix so the object phrase stays scannable.
    public static func sidebarTaskTitlePresentation(
        _ text: String
    ) -> SidebarTaskTitlePresentation {
        let normalized = normalizedSidebarTaskTitle(text)
        let (prefix, primarySource) = sidebarTaskPrefixAndPrimary(normalized)

        return SidebarTaskTitlePresentation(
            prefix: prefix,
            primary: primarySource.isEmpty ? normalized : primarySource,
            fullTitle: text
        )
    }

    /// Compact task titles for callers that need a single string. Prefer
    /// `sidebarTaskTitlePresentation(_:)` in SwiftUI rows so the action prefix
    /// can be visually de-emphasized.
    public static func sidebarTaskTitle(_ text: String, maxCharacters: Int = 32) -> String {
        let normalized = normalizedSidebarTaskTitle(text)
        let (prefix, primarySource) = sidebarTaskPrefixAndPrimary(normalized)
        let primaryBudget = if let prefix {
            max(12, maxCharacters - prefix.count - 3)
        } else {
            maxCharacters
        }
        let primary = compactSidebarTaskTitle(primarySource, maxCharacters: primaryBudget)

        guard let prefix, !prefix.isEmpty else { return primary }
        return "\(prefix) · \(primary)"
    }

    private static let sidebarTaskActionPrefixes: Set<String> = [
        "add",
        "analyze",
        "build",
        "check",
        "count",
        "create",
        "draft",
        "export",
        "find",
        "fix",
        "generate",
        "implement",
        "import",
        "inspect",
        "investigate",
        "list",
        "prepare",
        "query",
        "refactor",
        "remove",
        "review",
        "run",
        "summarize",
        "sync",
        "test",
        "update",
        "validate",
        "verify",
        "write"
    ]

    private static let sidebarTaskLeadingArticles: Set<String> = ["a", "an", "the"]

    private static func normalizedSidebarTaskTitle(_ text: String) -> String {
        let normalized = shortenIdentifierTokens(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsedRepeatedSidebarTitle(normalized)
    }

    private static func collapsedRepeatedSidebarTitle(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count >= 8, characters.count.isMultiple(of: 2) else { return text }

        let midpoint = characters.count / 2
        let firstHalf = String(characters[..<midpoint])
        let secondHalf = String(characters[midpoint...])
        guard firstHalf == secondHalf, firstHalf.contains(" ") else { return text }
        return firstHalf
    }

    private static func sidebarTaskPrefixAndPrimary(_ normalized: String) -> (String?, String) {
        var words = normalized.split(separator: " ").map(String.init)
        guard words.count > 1,
              let first = words.first,
              sidebarTaskActionPrefixes.contains(normalizedSidebarWord(first)) else {
            return (nil, normalized)
        }

        words.removeFirst()
        while let firstRemainder = words.first,
              sidebarTaskLeadingArticles.contains(normalizedSidebarWord(firstRemainder)) {
            words.removeFirst()
        }

        guard !words.isEmpty else { return (nil, normalized) }
        return (first, words.joined(separator: " "))
    }

    private static func normalizedSidebarWord(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?()[]{}\"'"))
            .lowercased()
    }

    private static func compactSidebarTaskTitle(_ normalized: String, maxCharacters: Int) -> String {
        guard normalized.count > maxCharacters else { return normalized }

        let words = normalized.split(separator: " ")
        guard words.count > 1 else {
            return normalized
        }

        let maxHeadWords = min(3, words.count - 1)
        let maxTailWords = min(4, words.count - 1)
        let separator = " … "
        var best: (value: String, totalWords: Int, headScore: Int, tailWords: Int, headWords: Int)?

        for headCount in 1...maxHeadWords {
            for tailCount in 1...maxTailWords {
                guard headCount + tailCount <= words.count else { continue }
                let head = words.prefix(headCount).joined(separator: " ")
                let tail = words.suffix(tailCount).joined(separator: " ")
                let candidate = "\(head)\(separator)\(tail)"
                guard candidate.count <= maxCharacters else { continue }

                let totalWords = headCount + tailCount
                let headScore = min(headCount, 2)
                if best == nil ||
                    tailCount > best!.tailWords ||
                    (tailCount == best!.tailWords && totalWords > best!.totalWords) ||
                    (tailCount == best!.tailWords && totalWords == best!.totalWords && headScore > best!.headScore) ||
                    (tailCount == best!.tailWords && totalWords == best!.totalWords && headScore == best!.headScore && headCount > best!.headWords) {
                    best = (candidate, totalWords, headScore, tailCount, headCount)
                }
            }
        }

        if let best {
            return best.value
        }

        let head = String(words.first ?? "")
        let tail = String(words.last ?? "")
        return "\(head)\(separator)\(tail)"
    }

    /// Return an SF Symbol name for a file path based on its extension.
    public static func fileIcon(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "jsx", "tsx": return "curlybraces"
        case "json": return "doc.text"
        case "md", "markdown", "qmd", "txt": return "doc.plaintext"
        case "html", "css": return "globe"
        case "sh", "zsh", "bash": return "terminal"
        case "yml", "yaml", "toml": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "tiff", "bmp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}
