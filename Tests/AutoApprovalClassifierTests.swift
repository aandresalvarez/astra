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
            permissionMode: PermissionPolicy.restricted.rawValue,
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
}
