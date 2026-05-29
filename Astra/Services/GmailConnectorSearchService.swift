import Foundation
import ASTRACore

struct GmailMessageSearchResult: Sendable, Equatable {
    var id: String
    var threadID: String?
    var subject: String
    var from: String?
    var to: String?
    var date: String?
    var snippet: String?
}

struct GmailMessageReadSummary: Sendable, Equatable {
    var id: String
    var threadID: String?
    var subject: String
    var from: String?
    var to: String?
    var date: String?
    var snippet: String?
    var body: String
    var truncated: Bool
}

@MainActor
struct GmailConnectorSearchService {
    nonisolated static let requestTimeout: TimeInterval = 15

    enum SearchError: LocalizedError, Equatable {
        case missingConnector
        case invalidBaseURL(String)
        case missingCredentials(String)
        case invalidQuery
        case missingMessageID
        case requestFailed(String)
        case httpError(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingConnector:
                return "No configured Gmail connector is available for this task."
            case .invalidBaseURL(let name):
                return "Gmail connector `\(name)` does not have a valid API base URL."
            case .missingCredentials(let name):
                return "Gmail connector `\(name)` is missing required credentials."
            case .invalidQuery:
                return "Missing Gmail search arguments. Provide `query`, `q`, `gmail_query`, `from`, or `subject`."
            case .missingMessageID:
                return "Missing Gmail message ID. Provide `message_id` or `id`."
            case .requestFailed(let message):
                return "Gmail request failed: \(message)"
            case .httpError(let status, let message):
                return "Gmail returned HTTP \(status): \(message)"
            case .invalidResponse:
                return "Gmail returned an unreadable response."
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
        requestTimeout: TimeInterval = GmailConnectorSearchService.requestTimeout
    ) {
        self.connectors = connectors
        self.contextText = contextText
        self.store = store
        self.transport = transport
        self.cancellationToken = cancellationToken
        self.requestTimeout = requestTimeout
    }

