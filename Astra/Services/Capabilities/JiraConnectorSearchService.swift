import Foundation
import ASTRACore

struct JiraSearchResult: Sendable, Equatable {
    var key: String
    var summary: String
    var status: String?
    var assignee: String?
    var issueType: String?
    var updated: String?
}

@MainActor
struct JiraConnectorSearchService {
    nonisolated static let requestTimeout: TimeInterval = 15

    enum SearchError: LocalizedError, Equatable {
        case missingConnector
        case invalidBaseURL(String)
        case missingCredentials(String)
        case invalidQuery
        case requestFailed(String)
        case httpError(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingConnector:
                return "No configured Jira connector is available for this task."
            case .invalidBaseURL(let name):
                return "Jira connector `\(name)` does not have a valid base URL."
            case .missingCredentials(let name):
                return "Jira connector `\(name)` is missing required credentials."
            case .invalidQuery:
                return "Missing Jira search arguments. Provide `jql`, `project`, or `query`."
            case .requestFailed(let message):
                return "Jira search request failed: \(message)"
            case .httpError(let status, let message):
                return "Jira search returned HTTP \(status): \(message)"
            case .invalidResponse:
                return "Jira search returned an unreadable response."
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
        requestTimeout: TimeInterval = JiraConnectorSearchService.requestTimeout
    ) {
        self.connectors = connectors
        self.contextText = contextText
        self.store = store
        self.transport = transport
        self.cancellationToken = cancellationToken
        self.requestTimeout = requestTimeout
    }

    func search(arguments: [String: LocalModelJSONValue]) async -> Result<[JiraSearchResult], SearchError> {
        guard cancellationToken?.isCancelled != true else {
            return .failure(.requestFailed("cancelled"))
        }
        let ranked = ConnectorPreflightService.preferredRuntimeConnectors(
            from: connectors.filter { $0.serviceType.caseInsensitiveCompare("jira") == .orderedSame },
            contextText: contextText,
            store: store
        )
        guard let connector = ranked.first else {
            return .failure(.missingConnector)
        }
        guard let baseURL = URL(string: connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.invalidBaseURL(connector.name))
        }

        if connector.authMethod != "none", !connector.missingCredentialKeys(store: store).isEmpty {
            return .failure(.missingCredentials(connector.name))
        }

        guard let jql = buildJQL(arguments: arguments, connector: connector) else {
            return .failure(.invalidQuery)
        }
        let maxResults = min(max(arguments["max_results"]?.intValue ?? 10, 1), 20)
        var request = URLRequest(url: ConnectorRequestBuilder.url(
            base: baseURL,
            path: "/rest/api/3/search/jql",
            queryItems: [
                URLQueryItem(name: "jql", value: jql),
                URLQueryItem(name: "maxResults", value: String(maxResults)),
                URLQueryItem(name: "fields", value: "summary,status,assignee,issuetype,updated")
            ]
        ))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        ConnectorRequestBuilder.applyAuthentication(
            authMethod: connector.authMethod,
            credentials: connector.credentials(store: store),
            to: &request
        )

        do {
            let (data, response) = try await transport.data(for: request, cancellationToken: cancellationToken)
            guard cancellationToken?.isCancelled != true else {
                return .failure(.requestFailed("cancelled"))
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.httpError(http.statusCode, errorMessage(from: data)))
            }
            guard let payload = try? JSONDecoder().decode(JiraSearchPayload.self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(payload.issues.map(\.result))
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func observation(from result: Result<[JiraSearchResult], SearchError>) -> LocalAgentToolObservation {
        switch result {
        case .success(let issues):
            if issues.isEmpty {
                return .init(status: "ok", content: "No Jira issues matched the query.")
            }
            return .init(
                status: "ok",
                content: issues.map(Self.issueLine).joined(separator: "\n")
            )
        case .failure(let error):
            return .init(status: "error", content: error.localizedDescription)
        }
    }

    private func buildJQL(arguments: [String: LocalModelJSONValue], connector: Connector) -> String? {
        if let jql = cleaned(arguments["jql"]?.stringValue), !jql.isEmpty {
            return jql
        }
        if let project = cleaned(arguments["project"]?.stringValue), !project.isEmpty {
            return "\(jqlProjectClause(project)) ORDER BY updated DESC"
        }
        if let query = cleaned(arguments["query"]?.stringValue), !query.isEmpty {
            if let project = bestConfiguredProject(connector: connector) {
                return #"\#(jqlProjectClause(project)) AND text ~ "\#(escapeJQLString(query))" ORDER BY updated DESC"#
            }
            return #"text ~ "\#(escapeJQLString(query))" ORDER BY updated DESC"#
        }
        return nil
    }

    private func jqlProjectClause(_ project: String) -> String {
        #"project = "\#(escapeJQLString(project.uppercased()))""#
    }

    private func bestConfiguredProject(connector: Connector) -> String? {
        let configured = projectKeys(from: connector.config["JIRA_PROJECTS"] ?? "")
        let requested = projectKeysMentioned(in: contextText, configuredProjects: configured)
        return requested.first ?? configured.first
    }

    private func projectKeysMentioned(in text: String, configuredProjects: [String]) -> [String] {
        let words = Set(text
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init))
        return configuredProjects.filter { words.contains($0) }
    }

    private func projectKeys(from raw: String) -> [String] {
        raw.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    private func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escapeJQLString(_ value: String) -> String {
        value.replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }

    private func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "empty response" }
        if let error = try? JSONDecoder().decode(JiraErrorPayload.self, from: data) {
            let messages = error.errorMessages + error.errors.values
            if !messages.isEmpty {
                return messages.joined(separator: "; ")
            }
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "unreadable response"
    }

    private static func issueLine(_ issue: JiraSearchResult) -> String {
        var details: [String] = []
        if let status = issue.status, !status.isEmpty {
            details.append(status)
        }
        if let issueType = issue.issueType, !issueType.isEmpty {
            details.append(issueType)
        }
        if let assignee = issue.assignee, !assignee.isEmpty {
            details.append("assignee: \(assignee)")
        }
        if let updated = issue.updated, !updated.isEmpty {
            details.append("updated: \(updated)")
        }
        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "- \(issue.key): \(issue.summary)\(suffix)"
    }
}

private struct JiraSearchPayload: Decodable {
    var issues: [JiraIssuePayload]
}

private struct JiraIssuePayload: Decodable {
    var key: String
    var fields: Fields

    var result: JiraSearchResult {
        JiraSearchResult(
            key: key,
            summary: fields.summary,
            status: fields.status?.name,
            assignee: fields.assignee?.displayName,
            issueType: fields.issuetype?.name,
            updated: fields.updated
        )
    }

    struct Fields: Decodable {
        var summary: String
        var status: NamedValue?
        var assignee: User?
        var issuetype: NamedValue?
        var updated: String?
    }

    struct NamedValue: Decodable {
        var name: String
    }

    struct User: Decodable {
        var displayName: String?
    }
}

private struct JiraErrorPayload: Decodable {
    var errorMessages: [String]
    var errors: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorMessages = (try? container.decode([String].self, forKey: .errorMessages)) ?? []
        errors = (try? container.decode([String: String].self, forKey: .errors)) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case errorMessages
        case errors
    }
}
