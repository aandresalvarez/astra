import Foundation

enum GitHubHostControlPolicy {
    private static let optionsWithValues: Set<String> = [
        "-H", "--header", "--hostname", "-R", "--repo", "--jq", "-q", "--json", "--template", "-t",
        "-X", "--method", "--cache", "-p", "--preview", "-f", "--raw-field", "-F", "--field", "--input"
    ]
    private static let shortOptionsWithValues: Set<Character> = ["H", "R", "q", "t", "X", "p", "f", "F"]

    private static let tokenDisplayFlags: Set<String> = ["--show-token"]
    private static let browserLaunchFlags: Set<String> = ["--web", "-w"]
    private static let jqFlags: Set<String> = ["--jq", "-q"]
    private static let authStatusDeniedFlags: Set<String> = ["--show-token", "-t"]

    static func denialReason(for arguments: [String]) -> String? {
        let operation = normalizedOperation(arguments)
        if containsDeniedFlag(arguments, deniedFlags: tokenDisplayFlags) {
            return denial(operation, reason: "credential and token display flags are not exposed")
        }
        if containsDeniedFlag(arguments, deniedFlags: browserLaunchFlags) {
            return denial(operation, reason: "opening a browser is not exposed")
        }
        if containsJQFilter(arguments) {
            // `gh auth status --json` describes the stored credentials; keep
            // its output fixed rather than filterable.
            if operation.command == "auth" {
                return denial(operation, reason: "credential and token display flags are not exposed")
            }
            // gh evaluates `--jq` with gojq, whose `env` and `$ENV` read the
            // broker's process environment.
            if jqFilters(in: arguments).contains(where: readsEnvironment) {
                return denial(operation, reason: "a jq filter cannot read the environment (env, $ENV)")
            }
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
            var apiArguments = arguments
            if let index = commandIndex(in: arguments) {
                apiArguments.remove(at: index)
            }
            if let reason = apiReadDenialReason(apiArguments) {
                return denial(operation, reason: reason + ". "
                    + "For inline PR comments use pr review-threads NUMBER --repo OWNER/REPO")
            }
            return nil
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

    // MARK: jq filters

    private static func containsJQFilter(_ arguments: [String]) -> Bool {
        containsDeniedFlag(arguments, deniedFlags: jqFlags)
    }

    /// Every `--jq`/`-q` value, including `--jq=F`, `-qF` and bundles such as `-cq F`.
    private static func jqFilters(in arguments: [String]) -> [String] {
        var filters: [String] = []
        for (index, token) in arguments.enumerated() {
            let next = index + 1 < arguments.count ? arguments[index + 1] : ""
            if token == "--jq" || token == "-q" {
                filters.append(next)
            } else if token.hasPrefix("--jq=") {
                filters.append(String(token.dropFirst("--jq=".count)))
            } else if token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 2 {
                let characters = Array(token.dropFirst())
                for (offset, character) in characters.enumerated() {
                    if character == "q" {
                        let rest = String(characters[(offset + 1)...])
                        filters.append(rest.isEmpty ? next : rest)
                        break
                    }
                    if shortOptionsWithValues.contains(character) {
                        break
                    }
                }
            }
        }
        return filters
    }

    /// `env` and `$ENV` as jq identifiers; a `.env` field access reads JSON, not the environment.
    private static func readsEnvironment(_ filter: String) -> Bool {
        filter.range(of: #"(?<![A-Za-z0-9_.$])\$?(env|ENV)(?![A-Za-z0-9_])"#, options: .regularExpression) != nil
    }

    // MARK: api reads

    private static let apiFlags: Set<String> = ["--paginate", "--slurp", "--include", "-i", "--silent"]
    private static let apiValuedOptions: Set<String> = [
        "--jq", "-q", "--template", "-t", "--cache", "--hostname", "--preview", "-p", "--header", "-H", "--method", "-X"
    ]
    private static let apiBodyOptions: Set<String> = ["-f", "--raw-field", "-F", "--field", "--input"]

    /// `gh api` is exposed for a single GET (or HEAD) of one REST path on
    /// github.com: no fields or body, no GraphQL, no other host, no
    /// method-override header, and no `--verbose` (it prints the request headers).
    private static func apiReadDenialReason(_ arguments: [String]) -> String? {
        var options: [(name: String, value: String?)] = []
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            if token == "--" {
                positionals.append(contentsOf: arguments[(index + 1)...])
                break
            }
            if token.hasPrefix("--") {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                if apiFlags.contains(name), parts.count == 1 {
                    options.append((name, nil))
                    index += 1
                } else if apiValuedOptions.contains(name) || apiBodyOptions.contains(name) {
                    options.append((name, parts.count == 2 ? parts[1] : next))
                    index += parts.count == 2 ? 1 : 2
                } else {
                    return "the option \(name) is not exposed for read-only API requests"
                }
                continue
            }
            if token.hasPrefix("-"), token.count > 1 {
                let characters = Array(token.dropFirst())
                var consumedNext = false
                for (offset, character) in characters.enumerated() {
                    let name = "-\(character)"
                    if apiFlags.contains(name) {
                        options.append((name, nil))
                        continue
                    }
                    guard apiValuedOptions.contains(name) || apiBodyOptions.contains(name) else {
                        return "the option \(name) is not exposed for read-only API requests"
                    }
                    let rest = String(characters[(offset + 1)...])
                    options.append((name, rest.isEmpty ? next : rest))
                    consumedNext = rest.isEmpty
                    break
                }
                index += consumedNext ? 2 : 1
                continue
            }
            positionals.append(token)
            index += 1
        }

        for option in options {
            if apiBodyOptions.contains(option.name) {
                return "fields and request bodies are not exposed; put query parameters in the endpoint path"
            }
            if option.name == "--method" || option.name == "-X" {
                let method = (option.value ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                guard method == "GET" || method == "HEAD" else {
                    return "only GET and HEAD requests are exposed"
                }
            }
            // `--hostname` picks the request host and the credential gh sends
            // with it (an enterprise token, for one), so keep it on github.com.
            if option.name == "--hostname",
               (option.value ?? "").trimmingCharacters(in: .whitespaces).lowercased() != "github.com" {
                return "only github.com is exposed as the API host"
            }
            if option.name == "--header" || option.name == "-H",
               let header = option.value,
               let colon = header.firstIndex(of: ":"),
               header[..<colon].lowercased().contains("method") {
                return "method-override headers are not exposed"
            }
        }

        guard positionals.count == 1, let endpoint = positionals.first else {
            return "exactly one REST endpoint path is required"
        }
        let path = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
        if path == "graphql" || path.hasPrefix("graphql?") {
            return "GraphQL requests are not exposed"
        }
        if endpoint.contains("://") {
            return "only endpoint paths on the configured GitHub host are exposed"
        }
        return nil
    }

    /// Index of the first positional argument (the gh command), skipping option values.
    private static func commandIndex(in arguments: [String]) -> Int? {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                return index + 1 < arguments.count ? index + 1 : nil
            }
            if token.hasPrefix("-") {
                index += 1
                let optionName = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                if optionsWithValues.contains(optionName), !token.contains("="), index < arguments.count {
                    index += 1
                }
                continue
            }
            return index
        }
        return nil
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
            if deniedFlags.contains(optionName) {
                return true
            }
            return containsDeniedShortOption(in: optionName, deniedFlags: deniedFlags)
        }
    }

    private static func containsDeniedShortOption(in optionName: String, deniedFlags: Set<String>) -> Bool {
        guard optionName.hasPrefix("-"),
              !optionName.hasPrefix("--"),
              optionName.count > 2 else {
            return false
        }

        for character in optionName.dropFirst() {
            let shortFlag = "-\(character)"
            if deniedFlags.contains(shortFlag) {
                return true
            }
            if shortOptionsWithValues.contains(character) {
                return false
            }
        }
        return false
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
