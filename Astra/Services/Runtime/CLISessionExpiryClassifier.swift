import Foundation
import ASTRACore
import ASTRAModels

/// Recognises a plugin CLI whose sign-in expired while the agent was using it,
/// from the output of the command the agent ran.
///
/// Before this, `gcloud` printing "Reauthentication required" was just a tool
/// error: the agent retried, gave up, or blamed the provider, and the person
/// had no button to fix it. Now the run stops with
/// `TaskRunStopReason.capabilitySessionExpired` and the task view offers the
/// sign-in and then Resume.
///
/// It fires only when the command that produced the output starts one of the
/// known CLIs and that command failed (the process monitor checks the tool
/// result's error flag), so an agent reading documentation or an issue body
/// that quotes these errors does not stop the run. A line that succeeded
/// still counts when a later command decided its exit status
/// (`gcloud projects list | cat`), or when the CLI ran in a substitution
/// inside another command (`echo "$(gh auth token)"`), which hides the CLI's
/// own failure.
/// Patterns are whole diagnostics, not fragments.
enum CLISessionExpiryClassifier {
    struct Family: Equatable, Sendable {
        let commands: [String]
        let displayName: String
        let signInCommand: String
        let checkBinary: String
        let checkArguments: [String]
        let patterns: [String]
        /// Signing in again fixes it. Not so for a token the environment
        /// supplies (`GH_TOKEN`), which overrides the stored sign-in.
        var offersSignIn = true
        var customStopMessage: String? = nil

        var stopMessage: String {
            customStopMessage
                ?? "The \(displayName) sign-in expired while the agent was using it. Run `\(signInCommand)`, then resume."
        }

        /// The sign-in repair, or for a family whose fix is outside ASTRA
        /// (`offersSignIn` false) a check-only one whose guidance is the
        /// family's own: Resume still re-runs the check, and a failed check
        /// repeats what actually fixes it.
        var repair: RepairAction {
            RepairAction(
                strategy: .terminal,
                componentName: "\(displayName) login",
                title: offersSignIn ? "Sign in to \(displayName)" : "Fix \(displayName) access",
                verb: offersSignIn ? "Sign in" : "Check",
                detail: offersSignIn || customStopMessage == nil
                    ? "Run `\(signInCommand)` in Terminal, then resume the task."
                    : customStopMessage ?? "",
                command: offersSignIn ? signInCommand : nil,
                checkBinary: checkBinary,
                checkArguments: checkArguments,
                checkExpect: checkBinary == "gcloud" ? SemanticCheck.stdoutNonEmpty.rawValue : nil
            )
        }

        /// The same family signing in to and checking a GitHub Enterprise
        /// host (`enterpriseHost` validated) instead of github.com.
        func onHost(_ host: String) -> Family {
            Family(
                commands: commands, displayName: displayName,
                signInCommand: "\(signInCommand) --hostname \(host)", checkBinary: checkBinary,
                checkArguments: ["auth", "status", "--hostname", host], patterns: patterns,
                offersSignIn: offersSignIn, customStopMessage: customStopMessage
            )
        }
    }

    static let googleCloud = Family(
        commands: ["gcloud", "bq", "gsutil"],
        displayName: "Google Cloud",
        signInCommand: "gcloud auth login",
        checkBinary: "gcloud",
        checkArguments: ["config", "config-helper", "--format=value(credential.token_expiry)"],
        patterns: [
            "reauthentication required",
            "reauthentication failed",
            "invalid_grant",
            "problem refreshing your current auth tokens",
            "you do not currently have an active account selected",
            "does not have any valid credentials",
            "please run:\n\n  $ gcloud auth login"
        ]
    )

    static let gitHub = Family(
        commands: ["gh"],
        displayName: "GitHub",
        signInCommand: "gh auth login",
        checkBinary: "gh",
        checkArguments: ["auth", "status", "--hostname", "github.com"],
        patterns: [
            "you are not logged into any github hosts",
            "http 401: bad credentials",
            "the token in default is invalid",
            "run gh auth login",
            "to get started with github cli, please run:  gh auth login"
        ]
    )

    /// `gh` reports a bad token from `GH_TOKEN` or `GITHUB_TOKEN`. Those
    /// variables take precedence over the stored sign-in (`gh help
    /// environment`), so `gh auth login` cannot fix it: the person has to
    /// update or remove the variable. Checked before `gitHub`, whose
    /// "run gh auth login" hint `gh` prints here too.
    static let gitHubEnvironmentToken = Family(
        commands: ["gh"],
        displayName: "GitHub",
        signInCommand: "gh auth login",
        checkBinary: "gh",
        checkArguments: ["auth", "status", "--hostname", "github.com"],
        patterns: ["the token in gh_token is invalid", "the token in github_token is invalid"],
        offersSignIn: false,
        customStopMessage: "GitHub rejected the token in GH_TOKEN or GITHUB_TOKEN. That variable overrides any sign-in, so signing in again won't help: update or remove it where ASTRA's environment gets it, then resume."
    )

