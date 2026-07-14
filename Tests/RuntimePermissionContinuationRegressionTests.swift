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
