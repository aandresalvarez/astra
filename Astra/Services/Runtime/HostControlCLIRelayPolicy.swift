import Foundation
import ASTRACore

enum HostControlCLIRelayPolicy {
    static let manifestMarker = "__astra_typed_host_control_relay__"

    static func isEnabled(in render: ProviderPolicyRender) -> Bool {
        render.allowedShellPatterns.contains(manifestMarker)
    }

    static func mentionsRelay(_ command: String) -> Bool {
        command.range(
            of: #"(^|[^A-Za-z0-9_-])astra-host-control([^A-Za-z0-9_-]|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func allows(_ command: String) -> Bool {
        guard let tokens = shellTokens(command),
              tokens.first == "astra-host-control",
              tokens.count >= 2 else {
            return false
        }

        switch tokens[1].lowercased() {
        case "jira":
            return allowsJira(Array(tokens.dropFirst(2)))
        case "ssh":
            return allowsSSH(Array(tokens.dropFirst(2)))
        case "github", "gcloud", "bq":
            let arguments = tokens.dropFirst(2).drop(while: { $0 == "--" })
            return !arguments.isEmpty
        default:
            return false
        }
    }

    private static func allowsJira(_ arguments: [String]) -> Bool {
        guard let options = pairedOptions(
            arguments,
            allowed: [
                "--operation", "--alias", "--issue-key", "--jql",
                "--max-results", "--next-page-token", "--timeout-seconds"
            ]
        ) else {
            return false
        }

        let operation = (options["--operation"] ?? "status")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        guard ["status", "search_jql", "get_issue", "get_comments"].contains(operation) else {
            return false
        }
        if let value = options["--max-results"],
           Int(value).map({ $0 > 0 }) != true {
            return false
        }
        return validPositiveDouble(options["--timeout-seconds"])
    }

    private static func allowsSSH(_ arguments: [String]) -> Bool {
        guard let options = pairedOptions(
            arguments,
            allowed: ["--alias", "--timeout-seconds"]
        ),
        options["--alias"] != nil else {
            return false
        }
        return validPositiveDouble(options["--timeout-seconds"])
    }

    private static func pairedOptions(
        _ arguments: [String],
        allowed: Set<String>
    ) -> [String: String]? {
        guard arguments.count.isMultiple(of: 2) else { return nil }
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            guard allowed.contains(key),
                  options[key] == nil,
                  !value.isEmpty else {
                return nil
            }
            options[key] = value
            index += 2
        }
        return options
    }

    private static func validPositiveDouble(_ value: String?) -> Bool {
        guard let value else { return true }
        guard let number = Double(value) else { return false }
        return number.isFinite && number > 0
    }

    private enum Quote {
        case single
        case double
    }

    private static func shellTokens(_ command: String) -> [String]? {
        var tokens: [String] = []
        var token = ""
        var quote: Quote?
        var escaping = false

        func finishToken() {
            guard !token.isEmpty else { return }
            tokens.append(token)
            token = ""
        }

        for character in command {
            if escaping {
                guard character != "\n", character != "\r" else { return nil }
                token.append(character)
                escaping = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    token.append(character)
                }
            case .double:
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    escaping = true
                } else {
                    guard character != "$", character != "`",
                          character != "\n", character != "\r" else {
                        return nil
                    }
                    token.append(character)
                }
            case nil:
                if character.isWhitespace {
                    finishToken()
                } else if character == "'" {
                    quote = .single
                } else if character == "\"" {
                    quote = .double
                } else if character == "\\" {
                    escaping = true
                } else {
                    guard !";&|<>\n\r`$(){}~*?[]#!".contains(character) else {
                        return nil
                    }
                    token.append(character)
                }
            }
        }

        guard quote == nil, !escaping else { return nil }
        finishToken()
        return tokens
    }
}
