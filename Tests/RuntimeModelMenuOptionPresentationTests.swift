import Testing
@testable import ASTRA

@Suite("Runtime Model Menu Option Presentation")
struct RuntimeModelMenuOptionPresentationTests {
    @Test("Provider aliases expose resolved family version and exact ID")
    func providerAliasesExposeResolvedFamilyVersionAndExactID() {
        let cache = RuntimeModelAvailabilityCache(rawSnapshots: [
            .claudeCode: """
            {"runtimeID":"claude_code","models":["default","sonnet","haiku"],"checkedAt":0,"authority":"authoritative","details":[{"value":"default","displayName":"Default (recommended)","description":"Opus 4.8 with 1M context · Best for everyday, complex tasks"},{"value":"sonnet","displayName":"Sonnet","description":"Sonnet 4.6 · Efficient for routine tasks"},{"value":"haiku","displayName":"Haiku","description":"Haiku 4.5 · Fastest for quick answers"}]}
            """
        ])

        let option = RuntimeModelMenuOptionPresentation(
            model: "default",
            runtime: .claudeCode,
            cache: cache
        )

        #expect(option.title == "Default (recommended) - Opus 4.8")
        #expect(option.subtitle == "with 1M context · Best for everyday, complex tasks")
        #expect(option.detail == "Model ID: default")
        #expect(option.compactTitle == "Opus 4.8")

        let sonnet = RuntimeModelMenuOptionPresentation(
            model: "sonnet",
            runtime: .claudeCode,
            cache: cache
        )

        #expect(sonnet.title == "Sonnet 4.6")
        #expect(sonnet.subtitle == "Efficient for routine tasks")
        #expect(sonnet.detail == "Model ID: sonnet")
        #expect(sonnet.compactTitle == "Sonnet 4.6")
    }

    @Test("Raw provider IDs render readable names without hiding the launch value")
    func rawProviderIDsRenderReadableNamesWithoutHidingLaunchValue() {
        let option = RuntimeModelMenuOptionPresentation(
            model: "anthropic/claude-opus-4-7",
            runtime: .openCodeCLI,
            cache: RuntimeModelAvailabilityCache()
        )

        #expect(option.title == "Claude Opus 4.7")
        #expect(option.subtitle == nil)
        #expect(option.detail == "Model ID: anthropic/claude-opus-4-7")
        #expect(option.compactTitle == "Claude Opus 4.7")

        let gpt = RuntimeModelMenuOptionPresentation(
            model: "openai/gpt-5.2-codex",
            runtime: .openCodeCLI,
            cache: RuntimeModelAvailabilityCache()
        )

        #expect(gpt.title == "GPT-5.2-Codex")
        #expect(gpt.detail == "Model ID: openai/gpt-5.2-codex")
    }
}
