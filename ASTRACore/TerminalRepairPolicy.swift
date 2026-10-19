import Foundation

/// What a Terminal repair may ask a CLI to do: sign in, check a sign-in, or
/// (for an install step) install with a package manager. Nothing else.
///
/// A repair runs in one click, and a plugin declares its command. Being a
/// plain call to the component's own CLI is not enough: `gcloud projects
/// delete victim --quiet`, `gh repo delete x --yes` and `gh api -X DELETE
/// /repos/x` are all plain calls. So after the CLI, every positional word
/// must spell one of the CLI's sign-in commands, exactly, and every flag
/// must be one that command lists, with a value it accepts
/// (`CLICommandShape`). A sign-in is not harmless with any flag: `gh auth
/// refresh --insecure-storage` stores the token in plain text, `--scopes
/// admin:org` asks for privileges the plugin chose, and `gcloud auth login
/// --cred-file` signs in with a credential file the plugin names. A flag's
/// separate value counts as a positional unless the flag is listed as taking
/// one. Fails closed: only a known CLI (`HealthCheckPolicy.knownCLIs`, the
/// list version checks use) with a sign-in listed here has a repair. Any
/// other binary gives `auth`, `login` or `sso` whatever meaning it likes
/// (`touch auth` creates a file), so its declared repair is guidance with no
/// button, and import refuses it. A call with no positional (a bare
/// `copilot`) is refused.
public enum TerminalRepairPolicy {
    typealias SignIn = CLICommandShape

    /// gcloud's global flags that pick the account, project or configuration
    /// a sign-in is for.
    private static let gcloudSignInFlags: [String: CLICommandShape.Value] = [
        "--account": .plain, "--project": .plain, "--configuration": .plain
    ]

    static let signIns: [String: [SignIn]] = [
        "gh": [
            SignIn(
                positionals: ["auth", "login"], booleanFlags: ["--web", "-w"],
                valueFlags: ["--hostname": .host, "-h": .host, "--git-protocol": .oneOf(["https", "ssh"]), "-p": .oneOf(["https", "ssh"])]
            ),
            SignIn(positionals: ["auth", "refresh"], valueFlags: ["--hostname": .host, "-h": .host]),
            SignIn(positionals: ["auth", "status"], booleanFlags: ["--active", "-a"], valueFlags: ["--hostname": .host, "-h": .host])
        ],
        "gcloud": [
            SignIn(positionals: ["auth", "login"], booleanFlags: ["--no-launch-browser", "--update-adc"], valueFlags: gcloudSignInFlags),
            SignIn(positionals: ["auth", "application-default", "login"], booleanFlags: ["--no-launch-browser"], valueFlags: gcloudSignInFlags)
        ],
        "az": [SignIn(positionals: ["login"], booleanFlags: ["--use-device-code"], valueFlags: ["--tenant": .plain, "-t": .plain])],
        "aws": [
            SignIn(positionals: ["sso", "login"], booleanFlags: ["--use-device-code"], valueFlags: ["--profile": .plain, "--sso-session": .plain]),
            SignIn(positionals: ["configure", "sso"], booleanFlags: ["--use-device-code"], valueFlags: ["--profile": .plain])
        ],
        // The provider CLIs whose sign-in is a plain command.
        "codex": [SignIn(positionals: ["login"])],
        "cursor-agent": [SignIn(positionals: ["login"])],
        "opencode": [SignIn(positionals: ["auth", "login"])]
    ]

    /// The CLIs with a listed sign-in: all of them known CLIs.
    public static var signInCLIs: Set<String> { Set(signIns.keys) }

    /// True when `arguments`, after the CLI named `cli` (a basename), sign in:
    /// a known CLI, and one of its listed sign-ins.
    public static func isSignIn(cli: String, arguments: [String]) -> Bool {
        guard HealthCheckPolicy.knownCLIs.contains(cli), let rule = signIns[cli] else { return false }
        return rule.contains { $0.matches(arguments) }
    }

    /// True when a package manager's `arguments` install packages by name
    /// (`brew install gh`, `brew install --cask docker`). Only `--cask` and
    /// `--formula` are flags it may carry.
    public static func isInstall(arguments: [String]) -> Bool {
        let flags: Set<String> = ["--cask", "--formula"]
        let words = arguments.filter { !flags.contains($0) }
        guard words.count >= 2, words[0] == "install" else { return false }
        return words.dropFirst().allSatisfy {
            $0.range(of: #"^[A-Za-z0-9@][A-Za-z0-9@._+/-]*$"#, options: .regularExpression) != nil
        }
    }
}
