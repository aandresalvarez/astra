import Foundation
import ASTRACore

enum ShellCommandRiskClassifier {
    enum Risk: String, Equatable {
        case read
        case fileRead
        case networkRead
        case mutation
        case destructive
        case credential
        case system
        case scriptExecution
        case packageMutation
        case unknown
    }

    struct Assessment: Equatable {
        var executable: String
        var pattern: String
        var risk: Risk
        var allowsTaskScopedReuse: Bool
    }

    static func assessment(forShellSegment segment: String) -> Assessment? {
        // Benign redirections (fd duplications like `2>&1`, discards to
        // /dev/null) must not make an otherwise-scopable command
        // unclassifiable — that is what turned a read-only `git status 2>&1`
        // into an un-grantable, run-killing request. Redirections to a named
        // file are left intact and still rejected as unsupported syntax below.
        let segment = strippingBenignRedirections(segment)
        guard !containsUnsupportedShellSyntax(segment) else { return nil }
        let tokens = shellTokens(segment)
        guard let rawExecutable = tokens.first,
              let executable = shellApprovalRoot(rawExecutable) else {
            return nil
        }
        let args = Array(tokens.dropFirst())
        let normalizedExecutable = executable.lowercased()
        let risk = riskForCommand(executable: normalizedExecutable, args: args)
        let pattern = shellApprovalPattern(executable: normalizedExecutable, args: args, risk: risk)
        let containsSensitiveArgument = args.contains(where: containsSensitivePathToken)
        guard !pattern.isEmpty else { return nil }
        return Assessment(
            executable: executable,
            pattern: pattern,
            risk: risk,
            allowsTaskScopedReuse: allowsTaskScopedReuse(
                risk: risk,
                pattern: pattern,
                containsSensitiveArgument: containsSensitiveArgument
            )
        )
    }

