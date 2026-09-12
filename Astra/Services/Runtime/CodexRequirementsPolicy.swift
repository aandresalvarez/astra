import Foundation
import ASTRACore

/// Codex sandbox modes, ordered least to most permissive.
///
/// Raw values are the spellings Codex accepts for `--sandbox` and for the
/// `sandbox_mode` config key, which are also the spellings an enterprise
/// requirements bundle uses in `allowed_sandbox_modes`.
enum CodexSandboxMode: String, CaseIterable, Comparable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    private var permissiveness: Int {
        switch self {
        case .readOnly: 0
        case .workspaceWrite: 1
        case .dangerFullAccess: 2
        }
    }

    static func < (lhs: CodexSandboxMode, rhs: CodexSandboxMode) -> Bool {
        lhs.permissiveness < rhs.permissiveness
    }
}

/// The sandbox values a local Codex install will actually accept.
///
/// Codex does not reject a disallowed sandbox mode, it *substitutes* one: a run
/// that asks for something outside the allowed set gets the most restrictive
/// allowed value instead, plus an error item in the JSON stream. So asking for
/// more than the org permits returns strictly less than asking for exactly what
/// it permits. Under a bundle allowing `[read-only, workspace-write]`,
/// `--dangerously-bypass-approvals-and-sandbox` lands on read-only and an
/// autonomous task spends its whole run unable to write a file; asking for
/// `workspace-write` gets workspace-write.
///
/// `nil` means "no constraint recorded", not "nothing allowed". Every missing
/// file, parse failure, and unrecognised value falls open to the unclamped
/// behaviour rather than narrowing a run on a guess.
///
/// The approval *policy* is still never sent from an allowed set. `codex exec`
/// overrides whatever policy arrives with `never` before the bundle sees it, so
/// naming an allowed one changes nothing, and an allowed set can list a
/// spelling the installed CLI has since dropped (`untrusted` is allowed by this
/// schema and fatal on 0.153.4: "no longer supported; remove this setting").
/// What is negotiated instead is the approval *reviewer* — see
/// `approvalArguments`.
struct CodexRequirementsPolicy: Equatable, Sendable {
    var allowedSandboxModes: Set<CodexSandboxMode>?
    /// The Windows sandbox implementation the requirements pin, when they pin
    /// exactly one. Codex validates this key on every host, so leaving it unset
    /// costs a spurious error item per turn even on macOS.
    var requiredWindowsSandbox: String?
    /// Approval spellings named verbatim, deliberately not mapped onto an enum.
    ///
    /// ASTRA only ever sends one approval policy of its own, so the single
    /// question to ask a bundle is whether `never` survives it — and an
    /// unrecognised spelling in the allowed set is still a spelling that is not
    /// `never`. Mapping first would read
    /// `allowed_approval_policies = ["quantum-approve"]` as "no constraint
    /// recorded" and put the run back into the failure this exists to avoid,
    /// which is the opposite of how an unknown sandbox mode has to be treated.
    var allowedApprovalPolicies: Set<String>?
    /// Reviewers the bundle permits, verbatim, for the same reason.
    var allowedApprovalsReviewers: Set<String>?
    /// Short, stable labels naming the requirement entries that constrained
    /// this policy, for logs and capability evidence.
    var evidence: [String]

    static let unconstrained = CodexRequirementsPolicy(
        allowedSandboxModes: nil,
        requiredWindowsSandbox: nil,
        allowedApprovalPolicies: nil,
        allowedApprovalsReviewers: nil,
        evidence: []
    )

    var isUnconstrained: Bool {
        allowedSandboxModes == nil
            && requiredWindowsSandbox == nil
            && allowedApprovalPolicies == nil
            && allowedApprovalsReviewers == nil
    }

    /// The strongest permitted mode at or below `preferred`. When nothing
    /// allowed sits at or below it, the least permissive allowed mode wins:
    /// naming *some* permitted value is the only way to stop Codex from
    /// picking one for us.
    func permittedSandboxMode(preferring preferred: CodexSandboxMode) -> CodexSandboxMode {
        guard let allowed = allowedSandboxModes,
              !allowed.isEmpty,
              !allowed.contains(preferred) else {
            return preferred
        }
        return allowed.filter { $0 < preferred }.max() ?? allowed.min() ?? preferred
    }

