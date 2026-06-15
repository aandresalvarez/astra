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
        #expect(RuntimeModelDisplayName.displayName("openai/gpt-5.2-codex") == "GPT-5.2-Codex")
    }

    @Test("Claude model IDs render family and version")
    func claudeModelIDsRenderFamilyAndVersion() {
        #expect(RuntimeModelDisplayName.displayName("claude-sonnet-4-6") == "Claude Sonnet 4.6")
        #expect(RuntimeModelDisplayName.displayName("claude-sonnet-4.6") == "Claude Sonnet 4.6")
        #expect(RuntimeModelDisplayName.displayName("claude-opus-4.7") == "Claude Opus 4.7")
        #expect(RuntimeModelDisplayName.displayName("claude-haiku-4-5-20251001") == "Claude Haiku 4.5")
        #expect(RuntimeModelDisplayName.displayName("anthropic/claude-sonnet-4-5") == "Claude Sonnet 4.5")
    }

    @Test("Unknown model IDs are trimmed and preserved")
    func unknownModelIDsAreTrimmedAndPreserved() {
        #expect(RuntimeModelDisplayName.displayName(" custom-model ") == "custom-model")
    }
}
