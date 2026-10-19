import Foundation

/// What a Terminal repair may ask a CLI to do: sign in, check a sign-in, or
/// (for an install step) install with a package manager. Nothing else.
///
/// A repair runs in one click, and a plugin declares its command. Being a
/// plain call to the component's own CLI is not enough: `gcloud projects
/// delete victim --quiet`, `gh repo delete x --yes` and `gh api -X DELETE
/// /repos/x` are all plain calls. So after the CLI, every positional word
/// must spell one of the CLI's sign-in commands, exactly. Flags (`--web`,
/// `--x=y`) are allowed; a flag's separate value counts as a positional
/// unless the flag is listed as taking one. Fails closed: a CLI not listed
/// may use only `auth`, `login` and `sso`, and a call with no positional
/// (a bare `copilot`) is refused.
public enum TerminalRepairPolicy {
    struct SignIn {
        let commands: Set<[String]>
        /// Flags whose value is the next word (`gh auth login --hostname h`).
        let valueFlags: Set<String>
    }

    static let signIns: [String: SignIn] = [
        "gh": SignIn(
            commands: [["auth", "login"], ["auth", "refresh"], ["auth", "status"]],
            valueFlags: ["--hostname", "-h", "--scopes", "-s", "--git-protocol", "-p"]
        ),
        "gcloud": SignIn(
            commands: [["auth", "login"], ["auth", "application-default", "login"]],
            valueFlags: ["--account", "--configuration", "--project"]
        ),
        "az": SignIn(commands: [["login"]], valueFlags: ["--tenant", "-t"]),
        "aws": SignIn(commands: [["sso", "login"], ["configure", "sso"]], valueFlags: ["--profile", "--sso-session"])
    ]

    /// The only words a CLI without its own entry may use (`codex login`,
    /// `opencode auth login`, `stanford-graph-mail login`).
    static let genericSignInVerbs: Set<String> = ["auth", "login", "sso"]

    /// True when `arguments`, after the CLI named `cli` (a basename), sign in.
    public static func isSignIn(cli: String, arguments: [String]) -> Bool {
        let rule = signIns[cli]
        let words = positionals(arguments, valueFlags: rule?.valueFlags ?? [])
        guard !words.isEmpty else { return false }
        if let rule { return rule.commands.contains(words) }
        return words.allSatisfy(genericSignInVerbs.contains)
    }

    /// True when a package manager's `arguments` install packages by name
    /// (`brew install gh`, `brew install --cask docker`).
    public static func isInstall(arguments: [String]) -> Bool {
        let words = positionals(arguments, valueFlags: [])
        guard words.count >= 2, words[0] == "install" else { return false }
        return words.dropFirst().allSatisfy {
            $0.range(of: #"^[A-Za-z0-9@][A-Za-z0-9@._+/-]*$"#, options: .regularExpression) != nil
        }
    }

    /// The words that are not flags or a listed flag's value. `-` and `--`
    /// count as positionals, so they never match a sign-in.
    static func positionals(_ arguments: [String], valueFlags: Set<String>) -> [String] {
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            guard word.hasPrefix("-"), word != "-", word != "--" else {
                words.append(word)
                continue
            }
            if valueFlags.contains(word), index < arguments.count { index += 1 }
        }
        return words
    }
}