    static let families = [googleCloud, gitHubEnvironmentToken, gitHub]

    struct Stop: Equatable {
        let reason: String
        let message: String
    }

    /// A stop when `content` is a sign-in failure printed by a command that
    /// runs one of the known CLIs. `failed` is the tool result's error flag:
    /// when the line succeeded, the CLI must have run where its own exit
    /// status was masked (`masksExitStatus`).
    static func stop(content: String, command: String?, failed: Bool = true) -> Stop? {
        guard let family = family(content: content, command: command, failed: failed) else { return nil }
        return Stop(reason: TaskRunStopReason.capabilitySessionExpired.rawValue, message: family.stopMessage)
    }

    static func family(content: String, command: String?, failed: Bool = true) -> Family? {
        guard let command, !command.isEmpty else { return nil }
        let lowered = content.lowercased()
        let family = families.first { family in
            family.commands.contains { failed ? runs($0, in: command) : masksExitStatus(of: $0, in: command) }
                && family.patterns.contains { lowered.contains($0) }
        }
        // A GitHub Enterprise host the command targeted is the one to sign
        // in to and check; github.com's login says nothing about it.
        if family == gitHub, let host = gitHubHost(in: command) { return gitHub.onHost(host) }
        return family
    }

    /// The family whose stop message this is; the message is ASTRA's own.
    static func family(forStopMessage message: String?) -> Family? {
        guard let message else { return nil }
        if let family = families.first(where: { $0.stopMessage == message }) { return family }
        // An enterprise stop names its host in the sign-in command.
        let prefix = "`\(gitHub.signInCommand) --hostname "
        guard let start = message.range(of: prefix),
              let end = message[start.upperBound...].firstIndex(of: "`"),
              let host = enterpriseHost(String(message[start.upperBound..<end])) else { return nil }
        let hosted = gitHub.onHost(host)
        return hosted.stopMessage == message ? hosted : nil
    }

    /// The GitHub Enterprise host a `gh` call in `command` targets: its
    /// `--hostname` flag, else a `GH_HOST=` assignment before it. Nil for
    /// github.com or a value that is not a plain host name.
    static func gitHubHost(in command: String) -> String? {
        for words in simpleCommands(command) {
            var rest = words
            var assignments: [String] = []
            stripWrappers(&rest, assignments: &assignments)
            guard let executable = rest.first, (executable as NSString).lastPathComponent == "gh" else { continue }
            var declared = assignments.last { $0.hasPrefix("GH_HOST=") }.map { String($0.dropFirst("GH_HOST=".count)) }
            let arguments = Array(rest.dropFirst())
            for (index, argument) in arguments.enumerated() {
                if argument == "--hostname", index + 1 < arguments.count {
                    declared = arguments[index + 1]
                } else if argument.hasPrefix("--hostname=") {
                    declared = String(argument.dropFirst("--hostname=".count))
                }
            }
            if let host = declared.flatMap(enterpriseHost) { return host }
        }
        return nil
    }

    /// A GitHub check still aimed at github.com while the resumed run's
    /// `GH_HOST` names an enterprise host checks that host instead: `gh`
    /// sends that run's calls there.
    static func checkingLaunchHost(_ repair: RepairAction) -> RepairAction {
        guard repair.checkBinary == "gh", repair.checkArguments == gitHub.checkArguments,
              let host = repair.checkEnvironment?["GH_HOST"].flatMap(enterpriseHost) else { return repair }
        var hosted = repair
        hosted.checkArguments = gitHub.onHost(host).checkArguments
        return hosted
    }

    /// `candidate` lowercased when it is a plain host name (with an optional
    /// port) other than github.com, so it is safe as one Terminal argument.
    private static func enterpriseHost(_ candidate: String) -> String? {
        let host = candidate.lowercased()
        guard host != "github.com", host.count <= 253,
              host.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$"#, options: .regularExpression) != nil
        else { return nil }
        return host
    }

