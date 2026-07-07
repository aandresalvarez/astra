import Foundation
import Testing
import ASTRAPersistence
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("ClaudeModelAvailabilityService")
struct ClaudeModelAvailabilityServiceTests {
    /// Real-world shape captured from `claude` 2.1.170: a control_response
    /// answering the initialize handshake, models included, OAuth login,
    /// no API key anywhere.
    private static let initializeResponseLine = """
    {"type":"control_response","response":{"subtype":"success","request_id":"astra-model-availability","response":{"commands":[{"name":"compact","description":""}],"models":[{"value":"default","displayName":"Default (recommended)","description":"Opus 4.8 with 1M context"},{"value":"claude-fable-5[1m]","displayName":"Fable","description":"Fable 5"},{"value":"sonnet","displayName":"Sonnet","description":"Sonnet 4.6"},{"value":"sonnet[1m]","displayName":"Sonnet (1M context)","description":"Sonnet 4.6 with 1M context"},{"value":"haiku","displayName":"Haiku","description":"Haiku 4.5"},{"value":"claude-sonnet-4-6","displayName":"Sonnet 4.6","description":"Efficient (claude-sonnet-4-6)"}]}}}
    """

    @Test("CLI initialize handshake supplies models without an API key")
    func cliInitializeHandshakeSuppliesModelsWithoutAPIKey() async {
        let http = StubModelAvailabilityHTTPClient()
        let runner = ClaudeProbeStubBinaryRunner(result: .exited(
            code: 0,
            stdout: Self.initializeResponseLine + "\n",
            stderr: ""
        ))
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = ClaudeModelAvailabilityService(
            runner: runner,
            httpClient: http,
            environment: { [:] },
            detectExecutable: { "/opt/test/claude" },
            isExecutable: { _ in true }
        )

        let result = await service.refreshAndPersist(
            configuration: ClaudeModelAvailabilityConfiguration(provider: .anthropic),
            defaults: defaults
        )

        let expected = [
            RuntimeModelDetail(value: "default", displayName: "Default (recommended)", description: "Opus 4.8 with 1M context"),
            RuntimeModelDetail(value: "claude-fable-5[1m]", displayName: "Fable", description: "Fable 5"),
            RuntimeModelDetail(value: "sonnet", displayName: "Sonnet", description: "Sonnet 4.6"),
            RuntimeModelDetail(value: "sonnet[1m]", displayName: "Sonnet (1M context)", description: "Sonnet 4.6 with 1M context"),
            RuntimeModelDetail(value: "haiku", displayName: "Haiku", description: "Haiku 4.5"),
            RuntimeModelDetail(value: "claude-sonnet-4-6", displayName: "Sonnet 4.6", description: "Efficient (claude-sonnet-4-6)")
        ]
        #expect(result == .available(models: expected))
        #expect(RuntimeModelAvailability.models(for: .claudeCode, defaults: defaults) == expected.map(\.value))
        #expect(await http.recordedRequests().isEmpty)

        // Display metadata survives the persist → cache → lookup path the
        // pickers use.
        let cache = RuntimeModelAvailabilityCache(
            cachedClaudeModelsJSON: defaults.string(forKey: AppStorageKeys.claudeAvailableModels) ?? "",
            cachedCopilotModelsJSON: ""
        )
        #expect(RuntimeModelAvailability.displayName(for: "claude-fable-5[1m]", runtime: .claudeCode, cache: cache) == "Fable")
        #expect(RuntimeModelAvailability.modelDescription(for: "haiku", runtime: .claudeCode, cache: cache) == "Haiku 4.5")

        let calls = await runner.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.path == "/opt/test/claude")
        #expect(calls.first?.args == [
            "--print", "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json"
        ])
        let stdin = calls.first?.stdin.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(stdin.contains(#""subtype":"initialize""#))
    }

    @Test("Configured executable path is preferred over detection")
    func configuredExecutablePathIsPreferredOverDetection() async {
        let runner = ClaudeProbeStubBinaryRunner(result: .exited(
            code: 0,
            stdout: Self.initializeResponseLine + "\n",
            stderr: ""
        ))
        let service = ClaudeModelAvailabilityService(
            runner: runner,
            httpClient: StubModelAvailabilityHTTPClient(),
            environment: { [:] },
            detectExecutable: { "/opt/detected/claude" },
            isExecutable: { _ in true }
        )

        let result = await service.availableModels(
            configuration: ClaudeModelAvailabilityConfiguration(
                provider: .anthropic,
                executablePath: " /opt/configured/claude "
            )
        )

        guard case .available = result else {
            Issue.record("Expected CLI-sourced models, got \(result).")
            return
        }
        #expect(await runner.recordedCalls().first?.path == "/opt/configured/claude")
    }

    @Test("CLI probe failure falls back to the Anthropic API")
    func cliProbeFailureFallsBackToAnthropicAPI() async {
        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "GET",
            url: "https://api.anthropic.com/v1/models",
            statusCode: 200,
            body: """
            {
              "data": [
                {"id": "claude-sonnet-4-6"},
                {"id": "claude-opus-future", "display_name": "Opus Future"},
                {"id": "claude-sonnet-4-6"}
              ]
            }
            """
        )
        let runner = ClaudeProbeStubBinaryRunner(result: .exited(code: 1, stdout: "not json\n", stderr: "boom"))
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = ClaudeModelAvailabilityService(
            runner: runner,
            httpClient: http,
            environment: { ["ANTHROPIC_API_KEY": "test-key"] },
            detectExecutable: { "/opt/test/claude" },
            isExecutable: { _ in true }
        )

        let result = await service.refreshAndPersist(
            configuration: ClaudeModelAvailabilityConfiguration(provider: .anthropic),
            defaults: defaults
        )

        #expect(result == .available(models: [
            RuntimeModelDetail(value: "claude-sonnet-4-6"),
            RuntimeModelDetail(value: "claude-opus-future", displayName: "Opus Future")
        ]))
        #expect(RuntimeModelAvailability.models(for: .claudeCode, defaults: defaults) == [
            "claude-sonnet-4-6",
            "claude-opus-future"
        ])
        let requests = await http.recordedRequests()
        #expect(requests.map(\.key) == ["GET https://api.anthropic.com/v1/models"])
        #expect(requests.first?.apiKey == "test-key")
        #expect(requests.first?.anthropicVersion == "2023-06-01")
    }

    @Test("Anthropic API key model check persists provider models when no CLI exists")
    func anthropicAPIKeyModelCheckPersistsProviderModels() async {
        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "GET",
            url: "https://api.anthropic.com/v1/models",
            statusCode: 200,
            body: """
            {"data": [{"id": "claude-sonnet-4-6"}, {"id": "claude-opus-future"}]}
            """
        )
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = ClaudeModelAvailabilityService(
            runner: ClaudeProbeStubBinaryRunner(result: .exited(code: 0, stdout: "", stderr: "")),
            httpClient: http,
            environment: { ["ANTHROPIC_API_KEY": "test-key"] },
            detectExecutable: { "" },
            isExecutable: { _ in false }
        )

        let result = await service.refreshAndPersist(
            configuration: ClaudeModelAvailabilityConfiguration(provider: .anthropic),
            defaults: defaults
        )

        #expect(result.modelValues == ["claude-sonnet-4-6", "claude-opus-future"])
        #expect(RuntimeModelAvailability.models(for: .claudeCode, defaults: defaults) == [
            "claude-sonnet-4-6",
            "claude-opus-future"
        ])
    }

    @Test("Missing CLI and missing Anthropic API key reports unavailable without network")
    func missingAnthropicAPIKeyDoesNotCallNetwork() async {
        let http = StubModelAvailabilityHTTPClient()
        let service = ClaudeModelAvailabilityService(
            runner: ClaudeProbeStubBinaryRunner(result: .exited(code: 0, stdout: "", stderr: "")),
            httpClient: http,
            environment: { [:] },
            detectExecutable: { "" },
            isExecutable: { _ in false }
        )

        let result = await service.availableModels(
            configuration: ClaudeModelAvailabilityConfiguration(provider: .anthropic)
        )

        if case .unavailable(let reason) = result {
            #expect(reason.contains("ANTHROPIC_API_KEY"))
            #expect(reason.contains("No runnable Claude CLI"))
        } else {
            Issue.record("Expected missing CLI + missing API key to be unavailable.")
        }
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test("CLI that runs without a model list blames the handshake, not the binary")
    func cliWithoutModelListBlamesHandshake() async {
        let service = ClaudeModelAvailabilityService(
            runner: ClaudeProbeStubBinaryRunner(result: .exited(code: 0, stdout: "not json\n", stderr: "")),
            httpClient: StubModelAvailabilityHTTPClient(),
            environment: { [:] },
            detectExecutable: { "/opt/test/claude" },
            isExecutable: { _ in true }
        )

        let result = await service.availableModels(
            configuration: ClaudeModelAvailabilityConfiguration(provider: .anthropic)
        )

        if case .unavailable(let reason) = result {
            #expect(reason.contains("initialize handshake did not return a model list"))
            #expect(!reason.contains("No runnable Claude CLI"))
        } else {
            Issue.record("Expected junk CLI output + missing API key to be unavailable.")
        }
    }

    @Test("Vertex model availability uses configured aliases")
    func vertexModelAvailabilityUsesConfiguredAliases() async {
        let service = ClaudeModelAvailabilityService(
            runner: ClaudeProbeStubBinaryRunner(result: .exited(code: 0, stdout: "", stderr: "")),
            environment: { [:] },
            detectExecutable: { "" },
            isExecutable: { _ in false }
        )

        let result = await service.availableModels(
            configuration: ClaudeModelAvailabilityConfiguration(
                provider: .vertex,
                vertexOpusModel: " claude-opus-4-6@default ",
                vertexSonnetModel: "claude-sonnet-4-6@default",
                vertexHaikuModel: "claude-sonnet-4-6@default"
            )
        )

        #expect(result == .available(models: [
            RuntimeModelDetail(value: "claude-opus-4-6@default"),
            RuntimeModelDetail(value: "claude-sonnet-4-6@default")
        ]))
    }

    @Test("Initialize parser skips junk lines and error responses")
    func initializeParserSkipsJunkLinesAndErrorResponses() {
        let output = """
        garbage that is not json
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"control_response","response":{"subtype":"error","request_id":"x","error":"nope"}}
        \(Self.initializeResponseLine)
        trailing noise
        """
        let models = ClaudeModelAvailabilityService.parseInitializeModels(from: output)
        #expect(models?.first?.value == "default")
        #expect(models?.first?.displayName == "Default (recommended)")
        #expect(models?.first?.description == "Opus 4.8 with 1M context")
        #expect(models?.count == 6)
    }

    @Test("Initialize parser returns nil for empty or model-less output")
    func initializeParserReturnsNilWithoutModels() {
        #expect(ClaudeModelAvailabilityService.parseInitializeModels(from: "") == nil)
        let noModels = """
        {"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"commands":[]}}}
        """
        #expect(ClaudeModelAvailabilityService.parseInitializeModels(from: noModels) == nil)
        let emptyModels = """
        {"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"models":[{"value":"  "}]}}}
        """
        #expect(ClaudeModelAvailabilityService.parseInitializeModels(from: emptyModels) == nil)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ClaudeModelAvailabilityServiceTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}

/// Records invocations and replays a canned `RunResult`, so tests never
/// spawn a real process.
private actor ClaudeProbeStubBinaryRunner: BinaryRunner {
    struct Call: Equatable {
        var path: String
        var args: [String]
        var stdin: Data?
    }

    private let result: RunResult
    private var calls: [Call] = []

    init(result: RunResult) {
        self.result = result
    }

    func recordedCalls() -> [Call] {
        calls
    }

    func run(
        path: String,
        args: [String],
        timeout _: TimeInterval,
        environment _: [String: String]?
    ) async -> RunResult {
        calls.append(Call(path: path, args: args, stdin: nil))
        return result
    }

    func run(
        path: String,
        args: [String],
        timeout _: TimeInterval,
        environment _: [String: String]?,
        stdin: Data?
    ) async -> RunResult {
        calls.append(Call(path: path, args: args, stdin: stdin))
        return result
    }
}
