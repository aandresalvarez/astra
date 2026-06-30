import Foundation

enum GitHubHostControlPolicy {
    private static let optionsWithValues: Set<String> = [
        "-H", "--hostname", "-R", "--repo", "--jq", "-q", "--json", "--template", "-t"
    ]

    private static let globallyDeniedFlags: Set<String> = ["--show-token", "--web", "-w", "--jq", "-q"]
    private static let authStatusDeniedFlags: Set<String> = ["--show-token", "-t"]

    static func denialReason(for arguments: [String]) -> String? {
        let operation = normalizedOperation(arguments)
        if containsDeniedFlag(arguments, deniedFlags: globallyDeniedFlags) {
            return denial(operation, reason: "credential and token display flags are not exposed")
        }

        switch operation.command {
        case "pr":
            return allow(operation, subcommands: ["checks", "diff", "list", "status", "view"])
        case "issue":
            return allow(operation, subcommands: ["list", "status", "view"])
        case "search":
            return allow(operation, subcommands: ["code", "commits", "issues", "prs", "repos"])
        case "repo":
            return allow(operation, subcommands: ["list", "view"])
        case "run":
            return allow(operation, subcommands: ["list", "view"])
        case "workflow":
            return allow(operation, subcommands: ["list", "view"])
        case "auth":
            if operation.subcommand == "status",
               containsDeniedFlag(arguments, deniedFlags: authStatusDeniedFlags)
                || containsAuthStatusTokenDisplayShorthand(arguments) {
                return denial(operation, reason: "credential and token display flags are not exposed")
            }
            return allow(operation, subcommands: ["status"])
        case "api":
            return denial(operation, reason: "raw GitHub API access is not an explicit read-only operation")
        default:
            return denial(operation, reason: "only explicit read-only GitHub operations are exposed")
        }
    }

    private static func allow(_ operation: Operation, subcommands: Set<String>) -> String? {
        guard let subcommand = operation.subcommand else {
            return denial(operation, reason: "a read-only subcommand is required")
        }
        guard subcommands.contains(subcommand) else {
            return denial(operation, reason: "the subcommand is not read-only")
        }
        return nil
    }

    private static func denial(_ operation: Operation, reason: String) -> String {
        "github does not allow GitHub operation '\(operation.displayName)': \(reason)"
    }

    private static func normalizedOperation(_ arguments: [String]) -> Operation {
        let tokens = commandTokens(from: arguments)
        let command = tokens.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let subcommand = tokens.dropFirst().first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return Operation(command: command, subcommand: subcommand)
    }

    private static func commandTokens(from arguments: [String]) -> [String] {
        var tokens: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                index += 1
                tokens.append(contentsOf: arguments.dropFirst(index))
                break
            }
            if token.hasPrefix("-") {
                index += 1
                let optionName = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                if optionsWithValues.contains(optionName), !token.contains("="), index < arguments.count {
                    index += 1
                }
                continue
            }
            tokens.append(token)
            index += 1
        }
        return tokens
    }

    private static func containsDeniedFlag(_ arguments: [String], deniedFlags: Set<String>) -> Bool {
        arguments.contains { token in
            let optionName = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            return deniedFlags.contains(optionName)
        }
    }

    private static func containsAuthStatusTokenDisplayShorthand(_ arguments: [String]) -> Bool {
        arguments.contains { token in
            let optionName = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            guard optionName.hasPrefix("-"),
                  !optionName.hasPrefix("--"),
                  optionName.count > 2 else {
                return false
            }
            return optionName.dropFirst().contains("t")
        }
    }

    private struct Operation {
        var command: String
        var subcommand: String?

        var displayName: String {
            ([command] + [subcommand].compactMap { $0 }).compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }.joined(separator: " ")
        }
    }
}
