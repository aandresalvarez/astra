import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Runtime Registry")
struct AgentRuntimeRegistryTests {
    @Test("Every runtime has a concrete provider descriptor")
    func everyRuntimeHasAConcreteProviderDescriptor() {
        let descriptorIDs = Set(AgentRuntimeRegistry.builtInDescriptors.map(\.id))
        let runtimeIDs = Set(AgentRuntimeID.allCases)

        #expect(descriptorIDs == runtimeIDs)
    }

    @Test("Provider descriptors carry install, auth, and model metadata")
    func providerDescriptorsCarryRequiredMetadata() {
        for runtime in AgentRuntimeID.allCases {
            let descriptor = AgentRuntimeRegistry.descriptor(for: runtime)

            #expect(!descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!descriptor.executableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!descriptor.installHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!descriptor.authHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(descriptor.prerequisite.binary == descriptor.executableName)
            #expect(descriptor.prerequisite.livenessArgs.isEmpty == false)
            #expect(descriptor.defaultModels == runtime.defaultModels)
            #expect(descriptor.supportsAstraRunProtocol == runtime.supportsAstraRunProtocol)
        }
    }
}

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

    @Test("Copilot runtime permission approval uses one-shot autonomous policy")
    func copilotRuntimePermissionApprovalUsesAutonomousPolicy() {
        let policy = AgentRuntimeExecutionPolicy.approvedRuntimePermission(runtime: .copilotCLI)

        #expect(policy.permissionPolicy(default: .restricted) == .autonomous)
        #expect(policy.allowedTools(default: ["Read"]) == ["Read"])
    }

    @Test("Runtime permission approval is provider agnostic")
    func runtimePermissionApprovalIsProviderAgnostic() {
        for runtime in AgentRuntimeID.allCases {
            let policy = AgentRuntimeExecutionPolicy.approvedRuntimePermission(runtime: runtime)

            #expect(policy.permissionPolicy(default: .restricted) == .autonomous)
            #expect(policy.allowedTools(default: ["Read", "Grep"]) == ["Read", "Grep"])
        }
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
