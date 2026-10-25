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
/// own failure. A call that `&&`, `||` or a branch may have skipped counts
/// only when the line shows it ran (`provablyRuns`).
/// Patterns are whole diagnostics, not fragments.
enum CLISessionExpiryClassifier {
    struct Family: Equatable, Sendable {
        let commands: [String]
        let displayName: String
        var signInCommand: String
        var checkBinary: String
        var checkArguments: [String]
        let patterns: [String]
        /// Signing in again fixes it. Not so for a token the environment
        /// supplies (`GH_TOKEN`), which overrides the stored sign-in.
        var offersSignIn = true
        var customStopMessage: String? = nil
        /// A custom stop message ends by naming the check Resume runs, so a
        /// host or executable path it targets survives in the message that
        /// `family(forStopMessage:)` reads back.
        var namesCheck = false
        /// Chosen only when every Google Cloud call in the command reads
        /// Application Default Credentials (`readsOnlyApplicationDefault`).
        var readsApplicationDefault = false
        /// Credential-store selectors the failed call set on itself
        /// (`CLOUDSDK_CONFIG=/team gcloud …`): only the read-only check uses
        /// that store. Login needs manual setup (`RepairAction.checkSelectors`).
        var storeSelectors: [String: String] = [:]
        /// Credential variables the failed call set on itself that ASTRA
        /// can't carry (`GH_TOKEN=… gh …`, another account): nothing signs in
        /// to or checks an unrelated store, so Resume doesn't wait.
        var ownCredentials: [String] = []

        var stopMessage: String {
            guard ownCredentials.isEmpty else {
                return "The \(displayName) credentials that command chose itself (\(ownCredentials.joined(separator: ", "))) were rejected. "
                    + "ASTRA can't sign in to or check those for you: fix them where the command sets them, then resume."
            }
            var message: String
            if let customStopMessage {
                message = namesCheck
                    ? "\(customStopMessage) Resume first checks `\(checkBinary) \(checkArguments.joined(separator: " "))`."
                    : customStopMessage
            } else {
                message = "The \(displayName) sign-in expired while the agent was using it. Run `\(signInCommand)`, then resume."
            }
            if !storeSelectors.isEmpty {
                message += CLISessionExpiryClassifier.storeSelectorsLead
                    + storeSelectors.sorted { $0.key < $1.key }.map { "\($0.key)=`\($0.value)`" }.joined(separator: ", ") + "."
            }
            return message
        }

        /// The same family for a call that set its own credentials.
        func withOwnCredentials(_ names: [String]) -> Family {
            var family = self
            family.ownCredentials = names
            family.offersSignIn = false
            return family
        }

        /// The sign-in repair, or for a family whose fix is outside ASTRA
        /// (`offersSignIn` false) a check-only one whose guidance is the
        /// family's own: Resume still re-runs the check, and a failed check
        /// repeats what actually fixes it.
        var repair: RepairAction {
            let checks = ownCredentials.isEmpty
            var repair = RepairAction(
                strategy: .terminal,
                componentName: "\(displayName) login",
                title: offersSignIn ? "Sign in to \(displayName)" : "Fix \(displayName) access",
                verb: offersSignIn ? "Sign in" : "Check",
                detail: offersSignIn || (customStopMessage == nil && checks)
                    ? "Run `\(signInCommand)` in Terminal, then resume the task."
                    : stopMessage,
                command: offersSignIn ? signInCommand : nil,
                checkBinary: checks ? checkBinary : nil,
                checkArguments: checks ? checkArguments : nil,
                checkExpect: checks && (checkBinary as NSString).lastPathComponent == "gcloud" && !readsApplicationDefault
                    ? SemanticCheck.stdoutNonEmpty.rawValue : nil,
                checkTimeout: checks && (checkBinary as NSString).lastPathComponent == "gcloud"
                    ? CommonCLIPrerequisites.gcloudSlowStartTimeout : nil
            )
            repair.checkSelectors = storeSelectors.isEmpty ? nil : storeSelectors
            return repair.targetingCredentialStore(storeSelectors)
        }

        /// The same family signing in to and checking a GitHub Enterprise
        /// host (`enterpriseHost` validated) instead of github.com.
        func onHost(_ host: String) -> Family {
            var family = self
            family.signInCommand += " --hostname \(host)"
            family.checkArguments = ["auth", "status", "--active", "--hostname", host]
            family.namesCheck = true
            return family
        }

        /// The same family checking the active account on every host
        /// (`gh auth status --active`): the command's `gh` calls named
        /// different hosts, or ran outside the run's checkout, so which host
        /// failed is unknown, and checking any one of them could pass while
        /// the failing one is still signed out. Sign-in stays manual.
        func onEveryHost() -> Family {
            var family = self
            family.offersSignIn = false
            family.checkArguments = ["auth", "status", "--active"]
            family.namesCheck = true
            if family.customStopMessage == nil {
                family.customStopMessage = "The \(displayName) sign-in expired while the agent was using it, on one of several hosts its command used. Sign in again to the host that failed, then resume."
            }
            return family
        }

        /// The application-default family when the run's
        /// `GOOGLE_APPLICATION_CREDENTIALS` picks its credential file: that
        /// file, not the one `gcloud auth application-default login` writes,
        /// is what failed and what Resume checks, so there is no sign-in to
        /// offer, only guidance naming the variable and the file. A file
        /// path that is not safe to show in backticks is left out.
        func credentialFile(_ file: String?) -> Family {
            var family = self
            let named = file.map { file in
                file.contains("`") || file.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? "" : " `\(file)`,"
            } ?? ""
            family.offersSignIn = false
            family.customStopMessage = "Google Cloud rejected the application default credentials in\(named) the file GOOGLE_APPLICATION_CREDENTIALS names. That variable overrides `gcloud auth application-default login`, so signing in won't help: update that file, or remove the variable where ASTRA's environment gets it, then resume."
            return family
        }

