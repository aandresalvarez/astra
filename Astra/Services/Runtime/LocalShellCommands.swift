import Foundation

/// Whether a shell command is known local work.
///
/// Ask asks before anything that acts outside ASTRA, Custom's per-item rules
/// govern only local work, and Auto records what Ask would have asked about
/// (`ExternalActionPolicy`). A shell string cannot in general be shown to act
/// outside this machine — a variable, an alias, `eval`, a runner or one more
/// option changes what runs — so this does not look for such actions. It
/// answers the opposite question from a fixed list: a command is local only
/// when every command in it is a listed tool used in a listed way. Anything
/// this does not read (a substitution, an unknown option, an unlisted
/// program) is not local, so a mistake costs a question, never an unasked
/// action.
///
/// The list judges the command, not the program the command runs: `make`,
/// `swift test`, `npm run build`, `python3 scripts/report.py` and `docker run`
/// execute project code or an image, and what that code does is the
/// project's (`docs/security/security-boundaries.md`).
///
/// So it guarantees that an action the command itself expresses asks; it is
/// not a boundary against code that hides one. Writing a script and running
/// it is local, and an option or variable that names a program to run is the
/// same capability. Forms of that it knows are rejected because it is free
/// to, but containing hidden actions is the sandbox's job (spec decision 14).
enum LocalShellCommands {
    static func isLocal(_ command: String) -> Bool {
        isLocal(command, depth: 0)
    }

    /// The simple commands of a shell string, each as its words with quotes
    /// removed, or nil when the string holds what this does not read: an
    /// unterminated quote, substitution or here document. Separators (`;`,
    /// `&&`, `||`, `|`, `&`, newlines, parentheses) end a command,
    /// redirections with their files are dropped, and a substitution stands
    /// as the word `$(…)` (`parse` keeps its body).
    static func simpleCommands(_ command: String) -> [[String]]? {
        parse(command)?.commands
    }

    /// The simple commands that are not known local work, substitution bodies
    /// included, or nil when the string cannot be read.
    static func commandsOutsideTheList(_ command: String) -> [[String]]? {
        commandsOutsideTheList(command, depth: 0)
    }

    private static func commandsOutsideTheList(_ command: String, depth: Int) -> [[String]]? {
        guard depth < maximumDepth, let parsed = parse(command) else { return nil }
        var outside = parsed.commands.filter { !isLocalCommand($0, depth: depth) }
        for body in parsed.substitutions {
            guard let inner = commandsOutsideTheList(body, depth: depth + 1) else { return nil }
            outside += inner
        }
        return outside
    }

