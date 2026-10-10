import CryptoKit
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

    static func approvalGrant(forShellSegment segment: String) -> PermissionGrant? {
        guard let assessment = assessment(forShellSegment: segment) else { return nil }
        return .shellCommand(executable: assessment.executable, pattern: assessment.pattern)
    }

    /// Every grant approving one shell command: the pattern, which a provider
    /// matches on replay, and — for anything but a read — a grant naming the
    /// command's whole content. A pattern stops after a few words (`gh pr
    /// comment 12 *`), so without the second grant approving one comment,
    /// body or request approved every other one the pattern also matches.
    /// The external-action gate compares grants (`AgentRuntimePolicyGuard`),
    /// so it asks again; the provider still matches the pattern, so the
    /// approved command itself still replays.
    /// `content`: the segment as written, when `segment` was normalized
    /// for pattern matching; the content grant names what was written.
    static func approvalGrants(forShellSegment segment: String, content: String? = nil) -> [PermissionGrant]? {
        guard let assessment = assessment(forShellSegment: segment) else { return nil }
        let grant = PermissionGrant.shellCommand(executable: assessment.executable, pattern: assessment.pattern)
        switch assessment.risk {
        case .read, .fileRead, .networkRead:
            return [grant]
        case .mutation, .destructive, .credential, .system, .scriptExecution, .packageMutation, .unknown:
            return [grant, contentGrant(executable: assessment.executable, segment: content ?? segment)]
        }
    }

    /// Names a command's content without repeating it: its words, as the
    /// shell splits them, so quoting and spacing do not change it.
    static let contentGrantPrefix = "content-sha256-"

    /// Whether a grant is one of these: ASTRA's gate reads it, a provider has
    /// no command it could match, and a person needs the pattern beside it.
    static func isContentGrant(_ grant: PermissionGrant) -> Bool {
        guard case .shellCommand(_, let pattern) = grant else { return false }
        return pattern.hasPrefix(contentGrantPrefix)
    }

    private static func contentGrant(executable: String, segment: String) -> PermissionGrant {
        let words = [executable.lowercased()] + shellTokens(strippingBenignRedirections(segment)).dropFirst()
        let digest = SHA256.hash(data: Data(words.joined(separator: "\u{1F}").utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        return .shellCommand(executable: executable, pattern: contentGrantPrefix + digest)
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
            return .mutation
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
        if ["push", "reset", "clean", "checkout", "switch", "rebase", "merge", "commit", "tag", "restore", "stash", "pull", "fetch"].contains(verb) {
            return .mutation
        }
        return .unknown
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
        default:
            return .unknown
        }
    }

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

    private static func riskForCloudCLI(args: [String], readVerbs: Set<String>, writeVerbs: Set<String>) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: ["--project", "--project-id", "--profile", "--region", "--zone", "-o"])
        if actionTokens.contains(where: { writeVerbs.contains($0) }) {
            return .mutation
        }
        if actionTokens.contains(where: { readVerbs.contains($0) }) {
            return .read
        }
        if actionTokens.contains("iam") || actionTokens.contains("secretsmanager") || actionTokens.contains("secret") {
            return .credential
        }
        return .unknown
    }

    private static func riskForKubernetes(_ args: [String]) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: ["--namespace", "-n", "--context"])
        guard let verb = actionTokens.first else { return .unknown }
        if ["get", "describe", "logs", "top", "api-resources", "version", "config"].contains(verb) {
            return .read
        }
        if ["apply", "delete", "exec", "port-forward", "cp", "edit", "scale", "rollout", "create", "patch", "replace"].contains(verb) {
            return .mutation
        }
        return .unknown
    }

    private static func riskForDocker(_ args: [String]) -> Risk {
        let actionTokens = dropLeadingOptions(args, optionsWithValues: ["--context", "-H"])
        guard let verb = actionTokens.first else { return .unknown }
        if ["ps", "images", "inspect", "logs", "version", "info"].contains(verb) {
            return .read
        }
        if ["run", "exec", "build", "pull", "push", "rm", "rmi", "stop", "kill", "compose"].contains(verb) {
            return .mutation
        }
        return .unknown
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
        // so the grant is still a write's.
        if ["curl", "wget"].contains(executable), usesOpaqueRequestConfig(executable: executable, args: args) {
            let tokens = args.map(normalizedPatternToken).filter(isSafeShellPatternToken)
            return (Array(tokens.prefix(4)) + ["*"]).joined(separator: " ")
        }
        if ["curl", "wget"].contains(executable),
           let hostPattern = hostScopedShellPattern(from: args) {
            // A write keeps the flag that makes it one, so approving it never
            // reads as approving every request to the host, and a host-scoped
            // read approval never covers a later write.
            let writes = withoutReadMethodRequests(args)
            guard writes.contains(where: isRemoteWriteFlag) else { return hostPattern }
            // And the method it names: approving `-X POST` is not approving
            // `-X DELETE`, and a body sent with `-X DELETE` is not the POST
            // its `-d` alone would be. A method this cannot read yields no
            // grant, so it is asked about each time.
            let method = explicitRequestMethod(executable: executable, args: writes)
            if case .some(.none) = method { return "" }
            let methodPattern = method.flatMap { $0 }.map { "\(executable == "wget" ? "--method" : "-X") \($0)" }
            let flagPattern = writes.first { isRemoteWriteFlag($0) && !isRequestMethodOption($0, executable: executable) }
                .map { flag -> String in
                    let name = flag.split(separator: "=", maxSplits: 1).first.map(String.init) ?? flag
                    return flag.contains("=") ? "\(name)=*" : name
                }
            return ([flagPattern, methodPattern].compactMap { $0 } + [hostPattern]).joined(separator: " ")
        }
        let allActionTokens = commandActionTokens(executable: executable, args: args, risk: risk)
            .map(normalizedPatternToken)
        let actionTokens = allActionTokens.filter(isSafeShellPatternToken)
        guard !actionTokens.isEmpty else { return "*" }
        let tokenLimit = patternTokenLimit(for: risk)
        let kept = Array(actionTokens.prefix(tokenLimit))
        // A force or delete past the kept tokens stays in the pattern, so
        // approving a push is not approving a force. A deleting refspec
        // (`:branch`) is not a safe pattern token, so it is named by the
        // flag that means the same.
        var escalations = executable == "git"
            ? actionTokens.dropFirst(tokenLimit).filter { isPushEscalation($0) }
            : []
        if executable == "git", allActionTokens.contains(where: { $0.hasPrefix(":") && $0.count > 1 }),
           !kept.contains("--delete"), !escalations.contains("--delete") {
            escalations.append("--delete")
        }
        return (kept + escalations + ["*"]).joined(separator: " ")
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
            return dropLeadingOptions(args, optionsWithValues: ["--namespace", "-n", "--context"])
        case "docker":
            return dropLeadingOptions(args, optionsWithValues: ["--context", "-H"])
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

    /// The method a request names, read as curl reads it — the last `-X` or
    /// `--request` wins (wget: `--method`) — once read methods are dropped.
    /// `.none` when it names none; `.some(nil)` when it names one this cannot
    /// read, which no grant may stand for.
    private static func explicitRequestMethod(executable: String, args: [String]) -> String?? {
        var method: String?? = .none
        var index = 0
        while index < args.count {
            let arg = normalizedArgument(args[index])
            if isRequestMethodOption(arg, executable: executable) {
                var value: String?
                if let equals = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                    value = String(arg[arg.index(after: equals)...])
                } else if arg.hasPrefix("--") || arg == "-X" {
                    if args.indices.contains(index + 1) { value = normalizedArgument(args[index + 1]) }
                    index += 1
                } else {
                    // `-XPOST`, `-sXPOST`: the method is the rest of the token,
                    // or the next one when the token ends at `X`.
                    let rest = String(arg.dropFirst(combinedShortOptions(arg).count + 1))
                    if !rest.isEmpty {
                        value = rest
                    } else {
                        if args.indices.contains(index + 1) { value = normalizedArgument(args[index + 1]) }
                        index += 1
                    }
                }
                method = .some(value.flatMap {
                    $0.range(of: #"^[A-Za-z]{1,32}$"#, options: .regularExpression) != nil ? $0.uppercased() : nil
                })
            }
            index += 1
        }
        return method
    }

    /// `-X`/`--request` (curl) or `--method` (wget), in any spelling curl
    /// and wget accept: separate, `=`-attached, or `-XPOST`/`-sXPOST`.
    private static func isRequestMethodOption(_ token: String, executable: String) -> Bool {
        let normalized = normalizedArgument(token)
        let name = (normalized.split(separator: "=", maxSplits: 1).first.map(String.init) ?? normalized).lowercased()
        if executable == "wget" { return name == "--method" }
        if name == "--request" { return true }
        guard normalized.hasPrefix("-"), !normalized.hasPrefix("--") else { return false }
        return normalized == "-X" || combinedShortOptions(normalized).last == "-X"
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
                "--post-file", "--post-data", "--json", "--body-data", "--body-file", "--data-ascii", "--quote",
                "--mail-rcpt"
            ].contains(optionName.lowercased()) || isWriteMethodOption(normalized)
        }
        let remoteWriteShortFlags: Set<String> = ["-d", "-F", "-X", "-T", "-Q"]
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

    private static func isNetworkMutationFlag(_ token: String) -> Bool {
        if isRemoteWriteFlag(token) { return true }
        let normalized = normalizedArgument(token)
        let optionName = normalized.split(separator: "=", maxSplits: 1).first.map(String.init) ?? normalized
        if ["-o", "-O"].contains(optionName) || optionName.lowercased() == "--output" { return true }
        return combinedShortOptions(normalized).contains { $0 == "-o" || $0 == "-O" }
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
        "list", "ls", "describe", "show", "get", "view", "read", "status", "version"
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
