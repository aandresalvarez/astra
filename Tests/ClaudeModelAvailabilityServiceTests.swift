import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("ClaudeModelAvailabilityService")
struct ClaudeModelAvailabilityServiceTests {
    @Test("Anthropic API key model check preserves provider models and persists them")
    func anthropicAPIKeyModelCheckPersistsProviderModels() async {
        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "GET",
            url: "https://api.anthropic.com/v1/models",
            statusCode: 200,
            body: """
            {
              "data": [
                {"id": "claude-sonnet-4-6"},
                {"id": "claude-opus-future"},
                {"id": "claude-sonnet-4-6"}
              ]
            }
            """
        )
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = ClaudeModelAvailabilityService(
            httpClient: http,
            environment: { ["ANTHROPIC_API_KEY": "test-key"] }
        )

        let result = await service.refreshAndPersist(
            configuration: ClaudeModelAvailabilityConfiguration(provider: .anthropic),
            defaults: defaults
        )

        #expect(result == .available(models: ["claude-sonnet-4-6", "claude-opus-future"]))
        #expect(RuntimeModelAvailability.models(for: .claudeCode, defaults: defaults) == [
            "claude-sonnet-4-6",
            "claude-opus-future"
        ])
        let requests = await http.recordedRequests()
        #expect(requests.map(\.key) == ["GET https://api.anthropic.com/v1/models"])
        #expect(requests.first?.apiKey == "test-key")
        #expect(requests.first?.anthropicVersion == "2023-06-01")
    }

    @Test("Missing Anthropic API key reports unavailable without network")
    func missingAnthropicAPIKeyDoesNotCallNetwork() async {
        let http = StubModelAvailabilityHTTPClient()
        let service = ClaudeModelAvailabilityService(
            httpClient: http,
            environment: { [:] }
        )

        let result = await service.availableModels(
            configuration: ClaudeModelAvailabilityConfiguration(provider: .anthropic)
        )

        if case .unavailable(let reason) = result {
            #expect(reason.contains("ANTHROPIC_API_KEY"))
        } else {
            Issue.record("Expected missing API key to be unavailable.")
        }
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test("Vertex model availability uses configured aliases")
    func vertexModelAvailabilityUsesConfiguredAliases() async {
        let service = ClaudeModelAvailabilityService(environment: { [:] })

        let result = await service.availableModels(
            configuration: ClaudeModelAvailabilityConfiguration(
                provider: .vertex,
                vertexOpusModel: " claude-opus-4-6@default ",
                vertexSonnetModel: "claude-sonnet-4-6@default",
                vertexHaikuModel: "claude-sonnet-4-6@default"
            )
        )

        #expect(result == .available(models: [
            "claude-opus-4-6@default",
            "claude-sonnet-4-6@default"
        ]))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ClaudeModelAvailabilityServiceTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
