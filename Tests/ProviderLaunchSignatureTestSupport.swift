import Foundation
import ASTRACore
@testable import ASTRA

enum ProviderLaunchSignatureFixture {
    static func make(
        runtime: AgentRuntimeID = .codexCLI,
        model: String = "gpt-5.5",
        resourceDigest: String? = nil,
        repositoryInstructionContract: String? = nil
    ) -> ProviderLaunchSignaturePayload {
        ProviderLaunchSignaturePayload(
            version: 1,
            runtimeID: runtime.rawValue,
            model: model,
            policyLevel: "standard",
            policyScope: "task",
            providerAdapterVersion: 1,
            permissionMode: "restricted",
            allowedTools: [],
            askFirstTools: [],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            runtimeSupportTools: [],
            scopedSkillIDs: [],
            scopedSkillNames: [],
            scopedConnectorDescriptors: [],
            scopedLocalToolCommands: [],
            environmentKeyNames: [],
            credentialLabels: [],
            mcpServerIDs: [],
            browserAdapters: [],
            promptSchemaVersion: "context_capsule_v2",
            executionEnvironmentFingerprint: WorkspaceExecutionEnvironment.host.signatureFingerprint,
            readOnlyResourceContractDigest: resourceDigest,
            repositoryInstructionContract: repositoryInstructionContract
        )
    }
}
