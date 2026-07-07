import Foundation

/// Moved wholesale from Astra/Services/Validation/ValidationService.swift
/// for Track A4 (ASTRAPersistence): fully self-contained (zero non-Foundation
/// dependencies), needed by WorkspaceConfigManager.swift's
/// isRunTestsCommandAllowed(_:workspacePath:) check.
public enum ValidationCommandPolicy {
    public static func isAllowed(_ command: String) -> Bool {
        isAssertionCommandAllowed(command, workspacePath: nil)
    }

    public static func isRunTestsCommandAllowed(_ command: String, workspacePath: String?) -> Bool {
        isAllowed(command, workspacePath: workspacePath, allowsFileAssertions: false)
    }

    public static func isAssertionCommandAllowed(_ command: String, workspacePath: String?) -> Bool {
        isAllowed(command, workspacePath: workspacePath, allowsFileAssertions: true)
    }

    /// The lowercased root command token (e.g. `"swift"` from `'swift' test` or
    /// `SWIFT BUILD`), using the exact same quote-aware tokenizer and lowercasing
    /// this policy's own allowlist check uses. `nil` if the command doesn't
    /// parse. Callers that need to reason about a SPECIFIC allowed root (e.g. to
    /// apply tool-specific handling downstream of the allowlist) should use this
    /// rather than re-splitting the raw string, so they can't drift from what
    /// the allowlist itself actually matched (a raw split would miss a quoted
    /// or differently-cased root this policy already allows through).
    public static func rootToken(of command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsedCommand = parseShellCommand(trimmed) else { return nil }
        return parsedCommand.tokens.first?.lowercased()
    }

    private static func isAllowed(
        _ command: String,
        workspacePath: String?,
        allowsFileAssertions: Bool
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedCommand = parseShellCommand(trimmed) else {
            return false
        }
        let tokens = parsedCommand.tokens
        guard !trimmed.isEmpty,
              !parsedCommand.containsUnsafeShellSyntax,
              let root = tokens.first?.lowercased() else {
            return false
        }

        let allowedExactRoots: Set<String> = [
            "pytest",
            "npm",
            "yarn",
            "pnpm",
            "swift",
            "xcodebuild",
            "make"
        ]
        if allowedExactRoots.contains(root) {
            return commandArgumentsAreValidationOrBuildOnly(root: root, tokens: tokens, workspacePath: workspacePath)
        }
        if allowsFileAssertions, root == "test" || root == "[" {
            return fileTestCommandIsAllowed(root: root, tokens: tokens)
        }
        if root == "python" || root == "python3" {
            return pythonCommandRunsPytest(root: root, tokens: tokens, workspacePath: workspacePath)
        }
        return false
    }

    private struct ParsedShellCommand {
        public var tokens: [String]
        public var containsUnsafeShellSyntax: Bool
    }

    private static func parseShellCommand(_ command: String) -> ParsedShellCommand? {
        var tokens: [String] = []
        var current = ""
        var isEscaped = false
        var isInSingleQuote = false
        var isInDoubleQuote = false
        var previousDoubleQuotedDollar = false
        var containsUnsafeShellSyntax = false

        func finishToken() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
        }

