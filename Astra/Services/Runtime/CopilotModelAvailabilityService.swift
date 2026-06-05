import Foundation
import ASTRACore

enum CopilotModelAvailabilityResult: Equatable, Sendable {
    case available(models: [String])
    case unavailable(reason: String)
}

protocol ModelAvailabilityHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionModelAvailabilityHTTPClient: ModelAvailabilityHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CopilotModelAvailabilityError.invalidHTTPResponse
        }
        return (data, http)
    }
}

struct CopilotModelAvailabilityService {
    private let runner: BinaryRunner
    private let httpClient: any ModelAvailabilityHTTPClient
    private let timeout: TimeInterval
    private let environment: @Sendable () -> [String: String]
    private let detectExecutable: @Sendable (String) -> String
    private let isExecutable: @Sendable (String) -> Bool

    init(
        runner: BinaryRunner = ProcessBinaryRunner(),
        httpClient: any ModelAvailabilityHTTPClient = URLSessionModelAvailabilityHTTPClient(),
        timeout: TimeInterval = 5,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        detectExecutable: @escaping @Sendable (String) -> String = {
            RuntimePathResolver.detectExecutablePath(named: $0)
        },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.runner = runner
        self.httpClient = httpClient
        self.timeout = timeout
        self.environment = environment
        self.detectExecutable = detectExecutable
        self.isExecutable = isExecutable
    }

    func refreshAndPersist(defaults: UserDefaults = .standard) async -> CopilotModelAvailabilityResult {
        let result = await availableModels()
        switch result {
        case .available(let models):
            RuntimeModelAvailability.persistAvailableModels(models, for: .copilotCLI, defaults: defaults)
            AppLogger.audit(.runtimeModelAvailability, category: "Worker", fields: [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "result": "available",
                "model_count": String(models.count),
                "checked_at": String(Int(Date().timeIntervalSince1970))
            ], level: .debug)
        case .unavailable(let reason):
            AppLogger.audit(.runtimeModelAvailability, category: "Worker", fields: [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "result": "unavailable",
                "reason": reason,
                "checked_at": String(Int(Date().timeIntervalSince1970))
            ], level: .warning, fieldMaxLength: 220)
        }
        return result
    }

    func availableModels() async -> CopilotModelAvailabilityResult {
        var sawToken = false
        var lastUnavailableReason: String?
        for loadToken in tokenLoaders() {
            guard let token = await loadToken() else { continue }
            sawToken = true
            let result = await availableModels(token: token)
            if case .available = result {
                return result
            }
            if case .unavailable(let reason) = result {
                lastUnavailableReason = reason
            }
        }

        guard sawToken else {
            return .unavailable(reason: "No GitHub token was available from GH_TOKEN, GITHUB_TOKEN, Copilot's local login, or `gh auth token`.")
        }
        return .unavailable(reason: lastUnavailableReason ?? "Could not load Copilot model availability.")
    }

    private func availableModels(token: String) async -> CopilotModelAvailabilityResult {
        let apiBaseURL = (try? await copilotAPIBaseURL(token: token)) ?? Self.defaultCopilotAPIBaseURL
        do {
            let models = try await fetchModels(apiBaseURL: apiBaseURL, token: token)
            let enabledModelIDs = models
                .filter(\.isEnabled)
                .map(\.id)
            let available = RuntimeModelAvailability.cleanProviderModels(enabledModelIDs)
            guard !available.isEmpty else {
                return .unavailable(reason: "Copilot returned no enabled models for this account.")
            }
            if let cliModels = await installedCLIModelChoices(), !cliModels.isEmpty {
                let availableSet = Set(available)
                let usable = cliModels.filter { availableSet.contains($0) }
                guard !usable.isEmpty else {
                    return .unavailable(reason: "Copilot account models do not overlap with the installed Copilot CLI's supported models.")
                }
                return .available(models: usable)
            }
            return .available(models: available)
        } catch {
            return .unavailable(reason: Self.userFacingMessage(for: error))
        }
    }

    private func tokenLoaders() -> [() async -> String?] {
        [
            { environmentAccessToken() },
            { await keychainCopilotToken() },
            { plaintextCopilotToken() },
            { await ghToken() }
        ]
    }

