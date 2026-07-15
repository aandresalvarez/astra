import Foundation
import ASTRACore

struct ShellCommandMutationContext: Equatable, Sendable {
    let command: String
    let variableBindings: [String: Set<String>]
    let referencedVariables: Set<String>
    let indirectReferencedVariables: Set<String>
    let pipelineInputExpressions: [String]
    let workingDirectoryExpressions: [String]

    var pathReferenceExpressions: [String] {
        var expressions = [command] + pipelineInputExpressions + workingDirectoryExpressions
        var pendingReferences = referencedVariables
        for workingDirectory in workingDirectoryExpressions {
            pendingReferences.formUnion(
                ShellCommandMutationContextParser.directVariableReferences(in: workingDirectory)
            )
        }
        if referencedVariables.contains(where: { $0.allSatisfy(\.isNumber) }) {
            pendingReferences.insert("@")
        }
        for reference in indirectReferencedVariables.sorted() {
            for targetName in variableBindings[reference, default: []].sorted() {
                pendingReferences.insert(targetName)
            }
        }

        expressions += resolvedBindingExpressions(startingWith: pendingReferences)
        return expressions
    }

    var mutationCandidateCommands: [String] {
        var candidates = [command]
        guard let commandReference = ShellCommandMutationContextParser
            .leadingCommandVariableReference(in: command) else {
            return candidates
        }
        for expression in resolvedBindingExpressions(startingWith: [commandReference]) {
            guard let commandName = ShellCommandMutationContextParser
                .executableName(fromBindingExpression: expression) else {
                continue
            }
            candidates.append("\(commandName) \(command)")
        }
        return candidates
    }

    private func resolvedBindingExpressions(startingWith references: Set<String>) -> [String] {
        var expressions: [String] = []
        var pendingReferences = references
        var visitedReferences: Set<String> = []
        while let reference = pendingReferences.popFirst() {
            guard visitedReferences.insert(reference).inserted else { continue }
            for expression in variableBindings[reference, default: []].sorted() {
                expressions.append(expression)
                pendingReferences.formUnion(
                    ShellCommandMutationContextParser.directVariableReferences(in: expression)
                )
            }
        }
        return expressions
    }
}

/// Produces mutation-checking contexts without flattening shell data flow.
///
/// Top-level commands create independent contexts, while pipeline
/// stages preserve their directional input expressions for downstream mutation
/// checks. Bindings retain every value that can survive conditional execution,
/// and exact `sh -lc` provider launchers are normalized per segment so earlier
/// exported values and launcher-local environment assignments remain visible.
enum ShellCommandMutationContextParser {
    private enum SegmentSeparator {
        case pipeline
        case conditional
        case sequence
        case end
    }

    private struct Segment {
        let command: String
        let separatorAfter: SegmentSeparator
        let containsHeredoc: Bool
    }

    private struct ChildShellCommand {
        let payload: String
        let environmentAssignments: [String: Set<String>]
        let arguments: [String]
    }

    private struct FunctionInvocation {
        let name: String
        let environmentAssignments: [String: Set<String>]
        let arguments: [String]
    }

    private struct VariableReferences {
        var direct: Set<String> = []
        var indirect: Set<String> = []

        mutating func formUnion(_ other: Self) {
            direct.formUnion(other.direct)
            indirect.formUnion(other.indirect)
        }
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
        contexts(
            for: rawCommand,
            initialBindings: [:],
            initialWorkingDirectories: [],
            initialPreviousWorkingDirectories: [],
            initialExportedNames: [],
            initialReadonlyNames: [],
            inheritedFunctions: [:],
            recursionDepth: 0
        )
    }

    private static func contexts(
        for rawCommand: String,
        initialBindings: [String: Set<String>],
        initialWorkingDirectories: Set<String>,
        initialPreviousWorkingDirectories: Set<String>,
        initialExportedNames: Set<String>,
        initialReadonlyNames: Set<String>,
        inheritedFunctions: [String: String],
        recursionDepth: Int
    ) -> [ShellCommandMutationContext] {
        let trimmedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return [] }