    /// Config override that settles the `windows.sandbox` requirement up front,
    /// or nothing when the requirements do not pin one.
    var windowsSandboxArguments: [String] {
        guard let requiredWindowsSandbox, !requiredWindowsSandbox.isEmpty else { return [] }
        return ["-c", "windows.sandbox=\"\(requiredWindowsSandbox)\""]
    }

    /// The only approval policy an ASTRA run wants: nothing in `codex exec`
    /// speaks an approval protocol, so a run that is asked to approve something
    /// has already lost.
    static let neverApprovalPolicy = "never"

    /// The reviewer that answers an approval request without a human. Codex also
    /// accepts `user`, which wants the interactive terminal ASTRA does not have,
    /// and `guardian_subagent`, which no bundle seen so far permits.
    static let automaticApprovalReviewer = "auto_review"

    /// How this run asks Codex not to stop for approval.
    ///
    /// Normally that is `approval_policy="never"` and Codex needs no persuading,
    /// because `exec` pins `never` for itself anyway. A bundle that disallows
    /// `never` corrects it to `on-request`, and from there every command Codex
    /// does not consider trivially safe raises an approval request that exec mode
    /// cannot service. `ls` still runs; anything else dies:
    ///
    ///     ERROR codex_app_server: command execution approval is not supported
    ///       in exec mode for thread `…`
    ///     ERROR codex_core::tools::router: error=exec_command failed:
    ///       CreateProcess { message: "Rejected(\"approval request failed\")" }
    ///
    /// Naming an allowed policy is not the way out: `exec` replaces it with
    /// `never` before the bundle is consulted, so such a run is corrected to
    /// `on-request` and fails exactly like one that named nothing. The lever that
    /// works is the reviewer. `approvals_reviewer="auto_review"` gives exec mode
    /// something that can answer, and the requests resolve rather than fail.
    /// Dropping ASTRA's own `never` alongside it is what keeps a disallowed-value
    /// error item out of every turn — and, unlike a sandbox widening, it concedes
    /// nothing the org withheld, since a reviewer cannot approve past the
    /// bundle's own network denials ("domain is explicitly denied by policy and
    /// cannot be approved from this prompt").
    ///
    /// The reviewer goes in as a `-c` override rather than as `exec`'s
    /// `--approve-for-me`, which is unusable twice over: it is rejected
    /// alongside `--sandbox` ("cannot be used with"), and `exec resume` does not
    /// take it at all, which would strand every turn after the first.
    ///
    /// A bundle that bars `never` while also barring `auto_review` leaves nothing
    /// to negotiate with, so that run keeps the arguments it has always had.
    var approvalArguments: [String] {
        if !permitsNeverApprovalPolicy, permitsAutomaticApprovalReviewer {
            return ["-c", "approvals_reviewer=\"\(Self.automaticApprovalReviewer)\""]
        }
        return ["-c", "approval_policy=\"\(Self.neverApprovalPolicy)\""]
    }

    var permitsNeverApprovalPolicy: Bool {
        guard let allowedApprovalPolicies, !allowedApprovalPolicies.isEmpty else { return true }
        return allowedApprovalPolicies.contains(Self.neverApprovalPolicy)
    }

    var permitsAutomaticApprovalReviewer: Bool {
        guard let allowedApprovalsReviewers, !allowedApprovalsReviewers.isEmpty else { return true }
        return allowedApprovalsReviewers.contains(Self.automaticApprovalReviewer)
    }
}

extension PermissionPolicy {
    var preferredCodexSandboxMode: CodexSandboxMode {
        switch self {
        case .autonomous: .dangerFullAccess
        case .restricted: .workspaceWrite
        case .interactive: .readOnly
        }
    }
}

/// Reads the enterprise requirements a local Codex install is already enforcing.
///
/// Codex caches its signed enterprise bundle at
/// `<CODEX_HOME>/cloud-config-bundle-cache.json` and applies the
/// `requirements_toml` entries inside it to every run, including runs launched
/// with `--ignore-user-config` and `--ignore-rules`. The bundle is keyed by
/// ChatGPT account rather than by directory, so the ambient Codex home is the
/// right read even for a run that scopes `CODEX_HOME` elsewhere.
///
/// An expired cache is still honoured. The bundle carries a one-hour TTL, but a
/// stale restriction only ever makes ASTRA ask for less than it could have, and
/// asking for less is never the thing that breaks a run — whereas ignoring a
/// restriction that is still in force is exactly what produces a silently
/// read-only autonomous task.
enum CodexRequirementsService {
    static let bundleCacheFileName = "cloud-config-bundle-cache.json"

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var memo: (fingerprint: String, policy: CodexRequirementsPolicy)?