    private func environmentAccessToken() -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            let token = environment()[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !token.isEmpty { return token }
        }
        return nil
    }

    private func ghToken() async -> String? {
        let gh = detectExecutable("gh")
        guard !gh.isEmpty, isExecutable(gh) else { return nil }
        let result = await runner.run(
            path: gh,
            args: ["auth", "token", "--hostname", "github.com"],
            timeout: timeout,
            environment: nil
        )
        guard result.isSuccess else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func installedCLIModelChoices() async -> [String]? {
        let copilot = detectExecutable("copilot")
        guard !copilot.isEmpty, isExecutable(copilot) else { return nil }

        for args in [["help", "config"], ["--help"]] {
            let result = await runner.run(
                path: copilot,
                args: args,
                timeout: timeout,
                environment: nil
            )
            guard result.isSuccess else { continue }

            let choices = Self.parseModelChoices(from: "\(result.stdout)\n\(result.stderr)")
            if !choices.isEmpty { return choices }
        }
        return nil
    }

    private func keychainCopilotToken() async -> String? {
        let security = detectExecutable("security")
        guard !security.isEmpty, isExecutable(security) else { return nil }
        let result = await runner.run(
            path: security,
            args: ["find-generic-password", "-s", "copilot-cli", "-w"],
            timeout: timeout,
            environment: nil
        )
        guard result.isSuccess else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func plaintextCopilotToken() -> String? {
        let url = Self.copilotConfigURL(environment: environment())
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["copilot_tokens"] as? [String: String] else {
            return nil
        }
        return tokens.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func copilotAPIBaseURL(token: String) async throws -> URL {
        var request = URLRequest(url: Self.githubGraphQLURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: Self.copilotEndpointQuery))

        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CopilotModelAvailabilityError.httpStatus(response.statusCode)
        }
        let decoded = try JSONDecoder().decode(CopilotEndpointResponse.self, from: data)
        guard let rawURL = decoded.data?.viewer?.copilotEndpoints?.api,
              let url = URL(string: rawURL) else {
            throw CopilotModelAvailabilityError.missingCopilotEndpoint
        }
        return url
    }

    private func fetchModels(apiBaseURL: URL, token: String) async throws -> [CopilotModelInfo] {
        let url = apiBaseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("conversation-agent", forHTTPHeaderField: "X-Interaction-Type")
        request.setValue("conversation-agent", forHTTPHeaderField: "Openai-Intent")
        request.setValue("user", forHTTPHeaderField: "X-Initiator")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Interaction-Id")
        request.setValue("copilot-developer-cli", forHTTPHeaderField: "Copilot-Integration-Id")
        request.setValue("ASTRA/\(AppBuildInfo.current.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CopilotModelAvailabilityError.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode(CopilotModelsResponse.self, from: data).models
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let error = error as? CopilotModelAvailabilityError {
            switch error {
            case .httpStatus(401), .httpStatus(403):
                return "GitHub rejected the token while checking Copilot model access."
            case .httpStatus(let status):
                return "GitHub Copilot model check failed with HTTP \(status)."
            case .invalidHTTPResponse:
                return "GitHub Copilot model check returned a non-HTTP response."
            case .missingCopilotEndpoint:
                return "GitHub did not return a Copilot API endpoint for this account."
            }
        }
        return "Could not load Copilot model availability."
    }

    private static let githubGraphQLURL = URL(string: "https://api.github.com/graphql")!
    private static let defaultCopilotAPIBaseURL = URL(string: "https://api.githubcopilot.com")!
    private static let copilotEndpointQuery = "{ viewer { copilotEndpoints { api } } }"

    private static func copilotConfigURL(environment: [String: String]) -> URL {
        let basePath: String
        let xdgConfigHome = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !xdgConfigHome.isEmpty {
            basePath = xdgConfigHome
        } else {
            let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let home, !home.isEmpty {
                basePath = home
            } else {
                basePath = NSHomeDirectory()
            }
        }
        return URL(fileURLWithPath: basePath)
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static func parseModelChoices(from text: String) -> [String] {
        if let source = modelOptionBlock(from: text) ?? modelConfigBlock(from: text) {
            let quotedChoices = quotedValues(in: source)
            if !quotedChoices.isEmpty {
                return RuntimeModelAvailability.cleanProviderModels(quotedChoices)
            }

            return RuntimeModelAvailability.cleanProviderModels(choiceList(from: source))
        }

        let source = text
        let quotedChoices = quotedValues(in: source)
        if !quotedChoices.isEmpty, source.range(of: "choices:", options: .caseInsensitive) != nil {
            return RuntimeModelAvailability.cleanProviderModels(quotedChoices)
        }

        guard let marker = source.range(of: "Allowed choices are", options: .caseInsensitive)
            ?? source.range(of: "choices:", options: .caseInsensitive) else {
            return []
        }

        let tail = String(source[marker.upperBound...])
        let firstLine = tail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? tail
        return RuntimeModelAvailability.cleanProviderModels(choiceList(from: firstLine))
    }

    private static func choiceList(from text: String) -> [String] {
        var trimCharacters = CharacterSet.whitespacesAndNewlines
        trimCharacters.formUnion(CharacterSet(charactersIn: "\"'()[]:."))
        return text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: trimCharacters) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    private static func modelOptionBlock(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let startIndex = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("--model")
        }) else {
            return nil
        }

        var block: [String] = []
        for index in startIndex..<lines.count {
            let line = lines[index]
            if index > startIndex {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("-") || trimmed == "Commands:" || trimmed == "Options:" {
                    break
                }
            }
            block.append(line)
        }
        return block.joined(separator: "\n")
    }

    private static func modelConfigBlock(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let startIndex = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("`model`:")
        }) else {
            return nil
        }

        var block: [String] = []
        for index in startIndex..<lines.count {
            let line = lines[index]
            if index > startIndex {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("`") && trimmed.contains("`:") {
                    break
                }
            }
            block.append(line)
        }
        return block.joined(separator: "\n")
    }

    private static func quotedValues(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#) else {
            return []
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
    }
}

private enum CopilotModelAvailabilityError: Error, Equatable {
    case httpStatus(Int)
    case invalidHTTPResponse
    case missingCopilotEndpoint
}

private struct GraphQLRequest: Encodable {
    var query: String
}

private struct CopilotEndpointResponse: Decodable {
    struct ResponseData: Decodable {
        struct Viewer: Decodable {
            struct Endpoints: Decodable {
                var api: String?
            }

            var copilotEndpoints: Endpoints?
        }

        var viewer: Viewer?
    }

    var data: ResponseData?
}

struct CopilotModelInfo: Decodable, Equatable, Sendable {
    struct Policy: Decodable, Equatable, Sendable {
        var state: String?
    }

    var id: String
    var policy: Policy?

    var isEnabled: Bool {
        policy?.state?.lowercased() != "disabled"
    }
}

private struct CopilotModelsResponse: Decodable {
    var models: [CopilotModelInfo]

    init(from decoder: Decoder) throws {
        if let models = try? [CopilotModelInfo](from: decoder) {
            self.models = models
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decode([CopilotModelInfo].self, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }
}
