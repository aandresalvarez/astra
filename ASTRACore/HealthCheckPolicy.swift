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
/// listed as taking one. Any CLI may report `--version` or `version`; a bare
/// call, which may start an interactive session, is refused. A check that
/// fails is never run (`HealthStatus.notChecked`, which is not a pass), and
/// import refuses it (`CapabilityPackageValidator`).
/// The sibling rule for repairs is `TerminalRepairPolicy`.
public enum HealthCheckPolicy {
    typealias Check = CLICommandShape

    /// Any CLI: `--version` or `version`.
    static let versionChecks = [Check(positionals: [], booleanFlags: ["--version"]), Check(positionals: ["version"])]

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

    /// Checks allowed only as these exact arguments. `osascript -e` runs any
    /// script, so only the one that returns a constant is a status check.
    /// `gcloud config config-helper` and `gcloud auth application-default
    /// print-access-token` print an access token unless `--format` picks the
    /// expiry, and the checker shows stdout as the CLI's "version": each
    /// refreshes the credential it reads and prints only when that expires.
    static let exactChecks: [String: Set<[String]>] = [
        "osascript": [["-e", "return \"ok\""]],
        "gcloud": [
            ["config", "config-helper", "--format=value(credential.token_expiry)"],
            ["auth", "application-default", "print-access-token", "--format=value(expiry)"]
        ]
    ]

    /// True when running `binary` (a name or path) with `arguments` is a
    /// read-only status check.
    public static func isReadOnly(binary: String, arguments: [String]) -> Bool {
        let cli = (binary as NSString).lastPathComponent
        guard !arguments.isEmpty else { return false }
        if exactChecks[cli]?.contains(arguments) == true { return true }
        return (versionChecks + (checks[cli] ?? [])).contains { $0.matches(arguments) }
    }

    /// Why `binary arguments` is not run, for the component's status.
    public static func refusal(binary: String, arguments: [String]) -> String {
        let command = ([binary] + arguments).joined(separator: " ")
        return "not checked: ASTRA runs only read-only status checks, and `\(command)` isn't one"
    }
}
