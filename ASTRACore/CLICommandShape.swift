import Foundation

/// One accepted call to a CLI: the positional words it must spell and the
/// only flags it may carry, with the values each flag accepts. Shared by
/// `HealthCheckPolicy` (what a check may run) and `TerminalRepairPolicy`
/// (what a repair may run), which differ only in the commands they list.
///
/// Fails closed: a flag not listed refuses the call, and so does a value a
/// listed flag does not accept. A flag's separate value counts as a
/// positional unless the flag is listed as taking one, so `--web delete`
/// never hides `delete`. `-` and `--` are positionals, never a match.
struct CLICommandShape: Sendable {
    /// What a value flag accepts, separate (`--project p`) or after `=`.
    enum Value: Sendable {
        /// Any word (an output format or a filter: a check prints it, nothing more).
        case any
        /// One plain word: letters, digits and `._@:+-`, not starting with `-`.
        case plain
        /// A host name with an optional port.
        case host
        /// Exactly one of these.
        case oneOf(Set<String>)

        func accepts(_ value: String) -> Bool {
            switch self {
            case .any: return true
            case .plain: return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._@:+-]*$"#, options: .regularExpression) != nil
            case .host: return value.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$"#, options: .regularExpression) != nil
            case .oneOf(let values): return values.contains(value)
            }
        }
    }

    /// The positional words, exactly; `*` is one plain operand, such as a
    /// property name (`core/project`).
    let positionals: [String]
    var booleanFlags: Set<String> = []
    var valueFlags: [String: Value] = [:]

    func matches(_ arguments: [String]) -> Bool {
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            guard word.hasPrefix("-"), word != "-", word != "--" else {
                words.append(word)
                continue
            }
            if let equals = word.firstIndex(of: "=") {
                guard let value = valueFlags[String(word[..<equals])],
                      value.accepts(String(word[word.index(after: equals)...])) else { return false }
            } else if let value = valueFlags[word] {
                guard index < arguments.count, value.accepts(arguments[index]) else { return false }
                index += 1
            } else if !booleanFlags.contains(word) {
                return false
            }
        }
        guard words.count == positionals.count else { return false }
        return zip(words, positionals).allSatisfy { word, expected in
            expected == "*"
                ? word.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil
                : word == expected
        }
    }
}
