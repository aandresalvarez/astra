import Foundation
import ASTRACore

struct SlackMessageSearchResult: Sendable, Equatable {
    var id: String
    var channelID: String?
    var channelName: String?
    var user: String?
    var username: String?
    var text: String
    var timestamp: String?
    var permalink: String?
}

struct SlackThreadSummary: Sendable, Equatable {
    var channelID: String
    var threadTimestamp: String
    var messages: [SlackThreadMessage]
    var truncated: Bool
}

struct SlackThreadMessage: Sendable, Equatable {
    var user: String?
    var username: String?
    var text: String
    var timestamp: String?
}

@MainActor
struct SlackConnectorSearchService {
    nonisolated static let requestTimeout: TimeInterval = 15

    enum SearchError: LocalizedError, Equatable {
        case missingConnector
        case invalidBaseURL(String)
        case missingCredentials(String)
        case invalidQuery
        case missingThreadArguments
        case requestFailed(String)
        case httpError(Int, String)
        case apiError(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingConnector:
                return "No configured Slack connector is available for this task."
            case .invalidBaseURL(let name):
                return "Slack connector `\(name)` does not have a valid API base URL."
            case .missingCredentials(let name):
                return "Slack connector `\(name)` is missing required credentials."
            case .invalidQuery:
                return "Missing Slack search arguments. Provide `query` or `q`."
            case .missingThreadArguments:
                return "Missing Slack thread arguments. Provide `channel_id` and `thread_ts`."
            case .requestFailed(let message):
                return "Slack request failed: \(message)"
            case .httpError(let status, let message):
                return "Slack returned HTTP \(status): \(message)"
            case .apiError(let message):
                return "Slack returned an API error: \(message)"
            case .invalidResponse:
                return "Slack returned an unreadable response."
            }
        }
    }

    let connectors: [Connector]
    let contextText: String
    let store: SecretStore
    let transport: any ConnectorHTTPTransport
    let cancellationToken: LocalAgentCancellationToken?
    let requestTimeout: TimeInterval

    init(
        connectors: [Connector],
        contextText: String,
        store: SecretStore = KeychainSecretStore(),
        transport: any ConnectorHTTPTransport = URLSessionConnectorHTTPTransport(),
        cancellationToken: LocalAgentCancellationToken? = nil,
        requestTimeout: TimeInterval = SlackConnectorSearchService.requestTimeout
    ) {
        self.connectors = connectors
        self.contextText = contextText
        self.store = store
        self.transport = transport
        self.cancellationToken = cancellationToken
        self.requestTimeout = requestTimeout
    }

    func search(arguments: [String: LocalModelJSONValue]) async -> Result<[SlackMessageSearchResult], SearchError> {
        guard cancellationToken?.isCancelled != true else {
            return .failure(.requestFailed("cancelled"))
        }
        let connectorResult = preferredConnector()
        guard case .success(let connector) = connectorResult else {
            return .failure(connectorResult.failure ?? .missingConnector)
        }
        guard let baseURL = apiBaseURL(for: connector) else {
            return .failure(.invalidBaseURL(connector.name))
        }
        guard let query = cleaned(arguments["query"]?.stringValue) ?? cleaned(arguments["q"]?.stringValue),
              !query.isEmpty else {
            return .failure(.invalidQuery)
        }
        let maxResults = min(max(arguments["max_results"]?.intValue ?? 10, 1), 20)
        var request = URLRequest(url: ConnectorRequestBuilder.url(
            base: baseURL,
            path: "/search.messages",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "count", value: String(maxResults))
            ]
        ))
        prepare(&request, connector: connector)

        do {
            let (data, response) = try await transport.data(for: request, cancellationToken: cancellationToken)
            guard cancellationToken?.isCancelled != true else {
                return .failure(.requestFailed("cancelled"))
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.httpError(http.statusCode, errorMessage(from: data)))
            }
            guard let payload = try? JSONDecoder().decode(SlackSearchPayload.self, from: data) else {
                return .failure(.invalidResponse)
            }
            guard payload.ok else {
                return .failure(.apiError(payload.error ?? "unknown_error"))
            }
            return .success(payload.messages?.matches.prefix(maxResults).map(\.result) ?? [])
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    func thread(arguments: [String: LocalModelJSONValue]) async -> Result<SlackThreadSummary, SearchError> {
        guard cancellationToken?.isCancelled != true else {
            return .failure(.requestFailed("cancelled"))
        }
        let connectorResult = preferredConnector()
        guard case .success(let connector) = connectorResult else {
            return .failure(connectorResult.failure ?? .missingConnector)
        }
        guard let baseURL = apiBaseURL(for: connector) else {
            return .failure(.invalidBaseURL(connector.name))
        }
        guard let channelID = cleaned(arguments["channel_id"]?.stringValue) ?? cleaned(arguments["channel"]?.stringValue),
              let threadTimestamp = cleaned(arguments["thread_ts"]?.stringValue) ?? cleaned(arguments["ts"]?.stringValue),
              !channelID.isEmpty,
              !threadTimestamp.isEmpty else {
            return .failure(.missingThreadArguments)
        }
        let maxResults = min(max(arguments["max_results"]?.intValue ?? 10, 1), 20)
        var request = URLRequest(url: ConnectorRequestBuilder.url(
            base: baseURL,
            path: "/conversations.replies",
            queryItems: [
                URLQueryItem(name: "channel", value: channelID),
                URLQueryItem(name: "ts", value: threadTimestamp),
                URLQueryItem(name: "limit", value: String(maxResults))
            ]
        ))
        prepare(&request, connector: connector)

        do {
            let (data, response) = try await transport.data(for: request, cancellationToken: cancellationToken)
            guard cancellationToken?.isCancelled != true else {
                return .failure(.requestFailed("cancelled"))
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.httpError(http.statusCode, errorMessage(from: data)))
            }
            guard let payload = try? JSONDecoder().decode(SlackThreadPayload.self, from: data) else {
                return .failure(.invalidResponse)
            }
            guard payload.ok else {
                return .failure(.apiError(payload.error ?? "unknown_error"))
            }
            let messages = payload.messages.prefix(maxResults).map(\.result)
            return .success(SlackThreadSummary(
                channelID: channelID,
                threadTimestamp: threadTimestamp,
                messages: messages,
                truncated: payload.messages.count > maxResults
            ))
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func searchObservation(from result: Result<[SlackMessageSearchResult], SearchError>) -> LocalAgentToolObservation {
        switch result {
        case .success(let messages):
            if messages.isEmpty {
                return .init(status: "ok", content: "No Slack messages matched the query.")
            }
            return .init(status: "ok", content: messages.map(Self.messageLine).joined(separator: "\n"))
        case .failure(let error):
            return .init(status: "error", content: error.localizedDescription)
        }
    }

    static func threadObservation(from result: Result<SlackThreadSummary, SearchError>) -> LocalAgentToolObservation {
        switch result {
        case .success(let summary):
            let suffix = summary.truncated ? "\n... (truncated)" : ""
            let body = summary.messages.map { message in
                let speaker = message.username ?? message.user ?? "unknown"
                let timestamp = message.timestamp.map { " [\($0)]" } ?? ""
                return "- \(speaker)\(timestamp): \(message.text)"
            }.joined(separator: "\n")
            return .init(
                status: "ok",
                content: "Slack thread \(summary.threadTimestamp) in \(summary.channelID):\n\(body)\(suffix)"
            )
        case .failure(let error):
            return .init(status: "error", content: error.localizedDescription)
        }
    }

    private func preferredConnector() -> Result<Connector, SearchError> {
        let ranked = ConnectorPreflightService.preferredRuntimeConnectors(
            from: connectors.filter { $0.serviceType.caseInsensitiveCompare("slack") == .orderedSame },
            contextText: contextText,
            store: store
        )
        guard let connector = ranked.first else {
            return .failure(.missingConnector)
        }
        if connector.authMethod != "none", !connector.missingCredentialKeys(store: store).isEmpty {
            return .failure(.missingCredentials(connector.name))
        }
        return .success(connector)
    }

    private func apiBaseURL(for connector: Connector) -> URL? {
        let raw = connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.isEmpty ? "https://slack.com/api" : raw)
    }

    private func prepare(_ request: inout URLRequest, connector: Connector) {
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        ConnectorRequestBuilder.applyAuthentication(
            authMethod: connector.authMethod,
            credentials: connector.credentials(store: store),
            to: &request
        )
    }

    private func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "empty response" }
        if let error = try? JSONDecoder().decode(SlackErrorPayload.self, from: data),
           let message = error.error,
           !message.isEmpty {
            return message
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "unreadable response"
    }

    private static func messageLine(_ message: SlackMessageSearchResult) -> String {
        var details: [String] = []
        if let channelName = message.channelName, !channelName.isEmpty {
            details.append("#\(channelName)")
        } else if let channelID = message.channelID, !channelID.isEmpty {
            details.append(channelID)
        }
        if let username = message.username, !username.isEmpty {
            details.append(username)
        } else if let user = message.user, !user.isEmpty {
            details.append(user)
        }
        if let timestamp = message.timestamp, !timestamp.isEmpty {
            details.append("ts: \(timestamp)")
        }
        if let permalink = message.permalink, !permalink.isEmpty {
            details.append(permalink)
        }
        let detailText = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "- \(message.text) [\(message.id)]\(detailText)"
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private struct SlackSearchPayload: Decodable {
    var ok: Bool
    var error: String?
    var messages: Matches?

    struct Matches: Decodable {
        var matches: [Match]
    }

    struct Match: Decodable {
        var iid: String?
        var channel: Channel?
        var user: String?
        var username: String?
        var text: String
        var ts: String?
        var permalink: String?

        var result: SlackMessageSearchResult {
            SlackMessageSearchResult(
                id: iid ?? ts ?? "unknown",
                channelID: channel?.id,
                channelName: channel?.name,
                user: user,
                username: username,
                text: text,
                timestamp: ts,
                permalink: permalink
            )
        }
    }

    struct Channel: Decodable {
        var id: String?
        var name: String?
    }
}

private struct SlackThreadPayload: Decodable {
    var ok: Bool
    var error: String?
    var messages: [Message]

    struct Message: Decodable {
        var user: String?
        var username: String?
        var text: String
        var ts: String?

        var result: SlackThreadMessage {
            SlackThreadMessage(
                user: user,
                username: username,
                text: text,
                timestamp: ts
            )
        }
    }
}

private struct SlackErrorPayload: Decodable {
    var error: String?
}
