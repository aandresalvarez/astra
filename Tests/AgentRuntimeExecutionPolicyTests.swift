import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Runtime Execution Policy")
struct AgentRuntimeExecutionPolicyTests {
    @Test("Approved plan policy carries approved tools for every runtime")
    func approvedPlanPolicyCarriesApprovedToolsForEveryRuntime() {
        let approvedTools = ["Read", "Write"]

        for runtime in AgentRuntimeID.allCases {
            let policy = AgentRuntimeExecutionPolicy.approvedPlan(
                runtime: runtime,
                currentPermissionPolicy: .restricted,
                allowedTools: approvedTools
            )

            #expect(policy.allowedToolsOverride == approvedTools)
            #expect(policy.permissionPolicyOverride != nil)
        }
    }

    @Test("Copilot review approval uses non-interactive provider policy")
    func copilotReviewApprovalUsesNonInteractiveProviderPolicy() {
        let policy = AgentRuntimeExecutionPolicy.approvedPlan(
            runtime: .copilotCLI,
            currentPermissionPolicy: .restricted,
            allowedTools: ["Write"]
        )

        #expect(policy.permissionPolicy(default: .restricted) == .autonomous)
        #expect(policy.allowedTools(default: ["Read"]) == ["Write"])
    }

    @Test("Claude review approval keeps restricted policy with approved tools")
    func claudeReviewApprovalKeepsRestrictedPolicyWithApprovedTools() {
        let policy = AgentRuntimeExecutionPolicy.approvedPlan(
            runtime: .claudeCode,
            currentPermissionPolicy: .restricted,
            allowedTools: ["Write"]
        )

        #expect(policy.permissionPolicy(default: .restricted) == .restricted)
        #expect(policy.allowedTools(default: ["Read"]) == ["Write"])
    }
}