        let segments = topLevelSegments(in: trimmedCommand)
        // A heredoc body belongs to its producer even though it contains raw
        // newlines. Keep a heredoc-fed pipeline intact so the body remains
        // correlated with a downstream mutator.
        if segments.contains(where: {
            $0.containsHeredoc && $0.separatorAfter == .pipeline
        }) || (segments.first?.containsHeredoc == true
            && isStandaloneHeredocCommand(trimmedCommand)) {
            let references = variableReferences(in: trimmedCommand)
            return [ShellCommandMutationContext(
                command: trimmedCommand,
                variableBindings: initialBindings,
                referencedVariables: references.direct,
                indirectReferencedVariables: references.indirect,
                pipelineInputExpressions: [],
                workingDirectoryExpressions: initialWorkingDirectories.sorted()
            )]
        }
        var bindings = initialBindings
        var workingDirectories = initialWorkingDirectories
        var previousWorkingDirectories = initialPreviousWorkingDirectories
        var exportedNames = initialExportedNames
        var readonlyNames = initialReadonlyNames
        var functions = inheritedFunctions
        var contexts: [ShellCommandMutationContext] = []
        if recursionDepth < 8,
           let loop = whileReadLoop(in: trimmedCommand) {
            var loopBindings = initialBindings
            loopBindings.merge(loop.assignments) { _, loopValue in loopValue }
            contexts.append(contentsOf: self.contexts(
                for: loop.body,
                initialBindings: loopBindings,
                initialWorkingDirectories: initialWorkingDirectories,
                initialPreviousWorkingDirectories: initialPreviousWorkingDirectories,
                initialExportedNames: initialExportedNames,
                initialReadonlyNames: initialReadonlyNames,
                inheritedFunctions: inheritedFunctions,
                recursionDepth: recursionDepth + 1
            ))
        }
        var pipelineInputExpressions: [String] = []
        var separatorBefore: SegmentSeparator = .sequence

