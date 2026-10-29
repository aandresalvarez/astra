import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Provider launch signature")
struct ProviderLaunchSignatureServiceTests {
    @Test("Legacy provider sessions and changed instruction modes require a fresh handoff")
    func repositoryInstructionModeInvalidatesNativeSession() throws {
        let legacy = signature(resourceDigest: nil)
        var guidance = legacy
        guidance.repositoryInstructionContract = "copilot-repository-instructions-v1:guidance:hash"
        var strict = guidance
        strict.repositoryInstructionContract = "copilot-repository-instructions-v1:strict:hash"
        #expect(legacy.signatureValue != guidance.signatureValue)
        #expect(strict.signatureValue != guidance.signatureValue)
        let decoded = try JSONDecoder().decode(ProviderLaunchSignaturePayload.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.repositoryInstructionContract == nil)
        #expect(decoded.signatureValue == legacy.signatureValue)
    }
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
        ProviderLaunchSignatureFixture.make(resourceDigest: resourceDigest)
    }
}
