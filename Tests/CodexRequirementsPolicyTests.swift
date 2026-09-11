import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The verbatim shape of `~/.codex/cloud-config-bundle-cache.json` on the machine
/// that hit this in production, trimmed only in the denied-domain list. The two
/// entries matter: the second constrains nothing this reads, so intersecting must
/// not narrow the first.
private let enterpriseBundleCache = #"""
{
  "signed_payload": {
    "version": 1,
    "cached_at": "2026-09-10T23:27:30.869211Z",
    "expires_at": "2026-09-11T00:27:30.869211Z",
    "bundle": {
      "config_toml": {"enterprise_managed": []},
      "requirements_toml": {
        "enterprise_managed": [
          {
            "id": "regulated-workspace-default-fallback",
            "name": "Baseline",
            "contents": "# For the options available here, refer to:\n# https://developers.openai.com/codex/config-reference#requirementstoml\n\nallowed_approval_policies = [\"on-request\", \"untrusted\"]\nallowed_approvals_reviewers = [\"user\", \"auto_review\"]\nallowed_sandbox_modes = [\"read-only\", \"workspace-write\"]\nallowed_web_search_modes = [\"cached\", \"disabled\"]\n\nexperimental_network.enabled = true\nexperimental_network.denied_domains = [\n  \"sequoia.stanford.edu\",\n  \"*.console.aws.amazon.com\",\n]\n\n[windows]\nallowed_sandbox_implementations = [\"elevated\"]\n\n[features]\ncomputer_use = false\nbrowser_use = false\n\n[mcp_servers]\n# None allowed\n"
          },
          {
            "id": "rbac-computer-history",
            "name": "Computer History access",
            "contents": "[features]\nchronicle = false\n"
          }
        ]
      }
    }
  },
  "signature": "q7J+eS52bMPy1Hyflqfhc1SC39kBQ9yCqEqKUamiWYw="
}
"""#

private func bundleCache(requirements: [String]) -> Data {
    let entries = requirements.enumerated().map { index, contents in
        let escaped = contents
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"id": "entry-\#(index)", "name": "Entry \#(index)", "contents": "\#(escaped)"}"#
    }
    let json = """
    {"signed_payload": {"bundle": {"requirements_toml": {"enterprise_managed": [\(entries.joined(separator: ","))]}}}}
    """
    return Data(json.utf8)
}

@Suite("Codex requirements policy")
struct CodexRequirementsPolicyTests {
    @Test("Enterprise bundle yields the sandbox modes and Windows pin it names")
    func enterpriseBundleYieldsAllowedSandboxModes() {
        let policy = CodexRequirementsService.policy(bundleCacheData: Data(enterpriseBundleCache.utf8))

        #expect(policy.allowedSandboxModes == [.readOnly, .workspaceWrite])
        #expect(policy.requiredWindowsSandbox == "elevated")
        #expect(policy.allowedApprovalPolicies == ["on-request", "untrusted"])
        #expect(policy.allowedApprovalsReviewers == ["user", "auto_review"])
        #expect(policy.evidence == ["codex-requirements:regulated-workspace-default-fallback"])
        #expect(!policy.isUnconstrained)
    }

    @Test("An autonomous run under enterprise requirements asks for workspace-write, not a bypass")
    func autonomousRunAsksForTheStrongestAllowedSandbox() {
        let policy = CodexRequirementsService.policy(bundleCacheData: Data(enterpriseBundleCache.utf8))

        // The bug this fixes: `--dangerously-bypass-approvals-and-sandbox` is not
        // in the allowed set, so Codex substitutes the *most restrictive* allowed
        // mode and the run spends its life unable to write a file.
        #expect(CodexCLIRuntime.codexPermissionArguments(policy: .autonomous, requirements: policy) == [
            "-c", "windows.sandbox=\"elevated\"",
            "-c", "approvals_reviewer=\"auto_review\"",
            "--sandbox", "workspace-write"
        ])
        #expect(CodexCLIRuntime.codexResumePermissionArguments(policy: .autonomous, requirements: policy) == [
            "-c", "windows.sandbox=\"elevated\"",
            "-c", "approvals_reviewer=\"auto_review\"",
            "-c", "sandbox_mode=\"workspace-write\""
        ])
    }

    @Test("Requirements never widen a policy that already asks for less")
    func requirementsNeverWidenANarrowerPolicy() {
        let policy = CodexRequirementsService.policy(bundleCacheData: Data(enterpriseBundleCache.utf8))

        #expect(CodexCLIRuntime.codexPermissionArguments(policy: .interactive, requirements: policy) == [
            "-c", "windows.sandbox=\"elevated\"",
            "-c", "approvals_reviewer=\"auto_review\"",
            "--sandbox", "read-only"
        ])
    }

    @Test("A bundle that bars `never` gets a reviewer that exec mode can answer with")
    func bundleBarringNeverAsksForTheAutomaticReviewer() {
        // Reproduced on codex-cli 0.153.4 against this exact bundle: under the
        // corrected `on-request` policy `ls` still runs, but anything Codex does
        // not consider trivially safe dies with
        //   exec_command failed: CreateProcess { message: "Rejected(\"approval request failed\")" }
        // because `codex exec` answers its own approval requests with
        //   -32000 command execution approval is not supported in exec mode
        // Naming `on-request` does not help — exec overrides it back to `never`
        // and the bundle corrects that — and `untrusted`, the only other value
        // this bundle allows, is fatal at launch on that CLI.
        let policy = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "allowed_approval_policies = [\"on-request\", \"untrusted\"]\nallowed_approvals_reviewers = [\"user\", \"auto_review\"]"
        ]))

        #expect(!policy.permitsNeverApprovalPolicy)
        #expect(policy.permitsAutomaticApprovalReviewer)
        #expect(policy.approvalArguments == ["-c", "approvals_reviewer=\"auto_review\""])
    }

    @Test("Approval clamping turns only on the values the bundle actually names")
    func approvalClampingTurnsOnlyOnTheNamedValues() {
        let neverArguments = ["-c", "approval_policy=\"never\""]

        // A bundle that still permits `never` needs no reviewer: `codex exec`
        // pins `never` for itself and no approval is ever requested.
        let permitsNever = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "allowed_approval_policies = [\"never\", \"on-request\"]"
        ]))
        #expect(permitsNever.permitsNeverApprovalPolicy)
        #expect(permitsNever.approvalArguments == neverArguments)

        // Barring `auto_review` too leaves nothing to negotiate with, so the run
        // keeps the arguments it has always had rather than sending a reviewer
        // the org withheld.
        let barsReviewer = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "allowed_approval_policies = [\"on-request\"]\nallowed_approvals_reviewers = [\"user\"]"
        ]))
        #expect(!barsReviewer.permitsAutomaticApprovalReviewer)
        #expect(barsReviewer.approvalArguments == neverArguments)

        // No recorded reviewer constraint is not a withheld reviewer.
        let reviewerUnconstrained = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "allowed_approval_policies = [\"on-request\"]"
        ]))
        #expect(reviewerUnconstrained.approvalArguments == ["-c", "approvals_reviewer=\"auto_review\""])

        // Unlike a sandbox mode, an unrecognised approval spelling must still
        // read as a constraint: it is evidence that `never` was excluded, and
        // falling open here puts the run straight back into the failure.
        let unknownOnly = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "allowed_approval_policies = [\"quantum-approve\"]"
        ]))
        #expect(unknownOnly.allowedApprovalPolicies == ["quantum-approve"])
        #expect(unknownOnly.approvalArguments == ["-c", "approvals_reviewer=\"auto_review\""])

        // `Never` and `never` are the same permission.
        let mixedCase = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "allowed_approval_policies = [\"Never\"]"
        ]))
        #expect(mixedCase.approvalArguments == neverArguments)
    }

    @Test("An unconstrained policy reproduces the unclamped arguments exactly")
    func unconstrainedPolicyReproducesUnclampedArguments() {
        for policy in PermissionPolicy.allCases {
            #expect(
                CodexCLIRuntime.codexPermissionArguments(policy: policy, requirements: .unconstrained)
                    == CodexCLIRuntime.codexPermissionArguments(policy: policy)
            )
        }
        #expect(CodexCLIRuntime.codexPermissionArguments(policy: .autonomous, requirements: .unconstrained)
            == ["--dangerously-bypass-approvals-and-sandbox"])
        #expect(CodexCLIRuntime.codexPermissionArguments(policy: .restricted, requirements: .unconstrained)
            == ["-c", "approval_policy=\"never\"", "--sandbox", "workspace-write"])
        #expect(CodexRequirementsPolicy.unconstrained.isUnconstrained)
    }

    @Test("Unreadable, unrecognised, and constraint-free bundles all fail open")
    func malformedBundlesFailOpen() {
        #expect(CodexRequirementsService.policy(bundleCacheData: Data("not json".utf8)) == .unconstrained)
        #expect(CodexRequirementsService.policy(bundleCacheData: Data("{}".utf8)) == .unconstrained)
        #expect(CodexRequirementsService.policy(
            bundleCacheData: bundleCache(requirements: ["[features]\nchronicle = false\n"])
        ) == .unconstrained)

        // A Codex release that adds a mode must not pin every run to the modes
        // this build happens to know about.
        let unknownOnly = CodexRequirementsService.policy(
            bundleCacheData: bundleCache(requirements: ["allowed_sandbox_modes = [\"quantum-write\"]"])
        )
        #expect(unknownOnly.allowedSandboxModes == nil)
    }

    @Test("Multiple requirement entries intersect rather than override")
    func multipleRequirementEntriesIntersect() {
        let policy = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "allowed_sandbox_modes = [\"read-only\", \"workspace-write\"]",
            "allowed_sandbox_modes = [\"workspace-write\", \"danger-full-access\"]"
        ]))

        #expect(policy.allowedSandboxModes == [.workspaceWrite])
        #expect(policy.evidence == ["codex-requirements:entry-0", "codex-requirements:entry-1"])
    }

    @Test("A Windows pin is only taken when the requirements leave one choice")
    func windowsPinRequiresASingleAllowedImplementation() {
        let single = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "[windows]\nallowed_sandbox_implementations = [\"elevated\"]"
        ]))
        #expect(single.requiredWindowsSandbox == "elevated")
        #expect(single.windowsSandboxArguments == ["-c", "windows.sandbox=\"elevated\""])

        let ambiguous = CodexRequirementsService.policy(bundleCacheData: bundleCache(requirements: [
            "[windows]\nallowed_sandbox_implementations = [\"elevated\", \"unprivileged\"]"
        ]))
        #expect(ambiguous.requiredWindowsSandbox == nil)
        #expect(ambiguous.windowsSandboxArguments.isEmpty)
    }

    @Test("Requirements allowing only a wider mode still name a permitted one")
    func requirementsAllowingOnlyAWiderModeStillNameAPermittedOne() {
        // Codex substitutes a value whenever the configured one is not allowed,
        // in either direction, so ASTRA has to name something from the set even
        // when the set has nothing at or below what the run wanted.
        let policy = CodexRequirementsPolicy(
            allowedSandboxModes: [.dangerFullAccess],
            requiredWindowsSandbox: nil,
            evidence: []
        )
        #expect(policy.permittedSandboxMode(preferring: .readOnly) == .dangerFullAccess)
        #expect(policy.permittedSandboxMode(preferring: .dangerFullAccess) == .dangerFullAccess)
    }

    @Test("The ambient host Codex home is closed to test processes")
    func ambientHostCodexHomeIsClosedToTests() {
        // Vacuous on a machine with no enterprise bundle, and the whole point on
        // one that has it: without this gate every suite asserting Codex launch
        // arguments passes or fails according to whose employer's policy ran it.
        CodexRequirementsService.invalidateCache()
        #expect(CodexRequirementsService.current() == .unconstrained)
    }

    @Test("Reading a real Codex home goes through the file access broker")
    func readingARealCodexHomeGoesThroughTheBroker() throws {
        let codexHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-requirements-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let environment = ["CODEX_HOME": codexHome.path]
        // No bundle yet: an install with no enterprise policy is the common case
        // and must reach Codex with the arguments it always used.
        CodexRequirementsService.invalidateCache()
        #expect(CodexRequirementsService.current(environment: environment) == .unconstrained)

        try Data(enterpriseBundleCache.utf8).write(
            to: codexHome.appendingPathComponent(CodexRequirementsService.bundleCacheFileName)
        )
        CodexRequirementsService.invalidateCache()
        let policy = CodexRequirementsService.current(environment: environment)
        #expect(policy.allowedSandboxModes == [.readOnly, .workspaceWrite])
        #expect(policy.requiredWindowsSandbox == "elevated")
    }

    @Test("The bundle cache path follows CODEX_HOME before HOME")
    func bundleCachePathFollowsCodexHome() {
        #expect(CodexRequirementsService.bundleCacheURL(
            environment: ["CODEX_HOME": "/scoped/codex", "HOME": "/Users/someone"],
            processHomeDirectory: "/Users/other"
        )?.path == "/scoped/codex/cloud-config-bundle-cache.json")

        #expect(CodexRequirementsService.bundleCacheURL(
            environment: ["HOME": "/Users/someone"],
            processHomeDirectory: "/Users/other"
        )?.path == "/Users/someone/.codex/cloud-config-bundle-cache.json")

        #expect(CodexRequirementsService.bundleCacheURL(
            environment: [:],
            processHomeDirectory: "/Users/other"
        )?.path == "/Users/other/.codex/cloud-config-bundle-cache.json")
    }
}

@Suite("Codex requirements TOML scanning")
struct CodexRequirementsTOMLTests {
    @Test("A root key is read past comments and unrelated multi-line arrays")
    func rootKeyIsReadPastCommentsAndMultiLineArrays() {
        let toml = """
        # allowed_sandbox_modes = ["danger-full-access"]
        experimental_network.denied_domains = [
          "a.example.com",
          "b.example.com",
        ]
        allowed_sandbox_modes = ["read-only", "workspace-write"]  # trailing note
        """

        #expect(CodexRequirementsTOML.stringArray(named: "allowed_sandbox_modes", table: nil, in: toml)
            == ["read-only", "workspace-write"])
    }

    @Test("A key is scoped to its table")
    func keyIsScopedToItsTable() {
        let toml = """
        allowed = ["root-value"]

        [windows]
        allowed = ["table-value"]
        """

        #expect(CodexRequirementsTOML.stringArray(named: "allowed", table: nil, in: toml) == ["root-value"])
        #expect(CodexRequirementsTOML.stringArray(named: "allowed", table: "windows", in: toml) == ["table-value"])
        #expect(CodexRequirementsTOML.stringArray(named: "allowed", table: "linux", in: toml) == nil)
        #expect(CodexRequirementsTOML.stringArray(named: "missing", table: nil, in: toml) == nil)
    }

    @Test("A multi-line array spanning the key being read is reassembled")
    func multiLineArrayForTheReadKeyIsReassembled() {
        let toml = """
        [windows]
        allowed_sandbox_implementations = [
          "elevated",   # the only one this org permits
          "unprivileged",
        ]
        """

        #expect(CodexRequirementsTOML.stringArray(
            named: "allowed_sandbox_implementations",
            table: "windows",
            in: toml
        ) == ["elevated", "unprivileged"])
    }
}