        for segment in segments {
            let semanticCommand = ProviderToolSemantics.mutationAnalysisShellCommand(segment.command)
            if let definition = functionDefinition(in: semanticCommand) {
                functions[definition.name] = definition.body
                pipelineInputExpressions.removeAll(keepingCapacity: true)
                separatorBefore = segment.separatorAfter
                continue
            }
            var contextBindings = bindings
            if semanticCommand != segment.command {
                contextBindings.merge(leadingEnvironmentAssignments(in: segment.command)) {
                    _, launcherValue in launcherValue
                }
            }
            let childShell = childShellCommand(in: semanticCommand)
            let analysisCommand = childShell?.payload ?? semanticCommand
            if let childShell {
                contextBindings = contextBindings.filter { exportedNames.contains($0.key) }
                contextBindings.merge(childShell.environmentAssignments) {
                    _, launcherValue in launcherValue
                }
                contextBindings = contextBindings.filter { !isPositionalBindingName($0.key) }
                contextBindings.merge(positionalAssignments(values: childShell.arguments)) {
                    _, argumentValue in argumentValue
                }
            }
            var references = variableReferences(in: analysisCommand)
            let commandWords = executableWords(in: analysisCommand)
            var functionSideEffects: [String: Set<String>]?
            if let childShell, recursionDepth < 8 {
                let childExportedNames = exportedNames
                    .intersection(contextBindings.keys)
                    .union(childShell.environmentAssignments.keys)
                let childContexts = self.contexts(
                    for: childShell.payload,
                    initialBindings: contextBindings,
                    initialWorkingDirectories: workingDirectories,
                    initialPreviousWorkingDirectories: previousWorkingDirectories,
                    initialExportedNames: childExportedNames,
                    initialReadonlyNames: [],
                    inheritedFunctions: [:],
                    recursionDepth: recursionDepth + 1
                )
                contexts.append(contentsOf: childContexts.map { context in
                    ShellCommandMutationContext(
                        command: context.command,
                        variableBindings: context.variableBindings,
                        referencedVariables: context.referencedVariables,
                        indirectReferencedVariables: context.indirectReferencedVariables,
                        pipelineInputExpressions: pipelineInputExpressions
                            + context.pipelineInputExpressions,
                        workingDirectoryExpressions: context.workingDirectoryExpressions
                    )
                })
            } else {
                if let commandName = commandWords.first,
                   commandName == "eval" || commandName == "trap" {
                    references.formUnion(variableReferences(
                        in: analysisCommand,
                        treatsSingleQuotedTextAsCode: true
                    ))
                }
                contexts.append(ShellCommandMutationContext(
                    command: analysisCommand,
                    variableBindings: contextBindings,
                    referencedVariables: references.direct,
                    indirectReferencedVariables: references.indirect,
                    pipelineInputExpressions: pipelineInputExpressions,
                    workingDirectoryExpressions: workingDirectories.sorted()
                ))
            }

            if childShell == nil,
               recursionDepth < 8,
               let invocation = functionInvocation(in: analysisCommand, functions: functions),
               let functionBody = functions[invocation.name] {
                // Function bodies are deferred shell programs. Analyze the
                // invoked body with the call's arguments projected onto the
                // function-local positional parameter scope.
                var functionBindings = contextBindings
                functionBindings.merge(invocation.environmentAssignments) {
                    _, argumentValue in argumentValue
                }
                functionBindings = functionBindings.filter { !isPositionalBindingName($0.key) }
                functionBindings.merge(
                    positionalAssignments(values: invocation.arguments)
                ) { _, argumentValue in argumentValue }
                contexts.append(contentsOf: self.contexts(
                    for: functionBody,
                    initialBindings: functionBindings,
                    initialWorkingDirectories: workingDirectories,
                    initialPreviousWorkingDirectories: previousWorkingDirectories,
                    initialExportedNames: exportedNames,
                    initialReadonlyNames: readonlyNames,
                    inheritedFunctions: functions,
                    recursionDepth: recursionDepth + 1
                ))
                functionSideEffects = functionBindingSideEffects(
                    in: functionBody,
                    initialBindings: functionBindings
                ).filter { !invocation.environmentAssignments.keys.contains($0.key) }
            }

            let isPipelineStage = separatorBefore == .pipeline
                || segment.separatorAfter == .pipeline
            // Bash pipeline stages run in subshells by default. Their writes
            // must not replace the parent-shell bindings used by later
            // sequential commands.
            if !isPipelineStage {
                if let functionSideEffects {
                    for (name, values) in functionSideEffects {
                        if separatorBefore == .conditional {
                            bindings[name, default: []].formUnion(values)
                        } else {
                            bindings[name] = values
                        }
                    }
                } else if let positionalAssignments = setPositionalAssignments(in: segment.command) {
                    if separatorBefore != .conditional {
                        bindings = bindings.filter { !isPositionalBindingName($0.key) }
                    }
                    for (name, values) in positionalAssignments {
                        if separatorBefore == .conditional {
                            bindings[name, default: []].formUnion(values)
                        } else {
                            bindings[name] = values
                        }
                    }
                } else if let assignments = persistentAssignments(in: segment.command)
                    ?? loopAssignments(in: segment.command, bindings: bindings)
                    ?? readAssignments(in: segment.command)
                    ?? arrayReadAssignment(in: segment.command)
                    ?? printfVariableAssignment(in: segment.command) {
                    let additiveNames = additiveAssignmentNames(in: segment.command)
                    for (name, values) in assignments {
                        if separatorBefore == .conditional || additiveNames.contains(name) {
                            bindings[name, default: []].formUnion(values)
                        } else {
                            bindings[name] = values
                        }
                    }
                } else if separatorBefore != .conditional {
                    for name in unsetVariableNames(in: segment.command)
                    where !readonlyNames.contains(name) {
                        bindings.removeValue(forKey: name)
                        exportedNames.remove(name)
                    }
                }
                if let workingDirectory = workingDirectoryAssignment(in: segment.command) {
                    if workingDirectory == "-" {
                        let destination = previousWorkingDirectories
                        previousWorkingDirectories = workingDirectories
                        if separatorBefore == .conditional {
                            workingDirectories.formUnion(destination)
                        } else {
                            workingDirectories = destination
                        }
                    } else if separatorBefore == .conditional {
                        previousWorkingDirectories.formUnion(workingDirectories)
                        workingDirectories.insert(workingDirectory)
                    } else {
                        previousWorkingDirectories = workingDirectories
                        workingDirectories = [workingDirectory]
                    }
                }
                let exportChanges = exportedVariableChanges(in: segment.command)
                exportedNames.formUnion(exportChanges.added)
                exportedNames.subtract(exportChanges.removed)
                readonlyNames.formUnion(readonlyVariableNames(in: segment.command))
            }

            if segment.separatorAfter == .pipeline {
                pipelineInputExpressions.append(analysisCommand)
                pipelineInputExpressions += references.direct.sorted().flatMap {
                    contextBindings[$0, default: []].sorted()
                }
            } else {
                pipelineInputExpressions.removeAll(keepingCapacity: true)
            }
            separatorBefore = segment.separatorAfter
        }
        return contexts
    }

    private static func isStandaloneHeredocCommand(_ command: String) -> Bool {
        let lines = command.components(separatedBy: .newlines)
        guard lines.count >= 3,
              let header = lines.first,
              topLevelSegments(in: header).count == 1,
              let markerRange = header.range(of: #"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"#,
                                             options: .regularExpression),
              let delimiterRange = header[markerRange]
                .range(of: #"[A-Za-z_][A-Za-z0-9_]*"#, options: .regularExpression) else {
            return false
        }
        let delimiter = String(header[delimiterRange])
        return lines.last(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.trimmingCharacters(in: .whitespacesAndNewlines) == delimiter
    }

    private static func whileReadLoop(
        in command: String
    ) -> (body: String, assignments: [String: Set<String>])? {
        guard command.hasPrefix("while "),
              let doRange = command.range(of: "; do "),
              let doneRange = command.range(of: "; done <<< ", options: .backwards),
              doRange.upperBound <= doneRange.lowerBound else {
            return nil
        }
        let headerStart = command.index(command.startIndex, offsetBy: "while ".count)
        let header = String(command[headerStart..<doRange.lowerBound])
        let input = String(command[doneRange.upperBound...])
        guard let assignments = readAssignments(in: "\(header) <<< \(input)") else {
            return nil
        }
        return (String(command[doRange.upperBound..<doneRange.lowerBound]), assignments)
    }

    private static func topLevelSegments(in command: String) -> [Segment] {
        let command = command
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\\\r", with: " ")
        var segments: [Segment] = []
        var current = ""
        var currentContainsHeredoc = false
        var index = command.startIndex
        var isEscaped = false
        var frames: [LexicalFrame] = [.topLevel]
        var groupingDepth = 0

        func finishSegment(separatorAfter: SegmentSeparator) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(Segment(
                    command: trimmed,
                    separatorAfter: separatorAfter,
                    containsHeredoc: currentContainsHeredoc
                ))
            }
            current = ""
            currentContainsHeredoc = false
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
                if character == "{",
                   groupingDepth > 0 || isFunctionDeclarationPrefix(current) {
                    groupingDepth += 1
                    current.append(character)
                    index = nextIndex
                    continue
                }
                if character == "}", groupingDepth > 0 {
                    groupingDepth -= 1
                    current.append(character)
                    index = nextIndex
                    continue
                }
                if character == "(" {
                    groupingDepth += 1
                    current.append(character)
                    index = nextIndex
                    continue
                }
                if character == ")", groupingDepth > 0 {
                    groupingDepth -= 1
                    current.append(character)
                    index = nextIndex
                    continue
                }
                if character == "<", next == "<" {
                    currentContainsHeredoc = true
                }
                if groupingDepth == 0,
                   (character == "&" && next == "&") || (character == "|" && next == "|") {
                    finishSegment(separatorAfter: .conditional)
                    index = command.index(after: nextIndex)
                    continue
                }
                if groupingDepth == 0, character == "|" {
                    finishSegment(separatorAfter: .pipeline)
                    index = nextIndex
                    continue
                }
                if groupingDepth == 0, character == ";" || character.isNewline {
                    finishSegment(separatorAfter: .sequence)
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

    private static func leadingEnvironmentAssignments(in command: String) -> [String: Set<String>] {
        var tokens = shellWords(in: command)
        if tokens.first == "env" {
            tokens.removeFirst()
            consumeEnvOptions(from: &tokens)
        }

        var assignments: [String: Set<String>] = [:]
        for token in tokens {
            guard let assignment = assignment(from: token) else { break }
            assignments[assignment.name] = [assignment.value]
        }
        return assignments
    }

    private static func consumeEnvOptions(from words: inout [String]) {
        let optionsWithSeparateOperands: Set<String> = [
            "-u", "--unset", "-C", "--chdir", "-S", "--split-string",
            "--block-signal", "--default-signal", "--ignore-signal"
        ]
        while let option = words.first, option.hasPrefix("-") {
            words.removeFirst()
            if option == "--" {
                return
            }
            if optionsWithSeparateOperands.contains(option), !words.isEmpty {
                words.removeFirst()
            }
        }
    }

    private static func persistentAssignments(in segment: String) -> [String: Set<String>]? {
        var tokens = shellWords(in: segment)
        let assignmentControlWords: Set<String> = [
            "if", "then", "do", "else", "elif", "while", "until", "!", "{"
        ]
        while let first = tokens.first, assignmentControlWords.contains(first) {
            tokens.removeFirst()
        }
        if tokens.first == "case",
           let armPatternIndex = tokens.firstIndex(where: { $0.hasSuffix(")") }) {
            tokens.removeFirst(tokens.distance(from: tokens.startIndex, to: armPatternIndex) + 1)
        }
        let declarationBuiltins: Set<String> = [
            "declare", "export", "local", "readonly", "typeset"
        ]
        var isNameReference = false
        var isDisplayOnly = false
        if let first = tokens.first, declarationBuiltins.contains(first) {
            tokens.removeFirst()
            while tokens.first.map({ $0.hasPrefix("-") || $0.hasPrefix("+") }) == true {
                if tokens[0].hasPrefix("-"), tokens[0].dropFirst().contains("n") {
                    isNameReference = true
                }
                if tokens[0].hasPrefix("+"), tokens[0].dropFirst().contains("n") {
                    isNameReference = false
                }
                if tokens[0].hasPrefix("-"), tokens[0].dropFirst().contains("p") {
                    isDisplayOnly = true
                }
                tokens.removeFirst()
            }
        }
        guard !isDisplayOnly, !tokens.isEmpty else { return nil }

        var assignments: [String: Set<String>] = [:]
        for token in tokens {
            guard let assignment = assignment(from: token) else { return nil }
            if isNameReference, isValidVariableName(assignment.value) {
                assignments[assignment.name] = ["$\(assignment.value)"]
            } else {
                assignments[assignment.name] = [assignment.value]
            }
        }
        return assignments
    }

    private static func loopAssignments(
        in segment: String,
        bindings: [String: Set<String>]
    ) -> [String: Set<String>]? {
        let tokens = shellWords(in: segment)
        guard tokens.count >= 2,
              tokens[0] == "for",
              isValidVariableName(tokens[1]) else {
            return nil
        }
        if tokens.count == 2 {
            return [tokens[1]: bindings["@", default: []]]
        }
        guard tokens.count >= 4, tokens[2] == "in" else { return nil }
        return [tokens[1]: [tokens.dropFirst(3).joined(separator: " ")]]
    }

    private static func readAssignments(in segment: String) -> [String: Set<String>]? {
        let tokens = shellWords(in: segment)
        guard tokens.first == "read" else { return nil }
        guard let redirectIndex = tokens.firstIndex(of: "<<<"),
              redirectIndex > tokens.index(after: tokens.startIndex),
              tokens.index(after: redirectIndex) < tokens.endIndex else {
            return nil
        }
        var nameIndex = tokens.index(after: tokens.startIndex)
        while nameIndex < redirectIndex, tokens[nameIndex].hasPrefix("-") {
            let option = tokens[nameIndex]
            nameIndex = tokens.index(after: nameIndex)
            if readOptionRequiresSeparateOperand(option), nameIndex < redirectIndex {
                nameIndex = tokens.index(after: nameIndex)
            }
            if option == "--" { break }
        }
        let names = tokens[nameIndex..<redirectIndex].filter(isValidVariableName)
        guard !names.isEmpty else { return nil }

        let rawInput = tokens[tokens.index(after: redirectIndex)...].joined(separator: " ")
        let input = unquotedShellScalar(rawInput)
        let fields = input.split(whereSeparator: \.isWhitespace).map(String.init)
        var assignments: [String: Set<String>] = [:]
        for (offset, name) in names.enumerated() {
            let value: String
            if offset == names.count - 1 {
                value = fields.dropFirst(offset).joined(separator: " ")
            } else {
                value = offset < fields.count ? fields[offset] : ""
            }
            assignments[name] = [value]
        }
        return assignments
    }

    private static func readOptionRequiresSeparateOperand(_ option: String) -> Bool {
        ["-a", "-d", "-i", "-n", "-N", "-p", "-t", "-u"].contains(option)
    }

    private static func unquotedShellScalar(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              (first == "'" || first == "\""),
              value.last == first else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func arrayReadAssignment(in segment: String) -> [String: Set<String>]? {
        let tokens = executableWords(in: segment)
        guard let command = tokens.first,
              command == "mapfile" || command == "readarray",
              let redirectIndex = tokens.firstIndex(of: "<<<"),
              redirectIndex > tokens.startIndex,
              tokens.index(after: redirectIndex) < tokens.endIndex else {
            return nil
        }
        let name = tokens[tokens.index(before: redirectIndex)]
        guard isValidVariableName(name) else { return nil }
        return [name: [tokens[tokens.index(after: redirectIndex)]]]
    }

    private static func workingDirectoryAssignment(in segment: String) -> String? {
        var tokens = executableWords(in: segment)
        guard let command = tokens.first,
              command == "cd" || command == "pushd" else { return nil }
        tokens.removeFirst()
        if command == "pushd", tokens.contains("-n") {
            return nil
        }
        if command == "cd", tokens.first == "-" {
            return "-"
        }
        while tokens.first?.hasPrefix("-") == true {
            if tokens.first == "--" {
                tokens.removeFirst()
                break
            }
            tokens.removeFirst()
        }
        return tokens.first
    }

    private static func childShellCommand(in segment: String) -> ChildShellCommand? {
        var tokens = executableWords(in: segment)
        var environmentAssignments: [String: Set<String>] = [:]
        while let first = tokens.first, let assignment = assignment(from: first) {
            environmentAssignments[assignment.name] = [assignment.value]
            tokens.removeFirst()
        }
        guard let executable = tokens.first,
              ["sh", "bash", "zsh"].contains(
                URL(fileURLWithPath: unquotedShellScalar(executable)).lastPathComponent.lowercased()
              ) else {
            return nil
        }
        tokens.removeFirst()
        guard let optionIndex = tokens.firstIndex(where: {
            $0.hasPrefix("-") && $0.dropFirst().contains("c")
        }),
        tokens.index(after: optionIndex) < tokens.endIndex else {
            return nil
        }
        let payloadIndex = tokens.index(after: optionIndex)
        let argumentZeroIndex = tokens.index(after: payloadIndex)
        let arguments = argumentZeroIndex < tokens.endIndex
            ? Array(tokens[tokens.index(after: argumentZeroIndex)...])
            : []
        return ChildShellCommand(
            payload: unquotedShellScalar(tokens[payloadIndex]),
            environmentAssignments: environmentAssignments,
            arguments: arguments
        )
    }

    private static func functionInvocation(
        in segment: String,
        functions: [String: String]
    ) -> FunctionInvocation? {
        var tokens = executableWords(in: segment)
        var environmentAssignments: [String: Set<String>] = [:]
        while let first = tokens.first, let assignment = assignment(from: first) {
            environmentAssignments[assignment.name] = [assignment.value]
            tokens.removeFirst()
        }
        guard let name = tokens.first, functions[name] != nil else { return nil }
        return FunctionInvocation(
            name: name,
            environmentAssignments: environmentAssignments,
            arguments: Array(tokens.dropFirst())
        )
    }

    private static func functionBindingSideEffects(
        in body: String,
        initialBindings: [String: Set<String>]
    ) -> [String: Set<String>] {
        var bindings = initialBindings
        var assignedNames: Set<String> = []
        var localNames: Set<String> = []
        var separatorBefore: SegmentSeparator = .sequence
        for segment in topLevelSegments(in: body) {
            if let declaredLocals = functionLocalVariableNames(in: segment.command) {
                localNames.formUnion(declaredLocals)
                separatorBefore = segment.separatorAfter
                continue
            }
            guard let assignments = persistentAssignments(in: segment.command) else {
                separatorBefore = segment.separatorAfter
                continue
            }
            let additiveNames = additiveAssignmentNames(in: segment.command)
            let nonLocalAssignments = assignments.filter { !localNames.contains($0.key) }
            assignedNames.formUnion(nonLocalAssignments.keys)
            for (name, values) in nonLocalAssignments {
                if separatorBefore == .conditional || additiveNames.contains(name) {
                    bindings[name, default: []].formUnion(values)
                } else {
                    bindings[name] = values
                }
            }
            separatorBefore = segment.separatorAfter
        }
        return bindings.filter { assignedNames.contains($0.key) }
    }

    private static func functionLocalVariableNames(in segment: String) -> Set<String>? {
        var tokens = executableWords(in: segment)
        guard let command = tokens.first else { return nil }
        guard command == "local" || command == "declare" || command == "typeset" else {
            return nil
        }
        tokens.removeFirst()
        let isGlobal = tokens.contains(where: {
            $0.hasPrefix("-") && $0.dropFirst().contains("g")
        })
        guard command == "local" || !isGlobal else { return nil }
        while tokens.first.map({ $0.hasPrefix("-") || $0.hasPrefix("+") }) == true {
            tokens.removeFirst()
        }
        return Set(tokens.compactMap { token -> String? in
            if let assignment = assignment(from: token) { return assignment.name }
            return isValidVariableName(token) ? token : nil
        })
    }

    private static func exportedVariableChanges(
        in segment: String
    ) -> (added: Set<String>, removed: Set<String>) {
        var tokens = executableWords(in: segment)
        guard tokens.first == "export" else { return ([], []) }
        tokens.removeFirst()
        var removesExport = false
        while let option = tokens.first, option.hasPrefix("-") {
            removesExport = removesExport || option.dropFirst().contains("n")
            tokens.removeFirst()
        }
        let names = Set(tokens.compactMap { token -> String? in
            if let assignment = assignment(from: token) { return assignment.name }
            return isValidVariableName(token) ? token : nil
        })
        return removesExport ? ([], names) : (names, [])
    }

    private static func readonlyVariableNames(in segment: String) -> Set<String> {
        var tokens = executableWords(in: segment)
        guard let command = tokens.first else { return [] }
        tokens.removeFirst()
        var declaresReadonly = command == "readonly"
        if command == "declare" || command == "typeset" {
            declaresReadonly = tokens.contains(where: {
                $0.hasPrefix("-") && $0.dropFirst().contains("r")
            })
        }
        guard declaresReadonly else { return [] }
        while tokens.first.map({ $0.hasPrefix("-") || $0.hasPrefix("+") }) == true {
            tokens.removeFirst()
        }
        return Set(tokens.compactMap { token -> String? in
            if let assignment = assignment(from: token) { return assignment.name }
            return isValidVariableName(token) ? token : nil
        })
    }

    private static func printfVariableAssignment(in segment: String) -> [String: Set<String>]? {
        let tokens = executableWords(in: segment)
        guard tokens.count >= 4,
              tokens[0] == "printf",
              tokens[1] == "-v" else {
            return nil
        }
        let nameIndex = 2
        let name = tokens[nameIndex]
        let valueStart = tokens.index(after: nameIndex)
        guard isValidVariableName(name), valueStart < tokens.endIndex else { return nil }
        let format = tokens[valueStart]
        var outputExpressions = [format]
        if printfFormatConsumesArguments(format) {
            outputExpressions.append(contentsOf: tokens[tokens.index(after: valueStart)...])
        }
        return [name: [outputExpressions.joined(separator: " ")]]
    }

    private static func printfFormatConsumesArguments(_ format: String) -> Bool {
        var index = format.startIndex
        while index < format.endIndex {
            guard format[index] == "%" else {
                index = format.index(after: index)
                continue
            }
            let nextIndex = format.index(after: index)
            guard nextIndex < format.endIndex else { return false }
            if format[nextIndex] != "%" {
                return true
            }
            index = format.index(after: nextIndex)
        }
        return false
    }

    private static func setPositionalAssignments(in segment: String) -> [String: Set<String>]? {
        var tokens = shellWords(in: segment)
        let controlWords: Set<String> = ["if", "then", "do", "else", "elif", "while", "until", "!"]
        while let first = tokens.first, controlWords.contains(first) {
            tokens.removeFirst()
        }
        guard tokens.count >= 2, tokens[0] == "set", tokens[1] == "--" else {
            return nil
        }

        return positionalAssignments(values: Array(tokens.dropFirst(2)))
    }

    private static func positionalAssignments(values: [String]) -> [String: Set<String>] {
        var assignments: [String: Set<String>] = [:]
        for (offset, value) in values.enumerated() {
            assignments[String(offset + 1)] = [value]
        }
        let allValues = Set(values)
        assignments["@"] = allValues
        assignments["*"] = allValues
        return assignments
    }

    private static func executableWords(in segment: String) -> [String] {
        var tokens = shellWords(in: segment)
        let controlWords: Set<String> = [
            "if", "then", "do", "else", "elif", "while", "until", "!", "{"
        ]
        while let first = tokens.first, controlWords.contains(first) {
            tokens.removeFirst()
        }
        return tokens
    }

    private static func isFunctionDeclarationPrefix(_ value: String) -> Bool {
        functionName(inDeclarationPrefix: value) != nil
    }

    private static func functionName(inDeclarationPrefix value: String) -> String? {
        var compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFunctionKeyword = compact.hasPrefix("function ")
        if hasFunctionKeyword {
            compact.removeFirst("function ".count)
            compact = compact.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        compact.removeAll(where: \.isWhitespace)
        if compact.hasSuffix("()") {
            compact.removeLast(2)
        } else if !hasFunctionKeyword {
            return nil
        }
        return isValidVariableName(compact) ? compact : nil
    }

    private static func functionDefinition(in segment: String) -> (name: String, body: String)? {
        guard let openingBrace = segment.firstIndex(of: "{"),
              let closingBrace = segment.lastIndex(of: "}"),
              openingBrace < closingBrace else {
            return nil
        }
        let prefix = String(segment[..<openingBrace])
        guard let name = functionName(inDeclarationPrefix: prefix) else { return nil }
        let bodyStart = segment.index(after: openingBrace)
        return (name, String(segment[bodyStart..<closingBrace]))
    }

    private static func isPositionalBindingName(_ name: String) -> Bool {
        name == "@" || name == "*" || (!name.isEmpty && name.allSatisfy(\.isNumber))
    }

    private static func unsetVariableNames(in segment: String) -> [String] {
        var tokens = shellWords(in: segment)
        guard tokens.first == "unset" else { return [] }
        tokens.removeFirst()

        var names: [String] = []
        var functionOnly = false
        var reachedNames = false
        for token in tokens {
            if !reachedNames, token == "--" {
                reachedNames = true
                continue
            }
            if !reachedNames, token.hasPrefix("-") {
                if token.dropFirst().contains("f") {
                    functionOnly = true
                }
                continue
            }
            reachedNames = true
            if isValidVariableName(token) {
                names.append(token)
            }
        }
        return functionOnly ? [] : names
    }

    private static func assignment(
        from token: String
    ) -> (name: String, value: String, isAdditive: Bool)? {
        guard let separator = token.firstIndex(of: "=") else { return nil }
        var name = String(token[..<separator])
        var isAdditive = false
        if name.hasSuffix("+") {
            name.removeLast()
            isAdditive = true
        }
        if let arrayIndex = name.firstIndex(of: "["), name.hasSuffix("]") {
            name = String(name[..<arrayIndex])
            isAdditive = true
        }
        guard isValidVariableName(name) else { return nil }
        return (name, String(token[token.index(after: separator)...]), isAdditive)
    }

    private static func additiveAssignmentNames(in segment: String) -> Set<String> {
        Set(shellWords(in: segment).compactMap { token in
            guard let assignment = assignment(from: token), assignment.isAdditive else {
                return nil
            }
            return assignment.name
        })
    }

    private static func shellWords(in command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var index = command.startIndex
        var isEscaped = false
        var frames: [LexicalFrame] = [.topLevel]
        var wordGroupingDepth = 0

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
            if frames.count == 1, quote == nil, !isInBacktickSubstitution {
                if character == "(", !current.isEmpty {
                    wordGroupingDepth += 1
                } else if character == ")", wordGroupingDepth > 0 {
                    wordGroupingDepth -= 1
                }
            }
            if character.isWhitespace,
               quote == nil,
               frames.count == 1,
               wordGroupingDepth == 0,
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

    private static func variableReferences(
        in command: String,
        treatsSingleQuotedTextAsCode: Bool = false
    ) -> VariableReferences {
        var references = VariableReferences()
        var index = command.startIndex
        var quote: Character?
        var isEscaped = false

        while index < command.endIndex {
            let character = command[index]
            if isEscaped {
                isEscaped = false
                index = command.index(after: index)
                continue
            }
            if character == "\\", quote != "'" {
                isEscaped = true
                index = command.index(after: index)
                continue
            }
            if character == "'", quote != "\"", !treatsSingleQuotedTextAsCode {
                quote = quote == "'" ? nil : "'"
                index = command.index(after: index)
                continue
            }
            if character == "\"", quote != "'" {
                quote = quote == "\"" ? nil : "\""
                index = command.index(after: index)
                continue
            }
            guard character == "$", quote != "'" else {
                index = command.index(after: index)
                continue
            }

            let valueStart = command.index(after: index)
            guard valueStart < command.endIndex else { break }
            if command[valueStart] == "{" {
                var nameStart = command.index(after: valueStart)
                if let closingBrace = command[nameStart...].firstIndex(of: "}") {
                    let isIndirect = nameStart < closingBrace && command[nameStart] == "!"
                    if isIndirect {
                        nameStart = command.index(after: nameStart)
                    }
                    var nameEnd = nameStart
                    if nameEnd < closingBrace,
                       command[nameEnd].isNumber || command[nameEnd] == "@" || command[nameEnd] == "*" {
                        nameEnd = command.index(after: nameEnd)
                        while nameEnd < closingBrace, command[nameEnd].isNumber {
                            nameEnd = command.index(after: nameEnd)
                        }
                        let name = String(command[nameStart..<nameEnd])
                        if isIndirect {
                            references.indirect.insert(name)
                        } else {
                            references.direct.insert(name)
                        }
                    } else if nameEnd < closingBrace, isVariableNameStart(command[nameEnd]) {
                        nameEnd = command.index(after: nameEnd)
                        while nameEnd < closingBrace,
                              isVariableNameContinuation(command[nameEnd]) {
                            nameEnd = command.index(after: nameEnd)
                        }
                        let name = String(command[nameStart..<nameEnd])
                        if isIndirect {
                            references.indirect.insert(name)
                        } else {
                            references.direct.insert(name)
                        }
                    }
                    index = command.index(after: closingBrace)
                    continue
                }
            } else if command[valueStart].isNumber
                || command[valueStart] == "@"
                || command[valueStart] == "*" {
                references.direct.insert(String(command[valueStart]))
                index = command.index(after: valueStart)
                continue
            } else if isVariableNameStart(command[valueStart]) {
                var nameEnd = command.index(after: valueStart)
                while nameEnd < command.endIndex, isVariableNameContinuation(command[nameEnd]) {
                    nameEnd = command.index(after: nameEnd)
                }
                references.direct.insert(String(command[valueStart..<nameEnd]))
                index = nameEnd
                continue
            }
            index = valueStart
        }
        return references
    }

    fileprivate static func directVariableReferences(in expression: String) -> Set<String> {
        variableReferences(in: expression).direct
    }

    fileprivate static func leadingCommandVariableReference(in command: String) -> String? {
        guard var firstWord = shellWords(in: command).first else { return nil }
        if firstWord.count >= 2,
           firstWord.first == "\"",
           firstWord.last == "\"" {
            firstWord.removeFirst()
            firstWord.removeLast()
        }
        if firstWord.hasPrefix("${"), firstWord.hasSuffix("}") {
            let name = String(firstWord.dropFirst(2).dropLast())
            return isValidVariableName(name) ? name : nil
        }
        guard firstWord.first == "$" else { return nil }
        let name = String(firstWord.dropFirst())
        return isValidVariableName(name) ? name : nil
    }

    fileprivate static func executableName(fromBindingExpression expression: String) -> String? {
        var value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           let first = value.first,
           (first == "'" || first == "\""),
           value.last == first {
            value.removeFirst()
            value.removeLast()
        }
        guard let name = value.split(whereSeparator: \.isWhitespace).first,
              !name.isEmpty else {
            return nil
        }
        return String(name)
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
