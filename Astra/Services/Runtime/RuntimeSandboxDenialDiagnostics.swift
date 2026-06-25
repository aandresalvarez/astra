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

enum RuntimeSandboxDenialDiagnostics {
    static func fileDenial(in text: String) -> RuntimeSandboxFileDenial? {
        for line in denialCandidateLines(in: text) {
            let lower = line.lowercased()
            guard lower.contains("operation not permitted") else { continue }
            guard isFatalDenialLine(lower) else { continue }
            guard let path = filesystemPaths(in: line).first else { continue }

            let operation = operationKind(text: lower, path: path)
            return RuntimeSandboxFileDenial(
                operation: operation,
                path: path,
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

    private static func operationKind(text: String, path: String) -> RuntimeSandboxFileDenial.Operation {
        if text.contains("write")
            || text.contains("create")
            || text.contains("mkdir")
            || text.contains("unlink")
            || text.contains("chmod")
            || text.contains("chown") {
            return .write
        }

        let lowerPath = path.lowercased()
        if text.contains("read")
            || text.contains("unable to access")
            || text.contains("hostkeys_foreach")
            || lowerPath.contains(".gitconfig")
            || lowerPath.contains("known_hosts") {
            return .read
        }

        return .access
    }

    private static func filesystemPaths(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:~|/)[^\s`"'<>]+"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range, in: text) else { return nil }
            let value = String(text[valueRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,);:'\""))
            return value.isEmpty ? nil : value
        }
    }
}
