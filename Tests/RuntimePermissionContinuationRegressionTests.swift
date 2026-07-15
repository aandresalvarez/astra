import Testing
import ASTRACore
@testable import ASTRA

@Suite("Runtime Permission Continuation Regression")
struct RuntimePermissionContinuationRegressionTests {
    @Test("Broker scopes provider shell launchers to their semantic command")
    func brokerScopesProviderShellLaunchersToSemanticCommand() {
        let commands = [
            "/bin/zsh -lc 'git status --short --branch'",
            #"/bin/zsh -lc "git status --short --branch""#,
            #"/bin/zsh -lc 'zsh -lc "git status --short --branch"'"#
        ]

        for command in commands {
            let grants = PermissionBroker.approvalGrants(for: .shell(
                command: command,
                toolName: "command_execution"
            ))
            #expect(
                grants == [.shellCommand(executable: "git", pattern: "status --short *")],
                "Expected semantic git grant for \(command)"
            )
        }
    }

    @Test("Semantic shell normalization rejects ordinary commands ending in a launcher-like argument")
    func semanticShellNormalizationRequiresExactLauncherPrefix() {
        let ordinaryCommand = "rm -- /tmp/attached.pdf /bin/sh -lc 'true'"
        let assignmentWrapper = "ATTACH='/tmp/path with spaces.pdf' /bin/sh -lc 'rm \"$ATTACH\"'"
        let envWrapper = "env -u OLD ATTACH='/tmp/path with spaces.pdf' /bin/bash -lc 'rm \"$ATTACH\"'"

        #expect(ProviderToolSemantics.semanticShellCommand(ordinaryCommand) == ordinaryCommand)
        #expect(ProviderToolSemantics.semanticShellCommand(assignmentWrapper) == assignmentWrapper)
        #expect(ProviderToolSemantics.semanticShellCommand(envWrapper) == envWrapper)
        #expect(
            ProviderToolSemantics.mutationAnalysisShellCommand(assignmentWrapper)
                == "rm \"$ATTACH\""
        )
        #expect(
            ProviderToolSemantics.mutationAnalysisShellCommand(envWrapper)
                == "rm \"$ATTACH\""
        )
    }

    @Test("Environment-configured launchers cannot reuse a payload-only approval")
    func environmentConfiguredLauncherDoesNotReusePayloadApproval() {
        let approvedGrant = PermissionGrant.shellCommand(
            executable: "git",
            pattern: "status --short *"
        )
        let command = "BASH_ENV=/tmp/astra-hook /bin/bash -lc 'git status --short --branch'"
        let generatedGrants = PermissionBroker.approvalGrants(for: .shell(
            command: command,
            toolName: "command_execution"
        ))
        #expect(!generatedGrants.contains(approvedGrant))

        let manifest = runtimePolicyManifest(
            allowedTools: ["Read"],
            askFirstTools: ["Bash"],
            providerID: .codexCLI,
            approvalGrants: [approvedGrant]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "command_execution",
                id: "environment-configured-launcher",
                input: ["command": command]
            ),
            process: nil
        )

        #expect(shouldKill)
        #expect(monitor.policyApprovalRequired)
        #expect(!monitor.policyViolation)
    }

    @Test("Codex resumed Ask approval authorizes the exact wrapped command once")
    func codexResumedAskApprovalAuthorizesExactWrappedCommand() {
        let grant = PermissionGrant.shellCommand(
            executable: "git",
            pattern: "status --short *"
        )
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read"],
            askFirstTools: ["Bash"],
            providerID: .codexCLI,
            approvalGrants: [grant]
        )
        let approvedMonitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let approvedShouldKill = approvedMonitor.processEvent(
            .toolUse(
                name: "command_execution",
                id: "approved",
                input: ["command": "/bin/zsh -lc 'git status --short --branch'"]
            ),
            process: nil
        )

        #expect(approvedShouldKill == false)
        #expect(approvedMonitor.policyApprovalRequired == false)
        #expect(approvedMonitor.policyViolation == false)

        let siblingMonitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )
        let siblingShouldKill = siblingMonitor.processEvent(
            .toolUse(
                name: "command_execution",
                id: "not-approved",
                input: ["command": "/bin/zsh -lc 'git push origin main'"]
            ),
            process: nil
        )

        #expect(siblingShouldKill == true)
        #expect(siblingMonitor.policyApprovalRequired == true)
        #expect(siblingMonitor.policyViolation == false)
    }
}
