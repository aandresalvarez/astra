import Foundation
import ASTRACore

/// Rewrites opaque worker failures into actionable install guidance when
/// the stderr contains a "command not found" signal.
///
/// When the Claude agent (or any subprocess it spawned) dies because a CLI
/// isn't installed, the raw message the user sees is useless — e.g.
/// `Agent exited with code 127. zsh: command not found: gcloud`. This
/// enricher:
///
///   1. Parses the stderr for a missing-binary name.
///   2. Looks up the binary against the union of known CLI prerequisites
///      (built-in catalog + the workspace's installed packages).
///   3. Returns a crisp "Install `X`" message with the known install hint
///      and URL, so the user can act without trawling docs.
///
/// If nothing matches, it returns `nil` so the caller falls back to the
/// raw error string.
public enum ClaudeErrorEnricher {
    /// Result of a successful enrichment. Exposes the missing binary and
    /// a pre-formatted user-facing message. URL and hint surface for UI
    /// that wants to render a "Install" button separately from the text.
    public struct Enrichment: Equatable {
        public let binary: String
        public let displayMessage: String
        public let installHint: String
        public let installURL: URL?
    }

    /// Enrich `stderr` against a universe of known prerequisites.
    ///
    /// - Parameters:
    ///   - stderr: Raw stderr from the failed agent run.
    ///   - knownPrerequisites: Everything we know about — union of
    ///     built-in catalog prereqs plus the workspace's installed
    ///     packages. Duplicates by binary name are fine; the first match
    ///     wins and they're all equivalent for display purposes.
    /// - Returns: An `Enrichment` if we recognized the missing binary,
    ///   otherwise `nil`.
    public static func enrich(
        stderr: String,
        knownPrerequisites: [CLIPrerequisite]
    ) -> Enrichment? {
        guard let missing = CommandNotFoundParser.parse(stderr: stderr) else {
            return nil
        }

        // Prefer a precise match from our catalog; otherwise fall back to
        // a generic "install this binary" message. Either way the user gets
        // a clear instruction; only the `installHint`/`installURL` differ.
        if let known = knownPrerequisites.first(where: { $0.binary == missing }) {
            let message = """
            `\(known.binary)` is required but was not found on your PATH. \
            \(known.installHint)
            """
            return Enrichment(
                binary: known.binary,
                displayMessage: message,
                installHint: known.installHint,
                installURL: known.installURL
            )
        }

        let genericHint = "Install `\(missing)` and make sure it's on your PATH, then retry."
        return Enrichment(
            binary: missing,
            displayMessage: "Required CLI `\(missing)` is not installed. \(genericHint)",
            installHint: genericHint,
            installURL: nil
        )
    }
}
