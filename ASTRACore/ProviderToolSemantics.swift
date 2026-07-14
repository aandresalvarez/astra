import Foundation

/// Canonical provider-tool semantics shared by event normalization, policy
/// enforcement, and permission brokerage. Provider-specific event names must
/// be classified here so those layers cannot disagree about the same action.
public enum ProviderToolSemantics {
    public static func normalizedName(_ tool: String) -> String {
        let lower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("shell(") || lower.hasPrefix("bash(") {
            return "bash"
        }
        switch lower {
        case "shell", "command_execution":
            return "bash"
        case "view":
            return "read"
        case "create", "apply_patch":
            return "write"
        case "multi_edit":
            return "multiedit"
        default:
            return lower
        }
    }

    public static func isShellTool(_ tool: String) -> Bool {
        normalizedName(tool) == "bash"
    }

    /// Returns the semantic command carried by an exact `sh -lc` style
    /// provider launcher. Codex reports shell work through concrete launchers
    /// such as `/bin/zsh -lc 'git status'`; policy and approval code must reason
    /// about `git status`, not accidentally grant the wrapper itself.
    ///
    /// Each wrapper layer must contain one fully quoted payload. Ambiguous
    /// quoting, interpolation-capable double-quoted payloads, and extra
    /// launcher arguments remain unchanged so callers continue to fail closed.
    public static func semanticShellCommand(_ command: String) -> String {
        var semantic = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<4 {
            guard let payload = shellLoginCommandPayload(from: semantic) else { break }
            semantic = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return semantic
    }

    private static func shellLoginCommandPayload(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markerRange = trimmed.range(of: " -lc ") else { return nil }

        let executable = String(trimmed[..<markerRange.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard ["sh", "bash", "zsh"].contains(
            URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        ) else {
            return nil
        }

        let quotedPayload = String(trimmed[markerRange.upperBound...])
        guard quotedPayload.count >= 2,
              let quote = quotedPayload.first,
              quote == "'" || quote == "\"",
              quotedPayload.last == quote else {
            return nil
        }

        let payload = String(quotedPayload.dropFirst().dropLast())
        if quote == "'" {
            guard !payload.contains("'") else { return nil }
        } else {
            guard !payload.contains("\""),
                  !payload.contains("\\"),
                  !payload.contains("$"),
                  !payload.contains("`") else {
                return nil
            }
        }
        return payload
    }
}
