import Foundation
import ASTRACore

enum ClaudeModelAvailabilityResult: Equatable, Sendable {
    case available(models: [RuntimeModelDetail])
    case unavailable(reason: String)

    /// Raw `--model` values, in provider order.
    var modelValues: [String] {
        guard case .available(let models) = self else { return [] }
        return models.map(\.value)
    }
}

struct ClaudeModelAvailabilityConfiguration: Equatable, Sendable {
    var provider: ClaudeProvider
    var executablePath: String
    var vertexOpusModel: String
    var vertexSonnetModel: String
    var vertexHaikuModel: String

    init(
        provider: ClaudeProvider,
        executablePath: String = "",
        vertexOpusModel: String = "",
        vertexSonnetModel: String = "",
        vertexHaikuModel: String = ""
    ) {
        self.provider = provider
        self.executablePath = executablePath
        self.vertexOpusModel = vertexOpusModel
        self.vertexSonnetModel = vertexSonnetModel
        self.vertexHaikuModel = vertexHaikuModel
    }
}

struct ClaudeModelAvailabilityService {
    private let runner: any BinaryRunner
    private let httpClient: any ModelAvailabilityHTTPClient
    private let timeout: TimeInterval
    private let cliProbeTimeout: TimeInterval
    private let environment: @Sendable () -> [String: String]
    private let detectExecutable: @Sendable () -> String
    private let isExecutable: @Sendable (String) -> Bool

    init(
        runner: any BinaryRunner = ProcessBinaryRunner(),
        httpClient: any ModelAvailabilityHTTPClient = URLSessionModelAvailabilityHTTPClient(),
        timeout: TimeInterval = 5,
        cliProbeTimeout: TimeInterval = 15,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        detectExecutable: @escaping @Sendable () -> String = { RuntimePathResolver.detectClaudePath() },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.runner = runner
        self.httpClient = httpClient
        self.timeout = timeout
        self.cliProbeTimeout = cliProbeTimeout
        self.environment = environment
        self.detectExecutable = detectExecutable
        self.isExecutable = isExecutable
    }

    func refreshAndPersist(
        configuration: ClaudeModelAvailabilityConfiguration,
        defaults: UserDefaults = .standard
    ) async -> ClaudeModelAvailabilityResult {
        let result = await availableModels(configuration: configuration)
        switch result {
        case .available(let models):
            RuntimeModelAvailability.persistAvailableModelDetails(models, for: .claudeCode, defaults: defaults)
            AppLogger.audit(.runtimeModelAvailability, category: "Worker", fields: [
                "runtime": AgentRuntimeID.claudeCode.rawValue,
                "provider": configuration.provider.rawValue,
                "result": "available",
                "model_count": String(models.count),
                "checked_at": String(Int(Date().timeIntervalSince1970))
            ], level: .debug)
        case .unavailable(let reason):
            AppLogger.audit(.runtimeModelAvailability, category: "Worker", fields: [
                "runtime": AgentRuntimeID.claudeCode.rawValue,
                "provider": configuration.provider.rawValue,
                "result": "unavailable",
                "reason": reason,
                "checked_at": String(Int(Date().timeIntervalSince1970))
            ], level: .warning, fieldMaxLength: 220)
        }
        return result
    }

    func availableModels(configuration: ClaudeModelAvailabilityConfiguration) async -> ClaudeModelAvailabilityResult {
        switch configuration.provider {
        case .anthropic:
            // Primary source: the authenticated CLI itself. Its stream-json
            // `initialize` handshake reports the models the *spawned runs*
            // can actually use (OAuth subscription, enterprise policy, …),
            // consumes no tokens, and needs no API key.
            if let models = await cliReportedModels(configuration: configuration) {
                return .available(models: models)
            }
            switch await anthropicAPIModels() {
            case .available(let models):
                return .available(models: models)
            case .unavailable(let reason):
                return .unavailable(
                    reason: "Claude CLI did not report a model list from its initialize handshake. \(reason)"
                )
            }
        case .vertex:
            let models = RuntimeModelAvailability.cleanProviderModels([
                configuration.vertexOpusModel,
                configuration.vertexSonnetModel,
                configuration.vertexHaikuModel
            ])
            guard !models.isEmpty else {
                return .unavailable(reason: "No Claude Vertex model aliases are configured.")
            }
            return .available(models: models.map { RuntimeModelDetail(value: $0) })
        }
    }

    /// Asks the Claude CLI for the models available to its current login by
    /// sending an `initialize` control request over stream-json and reading
    /// the response — the same handshake the official Agent SDK uses for
    /// `supportedModels()`. Local, zero tokens, entitlement-aware.
    private func cliReportedModels(
        configuration: ClaudeModelAvailabilityConfiguration
    ) async -> [RuntimeModelDetail]? {
        let configured = configuration.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = configured.isEmpty ? detectExecutable() : configured
        guard !executable.isEmpty, isExecutable(executable) else { return nil }

        let request = #"{"type":"control_request","request_id":"astra-model-availability","request":{"subtype":"initialize"}}"# + "\n"
        let result = await runner.run(
            path: executable,
            args: ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json"],
            timeout: cliProbeTimeout,
            environment: nil,
            stdin: Data(request.utf8)
        )
        // Parse whatever arrived even on a non-zero exit or timeout kill —
        // the response line may already be in the captured output.
        return Self.parseInitializeModels(from: result.stdout)
    }

    /// Extracts models (ID plus display metadata) from a stream-json
    /// `initialize` control response. Tolerates unrelated lines (system
    /// events, partial writes) before and after the response line.
    /// Returns nil when no usable list is found.
    static func parseInitializeModels(from output: String) -> [RuntimeModelDetail]? {
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(InitializeControlResponse.self, from: data),
                  envelope.type == "control_response",
                  envelope.response.subtype == "success",
                  let models = envelope.response.response?.models else {
                continue
            }
            let cleaned = RuntimeModelAvailability.cleanProviderModelDetails(models.map { model in
                RuntimeModelDetail(
                    value: model.value,
                    displayName: model.displayName,
                    description: model.description
                )
            })
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private func anthropicAPIModels() async -> ClaudeModelAvailabilityResult {
        guard let apiKey = anthropicAPIKey() else {
            return .unavailable(
                reason: "No ANTHROPIC_API_KEY is available for the Anthropic API model-list fallback."
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
            let models = RuntimeModelAvailability.cleanProviderModelDetails(decoded.data.map { model in
                RuntimeModelDetail(value: model.id, displayName: model.displayName)
            })
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
        var displayName: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    var data: [Model]
}

/// Shape of the CLI's `{"type":"control_response",...}` line answering an
/// `initialize` control request. Only the fields we read are declared.
private struct InitializeControlResponse: Decodable {
    struct Response: Decodable {
        struct Payload: Decodable {
            struct ModelInfo: Decodable {
                var value: String
                var displayName: String?
                var description: String?
            }

            var models: [ModelInfo]?
        }

        var subtype: String
        var response: Payload?
    }

    var type: String
    var response: Response
}
