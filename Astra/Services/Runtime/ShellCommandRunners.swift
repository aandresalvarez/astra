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
        "eval": []
    ]
}
