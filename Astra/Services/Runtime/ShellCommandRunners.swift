import Foundation

/// Commands that run another command: the external-command check in
/// `AgentRuntimePolicyGuard` and the record in `AgentExternalActionObserver`
/// both judge what the runner runs, not the runner.
enum ShellCommandRunners {
    /// The command a runner such as `env -u NAME`, `nice -n 5`, `timeout 30`,
    /// `time -p`, `xargs -n 1` or `eval '…'` runs, or nil when the segment does not start
    /// with one. A segment that starts with an option is read as `env`'s
    /// leftovers, because callers drop the `env` word and bare assignments
    /// first — which is how `env -u CI git push` read as a command named `-u`.
    static func wrappedCommand(_ segment: String) -> String? {
        if let expanded = gitInlineAliasExpansion(segment) { return expanded }
        if let actions = findExecPayloads(segment) { return actions }
        var tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return nil }
        let runner: String
        if first.hasPrefix("-") {
            runner = "env"
        } else {
            runner = URL(fileURLWithPath: first).lastPathComponent.lowercased()
            guard runnerOptionsWithValues[runner] != nil else { return nil }
            tokens.removeFirst()
        }
        let optionsWithValues = runnerOptionsWithValues[runner] ?? []
        var positionalsToSkip = ["timeout", "gtimeout"].contains(runner) ? 1 : 0
        // `eval` joins its arguments and runs them: a quoted payload is the command.
        var splitsString = runner == "eval"
        while let token = tokens.first {
            if token == "--" {
                tokens.removeFirst()
                break
            }
            if runner == "env", token == "-S" || token == "--split-string" {
                tokens.removeFirst()
                splitsString = true
                break
            }
            if token.hasPrefix("-") {
                tokens.removeFirst()
                if optionsWithValues.contains(token), !tokens.isEmpty { tokens.removeFirst() }
            } else if runner == "env", token.contains("=") {
                tokens.removeFirst()
            } else if positionalsToSkip > 0 {
                positionalsToSkip -= 1
                tokens.removeFirst()
            } else {
                break
            }
        }
        var command = tokens.joined(separator: " ")
        if splitsString, let quote = command.first, quote == "'" || quote == "\"",
           let close = command.dropFirst().firstIndex(of: quote) {
            command = String(command[command.index(after: command.startIndex)..<close])
                + command[command.index(after: close)...]
        }
        return command.isEmpty ? nil : command
    }

    /// `git -c alias.ship=push ship origin main` runs `git push origin main`,
    /// and `-c 'alias.x=!curl …'` runs that shell command: an alias defined on
    /// the command line is read, not guessed. One from the user's config cannot
    /// be read here, so the classifier does not call it local.
    static func gitInlineAliasExpansion(_ segment: String) -> String? {
        guard let tokens = AgentExternalActionObserver.shellSegments(segment).first,
              let first = tokens.first,
              URL(fileURLWithPath: first).lastPathComponent.lowercased() == "git" else {
            return nil
        }
        var aliases: [String: String] = [:]
        var leading: [String] = []
        var index = 1
        while index < tokens.count, tokens[index].hasPrefix("-") {
            let option = tokens[index]
            if ["-c", "-C", "--git-dir", "--work-tree"].contains(option), index + 1 < tokens.count {
                let value = tokens[index + 1]
                if option == "-c", value.lowercased().hasPrefix("alias."), let equals = value.firstIndex(of: "=") {
                    let name = value[value.index(value.startIndex, offsetBy: 6)..<equals].lowercased()
                    aliases[name] = String(value[value.index(after: equals)...])
                } else {
                    leading += [option, value]
                }
                index += 2
            } else {
                leading.append(option)
                index += 1
            }
        }
        guard index < tokens.count, let expansion = aliases[tokens[index].lowercased()] else { return nil }
        let rest = Array(tokens[(index + 1)...])
        if expansion.hasPrefix("!") {
            return ([String(expansion.dropFirst())] + rest).joined(separator: " ")
        }
        return (["git"] + leading + [expansion] + rest).joined(separator: " ")
    }

    /// `find … -exec CMD {} ;` (and `-execdir`, `-ok`, `-okdir`) runs CMD per
    /// match; several actions are joined with `;` so each is judged.
    static func findExecPayloads(_ segment: String) -> String? {
        let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first, URL(fileURLWithPath: first).lastPathComponent.lowercased() == "find" else {
            return nil
        }
        // A segment split at an escaped `\;` ends in a lone backslash.
        let terminators: Set<String> = [";", "\\;", "\\", "';'", "\";\"", "+"]
        var payloads: [String] = []
        var index = 1
        while index < tokens.count {
            guard ["-exec", "-execdir", "-ok", "-okdir"].contains(tokens[index]) else {
                index += 1
                continue
            }
            var command: [String] = []
            index += 1
            while index < tokens.count, !terminators.contains(tokens[index]) {
                command.append(tokens[index])
                index += 1
            }
            if !command.isEmpty { payloads.append(command.joined(separator: " ")) }
            index += 1
        }
        return payloads.isEmpty ? nil : payloads.joined(separator: " ; ")
    }

    /// `trap 'CMD' EXIT` runs CMD later, when the signal or exit comes. The
    /// handler is a command of its own; whether it succeeded is not the
    /// call's status, so it is asked about but not recorded as done.
    static func trapHandler(_ segment: String) -> String? {
        AgentExternalActionObserver.shellSegments(segment).first.flatMap(trapHandler(tokens:))
    }

    /// `trapHandler`, for tokens already split with their quotes grouped.
    static func trapHandler(tokens: [String]) -> String? {
        guard tokens.first?.lowercased() == "trap" else { return nil }
        let operands = tokens.dropFirst().drop { $0.hasPrefix("-") }
        guard let handler = operands.first, !handler.isEmpty, operands.count >= 2 else { return nil }
        return handler
    }

    private static let runnerOptionsWithValues: [String: Set<String>] = [
        "env": ["-u", "--unset", "-C", "--chdir", "-P"],
        "nice": ["-n", "--adjustment"],
        "timeout": ["-s", "--signal", "-k", "--kill-after"],
        "gtimeout": ["-s", "--signal", "-k", "--kill-after"],
        "time": ["-f", "--format", "-o", "--output"],
        "caffeinate": ["-t", "-w"],
        "stdbuf": ["-i", "-o", "-e"],
        "exec": ["-a"],
        "xargs": ["-I", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "--max-args", "--max-procs", "--max-chars",
                  "--delimiter", "--arg-file"],
        "nohup": [],
        "command": [],
        "builtin": [],
        "eval": [],
        "watch": ["-n", "--interval", "-q", "--equexit"]
    ]
}
