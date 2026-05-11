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
