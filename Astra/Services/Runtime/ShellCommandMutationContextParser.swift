import Foundation
import ASTRACore

struct ShellCommandMutationContext: Equatable, Sendable {
    let command: String
    let variableBindings: [String: String]
    let referencedVariables: Set<String>
}

/// Produces mutation-checking contexts without flattening shell data flow.
///
/// Top-level command separators create independent contexts, while quoted
/// separators and command/process substitutions remain attached to their
/// parent command. Simple assignment-only segments flow into later contexts,
/// including assignments that wrap an exact `sh -lc` provider launcher.
enum ShellCommandMutationContextParser {
    static func contexts(for rawCommand: String) -> [ShellCommandMutationContext] {
        let trimmedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return [] }

        let semanticCommand = ProviderToolSemantics.semanticShellCommand(trimmedCommand)
        var bindings = semanticCommand == trimmedCommand
            ? [:]
            : leadingEnvironmentAssignments(in: trimmedCommand)
        var contexts: [ShellCommandMutationContext] = []

        for segment in topLevelSegments(in: semanticCommand) {
            contexts.append(ShellCommandMutationContext(
                command: segment,
                variableBindings: bindings,
                referencedVariables: referencedVariables(in: segment)
            ))

            if let assignments = persistentAssignments(in: segment) {
                bindings.merge(assignments) { _, replacement in replacement }
            } else {
                for name in unsetVariableNames(in: segment) {
                    bindings.removeValue(forKey: name)
                }
            }
        }
        return contexts
    }

    private static func topLevelSegments(in command: String) -> [String] {
        let command = command
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\\\r", with: " ")
        var segments: [String] = []
        var current = ""
        var index = command.startIndex
        var quote: Character?
        var isEscaped = false
        var commandSubstitutionDepth = 0
        var isInBacktickSubstitution = false

        func finishSegment() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
            current = ""
        }

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil

            if isEscaped {
                current.append(character)
                isEscaped = false
                index = nextIndex
                continue
            }
            if character == "\\" {
                current.append(character)
                isEscaped = true
                index = nextIndex
                continue
            }
            if character == "'", quote != "\"", !isInBacktickSubstitution {
                quote = quote == "'" ? nil : "'"
                current.append(character)
                index = nextIndex
                continue
            }
            if character == "\"", quote != "'", !isInBacktickSubstitution {
                quote = quote == "\"" ? nil : "\""
                current.append(character)
                index = nextIndex
                continue
            }
            if character == "`", quote != "'" {
                isInBacktickSubstitution.toggle()
                current.append(character)
                index = nextIndex
                continue
            }

            if quote != "'", !isInBacktickSubstitution,
               (character == "$" || character == "<" || character == ">"), next == "(" {
                commandSubstitutionDepth += 1
                current.append(character)
                current.append("(")
                index = command.index(after: nextIndex)
                continue
            }
            if quote == nil, !isInBacktickSubstitution, commandSubstitutionDepth > 0 {
                if character == "(" {
                    commandSubstitutionDepth += 1
                } else if character == ")" {
                    commandSubstitutionDepth -= 1
                }
                current.append(character)
                index = nextIndex
                continue
            }

            if quote == nil, !isInBacktickSubstitution, commandSubstitutionDepth == 0 {
                if (character == "&" && next == "&") || (character == "|" && next == "|") {
                    finishSegment()
                    index = command.index(after: nextIndex)
                    continue
                }
                if character == "|" || character == ";" || character.isNewline {
                    finishSegment()
                    index = nextIndex
                    continue
                }
            }

            current.append(character)
            index = nextIndex
        }
        finishSegment()
        return segments
    }

    private static func leadingEnvironmentAssignments(in command: String) -> [String: String] {
        var tokens = shellWords(in: command)
        if tokens.first == "env" {
            tokens.removeFirst()
            while tokens.first?.hasPrefix("-") == true {
                tokens.removeFirst()
            }
        }

        var assignments: [String: String] = [:]
        for token in tokens {
            guard let assignment = assignment(from: token) else { break }
            assignments[assignment.name] = assignment.value
        }
        return assignments
    }

    private static func persistentAssignments(in segment: String) -> [String: String]? {
        var tokens = shellWords(in: segment)
        if tokens.first == "export" || tokens.first == "readonly" {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return nil }

        var assignments: [String: String] = [:]
        for token in tokens {
            guard let assignment = assignment(from: token) else { return nil }
            assignments[assignment.name] = assignment.value
        }
        return assignments
    }

    private static func unsetVariableNames(in segment: String) -> [String] {
        let tokens = shellWords(in: segment)
        guard tokens.first == "unset" else { return [] }
        return tokens.dropFirst().filter(isValidVariableName)
    }

    private static func assignment(from token: String) -> (name: String, value: String)? {
        guard let separator = token.firstIndex(of: "=") else { return nil }
        let name = String(token[..<separator])
        guard isValidVariableName(name) else { return nil }
        return (name, String(token[token.index(after: separator)...]))
    }

    private static func shellWords(in command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        func finishWord() {
            if !current.isEmpty {
                words.append(current)
            }
            current = ""
        }

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "'", quote != "\"" {
                quote = quote == "'" ? nil : "'"
                current.append(character)
                continue
            }
            if character == "\"", quote != "'" {
                quote = quote == "\"" ? nil : "\""
                current.append(character)
                continue
            }
            if character.isWhitespace, quote == nil {
                finishWord()
                continue
            }
            current.append(character)
        }
        finishWord()
        return words
    }

    private static func referencedVariables(in command: String) -> Set<String> {
        var variables: Set<String> = []
        var index = command.startIndex
        var isInSingleQuote = false
        var isEscaped = false

        while index < command.endIndex {
            let character = command[index]
            if isEscaped {
                isEscaped = false
                index = command.index(after: index)
                continue
            }
            if character == "\\" {
                isEscaped = true
                index = command.index(after: index)
                continue
            }
            if character == "'" {
                isInSingleQuote.toggle()
                index = command.index(after: index)
                continue
            }
            guard character == "$", !isInSingleQuote else {
                index = command.index(after: index)
                continue
            }

            let valueStart = command.index(after: index)
            guard valueStart < command.endIndex else { break }
            if command[valueStart] == "{" {
                let nameStart = command.index(after: valueStart)
                if let closingBrace = command[nameStart...].firstIndex(of: "}") {
                    let name = String(command[nameStart..<closingBrace])
                    if isValidVariableName(name) {
                        variables.insert(name)
                    }
                    index = command.index(after: closingBrace)
                    continue
                }
            } else if isVariableNameStart(command[valueStart]) {
                var nameEnd = command.index(after: valueStart)
                while nameEnd < command.endIndex, isVariableNameContinuation(command[nameEnd]) {
                    nameEnd = command.index(after: nameEnd)
                }
                variables.insert(String(command[valueStart..<nameEnd]))
                index = nameEnd
                continue
            }
            index = valueStart
        }
        return variables
    }

    private static func isValidVariableName(_ value: String) -> Bool {
        guard let first = value.first, isVariableNameStart(first) else { return false }
        return value.dropFirst().allSatisfy(isVariableNameContinuation)
    }

    private static func isVariableNameStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isVariableNameContinuation(_ character: Character) -> Bool {
        isVariableNameStart(character) || character.isNumber
    }
}