        for character in command {
            if isEscaped {
                if character == "\n" || character == "\r" {
                    containsUnsafeShellSyntax = true
                }
                current.append(character)
                isEscaped = false
                previousDoubleQuotedDollar = false
                continue
            }
            if character == "\\" && !isInSingleQuote {
                isEscaped = true
                previousDoubleQuotedDollar = false
                continue
            }
            if character == "'" && !isInDoubleQuote {
                isInSingleQuote.toggle()
                previousDoubleQuotedDollar = false
                continue
            }
            if character == "\"" && !isInSingleQuote {
                isInDoubleQuote.toggle()
                previousDoubleQuotedDollar = false
                continue
            }
            if character == "\n" || character == "\r" {
                containsUnsafeShellSyntax = true
            }
            if character.isWhitespace && !isInSingleQuote && !isInDoubleQuote {
                finishToken()
                previousDoubleQuotedDollar = false
                continue
            }
            if isInDoubleQuote {
                if character == "`" || character == "$" || (previousDoubleQuotedDollar && ["(", "{"].contains(character)) {
                    containsUnsafeShellSyntax = true
                }
                previousDoubleQuotedDollar = character == "$"
            } else {
                previousDoubleQuotedDollar = false
            }
            if !isInSingleQuote && !isInDoubleQuote && isUnsafeUnquotedShellCharacter(character) {
                containsUnsafeShellSyntax = true
            }
            current.append(character)
        }
        guard !isEscaped, !isInSingleQuote, !isInDoubleQuote else {
            return nil
        }
        finishToken()
        return ParsedShellCommand(tokens: tokens, containsUnsafeShellSyntax: containsUnsafeShellSyntax)
    }

    private static func isUnsafeUnquotedShellCharacter(_ character: Character) -> Bool {
        switch character {
        case "&", ";", "|", "`", "$", ">", "<", "\n", "\r", "*", "?", "(", ")", "{", "}":
            return true
        default:
            return false
        }
    }

    private static func pythonCommandRunsPytest(root: String, tokens: [String], workspacePath: String?) -> Bool {
        guard tokens.count >= 3 else { return false }
        return tokens[0].lowercased() == root &&
            tokens[1] == "-m" &&
            tokens[2] == "pytest" &&
            !containsDisplayOnlyFlag(tokens.dropFirst(3)) &&
            absolutePathTokensAreScoped(tokens.dropFirst(3), workspacePath: workspacePath)
    }

    private static func commandArgumentsAreValidationOrBuildOnly(
        root: String,
        tokens: [String],
        workspacePath: String?
    ) -> Bool {
        switch root {
        case "swift":
            guard tokens.count >= 2,
                  ["test", "build"].contains(tokens[1]),
                  !containsDisplayOnlyFlag(tokens.dropFirst(2)),
                  !(tokens[1] == "test" && swiftTestHasListSubcommand(tokens.dropFirst(2))),
                  // --disable-sandbox turns off SwiftPM's own internal Seatbelt
                  // confinement (its documented flag for "the caller is already
                  // sandboxed" scenarios). Since ASTRA's own validation floor
                  // also excludes swift-rooted commands from wrapping (they
                  // can't be nested under reliably — see
                  // ValidationService.isSelfSandboxingCommand), allowing this
                  // flag through would let a command run with NEITHER
                  // SwiftPM's sandbox NOR ASTRA's, an explicit way to strip the
                  // one confinement layer that command already had.
                  !tokens.dropFirst(2).contains("--disable-sandbox"),
                  swiftPathOptionsAreScoped(tokens: tokens, workspacePath: workspacePath) else {
                return false
            }
            return true
        case "xcodebuild":
            return xcodebuildHasBuildOrTestAction(tokens, workspacePath: workspacePath)
        case "pytest":
            return !containsDisplayOnlyFlag(tokens.dropFirst()) &&
                absolutePathTokensAreScoped(tokens.dropFirst(), workspacePath: workspacePath)
        case "npm":
            return packageManagerRunsOnlyTestScript(
                tokens: tokens,
                supportsBareForwardedArgs: false,
                workspacePath: workspacePath
            )
        case "yarn", "pnpm":
            return packageManagerRunsOnlyTestScript(
                tokens: tokens,
                supportsBareForwardedArgs: true,
                workspacePath: workspacePath
            )
        case "make":
            return makeRunsOnlyTestTarget(tokens)
        default:
            return false
        }
    }

    private static func containsDisplayOnlyFlag<T: Sequence>(_ tokens: T) -> Bool where T.Element == String {
        let displayOnly = Set([
            "--help", "-h", "-help",
            "--version", "-version",
            "--list-tests",
            "--collect-only", "--co",
            "--show-bin-path",
            "--print-manifest-job-graph",
            "--setup-plan", "--fixtures", "--fixtures-per-test", "--markers"
        ])
        return tokens.contains { displayOnly.contains($0) }
    }

    private static func swiftTestHasListSubcommand(_ tokens: ArraySlice<String>) -> Bool {
        let optionsWithValues: Set<String> = [
            "--filter", "--skip", "--xunit-output", "--parallel-workers",
            "--num-workers", "--configuration", "--package-path"
        ]
        var skipNext = false
        for token in tokens {
            if skipNext {
                skipNext = false
                continue
            }
            if optionsWithValues.contains(token) {
                skipNext = true
                continue
            }
            if token == "list" {
                return true
            }
        }
        return false
    }

    private static func swiftPathOptionsAreScoped(tokens: [String], workspacePath: String?) -> Bool {
        let pathOptions: Set<String> = [
            "--package-path",
            "--build-path",
            "--scratch-path",
            "--cache-path",
            "--config-path"
        ]
        var index = 2
        while index < tokens.count {
            let token = tokens[index]
            if let separator = token.firstIndex(of: "=") {
                let option = String(token[..<separator])
                if pathOptions.contains(option) {
                    let value = String(token[token.index(after: separator)...])
                    guard pathTokenIsScoped(value, workspacePath: workspacePath) else {
                        return false
                    }
                }
            } else if pathOptions.contains(token) {
                guard index + 1 < tokens.count,
                      pathTokenIsScoped(tokens[index + 1], workspacePath: workspacePath) else {
                    return false
                }
                index += 1
            }
            index += 1
        }
        return true
    }

    private static func packageManagerRunsOnlyTestScript(
        tokens: [String],
        supportsBareForwardedArgs: Bool,
        workspacePath: String?
    ) -> Bool {
        guard tokens.count >= 2 else { return false }
        let argumentStart: Int
        if tokens[1] == "test" {
            argumentStart = 2
        } else if tokens.count >= 3, tokens[1] == "run", tokens[2] == "test" {
            argumentStart = 3
        } else {
            return false
        }
        let trailing = tokens.dropFirst(argumentStart)
        guard !trailing.isEmpty else { return true }
        if supportsBareForwardedArgs {
            return !containsDisplayOnlyFlag(trailing) &&
                absolutePathTokensAreScoped(trailing, workspacePath: workspacePath)
        }
        guard trailing.first == "--" else { return false }
        return !containsDisplayOnlyFlag(trailing.dropFirst()) &&
            absolutePathTokensAreScoped(trailing.dropFirst(), workspacePath: workspacePath)
    }

    private static func xcodebuildHasBuildOrTestAction(_ tokens: [String], workspacePath: String?) -> Bool {
        guard !xcodebuildHasInfoOnlyMode(tokens.dropFirst()) else { return false }
        let optionsWithValues: Set<String> = [
            "-project", "-workspace", "-scheme", "-destination", "-configuration", "-sdk",
            "-derivedDataPath", "-resultBundlePath", "-resultBundleVersion",
            "-clonedSourcePackagesDirPath", "-archivePath", "-only-testing",
            "-skip-testing", "-testPlan", "-testProductsPath", "-xctestrun", "-toolchain"
        ]
        let allowedActions = Set(["test", "build", "build-for-testing", "test-without-building"])
        var skipNext = false
        var hasBuildOrTestAction = false
        for (offset, token) in tokens.dropFirst().enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if optionsWithValues.contains(token) {
                let valueIndex = offset + 2
                guard valueIndex < tokens.count else { return false }
                if xcodebuildPathOptions.contains(token),
                   !pathTokenIsScoped(tokens[valueIndex], workspacePath: workspacePath) {
                    return false
                }
                skipNext = true
                continue
            }
            if allowedActions.contains(token) {
                hasBuildOrTestAction = true
                continue
            }
            if token.hasPrefix("-") {
                continue
            }
            if isXcodebuildBuildSettingAssignment(token),
               absolutePathFragments(in: token).allSatisfy({ pathTokenIsScoped($0, workspacePath: workspacePath) }) {
                continue
            }
            return false
        }
        return hasBuildOrTestAction
    }

    private static func isXcodebuildBuildSettingAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
            return false
        }
        return token[..<separator].allSatisfy { character in
            character.isLetter || character.isNumber || character == "_"
        }
    }

    private static var xcodebuildPathOptions: Set<String> {
        [
            "-project", "-workspace", "-derivedDataPath", "-resultBundlePath",
            "-clonedSourcePackagesDirPath", "-archivePath", "-testProductsPath", "-xctestrun"
        ]
    }

    private static func xcodebuildHasInfoOnlyMode(_ tokens: ArraySlice<String>) -> Bool {
        let infoOnlyModes = Set([
            "-showBuildSettings", "-showdestinations", "-list", "-version", "-showsdks", "-usage", "-help"
        ])
        return tokens.contains { infoOnlyModes.contains($0) }
    }

    private static func makeRunsOnlyTestTarget(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2, tokens[1] == "test" else {
            return false
        }
        var index = 2
        while index < tokens.count {
            let token = tokens[index]
            if isMakeVariableAssignment(token) {
                return false
            }
            switch safeMakePostTargetOptionTokenStride(tokens, index: index) {
            case let stride where stride > 0:
                index += stride
            default:
                return false
            }
        }
        return true
    }

    private static func safeMakePostTargetOptionTokenStride(_ tokens: [String], index: Int) -> Int {
        let token = tokens[index]
        let safeStandaloneOptions: Set<String> = [
            "-k", "--keep-going",
            "-s", "--silent", "--quiet",
            "--no-print-directory"
        ]
        if safeStandaloneOptions.contains(token) {
            return 1
        }
        if ["-j", "--jobs"].contains(token),
           index + 1 < tokens.count,
           tokens[index + 1].allSatisfy(\.isNumber) {
            return 2
        }
        if token.hasPrefix("-j") {
            let value = token.dropFirst(2)
            return !value.isEmpty && value.allSatisfy(\.isNumber) ? 1 : 0
        }
        if token.hasPrefix("--jobs=") {
            let value = token.dropFirst("--jobs=".count)
            return !value.isEmpty && value.allSatisfy(\.isNumber) ? 1 : 0
        }
        return 0
    }

    private static func isMakeVariableAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
            return false
        }
        let name = token[..<separator]
        guard name.allSatisfy({ character in
            character.isLetter || character.isNumber || character == "_"
        }) else {
            return false
        }
        return true
    }

    private static func fileTestCommandIsAllowed(root: String, tokens: [String]) -> Bool {
        let testTokens: ArraySlice<String>
        if root == "[" {
            guard tokens.last == "]" else { return false }
            testTokens = tokens.dropFirst().dropLast()
        } else {
            testTokens = tokens.dropFirst()
        }
        guard testTokens.count == 2,
              let operatorToken = testTokens.first,
              ["-e", "-f", "-d", "-s"].contains(operatorToken),
              let pathToken = testTokens.last,
              !pathToken.isEmpty else {
            return false
        }
        return fileTestPathIsWorkspaceRelative(pathToken)
    }

    private static func fileTestPathIsWorkspaceRelative(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.hasPrefix("-"),
              !path.hasPrefix("=") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }

    private static func absolutePathTokensAreScoped<T: Sequence>(
        _ tokens: T,
        workspacePath: String?
    ) -> Bool where T.Element == String {
        tokens.allSatisfy { token in
            let paths = absolutePathFragments(in: token)
            guard !paths.isEmpty else {
                return true
            }
            return paths.allSatisfy { pathTokenIsScoped($0, workspacePath: workspacePath) }
        }
    }

    private static func absolutePathFragments(in token: String) -> [String] {
        var fragments: [String] = []
        if token.hasPrefix("/") || token.hasPrefix("~") {
            fragments.append(token)
        }
        if let separator = token.firstIndex(of: "=") {
            let value = String(token[token.index(after: separator)...])
            if value.hasPrefix("/") || value.hasPrefix("~") {
                fragments.append(value)
            }
        }
        return fragments
    }

    private static func pathTokenIsScoped(_ path: String, workspacePath: String?) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("~"),
              !path.hasPrefix("-"),
              !path.hasPrefix("=") else {
            return false
        }

        if path.hasPrefix("/") {
            guard let workspacePath else {
                return false
            }
            let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
            let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
            return candidate == workspace || candidate.hasPrefix(workspace + "/")
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }
}