        /// The same family checking and signing in with the installation the
        /// failed command ran (`exactExecutable` validated), not whichever
        /// one PATH finds first.
        func at(_ executable: String) -> Family {
            var family = self
            family.signInCommand = executable + signInCommand.dropFirst(checkBinary.count)
            family.checkBinary = executable
            family.namesCheck = true
            return family
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

    /// Application Default Credentials are a separate sign-in from the CLI's
    /// own account: `gcloud auth application-default login` writes them, and
    /// a healthy `gcloud auth login` says nothing about them. So a failed
    /// `gcloud auth application-default print-access-token` keeps ADC setup
    /// manual and retains its separate check. The check is that same command with `--format=none`: it
    /// refreshes the credential and exits non-zero when it cannot, and
    /// prints nothing, so no token reaches ASTRA. Its exit status alone is
    /// the result (no semantic test): the command returns a credentials
    /// object, whose `expiry` is set only by some credential types' refresh.
    static let googleCloudApplicationDefault = Family(
        commands: ["gcloud"],
        displayName: "Google Cloud application default credentials",
        signInCommand: "gcloud auth application-default login",
        checkBinary: "gcloud",
        checkArguments: ["auth", "application-default", "print-access-token", "--format=none"],
        patterns: googleCloud.patterns + ["please run:\n\n  $ gcloud auth application-default login"],
        offersSignIn: false,
        readsApplicationDefault: true
    )

    static let gitHub = Family(
        commands: ["gh"],
        displayName: "GitHub",
        signInCommand: "gh auth login",
        checkBinary: "gh",
        checkArguments: ["auth", "status", "--active", "--hostname", "github.com"],
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
        checkArguments: ["auth", "status", "--active", "--hostname", "github.com"],
        patterns: ["the token in gh_token is invalid", "the token in github_token is invalid"],
        offersSignIn: false,
        customStopMessage: "GitHub rejected the token in GH_TOKEN or GITHUB_TOKEN. That variable overrides any sign-in, so signing in again won't help: update or remove it where ASTRA's environment gets it, then resume."
    )

    /// The same for `GH_ENTERPRISE_TOKEN` or `GITHUB_ENTERPRISE_TOKEN`, the
    /// tokens `gh` uses for a GitHub Enterprise Server host. The host the
    /// command targeted is kept (`onHost`), else the launch's `GH_HOST`
    /// retargets the check (`checkingLaunchHost`).
    static let gitHubEnterpriseToken = Family(
        commands: ["gh"],
        displayName: "GitHub",
        signInCommand: "gh auth login",
        checkBinary: "gh",
        checkArguments: ["auth", "status", "--active", "--hostname", "github.com"],
        patterns: ["the token in gh_enterprise_token is invalid", "the token in github_enterprise_token is invalid"],
        offersSignIn: false,
        customStopMessage: "GitHub Enterprise rejected the token in GH_ENTERPRISE_TOKEN or GITHUB_ENTERPRISE_TOKEN. That variable overrides any sign-in, so signing in again won't help: update or remove it where ASTRA's environment gets it, then resume."
    )

    static let families = [googleCloudApplicationDefault, googleCloud, gitHubEnterpriseToken, gitHubEnvironmentToken, gitHub]

    /// The tools that run a shell command, as each provider names them:
    /// Claude's `Bash`, Codex's `command_execution`, Cursor's
    /// `shellToolCall`, Antigravity's `run_command`, and the like. Another
    /// tool (an MCP tool, a file read) whose input has a `command` field ran
    /// no CLI, so its result never stops the run.
    static func isShellTool(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "bash", "shell", "command_execution", "local_shell", "local_shell_call", "exec_command", "shell_command",
            "run_shell_command", "run_command", "run_terminal_cmd", "shelltoolcall", "terminal"
        ].contains(normalized) || normalized.hasPrefix("bash(") || normalized.hasPrefix("shell(")
    }

    struct Stop: Equatable {
        let reason: String
        let message: String
        let repairContext: RuntimeRepairContext?

        init(reason: String, message: String, repairContext: RuntimeRepairContext? = nil) {
            self.reason = reason
            self.message = message
            self.repairContext = repairContext
        }
    }

    /// A stop when `content` is a sign-in failure printed by a command that
    /// runs one of the known CLIs. `failed` is the tool result's error flag:
    /// when the line succeeded, the CLI must have run where its own exit
    /// status was masked (`masksExitStatus`).
    static func stop(content: String, command: String?, failed: Bool = true) -> Stop? {
        guard let command, let family = family(content: content, command: command, failed: failed) else { return nil }
        guard RuntimeRepairInvocationPolicy.permitsAutomaticRepair(command: command, commands: family.commands) else {
            let message = "Authentication failed in a shell context ASTRA cannot safely identify. "
                + "Review the command and its user, directory and credential store, then repair access manually before resuming."
            return Stop(reason: TaskRunStopReason.capabilitySessionExpired.rawValue, message: message,
                        repairContext: .manualReview(message: message))
        }
        return Stop(
            reason: TaskRunStopReason.capabilitySessionExpired.rawValue, message: family.stopMessage,
            repairContext: RuntimeRepairContext(providerBinary: family.checkBinary, message: family.stopMessage,
                                               repair: family.repair, offersAction: family.repair.command != nil)
        )
    }

