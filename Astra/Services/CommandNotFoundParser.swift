import Foundation

/// Parses a stderr blob for "command not found" patterns and returns the
/// offending binary name. Used to rewrite opaque task failures into
/// actionable "Install `gcloud`" errors in `AgentRuntimeWorker`.
///
/// Shells and tools print this message in a handful of predictable forms;
/// we match the common ones and return nil when none fit — the caller
/// falls back to the raw stderr.
///
/// Matched patterns:
///   - bash / sh     : "bash: gcloud: command not found"
///   - zsh           : "zsh: command not found: gcloud"
///   - direct exec   : "/bin/sh: gcloud: command not found"
///   - docker-compose: "docker-compose: command not found"
///   - npm / yarn    : "sh: 1: gcloud: not found"   (Linux-ish dash)
///   - fish          : "fish: Unknown command: gcloud"
///   - generic       : "gcloud: command not found" at end of string
public enum CommandNotFoundParser {
    /// Extract the missing binary name from `stderr`, or `nil` if no
    /// recognised pattern matched.
    public static func parse(stderr: String) -> String? {
        // Order matters: zsh's "command not found: X" comes before the
        // bash form because bash's pattern also matches inside a zsh line.
        let patterns: [String] = [
            // zsh: `zsh: command not found: gcloud`
            #"(?:zsh|fish): (?:Unknown )?command not found: ([\w.\-]+)"#,
            // bash/sh: `bash: gcloud: command not found`
            #"(?:bash|sh|dash|ksh): (?:\d+: )?([\w.\-]+): command not found"#,
            // /path/to/shell: `/bin/sh: gcloud: command not found`
            #"^/[^\s:]+: (?:\d+: )?([\w.\-]+): command not found"#,
            // Linux "not found" form
            #"([\w.\-]+): not found"#,
            // Bare form: `gcloud: command not found`
            #"^([\w.\-]+): command not found"#,
            // fish: `fish: Unknown command: gcloud`
            #"Unknown command: ([\w.\-]+)"#,
        ]

        for pattern in patterns {
            if let match = regexMatch(pattern: pattern, in: stderr) {
                // Defensive: refuse trivially-wrong captures. A binary
                // name shouldn't be pure digits or contain slashes.
                let trimmed = match.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty
                    && !trimmed.contains("/")
                    && Int(trimmed) == nil {
                    return trimmed
                }
            }
        }
        return nil
    }

    // MARK: - Private

    private static func regexMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, range: range),
              result.numberOfRanges >= 2,
              let captureRange = Range(result.range(at: 1), in: text)
        else { return nil }

        return String(text[captureRange])
    }
}
