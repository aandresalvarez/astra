import Foundation
import ASTRACore

enum LocalToolSecurityPolicy {
    static func isSafe(command: String, arguments: String = "") -> Bool {
        unsafeInvocationReason(command: command, arguments: arguments) == nil
    }

    static func unsafeInvocationReason(command: String, arguments: String = "") -> String? {
        if let reason = unsafeCommandReason(command) {
            return reason
        }
        if let reason = unsafeArgumentsReason(arguments) {
            return reason
        }
        if let reason = unsafeInterpreterExecutionReason(command: command, arguments: arguments) {
            return reason
        }
        return nil
    }

    static func unsafeCommandReason(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "missing command"
        }
        if trimmed.hasPrefix("-") {
            return "command starts with a flag"
        }
        if trimmed.contains(where: { $0.isWhitespace }) {
            return "command contains whitespace"
        }
        let shellMetacharacters = CharacterSet(charactersIn: ";|&`$<>(){}[]\n\r")
        if trimmed.rangeOfCharacter(from: shellMetacharacters) != nil {
            return "command contains shell metacharacters"
        }
        return nil
    }

    static func unsafeArgumentsReason(_ arguments: String) -> String? {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let shellMetacharacters = CharacterSet(charactersIn: ";|&`$<>()\n\r")
        if trimmed.rangeOfCharacter(from: shellMetacharacters) != nil {
            return "arguments contain shell metacharacters"
        }
        return nil
    }

    private static func unsafeInterpreterExecutionReason(command: String, arguments: String) -> String? {
        let executable = (command.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
            .lowercased()
        let flags: Set<String>
        if let configuredFlags = interpreterExecutionFlags[executable] {
            flags = configuredFlags
        } else if executable.hasPrefix("python") {
            flags = ["-c"]
        } else {
            flags = []
        }
        guard !flags.isEmpty else { return nil }
        let tokens = arguments
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard tokens.contains(where: { flags.contains($0) }) else { return nil }
        return "interpreter execution flag \(tokens.first(where: { flags.contains($0) }) ?? "") is not allowed in package defaults"
    }

    private static let interpreterExecutionFlags: [String: Set<String>] = [
        "sh": ["-c"],
        "bash": ["-c"],
        "zsh": ["-c"],
        "fish": ["-c"],
        "python": ["-c"],
        "python3": ["-c"],
        "python2": ["-c"],
        "node": ["-e", "--eval"],
        "ruby": ["-e"],
        "perl": ["-e"],
        "php": ["-r"],
        "osascript": ["-e"]
    ]
}

// `credentialTransportViolation` moved to ASTRACore/ConnectorSecurityPolicy.swift
// (pure, string-only — part of Track A2's Models<->Runtime cycle break, since
// Astra/Models/Connector.swift calls it directly). `isRuntimeSafe(_:)` stays
// here as an extension: it takes the `Connector` `@Model` type, which cannot
// appear in ASTRACore.
extension ConnectorSecurityPolicy {
    static func isRuntimeSafe(_ connector: Connector) -> Bool {
        credentialTransportViolation(
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            credentialKeys: connector.credentialKeys
        ) == nil
    }
}
