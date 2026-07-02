import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Auto-approval classifier")
struct AutoApprovalClassifierTests {
    /// A review-style render: Read/Glob/Grep allowed, Bash + edits ask-first,
    /// destructive shell denied. Mirrors the production `.review` preset shape.
    private func reviewManifest() -> RunPermissionManifest {
        let render = ProviderPolicyRender(
            providerID: .claudeCode,
            adapterVersion: 1,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: .restricted,
            allowedTools: ["Read", "Glob", "Grep"],
            runtimeSupportTools: [],
            askFirstTools: ["Bash", "Edit", "Write", "WebFetch"],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: ["rm:*", "sudo:*", "git push:*"],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
        return RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "run",
            providerID: .claudeCode,
            providerVersion: nil,
            model: "claude-sonnet-4-6",
            policyLevel: .review,
            policyScope: .builtInDefault,
            providerRender: render,
            workspacePath: "/tmp/classifier-ws",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            approvalGrants: []
        )
    }

    @Test("deny-listed commands are denied in every mode")
    func denyListedAlwaysDenied() {
        let manifest = reviewManifest()
        for policy in [PermissionPolicy.restricted, .interactive, .autonomous] {
            for command in ["rm -rf build", "sudo rm x", "git push origin main"] {
                let decision = AutoApprovalClassifier.decide(
                    toolName: "Bash", command: command, permissionPolicy: policy, manifest: manifest
                )
                if case .deny = decision { } else {
                    Issue.record("\(command) under \(policy) should deny, got \(decision)")
                }
            }
        }
    }

    @Test("ask-first commands forward in Ask, auto-approve in Auto")
    func askFirstForwardsOrAutoApproves() {
        let manifest = reviewManifest()
        // npm install: Bash is ask-first, command not deny-listed.
        #expect(AutoApprovalClassifier.decide(
            toolName: "Bash", command: "npm install lodash", permissionPolicy: .restricted, manifest: manifest
        ) == .forwardToUser)
        #expect(AutoApprovalClassifier.decide(
            toolName: "Bash", command: "npm install lodash", permissionPolicy: .autonomous, manifest: manifest
        ) == .autoApprove)
    }

    @Test("already-allowed tools auto-approve without bothering the user")
    func allowedAutoApproves() {
        let manifest = reviewManifest()
        #expect(AutoApprovalClassifier.decide(
            toolName: "Read", command: nil, permissionPolicy: .restricted, manifest: manifest
        ) == .autoApprove)
    }

    @Test("Auto never blanket-approves a deny-listed command (no provider-defined blast radius)")
    func autoDoesNotRubberStampDenied() {
        let manifest = reviewManifest()
        let decision = AutoApprovalClassifier.decide(
            toolName: "Bash", command: "rm -rf /", permissionPolicy: .autonomous, manifest: manifest
        )
        if case .deny = decision { } else {
            Issue.record("Auto must deny rm -rf, got \(decision)")
        }
    }

    @Test("An empty/whitespace tool name is denied, not auto-approved in Auto")
    func emptyToolNameDeniedInAuto() {
        let manifest = reviewManifest()
        for name in ["", "   ", "\n\t"] {
            let decision = AutoApprovalClassifier.decide(
                toolName: name, command: nil, permissionPolicy: .autonomous, manifest: manifest
            )
            if case .deny = decision { } else {
                Issue.record("empty tool name \(name.debugDescription) must deny in Auto, got \(decision)")
            }
        }
    }

    @Test("A tool neither allowed nor ask-first is denied, not auto-approved in Auto")
    func unlistedToolDeniedInAuto() {
        let manifest = reviewManifest()
        // WebSearch is neither in allowedTools nor askFirstTools here — the
        // post-hoc guard would stop it as "not in allow-list", so Auto must NOT
        // auto-approve it (the old default-.ask path would have).
        let auto = AutoApprovalClassifier.decide(
            toolName: "WebSearch", command: nil, permissionPolicy: .autonomous, manifest: manifest
        )
        if case .deny = auto { } else { Issue.record("Auto must deny an unlisted tool, got \(auto)") }
        let ask = AutoApprovalClassifier.decide(
            toolName: "WebSearch", command: nil, permissionPolicy: .restricted, manifest: manifest
        )
        if case .deny = ask { } else { Issue.record("Ask must deny an unlisted tool, got \(ask)") }
    }

    @Test("Allowed shell tool scoped by allowedShellPatterns: out-of-scope command not auto-approved")
    func shellOutsideAllowedPatternsNotAutoApproved() {
        // The hole the review flagged: Bash is broadly allowed, but
        // allowedShellPatterns scopes it to `git status *`. The old disposition
        // saw Bash allowed and stopped — missing validateShell, which denies a
        // command outside the scope. Routing through the guard catches it.
        let render = ProviderPolicyRender(
            providerID: .claudeCode, adapterVersion: 1, policyLevel: .custom,
            configOwnership: .generated, permissionMode: .restricted,
            allowedTools: ["Bash"], runtimeSupportTools: [],
            askFirstTools: [], deniedTools: [],
            allowedShellPatterns: ["git status *"], askFirstShellPatterns: [],
            deniedShellPatterns: ["rm:*"],
            allowedURLPatterns: [], deniedURLPatterns: [],
            cliArgumentsSummary: [], settingsSummary: "test", generatedConfigPreview: "",
            enforcementTiers: [.astraBrokered], diagnostics: [], usesBroadProviderPermissions: false
        )
        let manifest = RunPermissionManifest(
            taskID: UUID(), runID: UUID(), phase: "run", providerID: .claudeCode,
            providerVersion: nil, model: "claude-sonnet-4-6", policyLevel: .custom,
            policyScope: .builtInDefault, providerRender: render,
            workspacePath: "/tmp/classifier-ws", additionalPaths: [],
            environmentKeyNames: [], credentialLabels: [], approvalsGranted: [], approvalGrants: []
        )
        // In-scope command auto-approves.
        #expect(AutoApprovalClassifier.decide(
            toolName: "Bash", command: "git status -s", permissionPolicy: .autonomous, manifest: manifest
        ) == .autoApprove)
        // Out-of-scope command must NOT auto-approve, even though Bash is allowed.
        let curl = AutoApprovalClassifier.decide(
            toolName: "Bash", command: "curl https://evil.test", permissionPolicy: .autonomous, manifest: manifest
        )
        #expect(curl != .autoApprove)
    }
}
