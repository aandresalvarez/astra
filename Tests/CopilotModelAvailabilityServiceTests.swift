import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("CopilotModelAvailabilityService")
struct CopilotModelAvailabilityServiceTests {
    @Test("Account model check intersects enabled Copilot models with installed CLI choices")
    func accountModelCheckIntersectsEnabledModelsWithCLIChoices() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/copilot help config",
            result: RunResult(
                outcome: .exited(code: 0),
                stdout: """
                  `model`: AI model to use for Copilot CLI; can be changed with /model command or --model flag option.
                    - "claude-sonnet-4.6"
                    - "claude-sonnet-4.5"
                    - "claude-haiku-4.5"
                    - "claude-opus-4.7"
                    - "claude-opus-4.6"
                    - "gpt-5.2-codex"
                    - "gpt-5.2"
                    - "gpt-5-mini"
                    - "gpt-4.1"

                  `mouse`: whether to enable mouse support in alt screen mode; defaults to `true`.
                """,
                stderr: ""
            )
        )

        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "POST",
            url: "https://api.github.com/graphql",
            statusCode: 200,
            body: #"{"data":{"viewer":{"copilotEndpoints":{"api":"https://api.githubcopilot.test"}}}}"#
        )
        await http.setResponse(
            method: "GET",
            url: "https://api.githubcopilot.test/models",
            statusCode: 200,
            body: """
            {
              "data": [
                {"id": "text-embedding-3-small", "policy": {"state": "enabled"}},
                {"id": "claude-sonnet-4.5", "policy": {"state": "enabled"}},
                {"id": "claude-opus-4.7", "policy": {"state": "enabled"}},
                {"id": "gpt-4o-mini-2024-07-18", "policy": {"state": "enabled"}},
                {"id": "claude-sonnet-4.6", "policy": {"state": "enabled"}},
                {"id": "gpt-5.2", "policy": {"state": "enabled"}},
                {"id": "grok-code-fast-1", "policy": {"state": "enabled"}},
                {"id": "gpt-4.1", "policy": {"state": "disabled"}}
              ]
            }
            """
        )

        let service = CopilotModelAvailabilityService(
            runner: runner,
            httpClient: http,
            environment: { ["GITHUB_TOKEN": "env-token"] },
            detectExecutable: { $0 == "copilot" ? "/opt/homebrew/bin/copilot" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/copilot" }
        )

        let result = await service.availableModels()

        #expect(result == .available(models: ["claude-sonnet-4.6", "claude-sonnet-4.5", "claude-opus-4.7", "gpt-5.2"]))
        #expect(await runner.recordedCalls() == [
            StubBinaryRunner.Call(path: "/opt/homebrew/bin/copilot", args: ["help", "config"])
        ])
        #expect(await http.recordedRequests().last?.authorization == "Bearer env-token")
    }

    @Test("Installed CLI model choices fall back to top-level help")
    func installedCLIModelChoicesFallBackToTopLevelHelp() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/copilot help config",
            result: RunResult(outcome: .exited(code: 1), stdout: "", stderr: "unknown topic")
        )
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/copilot --help",
            result: RunResult(
                outcome: .exited(code: 0),
                stdout: """
                Usage: copilot [options]

                  --model <model>  Set the AI model to use (choices:
                                      "claude-sonnet-4.5", "claude-sonnet-4",
                                      "gpt-5")
                  --version        Show version information
                """,
                stderr: ""
            )
        )

        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "POST",
            url: "https://api.github.com/graphql",
            statusCode: 200,
            body: #"{"data":{"viewer":{"copilotEndpoints":{"api":"https://api.githubcopilot.test"}}}}"#
        )
        await http.setResponse(
            method: "GET",
            url: "https://api.githubcopilot.test/models",
            statusCode: 200,
            body: #"{"data":[{"id":"gpt-5"},{"id":"claude-sonnet-4.5"}]}"#
        )

        let service = CopilotModelAvailabilityService(
            runner: runner,
            httpClient: http,
            environment: { ["GITHUB_TOKEN": "env-token"] },
            detectExecutable: { $0 == "copilot" ? "/opt/homebrew/bin/copilot" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/copilot" }
        )

        let result = await service.availableModels()

        #expect(result == .available(models: ["claude-sonnet-4.5", "gpt-5"]))
        #expect(await runner.recordedCalls() == [
            StubBinaryRunner.Call(path: "/opt/homebrew/bin/copilot", args: ["help", "config"]),
            StubBinaryRunner.Call(path: "/opt/homebrew/bin/copilot", args: ["--help"])
        ])
    }

    @Test("Copilot CLI help parser reads multiline model choices")
    func copilotCLIHelpParserReadsMultilineModelChoices() {
        let choices = CopilotModelAvailabilityService.parseModelChoices(from: """
        Usage: copilot [options]

          --model <model>  Set the AI model to use (choices:
                              "claude-sonnet-4.5", "claude-sonnet-4",
                              "gpt-5")
          --version        Show version information
        """)

        #expect(choices == ["claude-sonnet-4.5", "claude-sonnet-4", "gpt-5"])
    }

    @Test("Copilot CLI config parser reads model setting choices only")
    func copilotCLIConfigParserReadsModelSettingChoicesOnly() {
        let choices = CopilotModelAvailabilityService.parseModelChoices(from: """
          `model`: AI model to use for Copilot CLI; can be changed with /model command or --model flag option.
            - "claude-sonnet-4.6"
            - "claude-sonnet-4.5"
            - "gpt-5.2"

          `mouse`: whether to enable mouse support in alt screen mode; defaults to `true`.
            - "true"
            - "false"
        """)

        #expect(choices == ["claude-sonnet-4.6", "claude-sonnet-4.5", "gpt-5.2"])
    }

    @Test("Account model check filters disabled Copilot models and persists the enabled set")
    func accountModelCheckFiltersDisabledModels() async throws {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/homebrew/bin/gh auth token --hostname github.com",
            result: RunResult(outcome: .exited(code: 0), stdout: "gh-token\n", stderr: "")
        )

        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "POST",
            url: "https://api.github.com/graphql",
            statusCode: 200,
            body: #"{"data":{"viewer":{"copilotEndpoints":{"api":"https://api.githubcopilot.test"}}}}"#
        )
        await http.setResponse(
            method: "GET",
            url: "https://api.githubcopilot.test/models",
            statusCode: 200,
            body: """
            {
              "data": [
                {"id": "gpt-5", "policy": {"state": "disabled"}},
                {"id": "claude-sonnet-4.5", "policy": {"state": "enabled"}},
                {"id": "claude-sonnet-4"},
                {"id": "future-model", "policy": {"state": "enabled"}}
              ]
            }
            """
        )
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let home = makeTempHome()

        let service = CopilotModelAvailabilityService(
            runner: runner,
            httpClient: http,
            environment: { ["HOME": home.path] },
            detectExecutable: { $0 == "gh" ? "/opt/homebrew/bin/gh" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/gh" }
        )

        let result = await service.refreshAndPersist(defaults: defaults)

        #expect(result == .available(models: ["claude-sonnet-4.5", "claude-sonnet-4", "future-model"]))
        #expect(RuntimeModelAvailability.models(for: .copilotCLI, defaults: defaults) == [
            "claude-sonnet-4.5",
            "claude-sonnet-4",
            "future-model"
        ])
        let requests = await http.recordedRequests()
        #expect(requests.map(\.key) == [
            "POST https://api.github.com/graphql",
            "GET https://api.githubcopilot.test/models"
        ])
        #expect(requests.last?.authorization == "Bearer gh-token")
    }

    @Test("Copilot keychain token is used before gh auth")
    func copilotKeychainTokenIsUsedBeforeGhAuth() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/usr/bin/security find-generic-password -s copilot-cli -w",
            result: RunResult(outcome: .exited(code: 0), stdout: "stored-token\n", stderr: "")
        )

        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "POST",
            url: "https://api.github.com/graphql",
            statusCode: 200,
            body: #"{"data":{"viewer":{"copilotEndpoints":{"api":"https://api.githubcopilot.test"}}}}"#
        )
        await http.setResponse(
            method: "GET",
            url: "https://api.githubcopilot.test/models",
            statusCode: 200,
            body: #"{"data":[{"id":"claude-sonnet-4.5"}]}"#
        )
        let home = makeTempHome()

        let service = CopilotModelAvailabilityService(
            runner: runner,
            httpClient: http,
            environment: { ["HOME": home.path] },
            detectExecutable: { binary in
                switch binary {
                case "security": "/usr/bin/security"
                case "gh": "/opt/homebrew/bin/gh"
                default: ""
                }
            },
            isExecutable: { $0 == "/usr/bin/security" || $0 == "/opt/homebrew/bin/gh" }
        )

        let result = await service.availableModels()

        #expect(result == .available(models: ["claude-sonnet-4.5"]))
        #expect(await runner.recordedCalls() == [
            StubBinaryRunner.Call(path: "/usr/bin/security", args: ["find-generic-password", "-s", "copilot-cli", "-w"])
        ])
        #expect(await http.recordedRequests().last?.authorization == "Bearer stored-token")
    }

    @Test("Plaintext Copilot token fallback is honored when the CLI stores one")
    func plaintextCopilotTokenFallbackIsHonored() async throws {
        let home = makeTempHome()
        let configDirectory = home.appendingPathComponent(".copilot", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Data(#"{"store_token_plaintext":true,"copilot_tokens":{"https://github.com:octo":"plain-token"}}"#.utf8)
            .write(to: configDirectory.appendingPathComponent("config.json"))

        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "POST",
            url: "https://api.github.com/graphql",
            statusCode: 200,
            body: #"{"data":{"viewer":{"copilotEndpoints":{"api":"https://api.githubcopilot.test"}}}}"#
        )
        await http.setResponse(
            method: "GET",
            url: "https://api.githubcopilot.test/models",
            statusCode: 200,
            body: #"{"data":[{"id":"claude-sonnet-4"}]}"#
        )

        let service = CopilotModelAvailabilityService(
            runner: StubBinaryRunner(),
            httpClient: http,
            environment: { ["HOME": home.path] },
            detectExecutable: { _ in "" },
            isExecutable: { _ in false }
        )

        let result = await service.availableModels()

        #expect(result == .available(models: ["claude-sonnet-4"]))
        #expect(await http.recordedRequests().last?.authorization == "Bearer plain-token")
    }

    @Test("Environment token avoids gh and falls back to the default Copilot API endpoint")
    func environmentTokenAvoidsGhAndFallsBackToDefaultEndpoint() async {
        let runner = StubBinaryRunner()
        let http = StubModelAvailabilityHTTPClient()
        await http.setResponse(
            method: "POST",
            url: "https://api.github.com/graphql",
            statusCode: 500,
            body: #"{"errors":[{"message":"temporary"}]}"#
        )
        await http.setResponse(
            method: "GET",
            url: "https://api.githubcopilot.com/models",
            statusCode: 200,
            body: #"[{"id":"gpt-5","policy":{"state":"enabled"}}]"#
        )

        let service = CopilotModelAvailabilityService(
            runner: runner,
            httpClient: http,
            environment: { ["GITHUB_TOKEN": "env-token"] },
            detectExecutable: { $0 == "gh" ? "/opt/homebrew/bin/gh" : "" },
            isExecutable: { $0 == "/opt/homebrew/bin/gh" }
        )

        let result = await service.availableModels()

        #expect(result == .available(models: ["gpt-5"]))
        #expect(await runner.recordedCalls().isEmpty)
        let requests = await http.recordedRequests()
        #expect(requests.map(\.key) == [
            "POST https://api.github.com/graphql",
            "GET https://api.githubcopilot.com/models"
        ])
        #expect(requests.last?.authorization == "Bearer env-token")
    }

    @Test("Missing token reports unavailable without calling the network")
    func missingTokenDoesNotCallNetwork() async {
        let service = CopilotModelAvailabilityService(
            runner: StubBinaryRunner(),
            httpClient: StubModelAvailabilityHTTPClient(),
            environment: { ["HOME": makeTempHome().path] },
            detectExecutable: { _ in "" },
            isExecutable: { _ in false }
        )

        let result = await service.availableModels()

        if case .unavailable(let reason) = result {
            #expect(reason.contains("No GitHub token"))
        } else {
            Issue.record("Expected missing token to be unavailable.")
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "CopilotModelAvailabilityServiceTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makeTempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CopilotModelAvailabilityServiceTests-\(UUID().uuidString)", isDirectory: true)
    }
}

actor StubModelAvailabilityHTTPClient: ModelAvailabilityHTTPClient {
    struct RecordedRequest: Equatable, Sendable {
        var key: String
        var authorization: String?
        var apiKey: String?
        var anthropicVersion: String?
    }

    private struct StubResponse: Sendable {
        var statusCode: Int
        var body: String
    }

    private var responses: [String: StubResponse] = [:]
    private var requests: [RecordedRequest] = []

    func setResponse(method: String, url: String, statusCode: Int, body: String) {
        responses["\(method) \(url)"] = StubResponse(statusCode: statusCode, body: body)
    }

    func recordedRequests() -> [RecordedRequest] {
        requests
    }

    nonisolated func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await response(for: request)
    }

    private func response(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? ""
        let key = "\(method) \(url)"
        requests.append(RecordedRequest(
            key: key,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            apiKey: request.value(forHTTPHeaderField: "x-api-key"),
            anthropicVersion: request.value(forHTTPHeaderField: "anthropic-version")
        ))
        let response = responses[key] ?? StubResponse(statusCode: 404, body: #"{"error":"missing stub"}"#)
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(response.body.utf8), http)
    }
}
