import Foundation
import ASTRACore

struct ShellCommandMutationContext: Equatable, Sendable {
    let command: String
    let variableBindings: [String: String]
    let referencedVariables: Set<String>
    let pipelineInputExpressions: [String]

    var pathReferenceExpressions: [String] {
        [command]
            + pipelineInputExpressions
            + referencedVariables.sorted().compactMap { variableBindings[$0] }
    }
}

/// Produces mutation-checking contexts without flattening shell data flow.
///
/// Top-level control separators create independent contexts, while pipeline
/// stages preserve their directional input expressions for downstream mutation
/// checks. Quoted separators and command/process substitutions remain attached
/// to their parent command. Simple assignment-only segments flow into later
/// contexts, including assignments that wrap an exact `sh -lc` provider launcher.
enum ShellCommandMutationContextParser {
    private enum SegmentSeparator {
        case pipeline
        case control
        case end
    }

    private struct Segment {
        let command: String
        let separatorAfter: SegmentSeparator
    }

    private struct LexicalFrame {
        var quote: Character?
        var isInBacktickSubstitution: Bool
        var parenthesisDepth: Int?

        static var topLevel: Self {
            Self(quote: nil, isInBacktickSubstitution: false, parenthesisDepth: nil)
        }

        static var substitution: Self {
            Self(quote: nil, isInBacktickSubstitution: false, parenthesisDepth: 1)
        }
    }

    static func contexts(for rawCommand: String) -> [ShellCommandMutationContext] {
        let trimmedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return [] }

        let rawSegments = topLevelSegments(in: trimmedCommand)
        let semanticCommand = rawSegments.count == 1
            ? ProviderToolSemantics.semanticShellCommand(trimmedCommand)
            : trimmedCommand
        let segments = semanticCommand == trimmedCommand
            ? rawSegments
            : topLevelSegments(in: semanticCommand)
        var bindings = semanticCommand == trimmedCommand
            ? [:]
            : leadingEnvironmentAssignments(in: trimmedCommand)
        var contexts: [ShellCommandMutationContext] = []
        var pipelineInputExpressions: [String] = []