    /// Whether a mutating segment changes something outside this machine — a
    /// remote repository, a hosted service, cloud infrastructure, a remote
    /// database — rather than the workspace. Ask and Custom ask before these
    /// even when a Custom rule allows the command family (`ExternalActionPolicy`,
    /// `AgentRuntimePolicyGuard`). Local writes such as `git commit` or `mv`
    /// stay with the user's per-item rules.
    static func actsOutsideMachine(forShellSegment segment: String) -> Bool {
        guard let assessment = assessment(forShellSegment: segment),
              [.mutation, .destructive, .packageMutation].contains(assessment.risk) else {
            return false
        }
        let args = Array(shellTokens(strippingBenignRedirections(segment)).dropFirst()).map(comparableCommandArgument)
        let executable = assessment.executable.lowercased()
        switch executable {
        case "git":
            // `send-pack` is the plumbing under `push`; a dry run changes nothing.
            // An alias or extension (`-c alias.ship=push ship`, `lfs push`) runs
            // something this cannot read, so it is not declared local.
            guard let verb = dropLeadingOptions(args, optionsWithValues: ["-c", "-C", "--git-dir", "--work-tree"]).first else {
                return false
            }
            if ["push", "send-pack"].contains(verb) { return !args.contains("--dry-run") && !args.contains("-n") }
            // An alias defined on this command line is judged by its expansion
            // (`ShellCommandRunners.gitInlineAliasExpansion`).
            if args.contains(where: { $0.hasPrefix("alias.\(verb)=") }) { return false }
            return ["send-email", "imap-send", "http-push", "svn", "p4"].contains(verb) || !knownLocalGitVerbs.contains(verb)
        case "gh" where isLocalGitHubCLIOperation(args):
            // `repo clone` and `pr checkout` change this checkout, not GitHub.
            return false
        case "docker" where reachesRemoteDockerDaemon(args):
            // Every mutating verb on another machine's daemon acts there.
            return true
        case "gh", "gcloud", "aws", "az", "bq", "kubectl", "helm", "terraform", "tofu", "psql", "mysql",
             BrowserBridgeMCPProjection.toolCommand:
            return true
        case "docker":
            return publishesDockerImage(args)
        case "curl", "wget":
            return usesOpaqueRequestConfig(executable: executable, args: args)
                || withoutReadMethodRequests(args).contains(where: isRemoteWriteFlag)
        case "rsync", "scp":
            // `rsync -a src/ backup/` stays here; a `host:path` or
            // `rsync://` operand is another machine.
            return args.contains { arg in
                !arg.hasPrefix("-") && (arg.hasPrefix("rsync://")
                    || arg.range(of: #"^[^/:]+:"#, options: .regularExpression) != nil)
            }
        default:
            if networkTransferRoots.contains(executable) { return true }
            if packageManagerRoots.contains(executable) {
                return changesPackageRegistry(args)
            }
            return false
        }
    }

    static func approvalGrant(forShellSegment segment: String) -> PermissionGrant? {
        guard let assessment = assessment(forShellSegment: segment) else { return nil }
        return .shellCommand(executable: assessment.executable, pattern: assessment.pattern)
    }

    /// Removes provably-benign I/O redirections from a single (already
    /// operator-split) shell segment so the underlying command stays
    /// classifiable for grant synthesis. Only file-descriptor duplications
    /// (`2>&1`, `>&2`, `2>&-`) and discards to `/dev/null` are removed — both
    /// add no new resource. A redirection to any named file is left in place,
    /// so the segment still trips `containsUnsupportedShellSyntax` and is
    /// conservatively rejected: a real write must never be folded silently into
    /// a base-command grant.
    private static func strippingBenignRedirections(_ segment: String) -> String {
        // Backslashes carry escape semantics (line continuations, escaped
        // whitespace/metacharacters) that whitespace re-tokenization would
        // silently reshape. Leave such segments untouched so the syntax check
        // still rejects them rather than mis-parsing a continuation as benign.
        guard !segment.contains("\\") else { return segment }
        let tokens = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var kept: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if isFileDescriptorDupToken(token) || isDiscardRedirectToken(token) {
                index += 1
                continue
            }
            // Two-token discard: `2>` `/dev/null`, `>` `/dev/null`.
            if isBareRedirectOperatorToken(token),
               index + 1 < tokens.count,
               tokens[index + 1] == "/dev/null" {
                index += 2
                continue
            }
            kept.append(token)
            index += 1
        }
        return kept.joined(separator: " ")
    }

    private static func isFileDescriptorDupToken(_ token: String) -> Bool {
        token.range(of: #"^[0-9]*>&([0-9]+|-)$"#, options: .regularExpression) != nil
    }

    private static func isDiscardRedirectToken(_ token: String) -> Bool {
        token.range(of: #"^(&|[0-9]*)>>?/dev/null$"#, options: .regularExpression) != nil
    }

    private static func isBareRedirectOperatorToken(_ token: String) -> Bool {
        token.range(of: #"^(&|[0-9]*)>>?$"#, options: .regularExpression) != nil
    }

    static func allowsTaskScopedReuse(_ grant: PermissionGrant) -> Bool {
        guard case .shellCommand(let rawExecutable, let rawPattern) = grant else { return true }
        let executable = rawExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty, !pattern.isEmpty else { return false }
        let assessment = assessment(forShellSegment: "\(executable) \(pattern)")
        return assessment?.allowsTaskScopedReuse ?? false
    }

    static func isOverbroadGrant(executable: String, pattern: String) -> Bool {
        let executable = normalizedExecutable(executable)
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pattern == "*" else { return false }
        return broadGrantDeniedRoots.contains(executable)
    }

    private static func allowsTaskScopedReuse(
        risk: Risk,
        pattern: String,
        containsSensitiveArgument: Bool
    ) -> Bool {
        guard !containsSensitiveArgument else { return false }
        switch risk {
        case .read, .networkRead:
            return !containsSensitivePathToken(pattern)
        case .fileRead, .mutation, .destructive, .credential, .system, .scriptExecution, .packageMutation, .unknown:
            return false
        }
    }

    private static func riskForCommand(executable: String, args: [String]) -> Risk {
        let args = args.map(comparableCommandArgument)
        if credentialRoots.contains(executable) {
            return .credential
        }
        if destructiveRoots.contains(executable) {
            return .destructive
        }
        if systemRoots.contains(executable) {
            return .system
        }
        if scriptExecutionRoots.contains(executable) {
            return .scriptExecution
        }
        if packageManagerRoots.contains(executable) {
            return riskForPackageManager(executable: executable, args: args)
        }
        if databaseRoots.contains(executable) {
            return riskForDatabaseClient(executable: executable, args: args)
        }
        if networkTransferRoots.contains(executable) {
            return riskForNetworkTransfer(executable: executable, args: args)
        }
        if fileReadRoots.contains(executable) {
            return args.contains(where: containsSensitivePathToken) ? .credential : .fileRead
        }
        if fileMutationRoots.contains(executable) {
            return .mutation
        }

        switch executable {
        case "git":
            return riskForGit(args)
        case "gh":
            return riskForGitHubCLI(args)
        case "gcloud":
            return riskForCloudCLI(args: args, readVerbs: cloudReadVerbs, writeVerbs: cloudWriteVerbs)
        case "bq":
            return riskForBigQuery(args)
        case "aws", "az":
            return riskForCloudCLI(args: args, readVerbs: cloudReadVerbs, writeVerbs: cloudWriteVerbs)
        case "kubectl":
            return riskForKubernetes(args)
        case "docker":
            return riskForDocker(args)
        case "helm":
            return riskForHelm(args)
        case "terraform", "tofu":
            return riskForTerraform(args)
        case "defaults":
            return args.first == "read" ? .read : .system
        case BrowserBridgeMCPProjection.toolCommand:
            // A page change is a write to a site; reads stay unclassified.
            guard let command = args.first, ShelfBrowserBridgeCommandRouter.commandChangesPage(command) else {
                return .unknown
            }
            return .mutation
        default:
            return .unknown
        }
    }

    private static func riskForGit(_ args: [String]) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: ["-c", "-C", "--git-dir", "--work-tree"])
        guard let verb = actionTokens.first else { return .unknown }
        if ["status", "diff", "log", "show", "branch", "rev-parse", "ls-files", "remote"].contains(verb) {
            return .read
        }
        if ["push", "send-pack", "reset", "clean", "checkout", "switch", "rebase", "merge", "commit", "tag", "restore", "stash", "pull", "fetch"].contains(verb) {
            return .mutation
        }
        // An alias or extension: what it runs is not known.
        if !knownLocalGitVerbs.contains(verb) { return .mutation }
        return .unknown
    }

    /// Git's own commands that change, at most, this machine or read a remote.
    /// Anything else — an alias, an extension such as `lfs`, a mail or foreign
    /// VCS bridge — is not proven local (`actsOutsideMachine`).
    private static let knownLocalGitVerbs: Set<String> = [
        "add", "am", "annotate", "apply", "archive", "bisect", "blame", "branch", "bundle", "cat-file",
        "check-attr", "check-ignore", "check-mailmap", "check-ref-format", "checkout", "checkout-index",
        "cherry", "cherry-pick", "clean", "clone", "commit", "commit-graph", "commit-tree", "config",
        "count-objects", "describe", "diff", "diff-files", "diff-index", "diff-tree", "difftool", "fetch",
        "for-each-ref", "format-patch", "fsck", "gc", "grep", "hash-object", "help", "init",
        "interpret-trailers", "log", "ls-files", "ls-remote", "ls-tree", "maintenance", "merge", "merge-base",
        "merge-file", "merge-tree", "mergetool", "mktag", "mktree", "mv", "name-rev", "notes", "pack-refs",
        "prune", "pull", "range-diff", "read-tree", "rebase", "reflog", "remote", "repack", "replace",
        "request-pull", "rerere", "reset", "restore", "rev-list", "rev-parse", "revert", "rm", "shortlog",
        "show", "show-branch", "show-ref", "sparse-checkout", "stash", "status", "stripspace", "submodule",
        "switch", "symbolic-ref", "tag", "update-index", "update-ref", "var", "verify-commit", "verify-pack",
        "verify-tag", "version", "whatchanged", "worktree", "write-tree"
    ]

    private static func isLocalGitHubCLIOperation(_ args: [String]) -> Bool {
        let tokens = dropLeadingOptions(args, optionsWithValues: ["--repo", "-r", "-R", "--hostname"])
        guard tokens.count >= 2 else { return false }
        return ["repo clone", "pr checkout", "repo set-default", "gist clone"].contains("\(tokens[0]) \(tokens[1])")
    }

    private static func riskForGitHubCLI(_ args: [String]) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: ["--repo", "-r", "--hostname"])
        guard let area = actionTokens.first else { return .unknown }
        let verb = actionTokens.dropFirst().first
        switch area {
        case "auth":
            if verb == "status" { return .read }
            return .credential
        case "search":
            return .read
        case "pr":
            if ["list", "view", "diff", "checks", "status"].contains(verb ?? "") { return .read }
            return .mutation
        case "issue":
            if ["list", "view", "status"].contains(verb ?? "") { return .read }
            return .mutation
        case "repo":
            if ["list", "view"].contains(verb ?? "") { return .read }
            return .mutation
        case "release":
            if ["list", "view", "download"].contains(verb ?? "") { return .read }
            return .mutation
        case "api":
            // A write method or fields; `AgentExternalActionObserver` reads those.
            return .unknown
        case "alias", "config", "extension", "completion", "help", "browse", "version":
            // Local to this machine: gh's own settings and extensions.
            return .unknown
        case "status":
            return .read
        case _ where !gitHubCLIAreas.contains(area):
            // Not one of gh's own commands: an alias (`gh alias set --shell`)
            // or an extension, which runs what this cannot read.
            return .mutation
        default:
            // Every other area is GitHub itself — `workflow run` starts Actions,
            // `secret set` stores a value there — so anything but a read verb
            // changes something outside this machine.
            guard let verb else { return .unknown }
            if gitHubReadVerbs.contains(verb) || verb.hasSuffix("-list") { return .read }
            return .mutation
        }
    }

