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
        // gh runs `--jq` filters with gojq, whose `env` and `$ENV` read the
        // broker's whole process environment, credentials included. No scan of
        // the filter text can keep that out (strings, Unicode, slice bounds,
        // comments), so filters are refused and the agent reads the JSON.
        if containsDeniedFlag(arguments, deniedFlags: jqFlags) {
            // `gh api` already answers in JSON and has no `--json` flag.
            let instead = operation.command == "api"
                ? "drop --jq and read the JSON response"
                : "use --json and read the JSON output"
            return denial(operation, reason: "jq filters are not exposed because they can read the broker's "
                + "environment; \(instead)")
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
                // The host pin goes right after `api`; behind a `--` it would be an operand.
                if arguments[..<index].contains("--") {
                    return denial(operation, reason: "a -- before the api command is not exposed")
                }
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

    // MARK: api reads

    private static let apiFlags: Set<String> = ["--paginate", "--slurp", "--include", "-i", "--silent"]
    /// No `--cache`: gh writes the response to a cache file, which a planted
    /// symlink (or an `X-GH-CACHE-DIR` header) could point anywhere.
    private static let apiValuedOptions: Set<String> = [
        "--jq", "-q", "--template", "-t", "--hostname", "--preview", "-p", "--header", "-H", "--method", "-X"
    ]
    /// The only request headers a read needs. Anything else can change who
    /// the request authenticates as (`Authorization`), what it does (a method
    /// override) or where gh writes (`X-GH-CACHE-DIR`).
    private static let apiAllowedHeaders: Set<String> = ["accept", "x-github-api-version"]
    private static let apiBodyOptions: Set<String> = ["-f", "--raw-field", "-F", "--field", "--input"]

    /// `gh api` is exposed for a single GET (or HEAD) of one REST path on
    /// github.com: no fields or body, no GraphQL, no other host, no
    /// method-override header, and no `--verbose` (it prints the request headers).
    private static func apiReadDenialReason(_ arguments: [String]) -> String? {
        let parsed = parseAPI(arguments)
        if let unexposed = parsed.unexposed {
            return "the option \(unexposed) is not exposed for read-only API requests"
        }
        let options = parsed.options
        let positionals = parsed.positionals

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
            if option.name == "--header" || option.name == "-H" {
                let header = option.value ?? ""
                let name = header.firstIndex(of: ":").map { header[..<$0] } ?? Substring(header)
                guard apiAllowedHeaders.contains(name.trimmingCharacters(in: .whitespaces).lowercased()) else {
                    return "only Accept and X-GitHub-Api-Version headers are exposed"
                }
            }
        }
        guard positionals.count == 1, let endpoint = positionals.first else {
            return "exactly one REST endpoint path is required"
        }
        if endpoint.contains("://") {
            return "only endpoint paths on the configured GitHub host are exposed"
        }
        // The path gh requests: before any query or fragment, percent-decoded,
        // without empty or `.` segments. `..` could step out of a REST path.
        let rawPath = String(endpoint.prefix { $0 != "?" && $0 != "#" })
        let segments = (rawPath.removingPercentEncoding ?? rawPath)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "." }
        if segments.contains("..") {
            return "endpoint paths with .. segments are not exposed"
        }
        if segments == ["graphql"] {
            return "GraphQL requests are not exposed"
        }
        return nil
    }

    /// `gh api`'s options and operands, each option with the value it consumes,
    /// as gh's flag parser reads them. `unexposed` names the first option that
    /// is not on the read-only list.
    private static func parseAPI(_ arguments: [String])
        -> (options: [(name: String, value: String?)], positionals: [String], unexposed: String?) {
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
                // Keep an explicit empty value (`--jq=`) so it cannot swallow the next option.
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let name = parts[0]
                if apiFlags.contains(name), parts.count == 1 {
                    options.append((name, nil))
                    index += 1
                } else if apiValuedOptions.contains(name) || apiBodyOptions.contains(name) {
                    options.append((name, parts.count == 2 ? parts[1] : next))
                    index += parts.count == 2 ? 1 : 2
                } else {
                    return (options, positionals, name)
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
                        return (options, positionals, name)
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
        return (options, positionals, nil)
    }

    /// What the broker runs for an allowed call. Without `--hostname`, `gh api`
    /// picks its default host: `GH_HOST`, or the only host gh is signed in to,
    /// with that host's credentials. An API read is pinned to github.com so the
    /// default can't move it; every other command runs as given.
    static func executionArguments(for arguments: [String]) -> [String] {
        guard normalizedOperation(arguments).command == "api", let index = commandIndex(in: arguments) else {
            return arguments
        }
        var apiArguments = arguments
        apiArguments.remove(at: index)
        // A real `--hostname` option, not a word another option consumed.
        guard !parseAPI(apiArguments).options.contains(where: { $0.name == "--hostname" }) else { return arguments }
        // Right after `api`: never inside another option's value, never after a `--`.
        var pinned = arguments
        pinned.insert(contentsOf: ["--hostname", "github.com"], at: index + 1)
        return pinned
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