    /// True when `command` executes `cli`: the command word of one of its
    /// simple commands (split at `;`, `&`, `|`, newlines and subshells), after
    /// any `VAR=value` assignments and wrappers like `env`, `command`, `exec`,
    /// `time`, `sudo`, compared by basename so `/opt/homebrew/bin/gcloud`
    /// counts. An argument that merely names the CLI does not.
    static func runs(_ cli: String, in command: String) -> Bool {
        simpleCommands(command).contains { executes(cli, $0) }
    }

    /// Operators after which a later command decides the line's exit status:
    /// a pipe, `||`, `;`, `&` or a newline. Not `&&`, which stops at a failure.
    private static let statusMaskingSeparators: Set<String> = ["|", "|&", "||", ";", "&", "\n"]

    /// True when `command` runs `cli` with another command after it that
    /// decides the line's exit status, or inside a substitution whose
    /// enclosing command is another program, so the CLI could fail while the
    /// line succeeds. A CLI that runs last, alone or after `&&`, does not
    /// count: its own success is the line's. Nor does `token=$(gh auth token)`,
    /// which exits with the substitution's status.
    static func masksExitStatus(of cli: String, in command: String) -> Bool {
        let segments = segments(command)
        return segments.indices.contains { index in
            let segment = segments[index]
            guard executes(cli, segment.words) else { return false }
            return segment.enclosingCommands.contains { !executes(cli, $0) }
                || (index < segments.count - 1 && statusMaskingSeparators.contains(segment.separator))
        }
    }

    private static func executes(_ cli: String, _ simpleCommand: [String]) -> Bool {
        var words = simpleCommand
        stripWrappers(&words)
        guard let executable = words.first else { return false }
        return (executable as NSString).lastPathComponent == cli
    }

    /// The simple commands of a shell line, each as its words, with quoting
    /// honored: a separator or a space inside quotes is part of a word, and
    /// the quotes themselves are removed. `$( … )` and backticks start a
    /// new command, as their contents run too, inside double quotes as well;
    /// inside single quotes they are literal text.
    static func simpleCommands(_ line: String) -> [[String]] {
        segments(line).map(\.words)
    }

    /// A simple command and the operator that ended it: `|`, `|&`, `||`,
    /// `&&`, `;`, `&`, a newline, a parenthesis or a backtick, or "" at the
    /// end of the line. A subshell's `)` takes the operator that follows it.
    struct Segment: Equatable {
        var words: [String]
        var separator: String
        /// The commands whose arguments this one's substitution produced,
        /// outermost first (`echo` in `echo "$(gh auth token)"`); their exit
        /// status, not this command's, is the line's.
        var enclosingCommands: [[String]] = []
    }