        for segment in segments {
            let referenced = referencedVariables(in: segment.command)
            contexts.append(ShellCommandMutationContext(
                command: segment.command,
                variableBindings: bindings,
                referencedVariables: referenced,
                pipelineInputExpressions: pipelineInputExpressions
            ))

            if let assignments = persistentAssignments(in: segment.command) {
                bindings.merge(assignments) { _, replacement in replacement }
            } else {
                for name in unsetVariableNames(in: segment.command) {
                    bindings.removeValue(forKey: name)
                }
            }

            if segment.separatorAfter == .pipeline {
                pipelineInputExpressions.append(segment.command)
                pipelineInputExpressions.append(contentsOf: referenced.sorted().compactMap { bindings[$0] })
            } else {
                pipelineInputExpressions.removeAll(keepingCapacity: true)
            }
        }
        return contexts
    }

    private static func topLevelSegments(in command: String) -> [Segment] {
        let command = command
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\\\r", with: " ")
        var segments: [Segment] = []
        var current = ""
        var index = command.startIndex
        var isEscaped = false
        var frames: [LexicalFrame] = [.topLevel]

        func finishSegment(separatorAfter: SegmentSeparator) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(Segment(command: trimmed, separatorAfter: separatorAfter))
            }
            current = ""
        }

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil
            let frameIndex = frames.index(before: frames.endIndex)
            let quote = frames[frameIndex].quote
            let isInBacktickSubstitution = frames[frameIndex].isInBacktickSubstitution

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
                frames[frameIndex].quote = quote == "'" ? nil : "'"
                current.append(character)
                index = nextIndex
                continue
            }
            if character == "\"", quote != "'", !isInBacktickSubstitution {
                frames[frameIndex].quote = quote == "\"" ? nil : "\""
                current.append(character)
                index = nextIndex
                continue
            }
            if character == "`", quote != "'" {
                frames[frameIndex].isInBacktickSubstitution.toggle()
                current.append(character)
                index = nextIndex
                continue
            }

            if quote != "'", !isInBacktickSubstitution,
               (character == "$" || character == "<" || character == ">"), next == "(" {
                frames.append(.substitution)
                current.append(character)
                current.append("(")
                index = command.index(after: nextIndex)
                continue
            }
            if frames.count > 1, quote == nil, !isInBacktickSubstitution {
                if character == "(" {
                    frames[frameIndex].parenthesisDepth? += 1
                } else if character == ")" {
                    frames[frameIndex].parenthesisDepth? -= 1
                    if frames[frameIndex].parenthesisDepth == 0 {
                        frames.removeLast()
                    }
                }
                current.append(character)
                index = nextIndex
                continue
            }

            if frames.count == 1, quote == nil, !isInBacktickSubstitution {
                if (character == "&" && next == "&") || (character == "|" && next == "|") {
                    finishSegment(separatorAfter: .control)
                    index = command.index(after: nextIndex)
                    continue
                }
                if character == "|" {
                    finishSegment(separatorAfter: .pipeline)
                    index = nextIndex
                    continue
                }
                if character == ";" || character.isNewline {
                    finishSegment(separatorAfter: .control)
                    index = nextIndex
                    continue
                }
            }

            current.append(character)
            index = nextIndex
        }
        finishSegment(separatorAfter: .end)
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
        let declarationBuiltins: Set<String> = [
            "declare", "export", "local", "readonly", "typeset"
        ]
        if let first = tokens.first, declarationBuiltins.contains(first) {
            tokens.removeFirst()
            while tokens.first?.hasPrefix("-") == true {
                tokens.removeFirst()
            }
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
        var index = command.startIndex
        var isEscaped = false
        var frames: [LexicalFrame] = [.topLevel]

        func finishWord() {
            if !current.isEmpty {
                words.append(current)
            }
            current = ""
        }

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil
            let frameIndex = frames.index(before: frames.endIndex)
            let quote = frames[frameIndex].quote
            let isInBacktickSubstitution = frames[frameIndex].isInBacktickSubstitution

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
                frames[frameIndex].quote = quote == "'" ? nil : "'"
                current.append(character)
                index = nextIndex
                continue
            }
            if character == "\"", quote != "'", !isInBacktickSubstitution {
                frames[frameIndex].quote = quote == "\"" ? nil : "\""
                current.append(character)
                index = nextIndex
                continue
            }
            if character == "`", quote != "'" {
                frames[frameIndex].isInBacktickSubstitution.toggle()
                current.append(character)
                index = nextIndex
                continue
            }
            if quote != "'", !isInBacktickSubstitution,
               (character == "$" || character == "<" || character == ">"), next == "(" {
                frames.append(.substitution)
                current.append(character)
                current.append("(")
                index = command.index(after: nextIndex)
                continue
            }
            if frames.count > 1, quote == nil, !isInBacktickSubstitution {
                if character == "(" {
                    frames[frameIndex].parenthesisDepth? += 1
                } else if character == ")" {
                    frames[frameIndex].parenthesisDepth? -= 1
                    if frames[frameIndex].parenthesisDepth == 0 {
                        frames.removeLast()
                    }
                }
                current.append(character)
                index = nextIndex
                continue
            }
            if character.isWhitespace,
               quote == nil,
               frames.count == 1,
               !isInBacktickSubstitution {
                finishWord()
                index = nextIndex
                continue
            }
            current.append(character)
            index = nextIndex
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
                    var nameEnd = nameStart
                    if nameEnd < closingBrace, isVariableNameStart(command[nameEnd]) {
                        nameEnd = command.index(after: nameEnd)
                        while nameEnd < closingBrace,
                              isVariableNameContinuation(command[nameEnd]) {
                            nameEnd = command.index(after: nameEnd)
                        }
                        variables.insert(String(command[nameStart..<nameEnd]))
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
