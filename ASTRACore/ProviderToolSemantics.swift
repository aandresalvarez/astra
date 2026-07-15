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
    /// Each wrapper layer must contain one fully quoted payload and an
    /// environment-neutral launcher. Environment configuration, ambiguous
    /// quoting, interpolation-capable double-quoted payloads, and extra
    /// launcher arguments remain unchanged so approval callers fail closed.
    public static func semanticShellCommand(_ command: String) -> String {
        semanticShellCommand(command, allowingLauncherEnvironment: false)
    }

    /// Returns the launcher payload for mutation data-flow analysis, including
    /// launchers with leading environment configuration. This must not be used
    /// for approval or allow-list matching because variables such as BASH_ENV
    /// can execute behavior before the quoted payload begins.
    public static func mutationAnalysisShellCommand(_ command: String) -> String {
        semanticShellCommand(command, allowingLauncherEnvironment: true)
    }

    private static func semanticShellCommand(
        _ command: String,
        allowingLauncherEnvironment: Bool
    ) -> String {
        var semantic = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<4 {
            guard let payload = shellLoginCommandPayload(
                from: semantic,
                allowingLauncherEnvironment: allowingLauncherEnvironment
            ) else { break }
            semantic = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return semantic
    }

    private static func shellLoginCommandPayload(
        from command: String,
        allowingLauncherEnvironment: Bool
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markerRange = unquotedRange(of: " -lc ", in: trimmed) else { return nil }

        let launcherPrefix = String(trimmed[..<markerRange.lowerBound])
        guard let executable = shellLauncherExecutable(
            from: launcherPrefix,
            allowingEnvironmentConfiguration: allowingLauncherEnvironment
        ) else {
            return nil
        }
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

    /// Accepts only an exact shell executable. Mutation-only analysis may also
    /// accept leading `env` options and assignments; approval normalization may
    /// not. Ordinary commands ending an argument list with `/bin/sh` must never
    /// be mistaken for launchers.
    private static func shellLauncherExecutable(
        from prefix: String,
        allowingEnvironmentConfiguration: Bool
    ) -> String? {
        guard var words = shellWords(in: prefix), !words.isEmpty else { return nil }
        var hasEnvironmentConfiguration = false
        if let first = words.first,
           URL(fileURLWithPath: first).lastPathComponent.lowercased() == "env" {
            hasEnvironmentConfiguration = true
            words.removeFirst()
            guard consumeEnvOptions(from: &words) else { return nil }
        }
        while let first = words.first, isEnvironmentAssignment(first) {
            hasEnvironmentConfiguration = true
            words.removeFirst()
        }
        guard allowingEnvironmentConfiguration || !hasEnvironmentConfiguration else { return nil }
        guard words.count == 1 else { return nil }
        return words[0]
    }

    private static func unquotedRange(
        of marker: String,
        in value: String
    ) -> Range<String.Index>? {
        var index = value.startIndex
        var quote: Character?
        var isEscaped = false
        while index < value.endIndex {
            let character = value[index]
            if isEscaped {
                isEscaped = false
                index = value.index(after: index)
                continue
            }
            if character == "\\", quote != "'" {
                isEscaped = true
                index = value.index(after: index)
                continue
            }
            if character == "'", quote != "\"" {
                quote = quote == "'" ? nil : "'"
                index = value.index(after: index)
                continue
            }
            if character == "\"", quote != "'" {
                quote = quote == "\"" ? nil : "\""
                index = value.index(after: index)
                continue
            }
            if quote == nil, value[index...].hasPrefix(marker) {
                return index..<value.index(index, offsetBy: marker.count)
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func consumeEnvOptions(from words: inout [String]) -> Bool {
        let optionsWithSeparateOperands: Set<String> = [
            "-u", "--unset", "-C", "--chdir", "-S", "--split-string",
            "--block-signal", "--default-signal", "--ignore-signal"
        ]
        while let option = words.first, option.hasPrefix("-") {
            words.removeFirst()
            if option == "--" {
                return true
            }
            if optionsWithSeparateOperands.contains(option) {
                guard !words.isEmpty else { return false }
                words.removeFirst()
            }
        }
        return true
    }

    private static func shellWords(in value: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\", quote != "'" {
                isEscaped = true
                continue
            }
            if character == "'", quote != "\"" {
                quote = quote == "'" ? nil : "'"
                continue
            }
            if character == "\"", quote != "'" {
                quote = quote == "\"" ? nil : "\""
                continue
            }
            if character.isWhitespace, quote == nil {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        guard quote == nil, !isEscaped else { return nil }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let separator = word.firstIndex(of: "=") else { return false }
        let name = word[..<separator]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