    func search(arguments: [String: LocalModelJSONValue]) async -> Result<[GmailMessageSearchResult], SearchError> {
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
        guard let query = buildQuery(arguments: arguments) else {
            return .failure(.invalidQuery)
        }

        let maxResults = min(max(arguments["max_results"]?.intValue ?? 10, 1), 10)
        var request = URLRequest(url: ConnectorRequestBuilder.url(
            base: baseURL,
            path: "/gmail/v1/users/me/messages",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxResults", value: String(maxResults))
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
            guard let payload = try? JSONDecoder().decode(GmailMessageListPayload.self, from: data) else {
                return .failure(.invalidResponse)
            }
            let IDs = payload.messages.prefix(maxResults).map(\.id)
            var results: [GmailMessageSearchResult] = []
            for id in IDs {
                guard cancellationToken?.isCancelled != true else {
                    return .failure(.requestFailed("cancelled"))
                }
                let metadata = await fetchMetadata(id: id, baseURL: baseURL, connector: connector)
                switch metadata {
                case .success(let result):
                    results.append(result)
                case .failure(let error):
                    return .failure(error)
                }
            }
            return .success(results)
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    func read(arguments: [String: LocalModelJSONValue]) async -> Result<GmailMessageReadSummary, SearchError> {
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
        guard let messageID = messageID(from: arguments) else {
            return .failure(.missingMessageID)
        }

        var request = URLRequest(url: ConnectorRequestBuilder.url(
            base: baseURL,
            path: "/gmail/v1/users/me/messages/\(escapedPathComponent(messageID))",
            queryItems: [URLQueryItem(name: "format", value: "full")]
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
            guard let payload = try? JSONDecoder().decode(GmailMessagePayload.self, from: data) else {
                return .failure(.invalidResponse)
            }
            let maxBytes = min(max(arguments["max_bytes"]?.intValue ?? 4_000, 1), 12_000)
            let body = payload.plainTextBody
            let bodyData = Data(body.utf8)
            let clippedData = bodyData.prefix(maxBytes)
            let clippedBody = String(data: clippedData, encoding: .utf8) ?? String(body.prefix(maxBytes))
            return .success(GmailMessageReadSummary(
                id: payload.id,
                threadID: payload.threadID,
                subject: payload.subject,
                from: payload.from,
                to: payload.to,
                date: payload.date,
                snippet: payload.snippet,
                body: clippedBody,
                truncated: bodyData.count > maxBytes
            ))
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func searchObservation(from result: Result<[GmailMessageSearchResult], SearchError>) -> LocalAgentToolObservation {
        switch result {
        case .success(let messages):
            if messages.isEmpty {
                return .init(status: "ok", content: "No Gmail messages matched the query.")
            }
            return .init(status: "ok", content: messages.map(Self.messageLine).joined(separator: "\n"))
        case .failure(let error):
            return .init(status: "error", content: error.localizedDescription)
        }
    }

    static func readObservation(from result: Result<GmailMessageReadSummary, SearchError>) -> LocalAgentToolObservation {
        switch result {
        case .success(let summary):
            var details: [String] = []
            if let from = summary.from, !from.isEmpty {
                details.append("from: \(from)")
            }
            if let to = summary.to, !to.isEmpty {
                details.append("to: \(to)")
            }
            if let date = summary.date, !date.isEmpty {
                details.append("date: \(date)")
            }
            if let threadID = summary.threadID, !threadID.isEmpty {
                details.append("thread: \(threadID)")
            }
            let detailText = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            let suffix = summary.truncated ? "\n... (truncated)" : ""
            return .init(
                status: "ok",
                content: "Gmail message: \(summary.subject) [\(summary.id)]\(detailText)\n\(summary.body)\(suffix)"
            )
        case .failure(let error):
            return .init(status: "error", content: error.localizedDescription)
        }
    }

    private func fetchMetadata(
        id: String,
        baseURL: URL,
        connector: Connector
    ) async -> Result<GmailMessageSearchResult, SearchError> {
        var request = URLRequest(url: ConnectorRequestBuilder.url(
            base: baseURL,
            path: "/gmail/v1/users/me/messages/\(escapedPathComponent(id))",
            queryItems: [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "To"),
                URLQueryItem(name: "metadataHeaders", value: "Date")
            ]
        ))
        prepare(&request, connector: connector)
        do {
            let (data, response) = try await transport.data(for: request, cancellationToken: cancellationToken)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.httpError(http.statusCode, errorMessage(from: data)))
            }
            guard let payload = try? JSONDecoder().decode(GmailMessagePayload.self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(payload.searchResult)
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    private func preferredConnector() -> Result<Connector, SearchError> {
        let ranked = ConnectorPreflightService.preferredRuntimeConnectors(
            from: connectors.filter { Self.isGmailServiceType($0.serviceType) },
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

    private static func isGmailServiceType(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return ["gmail", "googlemail", "googlegmail"].contains(normalized)
    }

    private func apiBaseURL(for connector: Connector) -> URL? {
        let raw = connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.isEmpty ? "https://gmail.googleapis.com" : raw)
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

    private func buildQuery(arguments: [String: LocalModelJSONValue]) -> String? {
        for key in ["gmail_query", "q", "query"] {
            if let value = cleaned(arguments[key]?.stringValue), !value.isEmpty {
                return value
            }
        }
        var terms: [String] = []
        if let from = cleaned(arguments["from"]?.stringValue), !from.isEmpty {
            terms.append("from:\(from)")
        }
        if let subject = cleaned(arguments["subject"]?.stringValue), !subject.isEmpty {
            terms.append("subject:(\(subject))")
        }
        let query = terms.joined(separator: " ")
        return query.isEmpty ? nil : query
    }

    private func messageID(from arguments: [String: LocalModelJSONValue]) -> String? {
        for key in ["message_id", "id"] {
            if let value = cleaned(arguments[key]?.stringValue), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escapedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "empty response" }
        if let error = try? JSONDecoder().decode(GmailErrorPayload.self, from: data),
           let message = error.error?.message,
           !message.isEmpty {
            return message
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "unreadable response"
    }

    private static func messageLine(_ message: GmailMessageSearchResult) -> String {
        var details: [String] = []
        if let from = message.from, !from.isEmpty {
            details.append("from: \(from)")
        }
        if let date = message.date, !date.isEmpty {
            details.append("date: \(date)")
        }
        if let threadID = message.threadID, !threadID.isEmpty {
            details.append("thread: \(threadID)")
        }
        let detailText = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        let snippet = message.snippet.map { "\n  \($0)" } ?? ""
        return "- \(message.subject) [\(message.id)]\(detailText)\(snippet)"
    }
}

private struct GmailMessageListPayload: Decodable {
    var messages: [MessageReference]

    struct MessageReference: Decodable {
        var id: String
        var threadId: String?
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private struct GmailMessagePayload: Decodable {
    var id: String
    var threadID: String?
    var snippet: String?
    var payload: Part?

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "threadId"
        case snippet
        case payload
    }

    var subject: String {
        header("Subject") ?? "(no subject)"
    }

    var from: String? {
        header("From")
    }

    var to: String? {
        header("To")
    }

    var date: String? {
        header("Date")
    }

    var searchResult: GmailMessageSearchResult {
        GmailMessageSearchResult(
            id: id,
            threadID: threadID,
            subject: subject,
            from: from,
            to: to,
            date: date,
            snippet: snippet
        )
    }

    var plainTextBody: String {
        guard let payload else {
            return snippet ?? ""
        }
        if let text = payload.firstDecodedBody(mimeType: "text/plain") {
            return text
        }
        if let html = payload.firstDecodedBody(mimeType: "text/html") {
            return Self.textFromHTML(html)
        }
        return snippet ?? ""
    }

    private func header(_ name: String) -> String? {
        payload?.headers?.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    private static func textFromHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<br>", with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: "<br/>", with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: "<br />", with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: "</p>", with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Part: Decodable {
        var mimeType: String?
        var headers: [Header]?
        var body: Body?
        var parts: [Part]?

        func firstDecodedBody(mimeType target: String) -> String? {
            if mimeType == target,
               let data = body?.data,
               let text = Self.decodeBase64URLText(data) {
                return text
            }
            for part in parts ?? [] {
                if let text = part.firstDecodedBody(mimeType: target) {
                    return text
                }
            }
            return nil
        }

        private static func decodeBase64URLText(_ value: String) -> String? {
            var base64 = value
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let remainder = base64.count % 4
            if remainder > 0 {
                base64 += String(repeating: "=", count: 4 - remainder)
            }
            guard let data = Data(base64Encoded: base64) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    struct Header: Decodable {
        var name: String
        var value: String
    }

    struct Body: Decodable {
        var data: String?
    }
}

private struct GmailErrorPayload: Decodable {
    var error: ErrorBody?

    struct ErrorBody: Decodable {
        var message: String?
    }
}