    /// The commands a shell string runs: its simple commands, and the bodies
    /// of its command and process substitutions (`$(…)`, `` `…` ``, `<(…)`),
    /// which run too, even inside double quotes or an unquoted here document.
    private static func parse(_ command: String) -> (commands: [[String]], substitutions: [String])? {
        var substitutions: [String] = []
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var wordStarted = false
        var wordQuoted = false
        // An unquoted `*`, `?`, `[` or `{` where an option could begin: the
        // shell may expand it into a file named like one (`--pastebin=all`).
        var wordGlobsIntoOption = false
        var wordBraceAtOptionPosition = false
        var opensSocket = false
        var inSingle = false
        var inDouble = false
        var redirectionTarget = false
        var heredocDelimiterNext: Bool?
        var pendingHeredocs: [(delimiter: String, expands: Bool, stripsTabs: Bool)] = []

        func endWord() {
            defer {
                word = ""
                wordStarted = false
                wordQuoted = false
                wordGlobsIntoOption = false
                wordBraceAtOptionPosition = false
            }
            guard wordStarted else { return }
            if let stripsTabs = heredocDelimiterNext {
                pendingHeredocs.append((word, !wordQuoted, stripsTabs))
                heredocDelimiterNext = nil
            } else if redirectionTarget {
                redirectionTarget = false
                // Bash opens `/dev/tcp/HOST/PORT` and `/dev/udp/…` as sockets:
                // a redirection there sends to another machine.
                if word.hasPrefix("/dev/tcp/") || word.hasPrefix("/dev/udp/") { opensSocket = true }
            } else {
                // Marked as an expansion, which is judged where an option could stand.
                // `{a,b}` and `{1..3}` expand; a lone `{}` (find's placeholder) does not.
                let braceExpands = wordBraceAtOptionPosition && (word.contains(",") || word.contains(".."))
                words.append(wordGlobsIntoOption || braceExpands ? "$" + word : word)
            }
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }

        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inSingle {
                if character == "'" { inSingle = false } else { word.append(character) }
                index += 1
                continue
            }
            if inDouble {
                if character == "\\", let next, "$`\"\\\n".contains(next) {
                    if next != "\n" { word.append(next) }
                    index += 2
                    continue
                }
                if character == "`" || (character == "$" && next == "(") {
                    guard let end = substitution(in: characters, at: index, into: &substitutions) else { return nil }
                    word.append("$(…)")
                    index = end
                    continue
                }
                if character == "\"" { inDouble = false } else { word.append(character) }
                index += 1
                continue
            }
            switch character {
            case "\\":
                guard let next else { return nil }
                if next != "\n" {
                    word.append(next)
                    wordStarted = true
                }
                index += 2
                continue
            case "'":
                inSingle = true
                wordStarted = true
                wordQuoted = true
            case "\"":
                inDouble = true
                wordStarted = true
                wordQuoted = true
            case "`", "$" where next == "(":
                guard let end = substitution(in: characters, at: index, into: &substitutions) else { return nil }
                word.append("$(…)")
                wordStarted = true
                index = end
                continue
            case "#" where !wordStarted:
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            case " ", "\t":
                endWord()
            case "\n":
                endCommand()
                index += 1
                if !pendingHeredocs.isEmpty {
                    guard let end = skipHeredocBodies(pendingHeredocs, in: characters, from: index, into: &substitutions) else {
                        return nil
                    }
                    pendingHeredocs = []
                    index = end
                }
                continue
            case ";":
                endCommand()
            case "&" where next == ">":
                endWord()
                index += 2
                if index < characters.count, characters[index] == ">" { index += 1 }
                redirectionTarget = true
                continue
            case "&":
                endCommand()
                if next == "&" { index += 1 }
            case "|":
                endCommand()
                if next == "|" || next == "&" { index += 1 }
            case "(", ")":
                endCommand()
            case ">" where next == "(", "<" where next == "(":
                // A process substitution is a file name whose body runs.
                guard let end = substitution(in: characters, at: index, into: &substitutions) else { return nil }
                endWord()
                words.append("$(…)")
                index = end
                continue
            case ">", "<":
                // A run of digits right before it names the descriptor.
                if wordStarted, !wordQuoted, word.allSatisfy(\.isNumber) {
                    word = ""
                    wordStarted = false
                } else {
                    endWord()
                }
                index += 1
                if character == "<", next == "<" {
                    index += 1
                    if index < characters.count, characters[index] == "<" {
                        // A here string: its word is data, not a command.
                        index += 1
                        redirectionTarget = true
                        continue
                    }
                    var stripsTabs = false
                    if index < characters.count, characters[index] == "-" {
                        stripsTabs = true
                        index += 1
                    }
                    heredocDelimiterNext = stripsTabs
                    continue
                }
                if index < characters.count, characters[index] == "&" {
                    // `2>&1`, `>&-`: a descriptor, not a file.
                    index += 1
                    var duplicated = false
                    while index < characters.count, characters[index].isNumber || characters[index] == "-" {
                        index += 1
                        duplicated = true
                    }
                    redirectionTarget = !duplicated
                    continue
                }
                if index < characters.count, characters[index] == ">" || characters[index] == "|" {
                    index += 1
                }
                redirectionTarget = true
                continue
            default:
                if "*?[".contains(character), word.allSatisfy({ $0 == "-" }) { wordGlobsIntoOption = true }
                if character == "{", word.allSatisfy({ $0 == "-" }) { wordBraceAtOptionPosition = true }
                word.append(character)
                wordStarted = true
            }
            index += 1
        }
        guard !inSingle, !inDouble, heredocDelimiterNext == nil else { return nil }
        endCommand()
        guard pendingHeredocs.isEmpty, !redirectionTarget, !opensSocket else { return nil }
        return (commands, substitutions)
    }

    /// Reads the substitution opening at `start` (`$(`, `<(`, `>(` or a
    /// backtick), keeps its body, and returns the index after it; nil when it
    /// does not close. `$((…))` is arithmetic and runs no command unless it
    /// holds a substitution of its own.
    private static func substitution(in characters: [Character], at start: Int, into bodies: inout [String]) -> Int? {
        if characters[start] == "`" {
            var body = ""
            var index = start + 1
            while index < characters.count {
                let character = characters[index]
                if character == "\\", index + 1 < characters.count {
                    body.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "`" {
                    bodies.append(body)
                    return index + 1
                }
                body.append(character)
                index += 1
            }
            return nil
        }
        let open = start + 1
        var depth = 1
        var quote: Character?
        var index = open + 1
        while index < characters.count {
            let character = characters[index]
            if character == "\\", quote != "'" {
                index += 2
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    let body = String(characters[(open + 1)..<index])
                    if body.hasPrefix("(") {
                        guard !body.contains("$(") && !body.contains("`") else { return nil }
                    } else {
                        bodies.append(body)
                    }
                    return index + 1
                }
            }
            index += 1
        }
        return nil
    }

    /// The index after the here documents' bodies, which start at `start`,
    /// keeping the substitutions an unquoted one expands; nil when one has no
    /// terminator or an unclosed substitution.
    private static func skipHeredocBodies(
        _ heredocs: [(delimiter: String, expands: Bool, stripsTabs: Bool)],
        in characters: [Character],
        from start: Int,
        into substitutions: inout [String]
    ) -> Int? {
        var index = start
        for heredoc in heredocs {
            var terminated = false
            while index < characters.count {
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                var line = String(characters[index..<end])
                index = min(end + 1, characters.count)
                if heredoc.stripsTabs { line = String(line.drop { $0 == "\t" }) }
                if line == heredoc.delimiter {
                    terminated = true
                    break
                }
                if heredoc.expands {
                    let text = Array(line)
                    var position = 0
                    while position < text.count {
                        if text[position] == "\\" {
                            position += 2
                        } else if text[position] == "`" || (text[position] == "$" && position + 1 < text.count && text[position + 1] == "(") {
                            guard let end = substitution(in: text, at: position, into: &substitutions) else { return nil }
                            position = end
                        } else {
                            position += 1
                        }
                    }
                }
            }
            guard terminated else { return nil }
        }
        return index
    }

    private static let maximumDepth = 4

    private static func isLocal(_ command: String, depth: Int) -> Bool {
        guard depth < maximumDepth, let parsed = parse(command) else { return false }
        // After a `cd` out of the working directory, a relative program path
        // no longer names a project file. The root of the working
        // directory's own repository is still the project.
        let toRepositoryRoot = parsed.substitutions.allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "git rev-parse --show-toplevel"
        }
        let leavesWorkingDirectory = parsed.commands.contains { words in
            ["cd", "pushd", "popd"].contains(words.first ?? "")
                && (words.count == 1 || words.dropFirst().contains { word in
                    !(word == "$(…)" && toRepositoryRoot)
                        && (word.hasPrefix("/") || word.hasPrefix("~") || word.contains("..") || word.contains("$") || word == "-")
                })
        }
        if leavesWorkingDirectory, parsed.commands.contains(where: { runsRelativeProgramFile($0) || runsDirectorysCode($0) }) {
            return false
        }
        return parsed.commands.allSatisfy { isLocalCommand($0, depth: depth) }
            && parsed.substitutions.allSatisfy { isLocal($0, depth: depth + 1) }
    }

    /// A relative program path, or the script an interpreter runs, which
    /// resolve against the working directory.
    private static func runsRelativeProgramFile(_ words: [String]) -> Bool {
        let command = words.drop(while: isAssignment)
        guard let program = command.first else { return false }
        let relative: (String) -> Bool = { $0.contains("/") && !$0.hasPrefix("/") && !$0.hasPrefix("~") }
        if relative(program) { return true }
        let interpreters: Set<String> = ["python", "python3", "node", "ruby", "perl", "sh", "bash", "zsh", "dash", "ksh", "swift"]
        guard interpreters.contains((program as NSString).lastPathComponent) else { return false }
        return command.dropFirst().first { !$0.hasPrefix("-") }.map(relative) ?? false
    }

    /// A tool that runs the code of the directory it is in: a build, test or
    /// package tool, `python -m`, or `git`, whose repository configuration
    /// names programs (`core.fsmonitor`, hooks).
    private static func runsDirectorysCode(_ words: [String]) -> Bool {
        let command = words.drop(while: isAssignment)
        guard let program = command.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
        return projectCodeRunners.contains(program) || program == "git"
            || (["python", "python3"].contains(program) && command.contains("-m"))
    }

    /// One simple command: shell grammar and assignments first, then the
    /// program and its arguments.
    private static func isLocalCommand(_ words: [String], depth: Int) -> Bool {
        guard depth < maximumDepth else { return false }
        var words = words[...]
        while let first = words.first {
            if ["!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while", "until"].contains(first) {
                words = words.dropFirst()
            } else if first == "time" {
                words = words.dropFirst()
                if words.first == "-p" { words = words.dropFirst() }
            } else if isAssignment(first) {
                // A variable set for the command that follows is that
                // program's environment, so only a listed name is local; a
                // standalone assignment only steers the shell.
                let setsAProgramsEnvironment = words.dropFirst().contains { !isAssignment($0) }
                guard setsAProgramsEnvironment ? isListedEnvironmentAssignment(first) : isLocalAssignment(first) else {
                    return false
                }
                words = words.dropFirst()
            } else {
                break
            }
        }
        guard let program = words.first else { return true }
        let args = Array(words.dropFirst())
        switch program {
        case "for":
            // `for name in words`: the words are values, the body is its own command.
            return true
        case "export", "readonly", "declare", "typeset", "local":
            // `-n` makes a name a reference to another variable (`PATH`).
            // A name exported (`export`, `declare -x`), whether assigned here
            // or before, is every later program's environment.
            let exports = program == "export" || args.contains { $0.hasPrefix("-") && $0.contains("x") }
            let names = args.filter { !$0.hasPrefix("-") && !$0.hasPrefix("+") }
            return !args.contains { $0.hasPrefix("-") && $0.contains("n") }
                && (exports ? names.allSatisfy(isListedEnvironmentAssignment) : names.filter(isAssignment).allSatisfy(isLocalAssignment))
        case "set":
            // `-a`/`allexport` exports every assignment after it.
            return !args.contains { ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("a")) || $0 == "allexport" }
        case "read", "getopts", "printf", "let":
            // Builtins that assign to the variables they name (`read PATH`,
            // `printf -v PATH`, `let PATH=…`): each name is judged as an
            // assignment would be.
            return args.allSatisfy { word in
                let name = String(word.prefix { $0 != "=" })
                return name.hasPrefix("-") || isLocalAssignment(name + "=")
            }
        case "hash":
            // `hash -p PATH NAME` points a command name at another program.
            return !args.contains { $0.hasPrefix("-") && $0.contains("p") }
        default:
            return isLocalProgram(program, args: args, depth: depth)
        }
    }

    private static func isAssignment(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil
    }

    /// A variable of the command's own, or one that only tunes a local
    /// program. A name tools read to pick which program runs, what it loads,
    /// which configuration or credentials it uses, or where it sends requests
    /// (`PATH`, `HOME`, `GIT_SSH_COMMAND`, `DOCKER_HOST`, `NODE_OPTIONS`,
    /// `HTTPS_PROXY`) is not; zsh ties `path` to `PATH`, so case is ignored.
    private static func isLocalAssignment(_ word: String) -> Bool {
        let name = String(word.prefix { $0 != "=" && $0 != "+" }).uppercased()
        if localEnvironmentNames.contains(name) || name.hasPrefix("LC_") { return true }
        return !toolSteeringNames.contains(name) && !toolSteeringPrefixes.contains(where: name.hasPrefix)
    }

    /// A variable on the list of ones that only tune a local program; any
    /// other can be a tool's configuration (`RIPGREP_CONFIG_PATH`).
    private static func isListedEnvironmentAssignment(_ word: String) -> Bool {
        let name = String(word.prefix { $0 != "=" && $0 != "+" }).uppercased()
        return localEnvironmentNames.contains(name) || name.hasPrefix("LC_")
    }

    /// The values of the named options, in either spelling (`-f FILE`,
    /// `-fFILE`, `--file=FILE`).
    private static func optionOperands(_ args: [String], names: Set<String>) -> [String] {
        var values: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if names.contains(arg) {
                values.append(index < args.count ? args[index] : "-")
                index += 1
            } else if let name = names.first(where: { $0.hasPrefix("--") && arg.hasPrefix($0 + "=") }) {
                values.append(String(arg.dropFirst(name.count + 1)))
            } else if let name = names.first(where: { !$0.hasPrefix("--") && arg.hasPrefix($0) && arg.count > $0.count && !arg.hasPrefix("--") }) {
                values.append(String(arg.dropFirst(name.count)))
            }
        }
        return values
    }

    private static let toolSteeringNames: Set<String> = [
        "PATH", "HOME", "IFS", "CDPATH", "ENV", "BASH_ENV", "SHELLOPTS", "BASHOPTS", "PS4", "PROMPT_COMMAND",
        "ZDOTDIR", "SHELL", "EDITOR", "VISUAL", "PAGER", "MANPAGER", "LESSOPEN", "LESSCLOSE", "BROWSER", "HTTP_PROXY", "HTTPS_PROXY",
        "ALL_PROXY", "NO_PROXY", "FTP_PROXY", "CC", "CXX", "LD", "MAKEFLAGS", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS"
    ]

    private static let toolSteeringPrefixes = [
        "LD_", "DYLD_", "GIT_", "DOCKER_", "NODE_", "NPM_", "YARN_", "PNPM_", "BUN_", "PYTHON", "PIP_", "UV_",
        "PERL", "RUBY", "GEM_", "BUNDLE_", "CARGO_", "RUST", "GO", "SSH_", "GH_", "GITHUB_", "AWS_", "AZURE_",
        "GOOGLE_", "CLOUDSDK_", "KUBE", "HELM_", "TF_", "CURL_", "WGET", "XDG_", "HOMEBREW_", "OPENSSL_", "SSL_",
        "REQUESTS_", "SWIFT", "XCODE", "ASTRA_", "ANTHROPIC_", "OPENAI_", "CLAUDE_", "COPILOT_", "CODEX_"
    ]

    private static let localEnvironmentNames: Set<String> = [
        "CI", "DEBUG", "VERBOSE", "NODE_ENV", "RUST_LOG", "RUST_BACKTRACE", "PYTHONUNBUFFERED",
        "PYTHONDONTWRITEBYTECODE", "PYTHONHASHSEED", "LANG", "LANGUAGE", "TZ", "TERM", "NO_COLOR", "FORCE_COLOR",
        "CLICOLOR", "CLICOLOR_FORCE", "COLUMNS", "LINES", "CGO_ENABLED", "GOOS", "GOARCH", "DEVELOPER_DIR",
        "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "TMPDIR", "GIT_TERMINAL_PROMPT", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
        "GIT_AUTHOR_DATE", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_COMMITTER_DATE", "HOMEBREW_NO_AUTO_UPDATE",
        "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_ENV_HINTS", "PIP_DISABLE_PIP_VERSION_CHECK"
    ]

    private static func isLocalProgram(_ program: String, args: [String], depth: Int) -> Bool {
        guard !program.contains("$") else { return false }
        var name = program
        if program.contains("/") {
            // A relative path is a program file of the project, like a build
            // script; an absolute one is judged by its name only in a system
            // directory, where the name means the listed tool.
            // A `..` step can leave the project.
            guard program.hasPrefix("/") || program.hasPrefix("~") else {
                return !program.split(separator: "/").contains("..")
            }
            let directory = (program as NSString).deletingLastPathComponent
            guard ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/sbin", "/sbin"].contains(directory) else {
                return false
            }
            name = (program as NSString).lastPathComponent
        }
        if plainLocalPrograms.contains(name) { return true }
        // A word the shell expands can become any option (`rg "$OPT"` with
        // `OPT=--pre=…`), so a program whose options are judged is not local
        // with one where an option could stand, only as an option's value.
        if hasExpansionWhereAnOptionCouldBe(args) { return false }
        if projectCodeRunners.contains(name), !pathsStayInTheProject(args) { return false }
        switch name {
        case "awk":
            return awkIsLocal(args)
        case "codesign":
            // `--timestamp` asks a timestamp service on the network; only
            // `--timestamp=none` keeps the signature on this machine.
            return !args.contains { $0.hasPrefix("--timestamp") && $0 != "--timestamp=none" }
        case "make", "gmake":
            // `--eval` adds a rule, recipe included, from the command line, and
            // a variable set there can name what a recipe runs.
            // `-f FILE` and `-C DIR` pick the recipes that run, so they are
            // judged as an interpreter's script is.
            return !args.contains { $0 == "-E" || $0.hasPrefix("--eval") || ($0.hasPrefix("-E") && !$0.hasPrefix("--")) }
                && args.filter(isAssignment).allSatisfy { localEnvironmentNames.contains(String($0.prefix { $0 != "=" })) }
                && optionOperands(args, names: ["-f", "--file", "--makefile", "-C", "--directory"]).allSatisfy(isProjectScript)
        case "cmake":
            // `cmake -E env …` runs a program, in `cmake --build` the words
            // after `--` go to the native tool (`make --eval=…`), and `-P FILE`
            // runs a script, judged as an interpreter's is.
            if let script = args.firstIndex(of: "-P"), !(script + 1 < args.count && isProjectScript(args[script + 1])) {
                return false
            }
            return !args.contains("-E") && !(args.contains("--build") && args.contains("--"))
        case "ctest":
            return ctestIsLocal(args)
        case "swiftc", "clang", "clang++", "cc", "gcc", "g++", "rustc", "ld":
            return !loadsCompilerPlugin(args)
        case "pytest":
            return pytestIsLocal(args)
        case "ninja", "xcodegen", "eslint", "prettier", "jest", "vitest", "mypy", "flake8", "pylint":
            // Their paths stay in the project (above); a configuration given
            // inline (`jest --config '{…}'`) or pylint's `--init-hook` is code
            // on the command line.
            return !args.contains { $0.hasPrefix("{") || $0.contains("={") || $0.hasPrefix("--init-hook") }
        case "sed":
            return sedIsLocal(args)
        case "split":
            // GNU `--filter` writes each piece through a shell command.
            return !args.contains { $0.hasPrefix("--filter") }
        case "ag":
            return !args.contains { $0.hasPrefix("--pager") }
        case "rg":
            // `--pre` runs a program on every file searched, `--hostname-bin`
            // one for hyperlinks.
            return !args.contains { arg in
                ["--pre", "--hostname-bin"].contains { arg == $0 || arg.hasPrefix($0 + "=") }
            }
        case "sort":
            return !args.contains { $0.hasPrefix("--compress-program") }
        case "tar":
            return tarIsLocal(args)
        case "fd":
            return fdIsLocal(args, depth: depth)
        case "find":
            return findIsLocal(args, depth: depth)
        case "xargs", "env", "nice", "nohup", "timeout", "command", "builtin", "exec", "caffeinate":
            return runnerIsLocal(name, args: args, depth: depth)
        case "git":
            return gitIsLocal(args)
        case "gh":
            return gitHubCLIIsLocal(args)
        case "curl":
            return curlIsLocal(args)
        case "wget":
            return wgetIsLocal(args)
        case "docker":
            return dockerIsLocal(args)
        case "npm", "pnpm", "yarn", "bun":
            return packageManagerIsLocal(name, args: args)
        case "pip", "pip3":
            return pipIsLocal(args)
        case "uv":
            return uvIsLocal(args, depth: depth)
        case "python", "python3":
            return pythonIsLocal(args)
        case "node":
            return nodeIsLocal(args)
        case "ruby", "perl":
            return args.first.map(isProjectScript) ?? false
        case "sh", "bash", "zsh", "dash", "ksh":
            return shellIsLocal(args, depth: depth)
        case "swift":
            return swiftIsLocal(args)
        case "cargo":
            return cargoIsLocal(args)
        case "go":
            return goIsLocal(args)
        case "brew":
            return args.first.map(localBrewCommands.contains) ?? true
        case "xcrun":
            return xcrunIsLocal(args, depth: depth)
        case "xcodebuild":
            return xcodebuildIsLocal(args)
        case BrowserBridgeMCPProjection.toolCommand:
            return args.first.map { !ShelfBrowserBridgeCommandRouter.commandChangesPage($0) } ?? true
        default:
            return false
        }
    }

    private static func hasExpansionWhereAnOptionCouldBe(_ args: [String]) -> Bool {
        let valueOptions: Set<String> = [
            "-m", "--message", "-F", "--file", "-f", "-o", "--output", "-C", "-g", "--glob", "-e", "--regexp",
            "-b", "--branch", "-n", "-name", "-iname", "-path", "-ipath", "-regex", "--include", "--exclude", "-type"
        ]
        return args.indices.contains { index in
            let word = args[index]
            guard let dollar = word.firstIndex(of: "$"), word[..<dollar].allSatisfy({ $0 == "-" }) else { return false }
            return index == 0 || !valueOptions.contains(args[index - 1])
        }
    }

    /// Programs that only read or change files and processes on this machine,
    /// whatever their arguments, plus the shell's own builtins.
    private static let plainLocalPrograms: Set<String> = [
        // Shell builtins and keywords.
        ":", "true", "false", "test", "[", "[[", "]]", "echo", "pwd", "cd", "pushd", "popd", "dirs",
        "wait", "sleep", "exit", "return", "break", "continue", "shift", "shopt", "unset", "type",
        "which", "whereis", "jobs", "umask",
        // Files and text.
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "tree", "cut", "tr",
        "uniq", "diff", "cmp", "comm", "jq", "yq", "xxd", "od", "hexdump", "file", "stat", "du", "df", "basename",
        "dirname", "realpath", "readlink", "mkdir", "rmdir", "touch", "cp", "mv", "rm", "ln", "chmod", "chown",
        "chflags", "xattr", "unzip", "gzip", "gunzip", "zcat", "bzip2", "bunzip2", "xz", "unxz",
        "shasum", "sha1sum", "sha256sum", "md5", "md5sum", "cksum", "base64", "column", "paste", "nl", "fold",
        "expand", "unexpand", "seq", "tee", "ditto", "mktemp", "patch", "iconv", "strings", "rev",
        "tput", "clear",
        // This machine.
        "date", "cal", "whoami", "id", "uname", "hostname", "printenv", "ps", "pgrep", "pkill", "kill", "lsof",
        "sw_vers", "plutil", "defaults", "mdfind", "mdls", "pbcopy", "pbpaste", "uptime", "vm_stat", "sysctl",
        // Formatters and binary tools no argument can make load code; a tool
        // one can (a config, plugin, formatter or test file) is a code runner.
        "swift-format", "swiftlint", "lipo", "otool", "nm", "dwarfdump", "atos", "dsymutil",
        "rustfmt", "gofmt", "tsc", "ruff", "black", "isort"
    ]

    /// A program in `awk` runs commands through `system()` and pipes.
    /// `sed` whose scripts are read command by command: GNU sed's `e`
    /// command and `s///e` flag run a shell command, and a command this does
    /// not know is not local. A script file is the project's code.
    private static func sedIsLocal(_ args: [String]) -> Bool {
        var scripts: [String] = []
        var hasScript = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg.hasPrefix("--") {
                let name = String(arg.prefix { $0 != "=" })
                if name == "--expression" || name == "--file" {
                    let value = arg.contains("=") ? String(arg.drop { $0 != "=" }.dropFirst()) : (index < args.count ? args[index] : "")
                    if !arg.contains("=") { index += 1 }
                    if name == "--file" { guard isProjectScript(value) else { return false } } else { scripts.append(value) }
                    hasScript = true
                } else if ["--version", "--help"].contains(arg) {
                    return true
                } else if !([
                    "--quiet", "--silent", "--regexp-extended", "--separate", "--unbuffered", "--null-data",
                    "--zero-terminated", "--posix", "--sandbox", "--debug", "--follow-symlinks"
                ].contains(arg) || name == "--in-place" || name == "--line-length") {
                    return false
                }
            } else if arg.hasPrefix("-"), arg.count > 1 {
                for (offset, letter) in arg.dropFirst().enumerated() {
                    if "nErsuz".contains(letter) { continue }
                    let rest = String(arg.dropFirst(offset + 2))
                    if letter == "i" {
                        // GNU attaches the backup suffix; BSD sed takes the
                        // next word (`-i ''`, `-i .bak`).
                        if rest.isEmpty, index < args.count, args[index].isEmpty || args[index].hasPrefix(".") { index += 1 }
                        break
                    }
                    guard "efl".contains(letter) else { return false }
                    let value = rest.isEmpty ? (index < args.count ? args[index] : "") : rest
                    if rest.isEmpty { index += 1 }
                    if letter == "e" { scripts.append(value); hasScript = true }
                    if letter == "f" { guard isProjectScript(value) else { return false }; hasScript = true }
                    break
                }
            } else if !hasScript {
                scripts.append(arg)
                hasScript = true
            }
        }
        return hasScript && scripts.allSatisfy(sedScriptIsLocal)
    }

    /// Every command of a sed script is one that edits text or reads and
    /// writes a file; `e`, the `s///e` flag and an unknown command are not.
    private static func sedScriptIsLocal(_ script: String) -> Bool {
        let characters = Array(script)
        var index = 0
        // Past the next unescaped `delimiter`; false when there is none.
        func skip(to delimiter: Character) -> Bool {
            while index < characters.count {
                if characters[index] == "\\" {
                    index += 2
                } else {
                    index += 1
                    if characters[index - 1] == delimiter { return true }
                }
            }
            return false
        }
        func skip(while matches: (Character) -> Bool) {
            while index < characters.count, matches(characters[index]) { index += 1 }
        }
        while index < characters.count {
            if " \t\n;}".contains(characters[index]) {
                index += 1
                continue
            }
            // Addresses: a line, `$`, a step, `/re/` or `\cREc`, a range,
            // GNU's `I`/`M` modifiers, then `!`.
            while index < characters.count {
                let character = characters[index]
                if character.isNumber || "$~+, \tIM!".contains(character) {
                    index += 1
                } else if character == "/" {
                    index += 1
                    guard skip(to: "/") else { return false }
                } else if character == "\\", index + 1 < characters.count {
                    index += 2
                    guard skip(to: characters[index - 1]) else { return false }
                } else {
                    break
                }
            }
            guard index < characters.count else { return true }
            let command = characters[index]
            index += 1
            switch command {
            case "{", "=", "d", "D", "g", "G", "h", "H", "n", "N", "p", "P", "x", "z", "F":
                continue
            case "q", "Q", "l", "L":
                skip { $0.isNumber || $0 == " " }
            case "a", "i", "c", "r", "R", "w", "W", "#":
                // Text or a file name, to the end of the line.
                skip { $0 != "\n" }
            case ":", "b", "t", "T", "v":
                // A label, which GNU sed ends at `;` as well.
                skip { $0 != "\n" && $0 != ";" }
            case "s", "y":
                guard index < characters.count else { return false }
                let delimiter = characters[index]
                index += 1
                guard skip(to: delimiter), skip(to: delimiter) else { return false }
                guard command == "s" else { continue }
                while index < characters.count, "gpiImM0123456789ew".contains(characters[index]) {
                    if characters[index] == "e" { return false }
                    if characters[index] == "w" {
                        skip { $0 != "\n" }
                        break
                    }
                    index += 1
                }
            default:
                return false
            }
        }
        return true
    }

    private static func awkIsLocal(_ args: [String]) -> Bool {
        var index = 0
        var sawProgramFile = false
        while index < args.count, args[index].hasPrefix("-") {
            // Every program file is judged as an interpreter's script is.
            if args[index] == "-f" {
                guard index + 1 < args.count, isProjectScript(args[index + 1]) else { return false }
                sawProgramFile = true
                index += 2
                continue
            }
            index += ["-F", "-v"].contains(args[index]) ? 2 : 1
        }
        if sawProgramFile { return true }
        guard index < args.count else { return false }
        let program = args[index]
        return !program.contains("system") && !program.contains("|")
    }

    /// `tar` with the options that create, list and extract. One that names a
    /// program to run (`--use-compress-program`, `-I`, `--checkpoint-action`,
    /// `--to-command`) is not listed.
    private static func tarIsLocal(_ args: [String]) -> Bool {
        let letters = Set("cxtrufzjJvpkmOSqaChXTPn")
        let valuedLetters = Set("fCXT")
        let longFlags: Set<String> = [
            "--create", "--extract", "--list", "--append", "--update", "--gzip", "--bzip2", "--xz", "--zstd",
            "--verbose", "--preserve-permissions", "--same-owner", "--no-same-owner", "--keep-old-files",
            "--overwrite", "--totals", "--numeric-owner", "--no-recursion", "--one-file-system", "--dereference",
            "--auto-compress", "--absolute-names"
        ]
        let longValued: Set<String> = [
            "--file", "--directory", "--exclude", "--exclude-from", "--files-from", "--include", "--strip-components",
            "--format"
        ]
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg.hasPrefix("--") {
                let name = String(arg.prefix { $0 != "=" })
                if longFlags.contains(name), !arg.contains("=") { continue }
                guard longValued.contains(name) else { return false }
                if !arg.contains("=") { index += 1 }
            } else if arg.hasPrefix("-") || (index == 1 && !arg.isEmpty && arg.allSatisfy(letters.contains)) {
                // `-czf out.tar`, or the old `czf out.tar`: each value letter
                // takes the next word.
                let cluster = arg.hasPrefix("-") ? arg.dropFirst() : Substring(arg)
                guard !cluster.isEmpty, cluster.allSatisfy(letters.contains) else { return false }
                index += cluster.filter(valuedLetters.contains).count
            }
        }
        return true
    }

    /// `fd` is local when the command its `-x`/`-X` runs is.
    private static func fdIsLocal(_ args: [String], depth: Int) -> Bool {
        // `-xcurl` or a cluster `-Hx` hides the command from the reading below.
        if args.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.count > 2 && ($0.contains("x") || $0.contains("X")) }) {
            return false
        }
        guard let flag = args.firstIndex(where: { ["-x", "--exec", "-X", "--exec-batch"].contains($0) }) else {
            return !args.contains { $0.hasPrefix("--exec") }
        }
        let rest = args.dropFirst(flag + 1)
        let command = Array(rest.prefix { $0 != ";" })
        // fd adds the paths it found, which can read as options, so only a
        // program whose arguments are not judged.
        guard let program = command.first, plainLocalPrograms.contains(program),
              isLocalCommand(command, depth: depth + 1) else { return false }
        return fdIsLocal(Array(rest.dropFirst(command.count + 1)), depth: depth)
    }

    /// `find` is local when each `-exec`/`-ok` command it runs is.
    private static func findIsLocal(_ args: [String], depth: Int) -> Bool {
        var index = 0
        while index < args.count {
            guard ["-exec", "-execdir", "-ok", "-okdir"].contains(args[index]) else {
                index += 1
                continue
            }
            guard let end = args[(index + 1)...].firstIndex(where: { $0 == ";" || $0 == "+" }),
                  isLocalCommand(Array(args[(index + 1)..<end]), depth: depth + 1) else {
                return false
            }
            // `-execdir` and `-okdir` run in each match's directory, where a
            // relative program path is no longer a project file.
            if ["-execdir", "-okdir"].contains(args[index]),
               runsRelativeProgramFile(Array(args[(index + 1)..<end])) {
                return false
            }
            index = end + 1
        }
        return true
    }

    /// A program that runs another one: it is local when its own options are
    /// listed and the program it runs is local.
    private static func runnerIsLocal(_ runner: String, args: [String], depth: Int) -> Bool {
        let flags: Set<String>
        let valued: Set<String>
        switch runner {
        case "xargs":
            flags = ["-0", "-r", "-t", "-x"]
            valued = ["-n", "-L", "-P", "-I", "-d", "-E", "-s"]
        case "env":
            flags = ["-i", "-"]
            valued = ["-u"]
        case "nice":
            flags = []
            valued = ["-n"]
        case "timeout":
            flags = ["--preserve-status", "--foreground", "-v"]
            valued = ["-s", "-k"]
        case "command":
            if args.first == "-v" || args.first == "-V" { return true }
            flags = ["-p"]
            valued = []
        case "caffeinate":
            flags = ["-d", "-i", "-m", "-s", "-u"]
            valued = ["-t", "-w"]
        default:
            flags = []
            valued = []
        }
        var index = 0
        while index < args.count, args[index].hasPrefix("-"), args[index] != "--" {
            let option = args[index]
            if flags.contains(option) {
                index += 1
            } else if valued.contains(option) {
                index += 2
            } else if runner == "xargs", valued.contains(where: { option.hasPrefix($0) && option.count > 2 }) {
                // `-n1`, `-I{}`: the value attached.
                index += 1
            } else {
                return false
            }
        }
        if index < args.count, args[index] == "--" { index += 1 }
        var rest = Array(args.dropFirst(index))
        if runner == "env" {
            // The program's environment, as a prefix assignment is.
            while let first = rest.first, isAssignment(first) {
                guard isListedEnvironmentAssignment(first) else { return false }
                rest.removeFirst()
            }
        }
        if runner == "timeout" {
            guard !rest.isEmpty else { return false }
            rest.removeFirst()
        }
        // `xargs` alone runs `echo`; `env` alone prints the environment.
        guard !rest.isEmpty else { return ["xargs", "env", "caffeinate"].contains(runner) }
        // `xargs` adds words read from its input, unread here, so it runs only
        // a program whose arguments are not judged.
        if runner == "xargs" { return rest.first.map(plainLocalPrograms.contains) ?? false }
        return isLocalCommand(rest, depth: depth + 1)
    }

    // MARK: Git and GitHub

    private static func gitIsLocal(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            let option = args[index]
            // The repository chosen (`-C`, `--git-dir`, `--work-tree`) brings
            // its configuration, which names programs git runs.
            if ["-C", "--git-dir", "--work-tree", "--namespace"].contains(option) {
                guard option == "--namespace" || (index + 1 < args.count && !leavesTheProject(args[index + 1])) else {
                    return false
                }
                index += 2
            } else if ["--no-pager", "-P", "--paginate", "-p", "--bare", "--no-optional-locks", "--literal-pathspecs",
                       "--no-replace-objects", "--version", "--help"].contains(option)
                        || ["--git-dir=", "--work-tree=", "--namespace="].contains(where: option.hasPrefix) && !leavesTheProject(option) {
                index += 1
            } else {
                // `-c`, `--exec-path`, `--config-env`: they change what runs.
                return false
            }
        }
        guard index < args.count else { return true }
        let verb = args[index]
        let rest = Array(args.dropFirst(index + 1))
        switch verb {
        case "rebase":
            // `-x`/`--exec` runs a command after each commit.
            return !rest.contains { $0 == "--exec" || $0.hasPrefix("--exec=") || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("x")) }
        case "submodule":
            return !rest.contains("foreach")
        case "grep":
            // `-O`/`--open-files-in-pager` runs a program on the matches.
            return !rest.contains { $0.hasPrefix("--open-files-in-pager") || ($0.hasPrefix("-O") && !$0.hasPrefix("--")) }
        case "bisect":
            return !rest.contains("run")
        case "config":
            return gitConfigReads(rest)
        case "fetch", "pull", "clone", "ls-remote", "archive":
            // `--upload-pack`, `--exec` and `-u` name a program to run;
            // `-c`/`--config` set configuration that can name one.
            return !rest.contains { arg in
                // In any spelling: `-u/tmp/x`, a cluster `-qu/tmp/x`.
                (arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.dropFirst().contains { "uc".contains($0) })
                    || ["--upload-pack", "--receive-pack", "--exec", "--config"].contains(where: arg.hasPrefix)
            }
        default:
            return localGitVerbs.contains(verb)
        }
    }

    private static let localGitVerbs: Set<String> = [
        "status", "diff", "log", "show", "add", "commit", "checkout", "switch", "restore", "reset", "branch", "tag",
        "stash", "merge", "cherry-pick", "revert", "init", "rm", "mv", "blame", "grep", "ls-files", "ls-tree",
        "rev-parse", "rev-list", "describe", "shortlog", "reflog", "worktree", "remote", "clean", "apply", "am",
        "format-patch", "cat-file", "show-ref", "symbolic-ref", "update-ref", "merge-base", "name-rev", "for-each-ref",
        "notes", "gc", "fsck", "prune", "count-objects", "check-ignore", "check-attr", "version", "help", "range-diff",
        "sparse-checkout", "whatchanged", "diff-tree", "diff-files", "diff-index", "hash-object", "write-tree",
        "read-tree", "commit-tree", "mktree", "update-index", "var", "stripspace", "interpret-trailers",
        "verify-commit", "verify-tag", "mailinfo", "column", "check-ref-format", "show-branch", "cherry"
    ]

    /// `git config` reads a key or lists; setting one can name a program a
    /// later Git command runs (`core.fsmonitor`, `alias.*`, `core.sshCommand`).
    private static func gitConfigReads(_ args: [String]) -> Bool {
        if let first = args.first, ["get", "list"].contains(first) { return true }
        let readOptions: Set<String> = [
            "--get", "--get-all", "--get-regexp", "--list", "-l", "--global", "--local", "--system", "--worktree",
            "--show-origin", "--show-scope", "--name-only", "--bool", "--int", "--path", "-z", "--null", "--includes",
            "--no-includes"
        ]
        var operands = 0
        var index = 0
        while index < args.count {
            let arg = args[index]
            if ["--file", "-f", "--blob", "--default", "--type"].contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                guard readOptions.contains(arg) || arg.hasPrefix("--type=") || arg.hasPrefix("--file=") else { return false }
            } else {
                operands += 1
            }
            index += 1
        }
        let gets = args.contains { ["--get", "--get-all", "--get-regexp"].contains($0) }
        return operands <= (gets ? 2 : 1)
    }

    private static func gitHubCLIIsLocal(_ args: [String]) -> Bool {
        var operands: [String] = []
        var index = 0
        while index < args.count, operands.count < 2 {
            let arg = args[index]
            if ["-R", "--repo"].contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                if operands.isEmpty, !["--version", "--help", "-h", "--repo="].contains(where: arg.hasPrefix) { return false }
            } else {
                operands.append(arg)
            }
            index += 1
        }
        guard let area = operands.first else { return true }
        let verb = operands.count > 1 ? operands[1] : ""
        let reads: Set<String> = ["view", "list", "ls", "status", "checks", "diff"]
        switch area {
        case "status", "help", "version", "search":
            return true
        case "auth":
            return verb == "status"
        case "api":
            guard let apiIndex = args.firstIndex(of: "api") else { return false }
            return gitHubAPIReads(Array(args.dropFirst(apiIndex + 1)))
        case "pr":
            return reads.contains(verb) || verb == "checkout"
        case "repo":
            // Words after `--` go to `git clone` itself (`-c core.sshCommand=…`).
            return reads.contains(verb) || (verb == "clone" && !args.contains("--"))
        case "release", "run":
            return reads.contains(verb) || verb == "download" || verb == "watch"
        case "issue", "workflow", "label", "gist", "cache", "ruleset", "variable", "secret", "project", "org":
            return reads.contains(verb)
        default:
            // An alias or extension runs what its definition says.
            return false
        }
    }

    /// `gh api` reads without fields, with GET, or with a GraphQL query that
    /// holds no `mutation`; fields alone make it a POST.
    private static func gitHubAPIReads(_ args: [String]) -> Bool {
        if args.contains(where: overridesMethod) { return false }
        let flags: Set<String> = ["--paginate", "--slurp", "--include", "-i", "--silent", "--verbose"]
        let valued: Set<String> = ["--jq", "-q", "--template", "-t", "--cache", "--hostname", "--preview", "-p", "--header", "-H"]
        let fields: Set<String> = ["-f", "--raw-field", "-F", "--field"]
        var endpoint: String?
        var fieldValues: [String] = []
        var namesGET = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            let name = arg.hasPrefix("--") ? String(arg.prefix { $0 != "=" }) : arg
            let attached = arg.hasPrefix("--") && arg.contains("=") ? String(arg.drop { $0 != "=" }.dropFirst()) : nil
            if flags.contains(arg) {
                index += 1
            } else if valued.contains(name) {
                index += attached == nil ? 2 : 1
            } else if ["-X", "--method"].contains(name) {
                let value = attached ?? (index + 1 < args.count ? args[index + 1] : "")
                guard ["GET", "HEAD"].contains(value.uppercased()) else { return false }
                namesGET = true
                index += attached == nil ? 2 : 1
            } else if arg.hasPrefix("-X"), arg.count > 2 {
                guard ["GET", "HEAD"].contains(arg.dropFirst(2).uppercased()) else { return false }
                namesGET = true
                index += 1
            } else if fields.contains(name) {
                guard let value = attached ?? (index + 1 < args.count ? args[index + 1] : nil) else { return false }
                fieldValues.append(value)
                index += attached == nil ? 2 : 1
            } else if arg.hasPrefix("-") {
                return false
            } else {
                guard endpoint == nil else { return false }
                endpoint = arg
                index += 1
            }
        }
        // With GET the fields are a query string.
        guard !fieldValues.isEmpty, !namesGET else { return true }
        // GraphQL changes data only through an operation named `mutation`.
        guard endpoint == "graphql" else { return false }
        return fieldValues.allSatisfy { value in
            let fieldValue = value.drop { $0 != "=" }.dropFirst()
            return !fieldValue.hasPrefix("@") && fieldValue.range(of: #"\bmutation\b"#, options: .regularExpression) == nil
        }
    }

    // MARK: Network reads

    /// `curl` with only the options that fetch: no body, no upload, no
    /// config file, and a GET or HEAD method. (`~/.curlrc` is the user's own.)
    /// A header that names another method (`X-HTTP-Method-Override: DELETE`)
    /// turns a GET into whatever the server honours, so a request carrying
    /// one is not a fetch.
    private static func overridesMethod(_ word: String) -> Bool {
        guard let colon = word.firstIndex(of: ":") else { return false }
        return word[..<colon].lowercased().contains("method")
    }

    private static func curlIsLocal(_ args: [String]) -> Bool {
        if args.contains(where: overridesMethod) { return false }
        let flags: Set<Character> = ["s", "S", "L", "f", "I", "i", "v", "k", "O", "J", "q", "N", "g", "4", "6"]
        let valued: Set<Character> = ["o", "w", "A", "H", "m", "X", "u", "e", "r", "C", "x", "b", "c", "y", "Y"]
        let longFlags: Set<String> = [
            "--silent", "--show-error", "--location", "--fail", "--fail-with-body", "--head", "--include", "--verbose",
            "--compressed", "--insecure", "--remote-name", "--remote-header-name", "--remote-name-all", "--create-dirs",
            "--progress-bar", "--no-progress-meter", "--http1.1", "--http2", "--ipv4", "--ipv6", "--globoff",
            "--no-buffer", "--disable", "--fail-early", "--raw", "--no-keepalive"
        ]
        let longValued: Set<String> = [
            "--output", "--write-out", "--user-agent", "--header", "--max-time", "--connect-timeout", "--retry",
            "--retry-delay", "--retry-max-time", "--request", "--url", "--max-redirs", "--cacert", "--resolve", "--user",
            "--referer", "--range", "--proxy", "--output-dir", "--cookie", "--cookie-jar", "--limit-rate",
            "--max-filesize", "--continue-at"
        ]
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--" { return args.dropFirst(index).allSatisfy(isWebURL) }
            if arg.hasPrefix("--") {
                let name = String(arg.prefix { $0 != "=" })
                let attached = arg.contains("=") ? String(arg.drop { $0 != "=" }.dropFirst()) : nil
                if longFlags.contains(name), attached == nil { continue }
                guard longValued.contains(name) else { return false }
                let value = attached ?? (index < args.count ? args[index] : "")
                if attached == nil { index += 1 }
                if name == "--request", !["GET", "HEAD"].contains(value.uppercased()) { return false }
                if sendsAFile(option: name, value: value) { return false }
                if name == "--url", !isWebURL(value) { return false }
            } else if arg.hasPrefix("-"), arg.count > 1 {
                for (offset, letter) in arg.dropFirst().enumerated() {
                    if flags.contains(letter) { continue }
                    guard valued.contains(letter) else { return false }
                    let remainder = String(arg.dropFirst(offset + 2))
                    let value = remainder.isEmpty ? (index < args.count ? args[index] : "") : remainder
                    if remainder.isEmpty { index += 1 }
                    if letter == "X", !["GET", "HEAD"].contains(value.uppercased()) { return false }
                    if sendsAFile(option: letter == "H" ? "--header" : letter == "b" ? "--cookie" : "", value: value) { return false }
                    break
                }
            } else if !isWebURL(arg) {
                // `telnet://`, `ftp://`, `smtp://`, `dict://` and a bare host
                // curl guesses a protocol for can send what curl reads.
                return false
            }
        }
        return true
    }

    /// A header or cookie curl reads from a file (`-H @file`, `-b file`)
    /// sends what the command does not show.
    private static func sendsAFile(option: String, value: String) -> Bool {
        (option == "--header" && value.hasPrefix("@")) || (option == "--cookie" && !value.contains("="))
    }

    private static func isWebURL(_ word: String) -> Bool {
        let lower = word.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    private static func wgetIsLocal(_ args: [String]) -> Bool {
        if args.contains(where: overridesMethod) { return false }
        let flags: Set<String> = [
            "-q", "--quiet", "-nv", "--no-verbose", "-c", "--continue", "-S", "--server-response", "--spider",
            "--no-check-certificate", "-N", "--timestamping", "-r", "--recursive", "-np", "--no-parent"
        ]
        let valued: Set<String> = [
            "-O", "--output-document", "-P", "--directory-prefix", "-T", "--timeout", "-t", "--tries", "--header",
            "-U", "--user-agent", "-o", "--output-file"
        ]
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            guard arg.hasPrefix("-") else { continue }
            let name = String(arg.prefix { $0 != "=" })
            if flags.contains(arg) { continue }
            if valued.contains(name) {
                if !arg.contains("=") { index += 1 }
                continue
            }
            // `-Ofile`, `-Pdir`: the value attached.
            if ["-O", "-P", "-o"].contains(where: { arg.hasPrefix($0) && !arg.hasPrefix("--") }) { continue }
            return false
        }
        return true
    }

    // MARK: Containers and packages

    /// `docker` without a push, a login, or a global option that picks a
    /// daemon or configuration on the command line. Which daemon it reaches
    /// otherwise is the user's Docker configuration — a context, a provider
    /// home, a capability's `DOCKER_HOST` — which the command does not
    /// express (spec decision 14), as `~/.curlrc` is curl's.
    private static func dockerIsLocal(_ args: [String]) -> Bool {
        guard let verb = args.first else { return true }
        if ["--version", "-v", "--help"].contains(verb) { return true }
        guard !verb.hasPrefix("-"),
              !args.contains(where: { $0.lowercased().contains("push") || $0.lowercased().contains("registry") }) else {
            return false
        }
        let rest = Array(args.dropFirst())
        // A build can export its cache or result to a service (`--cache-to
        // type=gha|s3|azblob`, `--output type=registry|…`): only a local
        // destination is local work.
        if ["build", "buildx", "image"].contains(verb), !dockerBuildExportsLocally(rest) { return false }
        switch verb {
        case "compose":
            return dockerComposeIsLocal(rest)
        case "buildx":
            return rest.first.map(["ls", "version", "du", "inspect"].contains) ?? false
        default:
            if let subcommands = localDockerSubcommands[verb] {
                return rest.first.map(subcommands.contains) ?? false
            }
            return localDockerVerbs.contains(verb)
        }
    }

    private static func dockerBuildExportsLocally(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--cache-to" || arg.hasPrefix("--cache-to=") { return false }
            let value: String
            if arg == "--output" || arg == "-o" {
                value = index < args.count ? args[index] : ""
                index += 1
            } else if arg.hasPrefix("--output=") {
                value = String(arg.dropFirst("--output=".count))
            } else if arg.hasPrefix("-o"), arg.count > 2 {
                value = String(arg.dropFirst(2))
            } else {
                continue
            }
            let type = value.split(separator: ",").first { $0.hasPrefix("type=") }.map { String($0.dropFirst(5)) }
            guard type == nil || ["local", "tar", "docker", "oci", "cacheonly"].contains(type!) else { return false }
        }
        return true
    }

    /// The second word of the management commands, by command.
    private static let localDockerSubcommands: [String: Set<String>] = [
        "image": ["ls", "list", "inspect", "rm", "prune", "build", "history", "tag", "pull", "load", "save", "import"],
        "container": [
            "ls", "list", "ps", "inspect", "rm", "prune", "start", "stop", "restart", "kill", "logs", "exec", "run",
            "create", "cp", "diff", "top", "stats", "port", "wait", "attach", "rename", "update", "export", "pause",
            "unpause", "commit"
        ],
        "volume": ["ls", "list", "create", "rm", "inspect", "prune"],
        "network": ["ls", "list", "create", "rm", "inspect", "prune", "connect", "disconnect"],
        "system": ["df", "info", "prune", "events"],
        "builder": ["prune", "ls", "du", "inspect"]
    ]

    /// `docker compose` running, building and reading the project's services;
    /// never `publish` or `push`, which send it to a registry.
    private static func dockerComposeIsLocal(_ args: [String]) -> Bool {
        let valued: Set<String> = [
            "-f", "--file", "-p", "--project-name", "--profile", "--env-file", "--project-directory", "--ansi",
            "--progress", "--parallel"
        ]
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            let option = args[index]
            if valued.contains(option) {
                index += 2
            } else if valued.contains(String(option.prefix { $0 != "=" })) || ["--compatibility", "--dry-run"].contains(option) {
                index += 1
            } else {
                return false
            }
        }
        guard index < args.count else { return false }
        return [
            "up", "down", "ps", "logs", "build", "pull", "start", "stop", "restart", "rm", "exec", "run", "config",
            "images", "ls", "top", "events", "kill", "pause", "unpause", "port", "create", "version", "cp", "wait",
            "watch", "stats"
        ].contains(args[index])
    }

    private static let localDockerVerbs: Set<String> = [
        "ps", "images", "build", "run", "exec", "logs", "inspect", "stop", "start", "restart", "rm", "rmi", "kill",
        "pause", "unpause", "wait", "port", "top", "stats", "diff", "cp", "create", "commit", "tag", "pull", "load",
        "save", "history", "events", "info", "version", "attach", "rename", "update", "export", "import", "search"
    ]

    /// npm, pnpm, yarn and bun: install, run the project's scripts, and read;
    /// never publish, log in, or run a package that is not the project's
    /// (`npx`, `exec`, `dlx`).
    private static func packageManagerIsLocal(_ manager: String, args: [String]) -> Bool {
        guard let command = args.first else { return manager != "bun" }
        if ["-v", "--version", "--help", "-h"].contains(command) { return true }
        if command == "config" { return args.count > 1 && ["get", "list", "ls"].contains(args[1]) }
        // `init <initializer>` installs and runs a registry package.
        if command == "init" { return args.dropFirst().allSatisfy { $0.hasPrefix("-") } }
        return localPackageCommands.contains(command) && packageOptionsAreListed(Array(args.dropFirst()))
    }

    /// The manager reads any `--name=value` as configuration, and some name a
    /// program (`--script-shell`, `--node-options`) or a config file, so only
    /// listed options pass; words after `--` go to the project's own script.
    private static func packageOptionsAreListed(_ args: [String]) -> Bool {
        let flags: Set<String> = [
            "-D", "-S", "-E", "-g", "-O", "-P", "-y", "-s", "-q", "-r", "--save", "--save-dev", "--save-exact",
            "--save-optional", "--save-prod", "--no-save", "--global", "--production", "--legacy-peer-deps",
            "--no-audit", "--no-fund", "--prefer-offline", "--offline", "--frozen-lockfile", "--immutable", "--silent",
            "--quiet", "--verbose", "--workspaces", "--if-present", "--ignore-scripts", "--dry-run", "--json", "--long",
            "--all", "--watch", "--coverage", "--recursive", "--parallel", "--stream", "--dev", "--exact", "--yes"
        ]
        let valued: Set<String> = ["-w", "--workspace", "--omit", "--include", "--depth", "--filter", "--tag"]
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { return true }
            let name = String(arg.prefix { $0 != "=" })
            if !arg.hasPrefix("-") || flags.contains(arg) {
                index += 1
            } else if valued.contains(name) {
                index += arg.contains("=") ? 1 : 2
            } else {
                return false
            }
        }
        return true
    }

    private static let localPackageCommands: Set<String> = [
        "install", "i", "ci", "add", "remove", "rm", "uninstall", "un", "update", "up", "upgrade", "run", "run-script",
        "test", "t", "start", "build", "ls", "list", "outdated", "why", "explain", "view", "info", "show", "pack",
        "init", "dedupe", "prune", "rebuild", "audit", "fund", "doctor", "version", "help", "cache", "lint", "dev"
    ]

    private static func pipIsLocal(_ args: [String]) -> Bool {
        guard let command = args.first else { return false }
        if command == "config" { return args.count > 1 && ["get", "list"].contains(args[1]) }
        return [
            "install", "uninstall", "list", "show", "freeze", "check", "download", "wheel", "cache", "inspect",
            "--version", "-V", "help", "debug"
        ].contains(command)
    }

    private static func uvIsLocal(_ args: [String], depth: Int) -> Bool {
        guard let command = args.first else { return false }
        switch command {
        case "pip":
            return pipIsLocal(Array(args.dropFirst()))
        case "run":
            var rest = Array(args.dropFirst())
            while let first = rest.first, first.hasPrefix("-") {
                // `--python`/`-p` names the interpreter uv runs.
                guard ["--with", "--project", "--directory", "--extra", "--group", "--package"].contains(first)
                        || ["--frozen", "--locked", "--no-sync", "--all-extras", "-q", "--quiet"].contains(first) else {
                    return false
                }
                rest.removeFirst(["--frozen", "--locked", "--no-sync", "--all-extras", "-q", "--quiet"].contains(first) ? 1 : min(2, rest.count))
            }
            guard let program = rest.first else { return false }
            if program.hasSuffix(".py") { return isProjectScript(program) }
            return isLocalCommand(rest, depth: depth + 1)
        default:
            return ["sync", "lock", "add", "remove", "venv", "tree", "init", "build", "version", "--version"].contains(command)
        }
    }

    // MARK: Interpreters

    /// A script file is the project's code; code on the command line
    /// (`-c`, `-e`) or read from standard input is not on the list.
    private static func pythonIsLocal(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count, args[index].hasPrefix("-"), args[index] != "-" {
            let option = args[index]
            if option == "-m" {
                guard index + 1 < args.count else { return false }
                let module = args[index + 1]
                if module == "pip" { return pipIsLocal(Array(args.dropFirst(index + 2))) }
                guard pathsStayInTheProject(Array(args.dropFirst(index + 2))) else { return false }
                if module == "pytest" { return pytestIsLocal(Array(args.dropFirst(index + 2))) }
                return [
                    "pytest", "unittest", "venv", "py_compile", "compileall", "json.tool", "doctest", "mypy", "black",
                    "ruff", "isort", "flake8", "pylint", "coverage"
                ].contains(module)
            }
            if ["--version", "-V"].contains(option) { return true }
            if ["-W", "-X"].contains(option) {
                index += 2
                continue
            }
            guard ["-u", "-B", "-O", "-OO", "-E", "-s", "-S", "-I", "-q", "-b", "-bb"].contains(option) else { return false }
            index += 1
        }
        return index < args.count && isProjectScript(args[index])
    }

    /// A script file of the project: not a standard-input stand-in (`-`,
    /// `/dev/stdin`, `/dev/fd/0`), and not a substitution's output (`<(…)`),
    /// which are code the command itself supplies.
    /// A file under the working directory: not absolute, not in a home, no
    /// `..` step, no expansion. Every operand that names code to run — an
    /// interpreter's script, `awk -f`, `cmake -P` — is judged by this.
    private static func isProjectScript(_ word: String) -> Bool {
        !word.hasPrefix("-") && !word.hasPrefix("/") && !word.hasPrefix("~") && !word.contains("$")
            && !word.split(separator: "/").contains("..")
    }

    /// A path that leaves the project: absolute, in a home, or with a `..`
    /// step; an option's attached value (`--package-path=/tmp/x`) counts.
    private static func leavesTheProject(_ word: String) -> Bool {
        // A short option's attached value (`-f/tmp/x`, `-C..`, `-C~/x`).
        if word.hasPrefix("-"), !word.hasPrefix("--"), !word.contains("="),
           word.range(of: #"^-[A-Za-z]+(\.\.(/|$)|[/~])"#, options: .regularExpression) != nil {
            return true
        }
        let value = word.hasPrefix("-") ? String(word.drop { $0 != "=" }.dropFirst()) : word
        return value.hasPrefix("/") || value.hasPrefix("~") || value.split(separator: "/").contains("..")
    }

    /// Tools that build, test or run the project's code. Any path one is
    /// given can choose which code that is (`--package-path`,
    /// `--manifest-path`, a test file, `-project`, a toolchain file), so every
    /// path stays in the project, as does the directory it runs in.
    private static let projectCodeRunners: Set<String> = [
        "swift", "cargo", "go", "pytest", "xcodebuild", "ctest", "cmake", "make", "gmake", "npm", "pnpm", "yarn", "bun", "uv",
        "ninja", "xcodegen", "eslint", "prettier", "jest", "vitest", "mypy", "flake8", "pylint"
    ]

    /// Words after `--` are the program's own arguments, its data.
    private static func pathsStayInTheProject(_ args: [String]) -> Bool {
        !args.prefix { $0 != "--" }.contains(where: leavesTheProject)
    }

    private static func nodeIsLocal(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            let option = args[index]
            if ["--version", "-v"].contains(option) { return true }
            if option == "--test" {
                index += 1
                continue
            }
            // An option that loads a module (`--experimental-loader=…`,
            // `--import`) names code to run, judged as the script is.
            let name = String(option.prefix { $0 != "=" })
            if name.contains("loader") || name.contains("import") || name.contains("require") {
                guard option.contains("="), isProjectScript(String(option.drop { $0 != "=" }.dropFirst())) else { return false }
                index += 1
                continue
            }
            guard ["--enable-source-maps", "--no-warnings", "--trace-warnings", "--trace-uncaught"].contains(option)
                    || option.hasPrefix("--experimental-") || option.hasPrefix("--max-old-space-size=") else {
                return false
            }
            index += 1
        }
        return index < args.count && isProjectScript(args[index])
    }

    /// A shell running a script file, or a `-c` string judged as a command.
    private static func shellIsLocal(_ args: [String], depth: Int) -> Bool {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            let option = args[index]
            if option == "--" {
                index += 1
                break
            }
            guard !option.hasPrefix("--"), option.dropFirst().allSatisfy({ "eluxvco".contains($0) }) else { return false }
            let takesOptionName = option.contains("o")
            if option.contains("c") {
                let payloadIndex = index + (takesOptionName ? 2 : 1)
                guard payloadIndex < args.count else { return false }
                return isLocal(args[payloadIndex], depth: depth + 1)
            }
            index += takesOptionName ? 2 : 1
        }
        // With no script, a shell reads its commands from standard input.
        return index < args.count && isProjectScript(args[index])
    }

    // MARK: Apple and language toolchains

    private static func swiftIsLocal(_ args: [String]) -> Bool {
        guard let command = args.first else { return false }
        switch command {
        case "build", "test", "run":
            return !loadsCompilerPlugin(Array(args.dropFirst()))
        case "format", "--version", "-version", "--help", "-h":
            return true
        case "package":
            let valued: Set<String> = [
                "--package-path", "--scratch-path", "--build-path", "--cache-path", "--config-path", "--security-path",
                "-c", "--configuration", "--jobs", "-j"
            ]
            let flags: Set<String> = [
                "--disable-sandbox", "-v", "--verbose", "--very-verbose", "-q", "--quiet", "--skip-update",
                "--disable-automatic-resolution", "--only-use-versions-from-resolved-file", "--force-resolved-versions"
            ]
            var index = 1
            while index < args.count, args[index].hasPrefix("-") {
                if valued.contains(args[index]) {
                    index += 2
                } else if flags.contains(args[index]) {
                    index += 1
                } else {
                    return false
                }
            }
            guard index < args.count else { return false }
            return [
                "resolve", "update", "describe", "dump-package", "show-dependencies", "clean", "reset", "purge-cache",
                "init", "compute-checksum", "edit", "unedit", "tools-version", "show-executables", "archive-source"
            ].contains(args[index])
        default:
            // `swift script.swift` runs a project file.
            return command.hasSuffix(".swift") && isProjectScript(command)
        }
    }

    /// `xcodebuild` building and testing on this Mac or a simulator. Exporting
    /// (`-exportArchive` can upload), provisioning (`-allowProvisioning…`
    /// changes the developer account) and a physical device destination are
    /// not local work.
    private static func xcodebuildIsLocal(_ args: [String]) -> Bool {
        if args.contains(where: { $0.hasPrefix("-export") || $0.hasPrefix("-allowProvisioning") || $0.hasPrefix("-authenticationKey") }) {
            return false
        }
        for (index, arg) in args.enumerated() where arg == "-destination" {
            guard index + 1 < args.count else { return false }
            let destination = args[index + 1]
            guard destination.contains("Simulator") || destination.contains("platform=macOS")
                    || destination.hasPrefix("generic/") else {
                return false
            }
        }
        return true
    }

    /// `ctest` running the project's tests with listed options; `--build-and-test`
    /// and `--test-command` run a given command, and dashboard modes submit
    /// results to a server.
    private static func ctestIsLocal(_ args: [String]) -> Bool {
        let flags: Set<String> = [
            "--output-on-failure", "-V", "-VV", "--verbose", "--extra-verbose", "-N", "--show-only", "--rerun-failed",
            "--stop-on-failure", "--schedule-random", "-Q", "--quiet", "--progress", "--no-tests=error",
            "--no-tests=ignore"
        ]
        let valued: Set<String> = [
            "-R", "--tests-regex", "-E", "--exclude-regex", "-L", "--label-regex", "-LE", "--label-exclude", "-j",
            "--parallel", "--test-dir", "-C", "--build-config", "--timeout", "--repeat", "-I", "--tests-information",
            "--output-junit", "-O", "--output-log"
        ]
        var index = 0
        while index < args.count {
            let arg = args[index]
            let name = String(arg.prefix { $0 != "=" })
            if flags.contains(arg) {
                index += 1
            } else if valued.contains(name) {
                index += arg.contains("=") ? 1 : 2
            } else if arg.hasPrefix("-j"), Int(arg.dropFirst(2)) != nil {
                index += 1
            } else {
                return false
            }
        }
        return true
    }

    /// A compiler option that loads a plugin runs it (`-load-plugin-executable`,
    /// `-fplugin=`), and the frontend passthroughs can name one.
    private static func loadsCompilerPlugin(_ args: [String]) -> Bool {
        args.contains { arg in
            let lower = arg.lowercased()
            // Also a linker or helper named on the command line (`rustc -C
            // linker=…`, `-fuse-ld=…`, `gcc -B dir`, `-wrapper`).
            // A configuration or response file (`--config=…`, `@args`)
            // holds options this cannot read.
            return lower.contains("plugin") || lower.hasPrefix("-load") || lower.contains("linker") || lower.contains("lto_library")
                || lower.hasPrefix("--config") || lower.hasPrefix("@")
                || lower.contains("link-arg") || lower.hasPrefix("-fuse-ld") || lower.hasPrefix("--ld-path")
                || lower.hasPrefix("-b") || lower == "-wrapper" || lower.hasPrefix("-z")
                || ["-xfrontend", "-xclang", "-xllvm", "-xswiftc", "-xcc", "-xlinker"].contains(lower)
        }
    }

    /// `pytest` runs the project's tests; `--pastebin` sends the session to
    /// bpaste.net.
    private static func pytestIsLocal(_ args: [String]) -> Bool {
        !args.contains { $0.hasPrefix("--pastebin") }
    }

    private static func cargoIsLocal(_ args: [String]) -> Bool {
        var rest = args[...]
        if rest.first?.hasPrefix("+") == true { rest = rest.dropFirst() }
        while let first = rest.first, first.hasPrefix("-") {
            if ["--version", "-V", "--help", "-h"].contains(first) { return true }
            guard ["-q", "-v", "-vv", "--quiet", "--verbose", "--locked", "--offline", "--frozen"].contains(first) else { return false }
            rest = rest.dropFirst()
        }
        guard let command = rest.first else { return true }
        // `--config` after the verb can name a program Cargo runs
        // (`build.rustc-wrapper`, `target.*.runner`).
        guard !rest.contains(where: { $0 == "--config" || $0.hasPrefix("--config=") || $0.hasPrefix("-Z") }) else { return false }
        return [
            "build", "b", "check", "c", "test", "t", "run", "r", "clippy", "fmt", "doc", "d", "clean", "tree", "metadata",
            "fetch", "update", "add", "remove", "rm", "bench", "init", "new", "generate-lockfile", "vendor", "version",
            "install", "uninstall", "search", "help", "locate-project", "pkgid", "verify-project", "fix"
        ].contains(command)
    }

    private static func goIsLocal(_ args: [String]) -> Bool {
        guard let command = args.first else { return true }
        // `go env -w`/`-u` change the defaults every later `go` reads
        // (`GOFLAGS=-toolexec=…`).
        // Go reads `-w`, `--w` and `-w=true` alike.
        let flagNames = args.filter { $0.hasPrefix("-") }.map { String($0.drop { $0 == "-" }.prefix { $0 != "=" }) }
        if command == "env" { return !flagNames.contains { $0 == "w" || $0 == "u" } }
        if command == "mod" {
            return args.count > 1 && ["tidy", "download", "graph", "verify", "why", "edit", "init", "vendor"].contains(args[1])
        }
        // `go generate` runs the commands its directives name, and `-exec` and
        // `-toolexec` name a program to run.
        guard !flagNames.contains(where: { ["exec", "toolexec", "vettool"].contains($0) }) else {
            return false
        }
        // `go run module@version` downloads and runs a module that is not
        // the project's, as `npx` would.
        if command == "run", args.dropFirst().contains(where: { !$0.hasPrefix("-") && $0.contains("@") }) { return false }
        return ["build", "test", "vet", "fmt", "run", "list", "env", "version", "doc", "clean", "install", "get", "work", "help"]
            .contains(command)
    }

    private static let localBrewCommands: Set<String> = [
        "list", "ls", "info", "search", "--prefix", "--cellar", "--cache", "--version", "outdated", "deps", "uses",
        "doctor", "config", "install", "reinstall", "uninstall", "remove", "rm", "upgrade", "update", "cleanup",
        "leaves", "desc", "log", "commands", "help", "tap", "tap-info"
    ]

    private static func xcrunIsLocal(_ args: [String], depth: Int) -> Bool {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            let option = args[index]
            if ["--show-sdk-path", "--show-sdk-version", "--show-sdk-platform-path", "--show-sdk-build-version",
                "--find", "-f", "--version"].contains(option) {
                return true
            }
            guard ["--sdk", "-sdk", "--toolchain"].contains(option) else { return false }
            index += 2
        }
        guard index < args.count else { return false }
        let tool = args[index]
        // `simctl` drives this Mac's simulators; `devicectl` changes a
        // connected device, which is not this machine. `simctl spawn DEVICE
        // COMMAND …` runs a command, which is judged as one.
        if tool == "simctl" {
            // A global option (`--set`, `--noxpc`) before the subcommand is
            // not read, so it is not local.
            guard let subcommand = args.dropFirst(index + 1).first, !subcommand.hasPrefix("-") else { return false }
            guard subcommand == "spawn" else { return true }
            var rest = Array(args.dropFirst(index + 2))
            while let first = rest.first, first.hasPrefix("-") {
                guard ["-w", "--wait-for-debugger", "-s", "--standalone"].contains(first) else { return false }
                rest.removeFirst()
            }
            guard rest.count >= 2 else { return false }
            return isLocalCommand(Array(rest.dropFirst()), depth: depth + 1)
        }
        return isLocalCommand(Array(args.dropFirst(index)), depth: depth + 1)
    }
}
