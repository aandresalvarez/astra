import Testing
@testable import ASTRA

extension RuntimePolicyGuardTests {
    @Test("Allowed shell pattern inspects Codex login shell payload")
    func allowedShellPatternInspectsCodexLoginShellPayload() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read"],
            allowedShellPatterns: ["git rev-parse *"],
            providerID: .codexCLI
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "command_execution",
                id: "t1",
                input: ["summary": "/bin/zsh -lc 'git rev-parse HEAD'"]
            ),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Codex login shell wrapper does not hide a disallowed command segment")
    func codexLoginShellWrapperDoesNotHideDisallowedCommandSegment() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            allowedShellPatterns: ["git rev-parse *"],
            providerID: .codexCLI
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "command_execution",
                id: "t1",
                input: ["summary": "/bin/zsh -lc 'git rev-parse HEAD && git push origin main'"]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("outside the allowed command patterns") == true)
    }

    @Test("Denied shell pattern inspects Codex login shell payload")
    func deniedShellPatternInspectsCodexLoginShellPayload() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            deniedShellPatterns: ["rm:*"],
            providerID: .codexCLI
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "command_execution",
                id: "t1",
                input: ["summary": "/bin/zsh -lc 'git status --short; rm -rf build'"]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("denied command pattern") == true)
    }
}
