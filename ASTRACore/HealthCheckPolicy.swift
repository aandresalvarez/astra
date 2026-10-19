import Foundation

/// What a health check may run: a known read-only status command for its
/// CLI, nothing else.
///
/// A prerequisite's check runs on every scan (the rail, the Plugins surface,
/// launch preflight, a repair's polling) with no click, and a plugin declares
/// its arguments. Having no shell syntax is not enough: `gcloud projects
/// delete victim --quiet` has none. So the arguments must match one of the
/// CLI's status commands below: its positional words exactly (`*` is one
/// plain operand, such as a property name), and only the flags that command
/// lists. A flag's separate value counts as a positional unless the flag is
/// listed as taking one. A version report (`--version`, the `version`
/// subcommand) counts only for the known CLIs in `versionForms`, each in the
/// forms it supports: the same word means something else to another
/// program (`touch version` creates a file, `sh version` runs a script).
/// Every rule matches the binary's basename, and only for a bare name or an
/// installed path (`TrustedExecutablePath`): `/tmp/plugin/gh` has no check,
/// and when one runs, the file found must still be an installed path once
/// symlinks resolve (a bare name ASTRA finds on its own search path aside). A bare call, which may start
/// an interactive session, is refused. A check that
/// fails is never run (`HealthStatus.notChecked`, which is not a pass), and
/// import refuses it (`CapabilityPackageValidator`).
/// The sibling rule for repairs is `TerminalRepairPolicy`.
public enum HealthCheckPolicy {
    typealias Check = CLICommandShape

    private static let versionFlag = Check(positionals: [], booleanFlags: ["--version"])
    private static let versionCommand = Check(positionals: ["version"])

    /// The CLIs whose version report is a read-only status check, by
    /// basename, each with only the forms it supports. The ones ASTRA runs
    /// or ships plugins for: cloud and source-control CLIs, language
    /// runtimes and package runners an MCP server starts with, the provider
    /// CLIs, and the binaries the bundled plugins and tool detector declare.
    /// `npm version` and `uv version` are left out: given an argument, each
    /// sets a project's version.
    static let versionForms: [String: [Check]] = {
        var forms: [String: [Check]] = [:]
        for cli in ["gh", "gcloud", "az", "docker", "git", "terraform"] { forms[cli] = [versionFlag, versionCommand] }
        for cli in ["bq", "gsutil", "kubectl"] { forms[cli] = [versionCommand] }
        for cli in [
            "aws", "node", "npm", "npx", "python3", "python", "uv", "uvx", "deno", "bun", "brew",
            "claude", "codex", "copilot", "cursor-agent", "opencode", "agy",
            "pwsh", "jq", "curl", "astra-mcp-smoke-server"
        ] { forms[cli] = [versionFlag] }
        return forms
    }()

    static let checks: [String: [Check]] = [
        // `--show-token` is not listed: it prints the token.
        "gh": [Check(positionals: ["auth", "status"], booleanFlags: ["--active", "-a"], valueFlags: ["--hostname": .host, "-h": .host])],
        "gcloud": [
            Check(positionals: ["auth", "list"], valueFlags: ["--format": .any, "--filter": .any]),
            Check(positionals: ["config", "get-value", "*"], valueFlags: ["--format": .any])
        ],
        "az": [Check(positionals: ["account", "show"], valueFlags: ["--output": .any, "-o": .any, "--query": .any])],
        "aws": [Check(
            positionals: ["sts", "get-caller-identity"],
            valueFlags: ["--output": .any, "--profile": .plain, "--query": .any, "--region": .plain]
        )],
        "docker": [
            Check(positionals: ["version"], valueFlags: ["--format": .any, "-f": .any]),
            Check(positionals: ["info"], valueFlags: ["--format": .any, "-f": .any]),
            Check(positionals: ["ps"], booleanFlags: ["--quiet", "-q"], valueFlags: ["--format": .any])
        ]
    ]

    /// ASTRA's own read-only check for a known CLI (by basename): its
    /// sign-in status where ASTRA knows one, else its version report. A
    /// source plugin's setup check is replaced with it, so what runs is
    /// never the plugin's text, and a repair's polling still has a check to
    /// verify with (threat model T9). Nil for a CLI ASTRA doesn't know.
    public static func ownCheck(forCLI cli: String) -> [String]? {
        let status: [String: [String]] = [
            "gh": ["auth", "status"],
            "gcloud": ["config", "config-helper", "--format=value(credential.token_expiry)"],
            "az": ["account", "show"],
            "aws": ["sts", "get-caller-identity"],
            "docker": ["info"]
        ]
        if let check = status[cli] { return check }
        guard let forms = versionForms[cli] else { return nil }
        return forms.contains { $0.matches(["--version"]) } ? ["--version"] : ["version"]
    }

    /// The CLIs ASTRA knows: the only ones with a version check, and the only
    /// ones a Terminal repair may sign in with (`TerminalRepairPolicy`).
    public static var knownCLIs: Set<String> { Set(versionForms.keys) }

    /// Checks allowed only as these exact arguments. `osascript -e` runs any
    /// script, so only the one that returns a constant is a status check.
    /// `gcloud config config-helper` and `gcloud auth application-default
    /// print-access-token` print an access token unless `--format` says
    /// otherwise, and the checker shows stdout as the CLI's "version": each
    /// refreshes the credential it reads and prints only its expiry, or
    /// (`--format=none`) nothing.
    static let exactChecks: [String: Set<[String]>] = [
        "osascript": [["-e", "return \"ok\""]],
        "gcloud": [
            ["config", "config-helper", "--format=value(credential.token_expiry)"],
            ["auth", "application-default", "print-access-token", "--format=none"]
        ]
    ]

    /// True when running `binary` (a name or path) with `arguments` is a
    /// read-only status check.
    public static func isReadOnly(binary: String, arguments: [String]) -> Bool {
        let cli = (binary as NSString).lastPathComponent
        // A known CLI's name is not its identity: `/tmp/plugin/gh` is not
        // the GitHub CLI (`TrustedExecutablePath`).
        guard !arguments.isEmpty, TrustedExecutablePath.isTrustedDeclaration(binary) else { return false }
        if exactChecks[cli]?.contains(arguments) == true { return true }
        return ((versionForms[cli] ?? []) + (checks[cli] ?? [])).contains { $0.matches(arguments) }
    }

    /// True for a check that runs nothing: no arguments, so ASTRA only finds
    /// `binary` (a bare name on its own search path, or a plain absolute
    /// path) and never starts it. For a CLI with no known status command,
    /// such as an MCP server's (`acme-mcp`): missing, it is a pending step.
    public static func isExistenceOnly(binary: String, arguments: [String]) -> Bool {
        guard arguments.isEmpty else { return false }
        return TrustedExecutablePath.isTrustedDeclaration(binary)
            || (binary.range(of: #"^(/[A-Za-z0-9._+-]+)+$"#, options: .regularExpression) != nil
                && !binary.split(separator: "/").contains { $0 == "." || $0 == ".." })
    }

    /// Why `binary arguments` is not run, for the component's status.
    public static func refusal(binary: String, arguments: [String]) -> String {
        let command = ([binary] + arguments).joined(separator: " ")
        return "not checked: ASTRA runs only read-only status checks, and `\(command)` isn't one"
    }
}