    /// gh's own top-level commands; anything else is an alias or extension.
    private static let gitHubCLIAreas: Set<String> = [
        "agent-task", "alias", "api", "attestation", "auth", "browse", "cache", "codespace", "completion", "config",
        "copilot", "extension", "gist", "gpg-key", "help", "issue", "label", "org", "pr", "preview", "project",
        "release", "repo", "ruleset", "run", "search", "secret", "ssh-key", "status", "variable", "version",
        "workflow", "accessibility"
    ]

    private static let gitHubReadVerbs: Set<String> = [
        "list", "ls", "view", "status", "diff", "checks", "download", "watch", "get", "check", "verify"
    ]

    /// Code an interpreter takes on the command line (`python3 -c`, `node -e`,
    /// `osascript -e`): what it does cannot be read, so it is not declared
    /// local. A script file or `-m module` is the user's own code and keeps
    /// the rule.
    static func runsInlineCode(forShellSegment segment: String) -> Bool {
        let tokens = shellTokens(strippingBenignRedirections(segment))
        guard let first = tokens.first, let executable = shellApprovalRoot(first)?.lowercased() else { return false }
        let inlineFlags: Set<String>
        switch executable {
        case _ where executable.hasPrefix("python"): inlineFlags = ["-c"]
        case "node", "nodejs": inlineFlags = ["-e", "--eval", "-p", "--print"]
        case "ruby", "lua", "osascript", "rscript": inlineFlags = ["-e"]
        case "perl": inlineFlags = ["-e", "-E"]
        case "php": inlineFlags = ["-r"]
        case "bun": inlineFlags = ["-e", "--eval", "-p", "--print"]
        case "deno": inlineFlags = ["eval"]
        case "pwsh", "powershell": inlineFlags = ["-c", "-command"]
        default: return false
        }
        return tokens.dropFirst().contains { inlineFlags.contains($0.lowercased()) || inlineFlags.contains($0) }
    }