    static func family(
        content: String, command: String?, failed: Bool = true,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Family? {
        guard let command, !command.isEmpty,
              RuntimeRepairInvocationPolicy.admitsDiagnostics(command: command, content: content) else { return nil }
        let lowered = content.lowercased()
        let applicationDefault = readsOnlyApplicationDefault(command)
        guard var family = families.first(where: { family in
            family.commands.contains { failed ? failureReaches(from: $0, in: command) : masksExitStatus(of: $0, in: command) }
                && family.patterns.contains { lowered.contains($0) }
                && (!family.readsApplicationDefault || applicationDefault == true)
                && (family.checkBinary != "gcloud" || applicationDefault != nil)
        }) else { return nil }
        // A GitHub Enterprise host the command targeted is the one to sign
        // in to and check; github.com's login says nothing about it. A
        // command whose every call names github.com pins it. Calls that name
        // different hosts, a repository on the default host, or a `cd` away
        // from the run's checkout leave the host unknown: the check covers
        // every host. Only a command that names no host leaves `gh` to infer
        // it from the checkout (`checkingCheckoutHost`).
        if family.checkBinary == "gh" {
            if let host = gitHubHost(in: command) {
                family = family.onHost(host)
            } else if namesOnlyGitHubCom(command) {
                family = family.onHost("github.com")
            } else if !leavesGitHubHostToCheckout(command) {
                family = family.onEveryHost()
            }
        }
        // A store the call selected itself is the one to sign in to and
        // check; credentials it set itself are not ASTRA's to check.
        let local = commandLocalCredentials(of: family, in: command)
        if !local.own.isEmpty {
            family = family.withOwnCredentials(local.own)
        } else {
            family.storeSelectors = local.selectors
        }
        // So is the installation it ran by path: another one on PATH may be
        // signed in while this one is not.
        if let executable = executablePath(of: family.checkBinary, in: command)
            ?? siblingCheckExecutable(of: family, in: command, isExecutable: isExecutable) {
            family = family.at(executable)
        }
        return family
    }

    /// True when `command` calls Google Cloud only as `gcloud auth
    /// application-default …`, on any release track and after any
    /// gcloud-wide flags. False when a call is another gcloud command, or a
    /// bq or gsutil call: the command may have failed on the CLI account
    /// instead. Nil when a call's flags leave its command unknown
    /// (`applicationDefaultReadings`): neither sign-in is offered, since
    /// `gcloud auth login` for a failed ADC read fixes nothing.
    static func readsOnlyApplicationDefault(_ command: String) -> Bool? {
        let calls = simpleCommands(command).compactMap { words -> [String]? in
            var rest = words
            stripWrappers(&rest)
            guard let executable = rest.first, googleCloud.commands.contains((executable as NSString).lastPathComponent) else { return nil }
            return rest
        }
        guard !calls.isEmpty else { return false }
        let readings = calls.map { call in
            (call[0] as NSString).lastPathComponent == "gcloud" ? applicationDefaultReadings(call.dropFirst()) : [false]
        }
        if readings.contains([false]) { return false }
        return readings.allSatisfy { $0 == [true] } ? true : nil
    }

    /// Whether a gcloud call's command group is `auth application-default`,
    /// after an optional release track, for each way its flags can be read.
    /// One answer when every flag before the command is a known gcloud-wide
    /// one (`gcloudValueFlags` take the next word, `gcloudBooleanFlags`
    /// don't, `--flag=value` carries its own); an unknown `--flag word` may
    /// be either, so both readings count. Past `maxUnknownFlags`, the call
    /// is unknown.
    private static func applicationDefaultReadings(_ arguments: ArraySlice<String>, positionals: [String] = [], unknownFlags: Int = 0) -> Set<Bool> {
        var positionals = positionals
        var rest = arguments
        while let word = rest.first, positionals.count < 3 {
            rest = rest.dropFirst()
            if word == "--" { break }
            guard word.hasPrefix("-"), word != "-" else {
                positionals.append(word)
                continue
            }
            if word.contains("=") || gcloudBooleanFlags.contains(word) { continue }
            if gcloudValueFlags.contains(word) {
                rest = rest.dropFirst()
                continue
            }
            guard unknownFlags < maxUnknownFlags else { return [true, false] }
            return applicationDefaultReadings(rest, positionals: positionals, unknownFlags: unknownFlags + 1)
                .union(applicationDefaultReadings(rest.dropFirst(), positionals: positionals, unknownFlags: unknownFlags + 1))
        }
        if let track = positionals.first, gcloudReleaseTracks.contains(track) { positionals.removeFirst() }
        return [Array(positionals.prefix(2)) == ["auth", "application-default"]]
    }

    private static let maxUnknownFlags = 4

    /// gcloud's release tracks, the optional first word of a command.
    private static let gcloudReleaseTracks: Set<String> = ["alpha", "beta"]

    /// gcloud-wide flags (`gcloud topic flags`) that take a value, and
    /// those that take none.
    private static let gcloudValueFlags: Set<String> = [
        "--project", "--account", "--configuration", "--impersonate-service-account", "--access-token-file",
        "--credential-file-override", "--billing-project", "--verbosity", "--format", "--flatten", "--flags-file", "--trace-token"
    ]
    private static let gcloudBooleanFlags: Set<String> = [
        "--quiet", "-q", "--help", "-h", "--log-http", "--no-log-http", "--user-output-enabled", "--no-user-output-enabled"
    ]

    /// The check CLI installed beside a companion that `command` runs by path
    /// (`/opt/google-cloud-sdk/bin/bq` → `…/bin/gcloud`): `bq` and `gsutil`
    /// read that SDK's sign-in. Nil when the check CLI itself runs in
    /// `command` (by name: PATH picks it), no companion or several run by
    /// path, or no executable check CLI sits beside it (a standalone `gsutil`).
    static func siblingCheckExecutable(of family: Family, in command: String, isExecutable: (String) -> Bool) -> String? {
        guard !runs(family.checkBinary, in: command) else { return nil }
        let siblings = Set(family.commands.filter { $0 != family.checkBinary }.compactMap { companion in
            executablePath(of: companion, in: command).map {
                (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent(family.checkBinary)
            }
        })
        guard siblings.count == 1, let sibling = siblings.first.flatMap(exactExecutable), isExecutable(sibling) else { return nil }
        return sibling
    }

    /// The family whose stop message this is; the message is ASTRA's own.
    static func family(forStopMessage fullMessage: String?) -> Family? {
        guard let fullMessage else { return nil }
        // A store the call selected comes last; the rest is read without it.
        let selectorsStart = fullMessage.range(of: storeSelectorsLead)
        let message = selectorsStart.map { String(fullMessage[..<$0.lowerBound]) } ?? fullMessage
        let selectors = selectorsStart.map { storeSelectors(in: String(fullMessage[$0.upperBound...])) } ?? [:]
        let ownCredentials = message.range(of: " credentials that command chose itself (").flatMap { start in
            message[start.upperBound...].firstIndex(of: ")").map {
                message[start.upperBound..<$0].components(separatedBy: ", ")
            }
        }
        // An enterprise stop names its host, and a stop for an installation
        // run by path names that path, in the sign-in or check command.
        let host = message.range(of: " --hostname ").flatMap { start in
            message[start.upperBound...].firstIndex(of: "`").flatMap { enterpriseHost(String(message[start.upperBound..<$0])) }
        }
        // The last one: a credential file named earlier is not the CLI.
        let executable = message.range(of: "`/", options: .backwards).flatMap { start in
            let path = message[message.index(before: start.upperBound)...].prefix { $0 != " " && $0 != "`" }
            return exactExecutable(String(path))
        }
        for family in families {
            var candidates = [family]
            if family.readsApplicationDefault {
                let file = message.range(of: "application default credentials in `").flatMap { start in
                    message[start.upperBound...].range(of: "`, the file GOOGLE_APPLICATION_CREDENTIALS names").map {
                        String(message[start.upperBound..<$0.lowerBound])
                    }
                }
                candidates.append(family.credentialFile(file))
            }
            if family.checkBinary == "gh" {
                if let host { candidates.append(family.onHost(host)) }
                if message.contains(" --hostname github.com`") { candidates.append(family.onHost("github.com")) }
                candidates.append(family.onEveryHost())
            }
            if let ownCredentials { candidates += candidates.map { $0.withOwnCredentials(ownCredentials) } }
            if !selectors.isEmpty {
                candidates = candidates.map { candidate in
                    var selected = candidate
                    selected.storeSelectors = selectors
                    return selected
                }
            }
            if let executable, (executable as NSString).lastPathComponent == family.checkBinary {
                candidates += candidates.map { $0.at(executable) }
            }
            if let match = candidates.first(where: { $0.stopMessage == fullMessage }) { return match }
        }
        return nil
    }

    /// Where a stop message names the store the failed call selected.
    static let storeSelectorsLead = " That command used its own credential store: "

    /// The `NAME=`value`` pairs after `storeSelectorsLead`.
    private static func storeSelectors(in text: String) -> [String: String] {
        var selectors: [String: String] = [:]
        for pair in text.dropLast().components(separatedBy: ", ") {
            guard let equals = pair.range(of: "=`"), pair.hasSuffix("`") else { return [:] }
            selectors[String(pair[..<equals.lowerBound])] = String(pair[equals.upperBound...].dropLast())
        }
        return selectors
    }

    /// Variables that hold or pick a credential ASTRA can't carry: a token,
    /// a credential file, or another account or configuration.
    private static let credentialNames: [String: Set<String>] = [
        "gcloud": RepairAction.credentialOverrideSelectors(for: "gcloud").union(["GOOGLE_APPLICATION_CREDENTIALS"]),
        "gh": ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"]
    ]

    /// gcloud's flags that pick another account, configuration or credential
    /// for one call: the repair can't reproduce them, so it checks nothing.
    private static let gcloudCredentialFlags = [
        "--account", "--configuration", "--impersonate-service-account", "--access-token-file", "--credential-file-override"
    ]

    /// The credential variables the family's calls in `command` set for
    /// themselves (`CLOUDSDK_CONFIG=/team gcloud …`, `env GH_CONFIG_DIR=/x gh
    /// …`, or an `export` earlier in the same shell scope): store selectors
    /// to carry, when every call sets the same plain absolute path, and what
    /// it can't carry (`own`): a credential variable, a selector the calls
    /// disagree on or that is not such a path, a variable `env` removed
    /// (`env -u GH_TOKEN`, `env -i`), or gcloud's `--account` and the like.
    /// With any of those, nothing signs in to or checks a store or account
    /// the call didn't use.
    static func commandLocalCredentials(of family: Family, in command: String) -> (selectors: [String: String], own: [String]) {
        let cli = (family.checkBinary as NSString).lastPathComponent
        let selectorNames = RepairAction.credentialStoreDirectorySelectors(for: cli)
        let watched = selectorNames.union(credentialNames[cli] ?? [])
        var own: Set<String> = []
        var exported: [(name: String, value: String?, scope: [Int])] = []
        var calls: [[String: String]] = []
        for segment in segments(command) {
            var rest = segment.words
            var assignments: [String] = []
            var cleared: [String] = []
            stripWrappers(&rest, assignments: &assignments, cleared: &cleared)
            if let builtin = rest.first, builtin == "export" || builtin == "unset" {
                for word in rest.dropFirst() {
                    let name = String(word.prefix { $0 != "=" })
                    guard watched.contains(name) else { continue }
                    if builtin == "unset" {
                        exported.append((name, nil, segment.scope))
                    } else if word.count > name.count {
                        exported.append((name, String(word.dropFirst(name.count + 1)), segment.scope))
                    }
                }
                continue
            }
            guard let executable = rest.first, family.commands.contains((executable as NSString).lastPathComponent) else { continue }
            if cleared.contains("*") { own.insert("env -i") }
            for name in cleared where watched.contains(name) { own.insert("env -u \(name)") }
            if (executable as NSString).lastPathComponent == "gcloud" {
                for argument in rest.dropFirst() {
                    for flag in gcloudCredentialFlags where argument == flag || argument.hasPrefix(flag + "=") { own.insert(flag) }
                }
            }
            var set: [String: String] = [:]
            for name in watched {
                if let entry = exported.last(where: { $0.name == name && segment.scope.starts(with: $0.scope) }), let value = entry.value {
                    set[name] = value
                }
            }
            for assignment in assignments {
                let name = String(assignment.prefix { $0 != "=" })
                if watched.contains(name) { set[name] = String(assignment.dropFirst(name.count + 1)) }
            }
            calls.append(set)
        }
        var selectors: [String: String] = [:]
        for name in Set(calls.flatMap(\.keys)) {
            let values = Set(calls.map { $0[name] })
            guard selectorNames.contains(name), values.count == 1, let value = values.first ?? nil,
                  value.hasPrefix("/"), value.count <= 1024, !value.contains("`"), !value.contains(", "),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { own.insert(name); continue }
            selectors[name] = value
        }
        return (own.isEmpty ? selectors : [:], own.sorted())
    }

    /// The absolute path `command` runs `cli` by (`/opt/team/bin/gh api
    /// user`), when every call to `cli` in it names that same path. Nil for a
    /// bare name, for calls that disagree, or for a path that is not safe as
    /// one Terminal word.
    static func executablePath(of cli: String, in command: String) -> String? {
        let executables = Set(simpleCommands(command).compactMap { words -> String? in
            var rest = words
            stripWrappers(&rest)
            guard let executable = rest.first, (executable as NSString).lastPathComponent == cli else { return nil }
            return executable
        })
        guard executables.count == 1, let executable = executables.first else { return nil }
        return exactExecutable(executable)
    }

    /// `candidate` when it is an installed path (`TrustedExecutablePath`):
    /// the path comes from the agent's own command, and Resume runs it and
    /// Sign in opens it in Terminal, so one the agent could have just
    /// written (`/tmp/x/gh`) is not carried. Invocation admission keeps
    /// that explicit untrusted call in manual review instead of repairing
    /// a different executable by name on PATH.
    private static func exactExecutable(_ candidate: String) -> String? {
        TrustedExecutablePath.installedPath(candidate)
    }

    /// The GitHub Enterprise host a `gh` call in `command` targets: its
    /// `--hostname` flag or the host of its `-R/--repo HOST/OWNER/REPO`, else
    /// the host of its `GH_REPO`, else its `GH_HOST`: assigned before it, or
    /// exported earlier in the same shell scope (`export GH_HOST=h; gh api
    /// user`; an `export` in a subshell does not reach past it, and `unset`
    /// clears one). Nil for github.com or a value that is not a plain host
    /// name, and nil when the `gh` calls disagree (`gh auth status --hostname
    /// a; gh auth status --hostname b`): which one failed is unknown, so the
    /// stop checks every host (`Family.onEveryHost`) rather than one that
    /// may be healthy.
    static func gitHubHost(in command: String) -> String? {
        let hosts = gitHubSelections(in: command).calls.map { $0.host.flatMap(enterpriseHost) }
        guard let host = hosts.first, hosts.allSatisfy({ $0 == host }) else { return nil }
        return host
    }

    /// True when no `gh` call in `command` selects a host or repository
    /// (`--hostname`, `-R/--repo`, `GH_HOST`, `GH_REPO`) and nothing in it
    /// changes directory: `gh` then infers the host from the run's checkout.
    static func leavesGitHubHostToCheckout(_ command: String) -> Bool {
        let selections = gitHubSelections(in: command)
        return !selections.changesDirectory && !selections.calls.contains(where: \.selects)
    }

    /// True when every `gh` call in `command` names github.com.
    static func namesOnlyGitHubCom(_ command: String) -> Bool {
        let calls = gitHubSelections(in: command).calls
        return !calls.isEmpty && calls.allSatisfy { $0.selects && $0.host?.lowercased() == "github.com" }
    }

    /// Each `gh` call's selected host (nil for the default host) and whether
    /// it selects one at all, and whether `command` changes directory.
    private static func gitHubSelections(in command: String) -> (calls: [(host: String?, selects: Bool)], changesDirectory: Bool) {
        var calls: [(host: String?, selects: Bool)] = []
        var changesDirectory = false
        // `export`ed and `unset` host variables, newest last, with the scope
        // they were set in.
        var exported: [(name: String, value: String?, scope: [Int])] = []
        for segment in segments(command) {
            var rest = segment.words
            var assignments: [String] = []
            stripWrappers(&rest, assignments: &assignments)
            if let builtin = rest.first, builtin == "export" || builtin == "unset" {
                for word in rest.dropFirst() {
                    let name = String(word.prefix { $0 != "=" })
                    guard ["GH_HOST", "GH_REPO"].contains(name) else { continue }
                    if builtin == "unset" {
                        exported.append((name, nil, segment.scope))
                    } else if word.count > name.count {
                        exported.append((name, String(word.dropFirst(name.count + 1)), segment.scope))
                    }
                }
                continue
            }
            if let builtin = rest.first, ["cd", "pushd", "popd"].contains(builtin) { changesDirectory = true }
            guard let executable = rest.first, (executable as NSString).lastPathComponent == "gh" else { continue }
            // `gh` treats an empty one as unset: `GH_HOST= gh api user`
            // still infers the host from the checkout.
            func assigned(_ name: String) -> String? {
                let value = assignments.last(where: { $0.hasPrefix("\(name)=") }).map { String($0.dropFirst(name.count + 1)) }
                    ?? exported.last { $0.name == name && segment.scope.starts(with: $0.scope) }?.value
                return value?.isEmpty == false ? value : nil
            }
            // A host-bearing `GH_REPO` names the repository, and with it the
            // host, so it outranks `GH_HOST`, the default for calls whose host
            // is neither given nor inferred (`gh help environment`).
            var declared = assigned("GH_REPO").flatMap(repositoryHost) ?? assigned("GH_HOST")
            var selects = assigned("GH_REPO") != nil || assigned("GH_HOST") != nil
            let arguments = Array(rest.dropFirst())
            for (index, argument) in arguments.enumerated() {
                let value = index + 1 < arguments.count ? arguments[index + 1] : nil
                if ["--hostname", "-R", "--repo"].contains(argument) || ["--hostname=", "--repo=", "-R"].contains(where: { argument.hasPrefix($0) }) {
                    selects = true
                }
                if argument == "--hostname", let value {
                    declared = value
                } else if argument.hasPrefix("--hostname=") {
                    declared = String(argument.dropFirst("--hostname=".count))
                } else if argument == "-R" || argument == "--repo", let host = value.flatMap(repositoryHost) {
                    declared = host
                } else if let host = ["--repo=", "-R"].lazy.compactMap({ argument.hasPrefix($0) ? String(argument.dropFirst($0.count)) : nil })
                    .first.flatMap(repositoryHost) {
                    declared = host
                }
            }
            calls.append((declared, selects))
        }
        return (calls, changesDirectory)
    }

    /// The host of a `HOST/OWNER/REPO` repository selector (`gh --repo`,
    /// `GH_REPO`); nil for `OWNER/REPO`, which means the default host.
    private static func repositoryHost(_ selector: String) -> String? {
        let parts = selector.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts.contains(where: \.isEmpty) else { return nil }
        return String(parts[0])
    }

    /// A GitHub check still aimed at github.com, by a command that named no
    /// host, while the resumed run's `GH_REPO` host (else its `GH_HOST`)
    /// names an enterprise host checks that host instead: `gh` sends that
    /// run's calls there. Its sign-in (`gh auth login`) signs in to that host
    /// too, so Sign in and the check agree: `GH_REPO` is not carried into
    /// Terminal. A host-bearing `GH_REPO` on github.com keeps github.com.
    static func checkingLaunchHost(_ repair: RepairAction) -> RepairAction {
        let environment = repair.checkEnvironment ?? [:]
        guard isUntargetedGitHubCheck(repair),
              let host = (environment["GH_REPO"].flatMap(repositoryHost) ?? environment["GH_HOST"]).flatMap(enterpriseHost)
        else { return repair }
        return retargeted(repair, to: host)
    }

    /// An application-default sign-in (recorded before the run's
    /// `GOOGLE_APPLICATION_CREDENTIALS` was known) for a run whose launch
    /// sets it becomes the check-only guidance about that file: the sign-in
    /// would write a file that run never reads.
    static func checkingCredentialFile(_ repair: RepairAction) -> RepairAction {
        guard repair.checkArguments == googleCloudApplicationDefault.checkArguments,
              let file = repair.checkEnvironment?["GOOGLE_APPLICATION_CREDENTIALS"], !file.isEmpty,
              let binary = repair.checkBinary
        else { return repair }
        var family = googleCloudApplicationDefault.credentialFile(file)
        if binary != family.checkBinary { family = family.at(binary) }
        var guidance = family.repair
        guidance.checkEnvironment = repair.checkEnvironment
        guidance.checkWorkingDirectory = repair.checkWorkingDirectory
        return guidance
    }

    /// A GitHub check still aimed at github.com, by a command that named no
    /// host, for a run whose launch selects none either (`GH_HOST`,
    /// `GH_REPO`; `gh` treats an empty one as unset), checks the host `gh`
    /// infers from the run's checkout (`checkWorkingDirectory`) when its
    /// remotes name one Enterprise host (`GitHubCheckoutHost`). Unchanged
    /// when the remotes can't be read,
    /// name several hosts or github.com: nothing is guessed. Not for the
    /// rejected-`GH_TOKEN` stop, a github.com token.
    static func checkingCheckoutHost(
        _ repair: RepairAction,
        readHost: (String) async -> String? = { await GitHubCheckoutHost.host(workingDirectory: $0) }
    ) async -> RepairAction {
        let environment = repair.checkEnvironment ?? [:]
        guard isUntargetedGitHubCheck(repair), environment["GH_HOST"]?.isEmpty != false, environment["GH_REPO"]?.isEmpty != false,
              repair.detail != gitHubEnvironmentToken.repair.detail,
              let directory = repair.checkWorkingDirectory,
              let host = await readHost(directory).flatMap(enterpriseHost)
        else { return repair }
        return retargeted(repair, to: host)
    }

    /// True for a `gh` repair still checking github.com whose sign-in and
    /// guidance name no host: one a launch or checkout host may retarget.
    private static func isUntargetedGitHubCheck(_ repair: RepairAction) -> Bool {
        guard let binary = repair.checkBinary, (binary as NSString).lastPathComponent == "gh",
              repair.checkArguments == gitHub.checkArguments else { return false }
        return ![repair.command ?? "", repair.detail].contains { $0.contains(" --hostname ") }
    }

    private static func retargeted(_ repair: RepairAction, to host: String) -> RepairAction {
        guard let binary = repair.checkBinary else { return repair }
        var hosted = repair
        hosted.checkArguments = gitHub.onHost(host).checkArguments
        if let command = repair.command, command == binary + gitHub.signInCommand.dropFirst(gitHub.checkBinary.count) {
            let retargeted = "\(command) --hostname \(host)"
            hosted.command = retargeted
            hosted.detail = repair.detail.replacingOccurrences(of: "`\(command)`", with: "`\(retargeted)`")
        }
        return hosted.enforcingTerminalPolicy()
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
    /// enclosing command is another program, or as the condition of an `if`,
    /// `elif`, `while` or `until` (which succeeds whether or not its
    /// condition does), so the CLI could fail while the line succeeds. A CLI
    /// that runs last, alone or after `&&`, does not count: its own success
    /// is the line's. Nor does `token=$(gh auth token)`, which exits with the
    /// substitution's status.
    static func masksExitStatus(of cli: String, in command: String) -> Bool {
        let segments = segments(command)
        let gates = gates(of: segments)
        return segments.indices.contains { index in
            let segment = segments[index]
            guard executes(cli, segment.words), provablyRuns(index, in: segments, gates: gates) else { return false }
            // A compound command's closing word (`}`, `fi`, `done`) carries
            // its status on: the operator after it is the one that decides.
            var end = index
            while end + 1 < segments.count, closes(segments[end + 1].words) { end += 1 }
            let separator = segments[end].separator
            return segment.enclosingCommands.contains { !executes(cli, $0) }
                || negates(segment.words)
                || isCondition(segment.words)
                // `&` runs it in the background, and the line succeeds,
                // even when nothing follows (`gh auth status &`).
                || separator == "&"
                || (end < segments.count - 1 && statusMaskingSeparators.contains(separator))
        }
    }

    /// Separators after which a command's failure still reaches the line's
    /// status: `&&` ends the line at a failure, a pipe hands its output on,
    /// and a parenthesis or backtick only opens or closes a group.
    private static let failurePassingSeparators: Set<String> = ["&&", "|", "|&", "(", ")", "`"]

    /// True when a failed line's status could be `cli`'s failure: a call to
    /// it whose status the line reaches (only `&&`, pipes, the end of a
    /// compound command, or a substitution's parentheses after it; not
    /// negated, not a condition or in the background), so a substitution
    /// counts when the command it feeds is the one that failed.
    /// `gh --version; cat incident.txt; false` failed on `false`.
    static func failureReaches(from cli: String, in command: String) -> Bool {
        let segments = segments(command)
        let gates = gates(of: segments)
        return segments.indices.contains { index in
            let segment = segments[index]
            guard executes(cli, segment.words), !negates(segment.words), !isCondition(segment.words),
                  provablyRuns(index, in: segments, gates: gates) else { return false }
            var position = index
            while position < segments.count - 1 {
                // `|| exit 1` (or `|| { …; exit 1; }`) ends the line with the
                // failure it caught.
                if segments[position].separator == "||", exitsWithFailure(after: position, in: segments) { return true }
                guard failurePassingSeparators.contains(segments[position].separator)
                    || closes(segments[position + 1].words) else { return false }
                position += 1
            }
            return segments[position].separator != "&"
        }
    }

    /// True when the command after the `||` at `position` is `exit` or
    /// `return` with a status other than 0 (none passes the failure on),
    /// alone or inside a `{ …; }` group it opens.
    private static func exitsWithFailure(after position: Int, in segments: [Segment]) -> Bool {
        func exits(_ words: [String]) -> Bool {
            let rest = words.drop { reservedWords.contains($0) }
            guard let first = rest.first, first == "exit" || first == "return" else { return false }
            return rest.dropFirst().first.map { $0 != "0" } ?? true
        }
        guard position + 1 < segments.count else { return false }
        let next = segments[position + 1]
        if exits(next.words) { return true }
        guard next.words.first == "{" else { return false }
        for segment in segments[(position + 1)...] {
            if exits(segment.words) { return true }
            if closes(segment.words) { return false }
        }
        return false
    }

    /// Commands that print no known CLI's diagnostic, only their own errors:
    /// what a call is commonly gated on (`cd repo && gh pr list`).
    private static let quietCommands: Set<String> = [
        "cd", "pushd", "popd", "export", "unset", "true", "false", ":", "test", "[", "[[", "mkdir", "sleep", "exit", "return"
    ]

    /// What may have skipped a command: the `&&` (true) and `||` (false)
    /// operators before it in its own list, the innermost branch or loop
    /// body it is in at its own level (`then`, `else`, `elif`, `do`), and
    /// whether the group or substitution it runs in was itself gated.
    private struct Gate {
        var list: [Bool] = []
        var body: Int?
        var inherited = false
        /// Every body it is in, at any level.
        var bodies: Set<Int> = []

        var isOpen: Bool { list.isEmpty && body == nil && !inherited }
    }

    /// Each segment's `Gate`, read left to right: an operator applies at
    /// the level its segment ends on (a group's last segment carries the
    /// operator after the group), and `;`, `&` or a newline starts a new list.
    private static func gates(of segments: [Segment]) -> [Gate] {
        struct Level {
            var scope: [Int]
            var inherited: Bool
            var outerBodies: Set<Int>
            var list: [Bool] = []
            /// Open compound commands, each with the body it is in (nil in
            /// its condition).
            var compounds: [Int?] = []
        }
        var levels = [Level(scope: [], inherited: false, outerBodies: [])]
        var nextBody = 0
        var gates: [Gate] = []
        for (index, segment) in segments.enumerated() {
            while levels.count > 1, !segment.scope.starts(with: levels[levels.count - 1].scope) { levels.removeLast() }
            while levels[levels.count - 1].scope.count < segment.scope.count {
                let parent = levels[levels.count - 1]
                let bodies = parent.outerBodies.union(parent.compounds.compactMap { $0 })
                levels.append(Level(
                    scope: Array(segment.scope.prefix(parent.scope.count + 1)),
                    inherited: parent.inherited || !parent.list.isEmpty || !bodies.isEmpty,
                    outerBodies: bodies
                ))
            }
            let top = levels.count - 1
            for word in segment.words.prefix(while: reservedWords.contains) {
                switch word {
                case "if", "while", "until":
                    levels[top].compounds.append(nil)
                // An `elif`'s condition and its `then` body are one: skipping
                // one skips the other.
                case "then", "do", "else", "elif":
                    guard !levels[top].compounds.isEmpty else { break }
                    guard ["else", "elif"].contains(word) || levels[top].compounds[levels[top].compounds.count - 1] == nil else { break }
                    levels[top].compounds[levels[top].compounds.count - 1] = nextBody
                    nextBody += 1
                case "fi", "done":
                    _ = levels[top].compounds.popLast()
                default:
                    break
                }
            }
            let level = levels[top]
            gates.append(Gate(
                list: level.list, body: level.compounds.last { $0 != nil } ?? nil, inherited: level.inherited,
                bodies: level.outerBodies.union(level.compounds.compactMap { $0 })
            ))
            let next = index + 1 < segments.count ? segments[index + 1].scope : []
            let depth = zip(segment.scope, next).prefix { $0 == $1 }.count
            guard let target = levels.lastIndex(where: { $0.scope.count == depth }) else { continue }
            switch segment.separator {
            case "&&", "||": levels[target].list.append(segment.separator == "&&")
            case ";", "\n", "&": levels[target].list = []
            default: break
            }
        }
        return gates
    }

    /// True when the call at `index` ran, or the line shows it did. A call
    /// after `&&` or `||`, or in a branch or loop body, may have been
    /// skipped (`cat incident.txt; false && gh api user` runs no `gh`), and
    /// then a sign-in error in the output is another command's. So it counts
    /// only when every command that could have run without it is quiet
    /// (`quietCommands`): each one before it, except the command its
    /// substitution feeds, which runs after it; and each one after it except
    /// its pipeline, and the rest of the `&&` chain or the body that skipped
    /// it. A `||` gate's skip succeeds, so the `&&` commands after it run.
    private static func provablyRuns(_ index: Int, in segments: [Segment], gates: [Gate]) -> Bool {
        let gate = gates[index]
        guard !gate.isOpen else { return true }
        let scope = segments[index].scope
        let earlier = segments.indices.prefix(index).allSatisfy { j in
            let feedsIt = ["(", "`"].contains(segments[j].separator)
                && scope.starts(with: segments[j + 1].scope) && segments[j + 1].scope.count > segments[j].scope.count
            return feedsIt || isQuiet(segments[j].words)
        }
        guard earlier else { return false }
        let andChain = !gate.inherited && gate.body == nil && gate.list.allSatisfy { $0 }
        var end = index
        while end + 1 < segments.count,
              ["|", "|&"].contains(segments[end].separator)
                || (andChain && segments[end].separator == "&&" && segments[end + 1].scope == scope) {
            end += 1
        }
        let body = gate.list.isEmpty && !gate.inherited ? gate.body : nil
        return segments.indices.dropFirst(end + 1).allSatisfy { k in
            body.map { gates[k].bodies.contains($0) } == true || isQuiet(segments[k].words)
        }
    }

    private static func isQuiet(_ words: [String]) -> Bool {
        var rest = words
        stripWrappers(&rest)
        return rest.first.map(quietCommands.contains) ?? true
    }

    /// Shell reserved words that open or continue a compound command: the
    /// word after one is a command (`if gh auth status; then …; fi`, `{ gh
    /// auth status; } 2>&1`).
    private static let reservedWords: Set<String> = ["if", "then", "elif", "else", "fi", "while", "until", "do", "done", "!", "{", "}"]

    /// Reserved words that close a compound command, whose status is then
    /// its last command's.
    private static let closingWords: Set<String> = ["}", "fi", "done"]

    /// True when this "command" only closes a compound command, perhaps with
    /// a redirection (`} 2>&1`).
    private static func closes(_ words: [String]) -> Bool {
        guard let first = words.first, closingWords.contains(first) else { return false }
        return words.dropFirst().allSatisfy { $0.contains(">") || $0.contains("<") }
    }

    /// Reserved words whose command is a condition.
    private static let conditionWords: Set<String> = ["if", "elif", "while", "until"]

    /// True when this command is a compound command's condition (`if gh
    /// auth status`, `then if ! gh …`).
    private static func isCondition(_ words: [String]) -> Bool {
        words.prefix { reservedWords.contains($0) }.contains { conditionWords.contains($0) }
    }

    /// True when the shell negates this command's status (`! gh auth
    /// status`, also after the `time` keyword or a reserved word such as
    /// `then`): the line succeeds exactly when the CLI fails.
    private static func negates(_ words: [String]) -> Bool {
        var rest = words.drop { reservedWords.contains($0) && $0 != "!" }
        if rest.first == "time" { rest = rest.dropFirst().drop { $0.hasPrefix("-") } }
        return rest.first == "!"
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
    /// inside single quotes they are literal text. A here-document's body
    /// (`<<EOF` or `<<-EOF` to its delimiter line) is text too.
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
        /// The subshells and substitutions it runs in, outermost first, each
        /// by its own number: an `export` reaches the commands after it whose
        /// scope starts with its own.
        var scope: [Int] = []
    }

    /// `depth` bounds the nesting a shell `-c` payload or a here-document's
    /// substitution parses into.
    static func segments(_ line: String, depth: Int = 0) -> [Segment] {
        parsedSegments(line, depth: depth) ?? []
    }

    /// Arithmetic is an expression, not a subshell executing its variable
    /// names. Unsupported syntax invalidates attribution for the whole line,
    /// including literal shell payloads and expanding here-documents.
    static func executionSegments(_ line: String) -> [Segment]? {
        parsedSegments(line, depth: 0)
    }

    private static func parsedSegments(_ line: String, depth: Int) -> [Segment]? {
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
        var groups: [(closer: Character, command: [String]?, id: Int, assignmentStart: Int?)] = []
        // Substitutions in an assignment (`TOKEN=$(gh auth token) echo ok`)
        // whose command was not known when they opened: their segments, and
        // the group depth where that command ends. A command that follows
        // (`echo`) feeds them; none (`TOKEN=$(gh …)` alone) leaves them be.
        var assignmentSubstitutions: [Range<Int>] = []
        var assignmentDepth = 0
        func closeGroup() {
            guard let group = groups.popLast() else { return }
            if let start = group.assignmentStart {
                assignmentSubstitutions.append(start..<segments.count)
                assignmentDepth = groups.count
            }
        }
        var groupCount = 0
        // Here-documents whose bodies follow this line, in order: the
        // delimiter, whether `<<-` strips leading tabs, whether the body
        // expands (its delimiter unquoted), and the command it feeds. A body
        // is text (`cat <<'EOF'` printing `$ gh auth status`), but an
        // expanding one still runs its substitutions (`$(gh auth status)`).
        var heredocs: [(delimiter: String, stripsTabs: Bool, expands: Bool, command: [String])] = []
        // Where the current word's delimiter starts, after an unquoted `<<`;
        // a bare `<<` takes the next word. A quote or backslash in the
        // delimiter makes the body literal.
        var heredocStart: (offset: Int, stripsTabs: Bool)?
        var heredocAwaitsWord: Bool?
        var heredocQuoted = false
        let characters = Array(line)
        var index = 0
        func endWord() {
            var feeds = words
            stripWrappers(&feeds)
            if let start = heredocStart {
                let delimiter = String(word.dropFirst(start.offset))
                if delimiter.isEmpty {
                    heredocAwaitsWord = start.stripsTabs
                } else {
                    heredocs.append((delimiter, start.stripsTabs, !heredocQuoted, feeds))
                    heredocQuoted = false
                }
                heredocStart = nil
            } else if inWord, let stripsTabs = heredocAwaitsWord {
                heredocs.append((word, stripsTabs, !heredocQuoted, feeds))
                heredocAwaitsWord = nil
                heredocQuoted = false
            }
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endCommand(_ separator: String) {
            endWord()
            words.removeAll { $0 == "$" }
            if !assignmentSubstitutions.isEmpty, groups.count == assignmentDepth {
                var command = words
                stripWrappers(&command)
                if !command.isEmpty {
                    for range in assignmentSubstitutions {
                        for index in range where index < segments.count { segments[index].enclosingCommands.append(command) }
                    }
                    assignmentSubstitutions = []
                } else if separator != "(" && separator != "`" {
                    assignmentSubstitutions = []
                }
            }
            if !words.isEmpty {
                segments.append(Segment(
                    words: words, separator: separator, enclosingCommands: groups.compactMap(\.command), scope: groups.map(\.id)
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
            // `$(…)`, and `<(…)` or `>(…)`, a process substitution, whose
            // command's status the line takes, not the substituted one's.
            let substitutes = opener == "`" || ["$", "<", ">"].contains { enclosing.last?.hasSuffix($0) == true }
            if opener == "(", substitutes { enclosing[enclosing.count - 1].removeLast() }
            enclosing.removeAll(where: \.isEmpty)
            let assigns = enclosing.contains { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil }
            stripWrappers(&enclosing)
            endCommand(String(opener))
            let pending = substitutes && enclosing.isEmpty && assigns
            groups.append((
                closer: closer, command: substitutes && !enclosing.isEmpty ? enclosing : nil, id: groupCount,
                assignmentStart: pending ? segments.count : nil
            ))
            groupCount += 1
        }
        func closeOrOpenGroup(_ character: Character) {
            guard character == ")" || (character == "`" && groups.last?.closer == "`") else {
                return openGroup(character, closer: character == "`" ? "`" : ")")
            }
            endCommand(String(character))
            if groups.last?.closer == character { closeGroup() }
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
                        if index + 1 < characters.count, characters[index + 1] == "(" { return nil }
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
            // This position is executable shell syntax, outside literals,
            // escaped characters and comment/here-document text.
            if character == "(", next == "(" { return nil }
            switch character {
            case "\\":
                escaped = true
                if heredocStart != nil || heredocAwaitsWord != nil { heredocQuoted = true }
            case "'", "\"":
                quote = character
                inWord = true
                if heredocStart != nil || heredocAwaitsWord != nil { heredocQuoted = true }
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
                closeGroup()
                substitutions.removeLast()
                quote = "\""
            case "(" where substitutions.last?.closer == ")", ")" where substitutions.last?.closer == ")":
                substitutions[substitutions.count - 1].depth += character == "(" ? 1 : -1
                closeOrOpenGroup(character)
            case "(", ")", "`":
                closeOrOpenGroup(character)
            case "#" where !inWord:
                // A comment runs to the end of the line: `false # ; gh auth
                // status` runs no `gh`.
                while index < characters.count, characters[index] != "\n" { index += 1 }
            case ";", "\n":
                endCommand(String(character))
                guard character == "\n" else { break }
                // Each pending here-document's body runs to its delimiter line.
                for heredoc in heredocs {
                    var body: [String] = []
                    while index < characters.count {
                        let end = characters[index...].firstIndex(of: "\n") ?? characters.count
                        let line = String(characters[index..<end])
                        index = min(end + 1, characters.count)
                        if (heredoc.stripsTabs ? String(line.drop { $0 == "\t" }) : line) == heredoc.delimiter { break }
                        body.append(line)
                    }
                    // An expanding body's substitutions run, feeding the
                    // command the here-document is for.
                    guard heredoc.expands, depth < maxShellDepth else { continue }
                    guard let expressions = heredocSubstitutions(body.joined(separator: "\n")) else { return nil }
                    for substitution in expressions {
                        guard let parsed = parsedSegments(substitution, depth: depth + 1) else { return nil }
                        segments += parsed.map { nested in
                            var nested = nested
                            nested.enclosingCommands = groups.compactMap(\.command) + [heredoc.command] + nested.enclosingCommands
                            nested.scope = groups.map(\.id) + [-1] + nested.scope
                            return nested
                        }
                    }
                }
                heredocs.removeAll()
                heredocAwaitsWord = nil
            case "<" where next == "<" && word.last != "<" && (index + 1 >= characters.count || characters[index + 1] != "<"):
                // `<<` or `<<-` starts a here-document (`<<<` is a string).
                index += 1
                let stripsTabs = index < characters.count && characters[index] == "-"
                if stripsTabs { index += 1 }
                word += stripsTabs ? "<<-" : "<<"
                inWord = true
                heredocStart = (word.count, stripsTabs)
                heredocQuoted = false
            default:
                // `$(` ends at the `(`, which starts the substituted command.
                word.append(character)
                inWord = true
            }
        }
        endCommand("")
        guard depth < maxShellDepth else { return segments }
        var expanded: [Segment] = []
        for segment in segments {
            guard let payload = shellPayloadSegments(segment, depth: depth) else { return nil }
            expanded += payload
        }
        return expanded
    }

    /// How deeply a shell `-c` payload or a here-document substitution is
    /// parsed into its commands.
    private static let maxShellDepth = 4

    /// A `sh`, `bash` or `zsh -c` call as the commands of its literal payload
    /// (`bash -lc 'gh auth status'`), which the shell runs, its status the
    /// last one's; any other command as itself. The payload's last command
    /// takes the call's separator, and all of them its substitution and
    /// scope, in a scope of their own.
    private static func shellPayloadSegments(_ segment: Segment, depth: Int) -> [Segment]? {
        guard let payload = shellPayload(segment.words) else { return [segment] }
        guard var nested = parsedSegments(payload, depth: depth + 1) else { return nil }
        guard !nested.isEmpty else { return [segment] }
        // What the shell ran under (`env GH_CONFIG_DIR=/team`, `GH_TOKEN=…`,
        // `env -u GH_TOKEN`) applies to every command it runs: each carries
        // it, after its own reserved words.
        var rest = segment.words
        stripWrappers(&rest)
        let prefix = segment.words.prefix(segment.words.count - rest.count).filter { !reservedWords.contains($0) }
        for index in nested.indices where !prefix.isEmpty {
            let words = nested[index].words
            let reserved = words.prefix { reservedWords.contains($0) }
            nested[index].words = Array(reserved) + prefix + words.dropFirst(reserved.count)
        }
        for index in nested.indices {
            nested[index].enclosingCommands = segment.enclosingCommands + nested[index].enclosingCommands
            nested[index].scope = segment.scope + [-2 - depth] + nested[index].scope
        }
        nested[nested.count - 1].separator = segment.separator
        return nested
    }

    /// The payload of `sh`, `bash` or `zsh` called with `-c` (alone or in a
    /// cluster such as `-lc`): its first operand after the options.
    static func shellPayload(_ words: [String]) -> String? {
        var rest = words
        stripWrappers(&rest)
        guard let shell = rest.first, ["sh", "bash", "zsh"].contains((shell as NSString).lastPathComponent) else { return nil }
        var runsPayload = false
        var index = 1
        while index < rest.count {
            let word = rest[index]
            index += 1
            if word == "-o" || word == "+o" {
                index += 1
            } else if word == "--" || word == "-" {
                break
            } else if word.hasPrefix("--") {
                continue
            } else if word.hasPrefix("-") || word.hasPrefix("+") {
                if word.hasPrefix("-"), word.dropFirst().contains("c") { runsPayload = true }
            } else {
                return runsPayload ? word : nil
            }
        }
        return runsPayload && index < rest.count ? rest[index] : nil
    }

    /// The commands an expanding here-document body substitutes: each
    /// `$(…)` (to its matching parenthesis) and backtick span; a backslash
    /// escapes the character after it.
    private static func heredocSubstitutions(_ body: String) -> [String]? {
        let characters = Array(body)
        var found: [String] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
            } else if character == "$", index + 1 < characters.count, characters[index + 1] == "(" {
                if index + 2 < characters.count, characters[index + 2] == "(" { return nil }
                var depth = 1
                var end = index + 2
                while end < characters.count, depth > 0 {
                    if characters[end] == "(" { depth += 1 } else if characters[end] == ")" { depth -= 1 }
                    end += 1
                }
                found.append(String(characters[(index + 2)..<max(index + 2, end - (depth == 0 ? 1 : 0))]))
                index = end
            } else if character == "`" {
                let end = characters[(index + 1)...].firstIndex(of: "`") ?? characters.count
                found.append(String(characters[(index + 1)..<end]))
                index = end + 1
            } else {
                index += 1
            }
        }
        return found
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
        "xargs": ["-I", "-L", "-n", "-P", "-s", "-d", "-E", "-a"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "gtimeout": ["-s", "-k", "--signal", "--kill-after"]
    ]

    /// Wrappers whose first operand, after their options, is not the
    /// command: `timeout [OPTION] DURATION COMMAND`.
    private static let durationWrappers: Set<String> = ["timeout", "gtimeout"]

    /// Drops leading assignments, wrappers with their options, and command
    /// substitutions, leaving the executable first.
    static func stripWrappers(_ words: inout [String]) {
        var assignments: [String] = []
        stripWrappers(&words, assignments: &assignments)
    }

    /// `stripWrappers`, collecting the `VAR=value` assignments it dropped.
    static func stripWrappers(_ words: inout [String], assignments: inout [String]) {
        var cleared: [String] = []
        stripWrappers(&words, assignments: &assignments, cleared: &cleared)
    }

    /// `stripWrappers`, also collecting the variables `env` removed: each
    /// `-u NAME` as `NAME`, and `-i` (or `-`), which empties the environment,
    /// as `*`.
    static func stripWrappers(_ words: inout [String], assignments: inout [String], cleared: inout [String]) {
        while let first = words.first {
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                assignments.append(words.removeFirst())
                continue
            }
            // The shell's negation and compound-command reserved words run
            // the command after them (`! gh …`, `if gh …; then gh …; fi`).
            if first.hasPrefix("$(") || reservedWords.contains(first) {
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
                if name == "env" {
                    if ["-i", "--ignore-environment", "-"].contains(option) {
                        cleared.append("*")
                    } else if option == "-u" || option == "--unset", let unset = words.first {
                        cleared.append(unset)
                    } else if option.hasPrefix("--unset=") {
                        cleared.append(String(option.dropFirst("--unset=".count)))
                    } else if option.hasPrefix("-u"), option.count > 2 {
                        cleared.append(String(option.dropFirst(2)))
                    }
                }
                // `-u name` takes the next word; `-uname` and `--user=name` don't.
                if valueOptions.contains(option), !option.contains("=") { _ = words.isEmpty ? nil : words.removeFirst() }
            }
            if durationWrappers.contains(name), !words.isEmpty { words.removeFirst() }
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