    /// Memoised per bundle file identity. Launch summaries and the launch itself
    /// both read this so the arguments a run is described with are the arguments
    /// it gets; re-parsing only happens when the file on disk changes.
    ///
    /// `environment` defaults to the host's, except inside a test process. The
    /// Codex home inside a test run is the developer's own, and the bundle
    /// stored there is their employer's real policy, which would make unrelated
    /// suites assert different launch arguments depending on whose laptop ran
    /// them. So the ambient read is closed to tests — leaving every suite seeing
    /// the unclamped arguments that predate this — and tests that exercise this
    /// service pass a Codex home of their own, the same contract
    /// `CodexMCPPolicyService` imposes for its shared defaults domain.
    static func current(
        environment: [String: String]? = nil,
        processHomeDirectory: String = NSHomeDirectory(),
        broker: HostFileAccessBroker = HostFileAccessBroker()
    ) -> CodexRequirementsPolicy {
        let resolvedEnvironment = environment
            ?? (isRunningTests ? nil : ProcessInfo.processInfo.environment)
        guard let resolvedEnvironment, let url = bundleCacheURL(
            environment: resolvedEnvironment,
            processHomeDirectory: processHomeDirectory
        ) else {
            return .unconstrained
        }
        let fingerprint = bundleFingerprint(url)
        cacheLock.lock()
        let hit = memo
        cacheLock.unlock()
        if let hit, hit.fingerprint == fingerprint {
            return hit.policy
        }

        let policy = readPolicy(at: url, broker: broker)
        cacheLock.lock()
        memo = (fingerprint: fingerprint, policy: policy)
        cacheLock.unlock()
        return policy
    }

    private static let isRunningTests: Bool = {
        ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }()

    /// Drops the memo. Bundle refreshes in place are already covered by the
    /// fingerprint, so this exists for tests and explicit re-detection.
    static func invalidateCache() {
        cacheLock.lock()
        memo = nil
        cacheLock.unlock()
    }

