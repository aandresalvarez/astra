import Testing
@testable import ASTRA

@Suite("Runtime Model Display Names")
struct RuntimeModelDisplayNameTests {
    @Test("GPT model IDs render as user-facing labels")
    func gptModelIDsRenderAsUserFacingLabels() {
        #expect(RuntimeModelDisplayName.displayName("gpt-5.5") == "GPT-5.5")
        #expect(RuntimeModelDisplayName.displayName("gpt-5.4") == "GPT-5.4")
        #expect(RuntimeModelDisplayName.displayName("gpt-5.4-mini") == "GPT-5.4-Mini")
        #expect(RuntimeModelDisplayName.displayName("gpt-5.3-codex-spark") == "GPT-5.3-Codex-Spark")
    }

    @Test("Unknown model IDs are trimmed and preserved")
    func unknownModelIDsAreTrimmedAndPreserved() {
        #expect(RuntimeModelDisplayName.displayName(" custom-model ") == "custom-model")
    }
}
