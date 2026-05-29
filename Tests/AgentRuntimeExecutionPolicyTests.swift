import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Runtime Adapter Registry")
struct AgentRuntimeAdapterRegistryTests {
    @Test("Every runtime has a concrete provider descriptor")
    func everyRuntimeHasAConcreteProviderDescriptor() {
        let descriptorIDs = AgentRuntimeAdapterRegistry.descriptors.map(\.id)

        #expect(Set(descriptorIDs).count == descriptorIDs.count)
        #expect(Set(descriptorIDs) == Set(AgentRuntimeAdapterRegistry.runtimeIDs))
    }

    @Test("Runtime IDs preserve unknown provider values")
    func runtimeIDsPreserveUnknownProviderValues() throws {
        let runtime = try #require(AgentRuntimeID(rawValue: "future_provider"))

        #expect(runtime.rawValue == "future_provider")
        #expect(runtime.displayName == "Future Provider")
        #expect(AgentRuntimeAdapterRegistry.defaultModels(for: runtime) == ["default"])
        #expect(AgentRuntimeAdapterRegistry.supportsAstraRunProtocol(for: runtime) == false)
        #expect(AgentRuntimeAdapterRegistry.executionCapabilities(for: runtime) == .textOnly)
    }

    @Test("Runtime IDs encode as strings and decode legacy keyed payloads")
    func runtimeIDsEncodeAsStringsAndDecodeLegacyKeyedPayloads() throws {
        let encoded = try JSONEncoder().encode(AgentRuntimeID.copilotCLI)
        #expect(String(data: encoded, encoding: .utf8) == #""copilot_cli""#)

        let decodedString = try JSONDecoder().decode(AgentRuntimeID.self, from: Data(#""future_provider""#.utf8))
        #expect(decodedString.rawValue == "future_provider")

        let decodedKeyed = try JSONDecoder().decode(AgentRuntimeID.self, from: Data(#"{"rawValue":"claude_code"}"#.utf8))
        #expect(decodedKeyed == .claudeCode)
    }

    @Test("Provider descriptors carry install, auth, and model metadata")
    func providerDescriptorsCarryRequiredMetadata() {
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)

            #expect(!descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!descriptor.executableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!descriptor.installHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!descriptor.authHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(descriptor.prerequisite.binary == descriptor.executableName)
            #expect(descriptor.prerequisite.livenessArgs.isEmpty == false)
            #expect(descriptor.defaultModels.contains(descriptor.defaultModel))
            #expect(descriptor.defaultModels == AgentRuntimeAdapterRegistry.defaultModels(for: runtime))
            #expect(descriptor.defaultModel == AgentRuntimeAdapterRegistry.defaultModel(for: runtime))
            #expect(descriptor.supportsAstraRunProtocol == AgentRuntimeAdapterRegistry.supportsAstraRunProtocol(for: runtime))
            #expect(descriptor.executionCapabilities == AgentRuntimeAdapterRegistry.executionCapabilities(for: runtime))
        }
    }

    @Test("Runtime descriptors distinguish CLI harnesses from local chat")
    func runtimeDescriptorsDistinguishCLIHarnessesFromLocalChat() {
        let local = AgentRuntimeAdapterRegistry.descriptor(for: .localMLX).executionCapabilities
        #expect(local.supportsTextOnly)
        #expect(local.supportsAstraBrokeredTools == false)
        #expect(local.supportsProviderNativeTools == false)
        #expect(local.supportsConnectors == false)
        #expect(local.supportsBrowserRead == false)
        #expect(local.supportsBrowserMutation == false)
        #expect(local.supportsFileWrite == false)
        #expect(local.supportsShell == false)
        #expect(local.supportsNetwork == false)
        #expect(local.canExecuteActions == false)

        let localAgent = LocalMLXRuntime.localAgentExecutionCapabilities
        #expect(localAgent.supportsTextOnly)
        #expect(localAgent.supportsAstraBrokeredTools)
        #expect(localAgent.supportsProviderNativeTools == false)
        #expect(localAgent.supportsConnectors)
        #expect(localAgent.supportsBrowserRead)
        #expect(localAgent.supportsBrowserMutation)
        #expect(localAgent.supportsFileWrite)
        #expect(localAgent.supportsShell)
        #expect(localAgent.supportsNetwork)
        #expect(localAgent.canExecuteActions)

        for runtime in [AgentRuntimeID.claudeCode, .copilotCLI, .antigravityCLI] {
            let capabilities = AgentRuntimeAdapterRegistry.descriptor(for: runtime).executionCapabilities
            #expect(capabilities.supportsTextOnly)
            #expect(capabilities.supportsProviderNativeTools)
            #expect(capabilities.supportsConnectors)
            #expect(capabilities.supportsBrowserRead)
            #expect(capabilities.supportsBrowserMutation)
            #expect(capabilities.supportsFileWrite)
            #expect(capabilities.supportsShell)
            #expect(capabilities.supportsNetwork)
            #expect(capabilities.canExecuteActions)
        }
    }
}

@Suite("Agent Runtime Execution Policy")
struct AgentRuntimeExecutionPolicyTests {
    @Test("Approved plan policy carries approved tools for every runtime")
    func approvedPlanPolicyCarriesApprovedToolsForEveryRuntime() {
        let approvedTools = ["Read", "Write"]

        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            let policy = AgentRuntimeExecutionPolicy.approvedPlan(
                runtime: runtime,
                currentPermissionPolicy: .restricted,
                allowedTools: approvedTools
            )

            #expect(policy.allowedToolsOverride == approvedTools)
            #expect(policy.permissionPolicyOverride != nil)
        }
    }

    @Test("Copilot review approval stays scoped to approved tools")
    func copilotReviewApprovalStaysScopedToApprovedTools() {
        let policy = AgentRuntimeExecutionPolicy.approvedPlan(
            runtime: .copilotCLI,
            currentPermissionPolicy: .restricted,
            allowedTools: ["Write"]
        )

        #expect(policy.permissionPolicy(default: .restricted) == .restricted)
        #expect(policy.allowedTools(default: ["Read"]) == ["Write"])
    }

    @Test("Copilot runtime permission approval stays scoped to approved tools")
    func copilotRuntimePermissionApprovalStaysScopedToApprovedTools() {
        let policy = AgentRuntimeExecutionPolicy.approvedRuntimePermission(
            runtime: .copilotCLI,
            allowedTools: ["Read", "shell(rm:*)"]
        )

        #expect(policy.permissionPolicy(default: .restricted) == .restricted)
        #expect(policy.allowedTools(default: ["Read"]) == ["Read", "shell(rm:*)"])
    }

    @Test("Runtime permission approval is provider agnostic")
    func runtimePermissionApprovalIsProviderAgnostic() {
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            let policy = AgentRuntimeExecutionPolicy.approvedRuntimePermission(
                runtime: runtime,
                allowedTools: ["Read", "Write"]
            )

            #expect(policy.permissionPolicy(default: .restricted) == .restricted)
            #expect(policy.allowedTools(default: ["Read", "Grep"]) == ["Read", "Write"])
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
