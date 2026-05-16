import Foundation

/// Shared formatting utilities used across multiple views.
enum Formatters {

    /// Format a token count for display (e.g., 1500 -> "1.5k", 1500000 -> "1.5M").
    static func formatTokens(_ count: Int) -> String {
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
    static func relativeShort(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        // 1 week to 1 year — show "Apr 17"
        if interval < 31_536_000 {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: date)
        }
        // Older — include the year.
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    /// Long-form timestamp suitable for a tooltip / accessibility hint
    /// when a UI surface only shows `relativeShort(_:)`.
    static func fullDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Middle-ellipsize identifier-like tokens (long, contain `. _ - /`) so
    /// compact rows preserve both the recognizable prefix and useful suffix.
    /// Normal prose is left alone.
    static func shortenIdentifierTokens(
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

    /// Compact task titles for narrow sidebar rows without clipping ordinary
    /// prose mid-word. Keeps the leading action/context and the trailing
    /// disambiguator so similarly-prefixed tasks remain scannable.
    static func sidebarTaskTitle(_ text: String, maxCharacters: Int = 32) -> String {
        let normalized = shortenIdentifierTokens(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count > maxCharacters else { return normalized }

        let words = normalized.split(separator: " ")
        guard words.count > 1 else {
            return middleEllipsizeToken(normalized, maxCharacters: maxCharacters)
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
                    headScore > best!.headScore ||
                    (headScore == best!.headScore && totalWords > best!.totalWords) ||
                    (headScore == best!.headScore && totalWords == best!.totalWords && tailCount > best!.tailWords) ||
                    (headScore == best!.headScore && totalWords == best!.totalWords && tailCount == best!.tailWords && headCount > best!.headWords) {
                    best = (candidate, totalWords, headScore, tailCount, headCount)
                }
            }
        }

        if let best {
            return best.value
        }

        let headBudget = max(4, (maxCharacters - separator.count) / 2)
        let tailBudget = max(4, maxCharacters - separator.count - headBudget)
        let head = middleEllipsizeToken(String(words.first ?? ""), maxCharacters: headBudget)
        let tail = middleEllipsizeToken(String(words.last ?? ""), maxCharacters: tailBudget)
        return "\(head)\(separator)\(tail)"
    }

    private static func middleEllipsizeToken(_ token: String, maxCharacters: Int) -> String {
        guard token.count > maxCharacters, maxCharacters > 1 else { return token }
        let sideCount = max(1, (maxCharacters - 1) / 2)
        let head = token.prefix(sideCount)
        let tail = token.suffix(max(1, maxCharacters - 1 - sideCount))
        return "\(head)…\(tail)"
    }

    /// Return an SF Symbol name for a file path based on its extension.
    static func fileIcon(for path: String) -> String {
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