    /// Whether a `docker` command reaches a daemon other than this machine's:
    /// the one its `--context`/`-c` or `-H`/`--host` names, or else the one the
    /// CLI would pick (`DockerDaemonLocality`).
    private static func reachesRemoteDockerDaemon(_ args: [String]) -> Bool {
        var context: String?
        var host: String?
        var configDirectory: String?
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            let arg = args[index]
            if arg.hasPrefix("-H"), !arg.hasPrefix("--"), arg.count > 2 {
                host = String(arg.dropFirst(2))
                index += 1
                continue
            }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            var value = parts.count == 2 ? parts[1] : nil
            if value == nil, dockerGlobalOptionsWithValues.contains(parts[0]), index + 1 < args.count {
                value = args[index + 1]
                index += 1
            }
            switch parts[0] {
            case "--context", "-c": context = value
            case "-H", "--host": host = value
            case "--config": configDirectory = value
            default: break
            }
            index += 1
        }
        if let host { return !DockerDaemonLocality.isLocalEndpoint(host) }
        return !DockerDaemonLocality.isLocal(context: context, configDirectory: configDirectory)
    }

    /// docker's global options that take a value, so it is not read as the verb.
    private static let dockerGlobalOptionsWithValues: Set<String> = [
        "--context", "-c", "-H", "--host", "--config", "-l", "--log-level", "--tlscacert", "--tlscert", "--tlskey"
    ]

    /// A package-manager command that changes a registry rather than this
    /// machine: publishing, removing, or deprecating a release; changing its
    /// tags, owners, or access; or the account's tokens, hooks, org, or
    /// profile. `npm dist-tag ls`, `npm owner ls`, `npm token list` read.
    /// The manager's own subcommand decides, after its global options: in
    /// `npm install publish` the package is named `publish`.
    private static func changesPackageRegistry(_ args: [String]) -> Bool {
        var tokens = dropLeadingOptions(args, optionsWithValues: packageManagerOptionsWithValues)
        if tokens.first == "npm" { tokens.removeFirst() }  // `yarn npm publish`
        guard let command = tokens.first else { return false }
        if packageRegistryWriteVerbs.contains(command) { return true }
        guard packageRegistryAdminCommands.contains(command) else { return false }
        return tokens.dropFirst().contains(where: packageRegistryAdminWriteVerbs.contains)
    }

    private static let packageManagerOptionsWithValues: Set<String> = [
        "--registry", "--userconfig", "--globalconfig", "--prefix", "--workspace", "-w", "--loglevel", "--cache",
        "--otp", "-C", "--cwd", "--dir", "--filter", "-F", "--manifest-path", "--config", "-Z", "--color",
        "--index-url", "--extra-index-url", "--source"
    ]

    private static let packageRegistryWriteVerbs: Set<String> = [
        "publish", "unpublish", "upload", "push", "deprecate", "undeprecate", "yank", "star", "unstar",
        "adduser", "add-user"
    ]

    private static let packageRegistryAdminCommands: Set<String> = [
        "dist-tag", "dist-tags", "owner", "access", "team", "token", "hook", "org", "profile"
    ]

    private static let packageRegistryAdminWriteVerbs: Set<String> = [
        "add", "rm", "remove", "set", "grant", "revoke", "create", "destroy", "public", "restricted", "update",
        "enable-2fa", "disable-2fa", "--add", "--remove", "-a", "-r"
    ]

    private static func riskForBigQuery(_ args: [String]) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: ["--project_id", "--location", "--format"])
        guard let verb = actionTokens.first else { return .unknown }
        if ["ls", "show", "help", "version"].contains(verb) {
            return .read
        }
        if verb == "query", actionTokens.dropFirst().contains(where: looksLikeReadOnlySQL) {
            return .read
        }
        return .mutation
    }

    /// `gcloud`, `aws` and `az` only act on a remote account, so a command
    /// that names no read verb is a write: `aws ec2 terminate-instances` and
    /// `az storage blob upload` name none of the generic write verbs either.
    private static func riskForCloudCLI(args: [String], readVerbs: Set<String>, writeVerbs: Set<String>) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: ["--project", "--project-id", "--profile", "--region", "--zone", "-o"])
        guard !actionTokens.isEmpty else { return .unknown }
        if let transfer = riskForObjectStorageTransfer(actionTokens, args: args) {
            return transfer
        }
        if actionTokens.contains(where: { writeVerbs.contains($0) }) {
            return .mutation
        }
        // Reads are named by the command's own words, before its options:
        // `--key get-secret` is a value, not an operation.
        let words = actionTokens.prefix { !$0.hasPrefix("-") }
        if words.contains(where: { readVerbs.contains($0) }) {
            return .read
        }
        if words.contains("iam") || words.contains("secretsmanager") || words.contains("secret") {
            return .credential
        }
        if words.contains(where: { token in cloudReadOperationPrefixes.contains { token.hasPrefix($0) } }) {
            return .read
        }
        return .mutation
    }

    /// `aws s3 cp|sync|mv` and `gcloud storage cp|rsync|mv` write the bucket
    /// only when it is the destination (or, for `mv`, either end); a
    /// download writes this machine. `--dryrun`/`--dry-run` changes nothing.
    private static func riskForObjectStorageTransfer(_ actionTokens: [String], args: [String]) -> Risk? {
        guard actionTokens.count >= 2,
              ["s3", "storage"].contains(actionTokens[0]),
              ["cp", "sync", "rsync", "mv"].contains(actionTokens[1]) else {
            return nil
        }
        if args.contains(where: { ["--dryrun", "--dry-run", "-n"].contains($0) }) { return .read }
        let locations = actionTokens.dropFirst(2).filter { !$0.hasPrefix("-") }
        let isBucket: (String) -> Bool = { $0.hasPrefix("s3://") || $0.hasPrefix("gs://") }
        if actionTokens[1] == "mv" { return locations.contains(where: isBucket) ? .mutation : .read }
        guard let destination = locations.last else { return .unknown }
        return isBucket(destination) ? .mutation : .read
    }

    private static let cloudReadOperationPrefixes = ["describe-", "list-", "get-", "head-", "show-", "lookup-"]

    /// `kubectl` changes the cluster unless the verb reads; `set image`,
    /// `label` and `drain` name no generic write verb. A dry run changes
    /// nothing.
    /// kubectl's global options that take a value, so it is not read as the verb.
    private static let kubectlOptionsWithValues: Set<String> = [
        "--namespace", "-n", "--context", "--kubeconfig", "--cluster", "--user", "--server", "-s", "--token",
        "--as", "--as-group", "--as-uid", "--certificate-authority", "--client-certificate", "--client-key",
        "--request-timeout", "--cache-dir", "--tls-server-name", "-v", "--v", "--profile", "--profile-output",
        "--log-file", "--vmodule"
    ]

    private static func riskForKubernetes(_ args: [String]) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: kubectlOptionsWithValues)
        guard let verb = actionTokens.first else { return .unknown }
        if [
            "get", "describe", "logs", "top", "api-resources", "api-versions", "version", "config", "explain",
            "cluster-info", "diff", "wait", "events", "completion"
        ].contains(verb) {
            return .read
        }
        if verb == "auth", ["can-i", "whoami"].contains(actionTokens.dropFirst().first ?? "") {
            return .read
        }
        if isKubectlDryRun(args) {
            return .read
        }
        return .mutation
    }

    /// `--dry-run`, `=client` or `=server` persist nothing; `=none` (the
    /// default) is a real write.
    private static func isKubectlDryRun(_ args: [String]) -> Bool {
        for (index, arg) in args.enumerated() {
            if arg.hasPrefix("--dry-run=") { return String(arg.dropFirst("--dry-run=".count)).lowercased() != "none" }
            if arg == "--dry-run" {
                return !(args.indices.contains(index + 1) && args[index + 1].lowercased() == "none")
            }
        }
        return false
    }

    /// A daemon's state changes unless the verb reads, so every other verb is
    /// a mutation — `create`, `start`, `volume create` — and a remote daemon's
    /// is judged as one (`actsOutsideMachine`). The CLI's own settings
    /// (`context`, `login`) stay with the rule.
    private static func riskForDocker(_ args: [String]) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: dockerGlobalOptionsWithValues)
        guard let verb = actionTokens.first else { return .unknown }
        let next = actionTokens.dropFirst().first ?? ""
        if ["ps", "images", "inspect", "logs", "version", "info", "stats", "top", "history", "search", "events",
            "diff", "port", "help"].contains(verb) {
            return .read
        }
        if ["container", "image", "volume", "network", "system", "node", "service", "stack", "secret", "config",
            "plugin", "builder", "buildx", "compose", "manifest", "trust", "swarm"].contains(verb),
           ["ls", "list", "inspect", "ps", "logs", "history", "top", "stats", "df", "events", "version", "ls-remote",
            "du"].contains(next) {
            return .read
        }
        if ["context", "login", "logout", "completion"].contains(verb) { return .unknown }
        return .mutation
    }

    /// A docker command that sends an image or manifest to a registry, even
    /// from a local daemon: `push`, `image push`, `manifest push`, `compose
    /// push`, `buildx imagetools create`, and any build with `--push` or an
    /// `--output type=registry`.
    private static func publishesDockerImage(_ args: [String]) -> Bool {
        let tokens = dropLeadingOptions(args, optionsWithValues: dockerGlobalOptionsWithValues)
        let verb = tokens.first ?? ""
        let next = tokens.dropFirst().first ?? ""
        if verb == "push" || (["image", "manifest", "compose", "trust"].contains(verb) && ["push", "sign"].contains(next)) {
            return true
        }
        if verb == "buildx", next == "imagetools", tokens.dropFirst(2).first == "create" { return true }
        for (index, arg) in args.enumerated() {
            if arg == "--push" || arg.hasPrefix("--push=true") { return true }
            let output = arg.hasPrefix("--output=") ? String(arg.dropFirst("--output=".count))
                : (["--output", "-o"].contains(arg) && args.indices.contains(index + 1)) ? args[index + 1] : nil
            if let output, output.contains("type=registry") || output.contains("push=true") { return true }
        }
        return false
    }

    private static func riskForHelm(_ args: [String]) -> Risk {
        guard let verb = dropLeadingOptions(args, optionsWithValues: ["--namespace", "-n", "--kube-context"]).first else {
            return .unknown
        }
        if ["list", "status", "history", "show", "repo"].contains(verb) {
            return .read
        }
        return .mutation
    }

    private static func riskForTerraform(_ args: [String]) -> Risk {
        guard let verb = dropLeadingOptions(args, optionsWithValues: ["-chdir"]).first else {
            return .unknown
        }
        if ["plan", "show", "output", "version", "validate", "fmt"].contains(verb) {
            return .read
        }
        return .mutation
    }

    private static func riskForPackageManager(executable: String, args: [String]) -> Risk {
        guard let verb = dropLeadingOptions(args, optionsWithValues: []).first else {
            return .packageMutation
        }
        if executable == "brew", ["list", "info", "outdated", "--version"].contains(verb) {
            return .read
        }
        if ["view", "info", "list", "outdated", "--version", "version"].contains(verb) {
            return .read
        }
        return .packageMutation
    }

    private static func riskForNetworkTransfer(executable: String, args: [String]) -> Risk {
        guard ["curl", "wget"].contains(executable) else { return .mutation }
        if usesOpaqueRequestConfig(executable: executable, args: args) { return .mutation }
        if withoutReadMethodRequests(args).contains(where: isNetworkMutationFlag) {
            return .mutation
        }
        return .networkRead
    }

    private static func shellApprovalPattern(executable: String, args: [String], risk: Risk) -> String {
        // A request read from a config file is approved with that file named,
        // so the grant is still a write's (`actsOutsideMachine`).
        if ["curl", "wget"].contains(executable), usesOpaqueRequestConfig(executable: executable, args: args) {
            let tokens = args.map(normalizedPatternToken).filter(isSafeShellPatternToken)
            return (Array(tokens.prefix(4)) + ["*"]).joined(separator: " ")
        }
        if ["curl", "wget"].contains(executable),
           let hostPattern = hostScopedShellPattern(from: args) {
            // A write keeps the flag that makes it one, so approving it never
            // reads as approving every request to the host, and a host-scoped
            // read approval never covers a later write (`actsOutsideMachine`).
            guard let writeFlag = withoutReadMethodRequests(args).first(where: isRemoteWriteFlag) else { return hostPattern }
            let name = writeFlag.split(separator: "=", maxSplits: 1).first.map(String.init) ?? writeFlag
            let flagPattern = writeFlag.contains("=") ? "\(name)=*" : name
            return "\(flagPattern) \(hostPattern)"
        }
        let actionTokens = commandActionTokens(executable: executable, args: args, risk: risk)
            .map(normalizedPatternToken)
            .filter(isSafeShellPatternToken)
        guard !actionTokens.isEmpty else { return "*" }
        let tokenLimit = patternTokenLimit(for: risk)
        let kept = Array(actionTokens.prefix(tokenLimit))
        // A force or delete past the kept tokens stays in the pattern, so the
        // approval names it (`pushEscalations`).
        let escalations = executable == "git"
            ? actionTokens.dropFirst(tokenLimit).filter { isPushEscalation($0) }
            : []
        return (kept + escalations + ["*"]).joined(separator: " ")
    }

    /// The options that turn a push into a different, destructive action:
    /// forcing, deleting, mirroring, pruning, or a `+refspec`. Approving a
    /// plain push is not approving these (`AgentRuntimePolicyGuard`).
    static func pushEscalations(inShellSegment segment: String) -> Set<String> {
        let tokens = shellTokens(strippingBenignRedirections(segment))
        guard let executable = tokens.first.flatMap(shellApprovalRoot)?.lowercased(), executable == "git" else { return [] }
        let args = Array(tokens.dropFirst()).map(comparableCommandArgument)
        let verb = dropLeadingOptions(args, optionsWithValues: ["-c", "-C", "--git-dir", "--work-tree"]).first
        guard ["push", "send-pack"].contains(verb ?? "") else { return [] }
        return Set(args.filter(isPushEscalation).map { token in
            token.hasPrefix("+") ? "+refspec" : (token.split(separator: "=").first.map(String.init) ?? token)
        })
    }

    private static func isPushEscalation(_ token: String) -> Bool {
        let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
        return ["--force", "-f", "--force-with-lease", "--force-if-includes", "--delete", "-d", "--mirror",
                "--prune", "--all"].contains(name)
            || (token.hasPrefix("+") && token.count > 1)
    }

    /// `curl -X GET`, `--request=GET`, `-XHEAD` and `wget --method GET` name a
    /// read, so they are not the write flags they would otherwise look like.
    private static func withoutReadMethodRequests(_ args: [String]) -> [String] {
        let readMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]
        let methodOptions: Set<String> = ["-X", "--request", "--method"]
        var kept: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if methodOptions.contains(arg), args.indices.contains(index + 1),
               readMethods.contains(args[index + 1].uppercased()) {
                index += 2
                continue
            }
            if parts.count == 2, methodOptions.contains(parts[0].lowercased() == "--request" ? "--request" : parts[0]),
               readMethods.contains(parts[1].uppercased()) {
                index += 1
                continue
            }
            if arg.hasPrefix("-X"), !arg.hasPrefix("--"), readMethods.contains(String(arg.dropFirst(2)).uppercased()) {
                index += 1
                continue
            }
            kept.append(arg)
            index += 1
        }
        return kept
    }

    private static func patternTokenLimit(for risk: Risk) -> Int {
        switch risk {
        case .read, .networkRead:
            return 2
        case .fileRead, .mutation, .destructive, .credential, .system, .scriptExecution, .packageMutation, .unknown:
            return 3
        }
    }

    private static func commandActionTokens(executable: String, args: [String], risk: Risk) -> [String] {
        switch executable {
        case "gh":
            return dropLeadingOptions(args, optionsWithValues: ["--repo", "-r", "--hostname"])
        case "git":
            return dropLeadingOptions(args, optionsWithValues: ["-c", "-C", "--git-dir", "--work-tree"])
        case "gcloud", "aws", "az":
            return dropLeadingOptions(args, optionsWithValues: ["--project", "--project-id", "--profile", "--region", "--zone", "-o"])
        case "kubectl":
            return dropLeadingOptions(args, optionsWithValues: kubectlOptionsWithValues)
        case "docker":
            return dropLeadingOptions(args, optionsWithValues: dockerGlobalOptionsWithValues)
        case "bq":
            return dropLeadingOptions(args, optionsWithValues: ["--project_id", "--location", "--format"])
        case "curl", "wget":
            return dropLeadingOptions(args, optionsWithValues: ["-H", "--header", "-A", "--user-agent", "-u", "--user"])
        default:
            return dropLeadingOptions(args, optionsWithValues: [])
        }
    }

    private static func shellTokens(_ segment: String) -> [String] {
        segment
            .split(whereSeparator: { $0.isWhitespace })
            .map { raw in
                String(raw)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private static func containsUnsupportedShellSyntax(_ segment: String) -> Bool {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        let characters = Array(segment)

        for index in characters.indices {
            let character = characters[index]
            let next = characters.index(after: index) < characters.endIndex
                ? characters[characters.index(after: index)]
                : nil

            if escaped {
                if character == "\n" || character == "\r" {
                    return true
                }
                escaped = false
                continue
            }

            if character == "\\" && !inSingleQuote {
                escaped = true
                continue
            }

            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            guard !inSingleQuote else { continue }

            if character == "\n" || character == "\r" || character == "`" {
                return true
            }

            if !inDoubleQuote, character == ";" || character == "|" || character == "&" {
                return true
            }

            if character == "$", next == "(" || next == "'" || next == "\"" {
                return true
            }

            if !inDoubleQuote, (character == "<" || character == ">") {
                return true
            }
        }

        return inSingleQuote || inDoubleQuote || escaped
    }

    private static func shellApprovalRoot(_ root: String) -> String? {
        let normalizedRoot = normalizedExecutable(root)
        guard !normalizedRoot.isEmpty,
              normalizedRoot.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r)")) == nil,
              normalizedRoot.rangeOfCharacter(from: grantMetacharacters) == nil,
              !unsafeGrantRoots.contains(normalizedRoot) else {
            return nil
        }
        return normalizedRoot
    }

    private static func normalizedExecutable(_ value: String) -> String {
        var executable = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'({["))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        executable = executable.trimmingCharacters(in: CharacterSet(charactersIn: "\"')}]"))
        if executable.hasPrefix("/") {
            executable = URL(fileURLWithPath: executable).lastPathComponent
        }
        return executable.lowercased()
    }

    private static func normalizedArgument(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func comparableCommandArgument(_ value: String) -> String {
        let token = normalizedArgument(value)
        if token.hasPrefix("--") {
            return token.lowercased()
        }
        if token.hasPrefix("-") {
            return token
        }
        return token.lowercased()
    }

    private static func normalizedPatternToken(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func dropLeadingOptions(_ args: [String], optionsWithValues: Set<String>) -> [String] {
        var index = 0
        while index < args.count {
            let token = args[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-") else { break }
            index += 1
            let optionName = token.split(separator: "=").first.map(String.init) ?? token
            if optionsWithValues.contains(optionName), !token.contains("="), index < args.count {
                index += 1
            }
        }
        return Array(args.dropFirst(index))
    }

    private static func hostScopedShellPattern(from args: [String]) -> String? {
        for arg in args {
            let trimmed = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(),
                  isSafeShellPatternToken(host) else {
                continue
            }
            return "*\(host)*"
        }
        return nil
    }

    private static func isSafeShellPatternToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: grantMetacharacters) == nil,
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ":()")) == nil else {
            return false
        }
        return true
    }

    private static func isNetworkMutationFlag(_ token: String) -> Bool {
        if isRemoteWriteFlag(token) { return true }
        let normalized = normalizedArgument(token)
        let optionName = normalized.split(separator: "=", maxSplits: 1).first.map(String.init) ?? normalized
        if ["-o", "-O"].contains(optionName) || optionName.lowercased() == "--output" { return true }
        return combinedShortOptions(normalized).contains { $0 == "-o" || $0 == "-O" }
    }

    /// The mutation flags that send something to the remote end, as opposed
    /// to `-o`/`--output`, which only write the response to a local file.
    /// Short flags count combined or with their value attached (`-sSd`,
    /// `-XPOST`, `-dbody`), as curl accepts them.
    private static func isRemoteWriteFlag(_ token: String) -> Bool {
        let normalized = normalizedArgument(token)
        let optionName = normalized.split(separator: "=", maxSplits: 1).first.map(String.init) ?? normalized
        if optionName.hasPrefix("--") {
            return [
                "--data", "--data-raw", "--data-binary", "--data-urlencode",
                "--form", "--form-string", "--request", "--upload-file",
                "--post-file", "--post-data", "--json", "--body-data", "--body-file"
            ].contains(optionName.lowercased()) || isWriteMethodOption(normalized)
        }
        let remoteWriteShortFlags: Set<String> = ["-d", "-F", "-X", "-T"]
        return remoteWriteShortFlags.contains(optionName)
            || combinedShortOptions(normalized).contains(where: remoteWriteShortFlags.contains)
    }

    /// `curl -K file` / `--config` and `wget -e` / `--execute` / `--config`
    /// take options from somewhere this does not read — `--data` among them —
    /// so the request is not called a read.
    private static func usesOpaqueRequestConfig(executable: String, args: [String]) -> Bool {
        switch executable {
        case "curl":
            return args.contains { arg in
                arg == "-K" || arg == "--config" || arg.hasPrefix("--config=") || combinedShortOptions(arg).contains("-K")
            }
        case "wget":
            return args.contains { ["-e", "--execute", "--config"].contains($0) || $0.hasPrefix("--execute=") || $0.hasPrefix("--config=") }
        default:
            return false
        }
    }

    /// `wget --method=POST`. A bare `--method` hides its value in the next
    /// token, so it counts as a write unless it names a read.
    private static func isWriteMethodOption(_ token: String) -> Bool {
        let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "--method" else { return false }
        guard parts.count == 2 else { return true }
        return !["GET", "HEAD", "OPTIONS"].contains(parts[1].uppercased())
    }

    /// The short options one `-abc` token sets, up to the first that takes a
    /// value: the rest of the token is that value.
    private static func combinedShortOptions(_ token: String) -> [String] {
        guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 2 else { return [] }
        var options: [String] = []
        for character in token.dropFirst() {
            options.append("-\(character)")
            if curlShortOptionsWithValues.contains(character) { break }
        }
        return options
    }

    private static let curlShortOptionsWithValues: Set<Character> = [
        "A", "b", "c", "C", "d", "D", "e", "E", "F", "H", "K", "m", "o", "P", "Q", "r", "t", "T", "u", "U",
        "w", "x", "X", "y", "Y", "z"
    ]

    /// `psql -c 'SELECT …'` / `mysql -e 'SHOW …'` read when every statement is a
    /// query: the first word reads and no word writes. A session, a script
    /// file, or anything else may write.
    private static func riskForDatabaseClient(executable: String, args: [String]) -> Risk {
        let queryFlags: Set<String> = executable == "mysql" ? ["-e", "--execute"] : ["-c", "--command"]
        guard ["psql", "mysql"].contains(executable),
              !args.contains(where: { ["-f", "--file", "--source"].contains($0) || $0.hasPrefix("--file=") }),
              let flag = args.firstIndex(where: { arg in
                  queryFlags.contains(arg) || queryFlags.contains { arg.hasPrefix($0 + "=") }
              }) else {
            return .mutation
        }
        let attached = args[flag].split(separator: "=", maxSplits: 1).dropFirst().map(String.init)
        let words = (attached + args[(flag + 1)...])
            .flatMap { $0.split(whereSeparator: { " ;,()\n\t".contains($0) }).map(String.init) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")).lowercased() }
            .filter { !$0.isEmpty }
        let reads: Set<String> = ["select", "show", "explain", "with", "table", "values", "describe", "desc"]
        let writes: Set<String> = [
            "insert", "update", "delete", "drop", "alter", "create", "truncate", "grant", "revoke", "copy", "call",
            "merge", "replace", "rename", "lock", "vacuum", "reindex", "cluster", "comment", "refresh", "do", "set",
            "into", "load", "import", "handler", "analyze", "optimize", "repair", "flush", "kill", "shutdown"
        ]
        guard let first = words.first, reads.contains(first), !words.contains(where: writes.contains) else {
            return .mutation
        }
        return .read
    }

    private static func looksLikeReadOnlySQL(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
        return normalized.hasPrefix("select ")
            || normalized.hasPrefix("with ")
            || normalized.hasPrefix("show ")
    }

    private static func containsSensitivePathToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.contains("/.ssh")
            || lower.contains(".zsh_history")
            || lower.contains(".bash_history")
            || lower.contains(".env")
            || lower.contains("id_rsa")
            || lower.contains("id_ed25519")
            || lower.contains("private_key")
            || lower.contains("token")
            || lower.contains("secret")
            || lower.contains("credential")
            || privacySensitivePathFragments.contains { matchesSensitivePathFragment(lower, fragment: $0) }
    }

    private static func matchesSensitivePathFragment(_ token: String, fragment: String) -> Bool {
        let normalizedToken = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if fragment.hasPrefix(".") {
            return normalizedToken.hasSuffix(fragment) || normalizedToken.contains(fragment + "/")
        }
        if fragment.hasPrefix("~/") {
            return normalizedToken == fragment || normalizedToken.hasPrefix(fragment + "/")
        }
        if normalizedToken == fragment || normalizedToken.hasPrefix(fragment + "/") {
            return true
        }

        guard fragment.hasPrefix("/") else { return false }
        let components = normalizedToken.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0] == "users" else { return false }
        let homeRelativePath = components.dropFirst(2).joined(separator: "/")
        let fragmentPath = String(fragment.dropFirst())
        return homeRelativePath == fragmentPath || homeRelativePath.hasPrefix(fragmentPath + "/")
    }

    private static var grantMetacharacters: CharacterSet {
        CharacterSet(charactersIn: "\n\r;&|`$<>\\")
    }

    private static let unsafeGrantRoots: Set<String> = [
        "#", "set", "cd", "pwd", "true", "false", ":", "export", "unset", "umask", "read",
        "dirname", "echo", "printf", "test", "[", "]", "exit", "return",
        "if", "then", "do", "else", "elif", "while", "for", "until", "case", "in",
        "fi", "done", "esac", "time", "command", "builtin", "exec", "!"
    ]

    private static let destructiveRoots: Set<String> = [
        "rm", "rmdir", "shred", "dd", "mkfs", "diskutil"
    ]

    private static let fileMutationRoots: Set<String> = [
        "mv", "cp", "chmod", "chown", "truncate", "tee", "touch", "install"
    ]

    private static let fileContentReadRoots: Set<String> = [
        "cat", "head", "tail", "less", "more"
    ]

    private static let fileReadRoots: Set<String> = fileContentReadRoots.union([
        "ls", "find", "stat", "file", "du", "wc"
    ])

    private static let privacySensitivePathFragments: [String] = [
        "~/pictures",
        "/pictures",
        "~/music",
        "/music",
        "~/movies",
        "/movies",
        "~/library/photos",
        "/library/photos",
        "~/library/mail",
        "/library/mail",
        "~/library/messages",
        "/library/messages",
        "~/library/calendars",
        "/library/calendars",
        "~/library/application support/addressbook",
        "/library/application support/addressbook",
        "/applications",
        ".photoslibrary",
        ".musiclibrary",
        ".medialibrary",
        ".app"
    ]

    private static let credentialRoots: Set<String> = [
        "security", "op", "pass", "vault", "keychain", "ssh-add"
    ]

    private static let systemRoots: Set<String> = [
        "sudo", "su", "launchctl", "systemctl", "scutil", "open", "osascript", "kill", "pkill"
    ]

    private static let scriptExecutionRoots: Set<String> = [
        "sh", "bash", "zsh", "fish", "python", "python3", "node", "ruby", "perl",
        "php", "swift", "make", "just", "xargs"
    ]

    private static let packageManagerRoots: Set<String> = [
        "npm", "npx", "pnpm", "yarn", "pip", "pip3", "uv", "cargo", "gem", "brew"
    ]

    private static let databaseRoots: Set<String> = [
        "psql", "mysql", "sqlite3", "duckdb"
    ]

    private static let networkTransferRoots: Set<String> = [
        "curl", "wget", "scp", "rsync", "ssh", "nc", "ftp", "sftp"
    ]

    private static let cloudReadVerbs: Set<String> = [
        "list", "ls", "describe", "show", "get", "view", "read", "status", "version", "info", "help", "wait",
        "presign"
    ]

    private static let cloudWriteVerbs: Set<String> = [
        "create", "delete", "remove", "rm", "update", "set", "put", "attach", "detach",
        "modify", "add-iam-policy-binding", "remove-iam-policy-binding", "set-iam-policy",
        "enable", "disable", "deploy", "run", "start", "stop", "restart", "write"
    ]

    private static let broadGrantDeniedRoots: Set<String> = destructiveRoots
        .union(fileMutationRoots)
        .union(fileContentReadRoots)
        .union(credentialRoots)
        .union(systemRoots)
        .union(scriptExecutionRoots)
        .union(packageManagerRoots)
        .union(databaseRoots)
        .union(networkTransferRoots)
        .union(["aws", "az", "bq", "docker", "gcloud", "gh", "git", "helm", "kubectl", "terraform", "tofu"])
}
