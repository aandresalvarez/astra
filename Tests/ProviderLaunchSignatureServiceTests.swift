import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Provider launch signature")
struct ProviderLaunchSignatureServiceTests {
    @Test("Read-only resource changes invalidate provider-native continuation identity")
    func readOnlyResourceChangesInvalidateNativeContinuationIdentity() throws {
        let original = signature(resourceDigest: "resource-a")
        let changed = signature(resourceDigest: "resource-b")
        #expect(original.signatureValue != changed.signatureValue)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "readOnlyResourceContractDigest")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder().decode(ProviderLaunchSignaturePayload.self, from: legacyData)
        #expect(decodedLegacy.readOnlyResourceContractDigest == nil)
    }

    private func signature(resourceDigest: String?) -> ProviderLaunchSignaturePayload {
        ProviderLaunchSignaturePayload(
            version: 1,
            runtimeID: AgentRuntimeID.codexCLI.rawValue,
            model: "gpt-5.5",
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
            readOnlyResourceContractDigest: resourceDigest
        )
    }
}