    static func bundleCacheURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processHomeDirectory: String = NSHomeDirectory()
    ) -> URL? {
        let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent(bundleCacheFileName)
        }
        let home = (environment["HOME"] ?? processHomeDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".codex")
            .appendingPathComponent(bundleCacheFileName)
    }

    /// The constraints carried by a bundle cache document. Pure, so tests never
    /// touch a real Codex home.
    static func policy(bundleCacheData data: Data) -> CodexRequirementsPolicy {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["signed_payload"] as? [String: Any],
              let bundle = payload["bundle"] as? [String: Any],
              let requirements = bundle["requirements_toml"] as? [String: Any],
              let entries = requirements["enterprise_managed"] as? [[String: Any]] else {
            return .unconstrained
        }

        var policy = CodexRequirementsPolicy.unconstrained
        for entry in entries {
            guard let contents = entry["contents"] as? String else { continue }
            let sandboxModes = allowedSandboxModes(in: contents)
            let windowsSandbox = pinnedWindowsSandbox(in: contents)
            let approvalPolicies = spellings(named: "allowed_approval_policies", in: contents)
            let approvalsReviewers = spellings(named: "allowed_approvals_reviewers", in: contents)
            guard sandboxModes != nil
                || windowsSandbox != nil
                || approvalPolicies != nil
                || approvalsReviewers != nil else { continue }
            policy.allowedSandboxModes = intersecting(policy.allowedSandboxModes, sandboxModes)
            policy.requiredWindowsSandbox = windowsSandbox ?? policy.requiredWindowsSandbox
            policy.allowedApprovalPolicies = intersecting(policy.allowedApprovalPolicies, approvalPolicies)
            policy.allowedApprovalsReviewers = intersecting(policy.allowedApprovalsReviewers, approvalsReviewers)
            policy.evidence.append("codex-requirements:\(label(for: entry))")
        }
        return policy
    }

    private static func label(for entry: [String: Any]) -> String {
        let identifier = (entry["id"] as? String) ?? ""
        if !identifier.isEmpty { return identifier }
        let name = (entry["name"] as? String) ?? ""
        return name.isEmpty ? "unnamed-requirements" : name
    }

    private static func readPolicy(at url: URL, broker: HostFileAccessBroker) -> CodexRequirementsPolicy {
        guard let data = try? broker.readData(
            at: url,
            intent: .astraManagedStorage(root: url.deletingLastPathComponent())
        ) else {
            return .unconstrained
        }
        return policy(bundleCacheData: data)
    }

    /// A requirement entry naming only modes ASTRA does not recognise imposes no
    /// constraint: a Codex release that adds a mode must not silently pin every
    /// run to the modes this build happens to know about.
    private static func allowedSandboxModes(in toml: String) -> Set<CodexSandboxMode>? {
        guard let raw = CodexRequirementsTOML.stringArray(
            named: "allowed_sandbox_modes",
            table: nil,
            in: toml
        ) else {
            return nil
        }
        let modes = Set(raw.compactMap(CodexSandboxMode.init(rawValue:)))
        return modes.isEmpty ? nil : modes
    }

    /// An allowed set kept as the bundle spells it, lowercased only so a
    /// differently-cased `Never` still reads as the value ASTRA sends. Nothing
    /// is dropped for being unrecognised: for approvals an unknown spelling is
    /// evidence of a constraint, not evidence of its absence.
    private static func spellings(named key: String, in toml: String) -> Set<String>? {
        guard let raw = CodexRequirementsTOML.stringArray(named: key, table: nil, in: toml) else {
            return nil
        }
        let values = Set(raw.map { $0.lowercased() })
        return values.isEmpty ? nil : values
    }

    /// Only a requirement leaving exactly one choice is worth pre-answering.
    /// With two or more, Codex's own default may already be allowed and ASTRA
    /// would be picking on the org's behalf.
    private static func pinnedWindowsSandbox(in toml: String) -> String? {
        let raw = CodexRequirementsTOML.stringArray(
            named: "allowed_sandbox_implementations",
            table: "windows",
            in: toml
        )
        guard let raw, raw.count == 1, let only = raw.first, !only.isEmpty else { return nil }
        return only
    }

    private static func intersecting<Value: Hashable>(_ current: Set<Value>?, _ next: Set<Value>?) -> Set<Value>? {
        guard let next else { return current }
        guard let current else { return next }
        return current.intersection(next)
    }

    private static func bundleFingerprint(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(url.path)|\(size)|\(modified)"
    }
}

/// Just enough TOML to read an array of strings out of a named table.
///
/// The requirements schema keeps its `allowed_*` lists at the document root or
/// one table deep, and a bundle is a few dozen lines, so a full TOML dependency
/// would buy nothing. The scanner tracks quoting, comments, table headers, and
/// multi-line arrays, which is the whole grammar these documents use.
enum CodexRequirementsTOML {
    /// `table` is `nil` for a root-level key, or the header name for a key
    /// inside `[header]`.
    static func stringArray(named key: String, table: String?, in toml: String) -> [String]? {
        var currentTable: String?
        var openBrackets = 0
        var pendingKey = ""
        var pendingTable: String?
        var pendingValue = ""

        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = strippingComment(String(rawLine))

            if openBrackets > 0 {
                pendingValue += " " + line
                openBrackets += bracketDelta(line)
                guard openBrackets <= 0 else { continue }
                if pendingKey == key, pendingTable == table { return stringArrayValues(pendingValue) }
                pendingKey = ""
                pendingValue = ""
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains("=") {
                currentTable = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: tableHeaderTrim)
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])

            openBrackets = bracketDelta(value)
            if openBrackets > 0 {
                pendingKey = name
                pendingTable = currentTable
                pendingValue = value
                continue
            }
            if name == key, currentTable == table { return stringArrayValues(value) }
        }
        return nil
    }

    /// Leaves `x` from `[x]`, `[[x]]`, and `[ "x" ]` alike.
    private static let tableHeaderTrim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "[]\"'"))

    private static func strippingComment(_ line: String) -> String {
        var quote: Character?
        for (offset, character) in line.enumerated() {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line.prefix(offset))
            }
        }
        return line
    }

    private static func bracketDelta(_ line: String) -> Int {
        var quote: Character?
        var delta = 0
        for character in line {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                delta += 1
            } else if character == "]" {
                delta -= 1
            }
        }
        return delta
    }

    private static func stringArrayValues(_ text: String) -> [String]? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else {
            return nil
        }
        return text[text.index(after: start)..<end]
            .split(separator: ",")
            .map { element in
                element
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
    }
}