    static func segments(_ line: String) -> [Segment] {
        var segments: [Segment] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        // Substitutions opened inside double quotes, innermost last: the
        // character that closes each, and the `(` depth inside it. Closing
        // one reopens the double quote it interrupted.
        var substitutions: [(closer: Character, depth: Int)] = []
        // Every open parenthesis or backtick, innermost last, with the
        // command a substitution there feeds (nil for a subshell, or for a
        // substitution that is the whole command, as in an assignment).
        var groups: [(closer: Character, command: [String]?)] = []
        let characters = Array(line)
        var index = 0
        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endCommand(_ separator: String) {
            endWord()
            words.removeAll { $0 == "$" }
            if !words.isEmpty {
                segments.append(Segment(
                    words: words, separator: separator, enclosingCommands: groups.compactMap(\.command)
                ))
            } else if segments.last?.separator == ")" {
                segments[segments.count - 1].separator = separator
            }
            words = []
        }
        // A `$(` or backtick substitution records the command it feeds when
        // that command runs a program (`echo`, not `token=`).
        func openGroup(_ opener: Character, closer: Character) {
            var enclosing = words + (inWord ? [word] : [])
            let substitutes = opener == "`" || enclosing.last?.hasSuffix("$") == true
            if opener == "(", substitutes { enclosing[enclosing.count - 1].removeLast() }
            enclosing.removeAll(where: \.isEmpty)
            stripWrappers(&enclosing)
            endCommand(String(opener))
            groups.append((closer: closer, command: substitutes && !enclosing.isEmpty ? enclosing : nil))
        }
        func closeOrOpenGroup(_ character: Character) {
            guard character == ")" || (character == "`" && groups.last?.closer == "`") else {
                return openGroup(character, closer: character == "`" ? "`" : ")")
            }
            endCommand(String(character))
            if groups.last?.closer == character { groups.removeLast() }
        }
        while index < characters.count {
            let character = characters[index]
            index += 1
            let next = index < characters.count ? characters[index] : nil
            if escaped {
                word.append(character)
                inWord = true
                escaped = false
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaped = true
                } else if open == "\"", character == "`" || (character == "$" && next == "(") {
                    // `"$(gh auth token)"` still runs `gh`: leave the quote
                    // for the substitution, as an unquoted `$(` would.
                    if character == "$" {
                        word.append(character)
                        index += 1
                    }
                    openGroup(character == "`" ? "`" : "(", closer: character == "`" ? "`" : ")")
                    substitutions.append((closer: character == "`" ? "`" : ")", depth: 0))
                    quote = nil
                } else {
                    word.append(character)
                    inWord = true
                }
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "'", "\"":
                quote = character
                inWord = true
            case " ", "\t":
                endWord()
            case "&" where word.hasSuffix(">") || word.hasSuffix("<") || next == ">":
                // `2>&1`, `<&3` and `&>file` are redirections, not operators.
                if next == ">" { endWord() }
                word.append(character)
                inWord = true
            case "&", "|":
                var separator = String(character)
                if let next, next == "&" || next == "|" {
                    separator.append(next)
                    index += 1
                }
                endCommand(separator)
            case ")" where substitutions.last?.closer == ")" && substitutions.last?.depth == 0,
                 "`" where substitutions.last?.closer == "`":
                endCommand(String(character))
                _ = groups.popLast()
                substitutions.removeLast()
                quote = "\""
            case "(" where substitutions.last?.closer == ")", ")" where substitutions.last?.closer == ")":
                substitutions[substitutions.count - 1].depth += character == "(" ? 1 : -1
                closeOrOpenGroup(character)
            case "(", ")", "`":
                closeOrOpenGroup(character)
            case ";", "\n":
                endCommand(String(character))
            default:
                // `$(` ends at the `(`, which starts the substituted command.
                word.append(character)
                inWord = true
            }
        }
        endCommand("")
        return segments
    }

    /// Wrappers and the options each takes a value for, so `env -i gcloud`
    /// and `sudo -u build gh` find the command they run. `env -S` is not
    /// here: its operand is the command itself (`envSplitString`).
    private static let wrapperValueOptions: [String: Set<String>] = [
        "env": ["-u", "-C", "-P", "--unset", "--chdir"],
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "--user", "--group", "--host", "--prompt", "--chdir"],
        "command": [],
        "exec": ["-a"],
        "time": ["-f", "-o", "--format", "--output"],
        "nohup": [],
        "xargs": ["-I", "-L", "-n", "-P", "-s", "-d", "-E", "-a"]
    ]

    /// Drops leading assignments, wrappers with their options, and command
    /// substitutions, leaving the executable first.
    static func stripWrappers(_ words: inout [String]) {
        var assignments: [String] = []
        stripWrappers(&words, assignments: &assignments)
    }

    /// `stripWrappers`, collecting the `VAR=value` assignments it dropped.
    static func stripWrappers(_ words: inout [String], assignments: inout [String]) {
        while let first = words.first {
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                assignments.append(words.removeFirst())
                continue
            }
            if first.hasPrefix("$(") {
                words.removeFirst()
                continue
            }
            let name = (first as NSString).lastPathComponent
            guard let valueOptions = wrapperValueOptions[name] else { return }
            words.removeFirst()
            while let option = words.first, option.hasPrefix("-") {
                words.removeFirst()
                if option == "--" { break }
                if name == "env", let split = envSplitString(option, rest: &words) {
                    words.insert(contentsOf: split, at: 0)
                    continue
                }
                // `-u name` takes the next word; `-uname` and `--user=name` don't.
                if valueOptions.contains(option), !option.contains("=") { _ = words.isEmpty ? nil : words.removeFirst() }
            }
        }
    }

    /// The words of `env -S`'s operand, which env splits into the arguments
    /// it runs (`env -S 'gh auth token'` runs `gh`), or nil for any other
    /// option. Takes the next word from `rest` when the operand is separate.
    private static func envSplitString(_ option: String, rest: inout [String]) -> [String]? {
        let operand: String
        if option == "-S" || option == "--split-string" {
            guard !rest.isEmpty else { return [] }
            operand = rest.removeFirst()
        } else if option.hasPrefix("--split-string=") {
            operand = String(option.dropFirst("--split-string=".count))
        } else if option.hasPrefix("-S") {
            operand = String(option.dropFirst(2))
        } else {
            return nil
        }
        return splitStringWords(operand)
    }

    /// Whitespace-separated words, honoring quotes and backslashes as env
    /// does for `-S`; no shell operators apply inside it.
    private static func splitStringWords(_ operand: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in operand {
            if escaped {
                word.append(character)
                escaped = false
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\\" {
                escaped = true
                inWord = true
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }
}
