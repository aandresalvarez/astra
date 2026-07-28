import Foundation

struct RuntimeSandboxFileDenial: Equatable, Sendable {
    enum Operation: String, Sendable {
        case read
        case write
        case access
    }

    let operation: Operation
    let path: String
    let detail: String

    var stopReason: String {
        switch operation {
        case .read: "os_sandbox_file_read_denied"
        case .write: "os_sandbox_file_write_denied"
        case .access: "os_sandbox_file_access_denied"
        }
    }

    var deniedActionValue: String {
        switch operation {
        case .read: "os_sandbox_blocked_read path=\(path)"
        case .write: "os_sandbox_blocked_write path=\(path)"
        case .access: "os_sandbox_blocked_access path=\(path)"
        }
    }
}

struct RuntimeSandboxDiagnosticContext: Equatable, Sendable {
    let boundaryApplied: Bool
    let workingDirectory: String?
    let boundaryReceipt: ExecutionSandboxBoundaryReceipt?

    static let none = RuntimeSandboxDiagnosticContext(
        boundaryApplied: false,
        workingDirectory: nil,
        boundaryReceipt: nil
    )

    func appliedBoundaryExplains(_ denial: RuntimeSandboxFileDenial) -> Bool {
        boundaryApplied && boundaryReceipt?.explains(denial) == true
    }
}

enum RuntimeSandboxDenialDiagnostics {
    private struct PathCandidate {
        let raw: String
        let resolved: String
    }

    static func fileDenial(
        in text: String,
        currentDirectory: String? = nil,
        operationContext: String? = nil
    ) -> RuntimeSandboxFileDenial? {
        for line in denialCandidateLines(in: text) {
            let lower = line.lowercased()
            let failureMarker = lower.contains("read-only file system")
                ? "read-only file system"
                : "operation not permitted"
            guard lower.contains(failureMarker) else { continue }
            guard isFatalDenialLine(lower) else { continue }
            // Shell-prefixed errors can contain both the shell and the actual
            // denied executable, e.g. `/bin/sh: /path/to/gcloud: Operation not
            // permitted`. The path nearest the failure text is the actionable
            // path ASTRA should project.
            let failurePrefix = line.range(
                of: failureMarker,
                options: [.caseInsensitive]
            ).map { String(line[..<$0.lowerBound]) } ?? line
            guard let candidate = filesystemPaths(
                in: failurePrefix,
                currentDirectory: currentDirectory
            ).last else {
                continue
            }
            let diagnosticText = lower.replacingOccurrences(
                of: candidate.raw.lowercased(),
                with: " "
            )

            let operation: RuntimeSandboxFileDenial.Operation = lower.contains("read-only file system")
                ? .write
                : operationKind(
                    diagnosticText: diagnosticText,
                    operationContext: operationContext
                )
            return RuntimeSandboxFileDenial(
                operation: operation,
                path: candidate.resolved,
                detail: LogSanitizer.sanitize(line, maxLength: 360)
            )
        }

        return nil
    }

    private static func denialCandidateLines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isFatalDenialLine(_ lower: String) -> Bool {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("warning:")
            && trimmed.contains("unable to access")
            && trimmed.contains("operation not permitted") {
            return false
        }
        return true
    }

    private static func operationKind(
        diagnosticText: String,
        operationContext: String?
    ) -> RuntimeSandboxFileDenial.Operation {
        let commandName = shellCommandName(in: operationContext ?? "")
        let diagnosticCommand = diagnosticText
            .split(separator: ":", maxSplits: 1)
            .first
            .map { URL(fileURLWithPath: String($0)).lastPathComponent.lowercased() }
        let writeCommands: Set<String> = [
            "chmod", "chown", "mkdir", "rm", "tee",
            "touch", "truncate", "unlink", "write"
        ]
        if commandName.map(writeCommands.contains) == true
            || diagnosticCommand.map(writeCommands.contains) == true
            || diagnosticText.contains("unable to create")
            || diagnosticText.contains("cannot create")
            || diagnosticText.contains("failed to create")
        {
            return .write
        }

        let readCommands: Set<String> = ["cat", "head", "less", "more", "read", "tail"]
        if commandName.map(readCommands.contains) == true
            || diagnosticCommand.map(readCommands.contains) == true
            || diagnosticText.contains("unable to read")
            || diagnosticText.contains("cannot read")
            || diagnosticText.contains("failed to read")
            || diagnosticText.contains("hostkeys_foreach")
        {
            return .read
        }

        return .access
    }

    private static func shellCommandName(in context: String) -> String? {
        let segments = shellSegments(in: context)
        guard segments.count == 1 else { return nil }
        var words = shellWords(in: segments[0])
        while let first = words.first, isEnvironmentAssignment(first) {
            words.removeFirst()
        }
        while let first = words.first {
            let name = URL(fileURLWithPath: first).lastPathComponent.lowercased()
            guard ["builtin", "command", "env", "nohup", "sudo"].contains(name) else {
                return name.isEmpty ? nil : name
            }
            words.removeFirst()
            guard words.first?.hasPrefix("-") != true else { return nil }
            while let assignment = words.first, isEnvironmentAssignment(assignment) {
                words.removeFirst()
            }
        }
        return nil
    }

    private static func shellSegments(in command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                current.append(character)
            } else if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character == ";" || character == "|" || character == "&" || character.isNewline {
                if !current.isEmpty { segments.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func shellWords(in segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in segment {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            return false
        }
        return value[..<separator].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func filesystemPaths(
        in text: String,
        currentDirectory: String?
    ) -> [PathCandidate] {
        let pattern = #"(?<![A-Za-z0-9._~+-])((?:~|/|\.\.?/)[^\s`"'<>:]+|[A-Za-z0-9._+@%=-]+(?:/[A-Za-z0-9._+@%=-]+)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [PathCandidate] = regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            let raw = String(text[valueRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,);]:'\""))
            return resolvedCandidate(raw, currentDirectory: currentDirectory)
        }
        if let bare = barePathCandidate(in: text, currentDirectory: currentDirectory) {
            candidates.append(bare)
        }
        return candidates
    }

    private static func barePathCandidate(
        in text: String,
        currentDirectory: String?
    ) -> PathCandidate? {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":"))
        )
        guard let separator = trimmed.lastIndex(of: ":") else { return nil }
        let field = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if let quote = field.last, quote == "'" || quote == "\"",
           let openingQuote = field.dropLast().lastIndex(of: quote) {
            raw = String(field[field.index(after: openingQuote)..<field.index(before: field.endIndex)])
        } else {
            raw = String(field.split(whereSeparator: \.isWhitespace).last ?? "")
        }
        let candidate = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,);]:'\""))
        let nonPaths: Set<String> = [
            "access", "create", "denied", "error", "failed", "fatal", "open",
            "read", "touch", "write"
        ]
        guard !candidate.isEmpty,
              !nonPaths.contains(candidate.lowercased()) else {
            return nil
        }
        return resolvedCandidate(candidate, currentDirectory: currentDirectory)
    }

    private static func resolvedCandidate(
        _ raw: String,
        currentDirectory: String?
    ) -> PathCandidate? {
        guard !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return PathCandidate(
                raw: raw,
                resolved: URL(fileURLWithPath: expanded).standardizedFileURL.path
            )
        }
        guard let currentDirectory,
              !currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        return PathCandidate(
            raw: raw,
            resolved: URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
        )
    }
}
