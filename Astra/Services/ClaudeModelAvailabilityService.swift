import Foundation
import ASTRACore

enum ClaudeModelAvailabilityResult: Equatable, Sendable {
    case available(models: [String])
    case unavailable(reason: String)
}

struct ClaudeModelAvailabilityConfiguration: Equatable, Sendable {
    var provider: ClaudeProvider
    var vertexOpusModel: String
    var vertexSonnetModel: String
    var vertexHaikuModel: String

    init(
        provider: ClaudeProvider,
        vertexOpusModel: String = "",
        vertexSonnetModel: String = "",
        vertexHaikuModel: String = ""
    ) {
        self.provider = provider
        self.vertexOpusModel = vertexOpusModel
        self.vertexSonnetModel = vertexSonnetModel
        self.vertexHaikuModel = vertexHaikuModel
    }
}

struct ClaudeModelAvailabilityService {
    private let httpClient: any ModelAvailabilityHTTPClient
    private let timeout: TimeInterval
    private let environment: @Sendable () -> [String: String]

    init(
        httpClient: any ModelAvailabilityHTTPClient = URLSessionModelAvailabilityHTTPClient(),
        timeout: TimeInterval = 5,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
        self.environment = environment
    }

    func refreshAndPersist(
        configuration: ClaudeModelAvailabilityConfiguration,
        defaults: UserDefaults = .standard
    ) async -> ClaudeModelAvailabilityResult {
        let result = await availableModels(configuration: configuration)
        if case .available(let models) = result {
            RuntimeModelAvailability.persistAvailableModels(models, for: .claudeCode, defaults: defaults)
        }
        return result
    }

    func availableModels(configuration: ClaudeModelAvailabilityConfiguration) async -> ClaudeModelAvailabilityResult {
        switch configuration.provider {
        case .anthropic:
            return await anthropicAPIModels()
        case .vertex:
            let models = RuntimeModelAvailability.cleanProviderModels([
                configuration.vertexOpusModel,
                configuration.vertexSonnetModel,
                configuration.vertexHaikuModel
            ])
            guard !models.isEmpty else {
                return .unavailable(reason: "No Claude Vertex model aliases are configured.")
            }
            return .available(models: models)
        }
    }

    private func anthropicAPIModels() async -> ClaudeModelAvailabilityResult {
        guard let apiKey = anthropicAPIKey() else {
            return .unavailable(
                reason: "No ANTHROPIC_API_KEY is available for a non-generating Anthropic model-list check. Claude Code login does not expose a safe local model-list command."
            )
        }

        var request = URLRequest(url: anthropicModelsURL())
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ASTRA/\(AppBuildInfo.current.version)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await httpClient.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable(reason: "Anthropic model check failed with HTTP \(response.statusCode).")
            }
            let decoded = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            let models = RuntimeModelAvailability.cleanProviderModels(decoded.data.map(\.id))
            guard !models.isEmpty else {
                return .unavailable(reason: "Anthropic returned no models for this API key.")
            }
            return .available(models: models)
        } catch {
            return .unavailable(reason: "Could not load Anthropic model availability.")
        }
    }

    private func anthropicAPIKey() -> String? {
        let key = environment()["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private func anthropicModelsURL() -> URL {
        let rawBase = environment()["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(string: rawBase ?? "") ?? URL(string: "https://api.anthropic.com")!
        if base.path.split(separator: "/").last.map(String.init) == "v1" {
            return base.appendingPathComponent("models")
        }
        return base.appendingPathComponent("v1").appendingPathComponent("models")
    }
}

private struct AnthropicModelsResponse: Decodable {
    struct Model: Decodable {
        var id: String
    }

    var data: [Model]
}
