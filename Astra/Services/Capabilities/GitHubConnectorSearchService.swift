import Foundation
import ASTRACore

struct GitHubSearchResult: Sendable, Equatable {
    var repository: String
    var number: Int
    var title: String
    var state: String
    var kind: String
    var author: String?
    var updated: String?
    var url: String?
}

@MainActor
struct GitHubConnectorSearchService {
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
                return "No configured GitHub connector is available for this task."
            case .invalidBaseURL(let name):
                return "GitHub connector `\(name)` does not have a valid API base URL."
            case .missingCredentials(let name):
                return "GitHub connector `\(name)` is missing required credentials."
            case .invalidQuery:
                return "Missing GitHub search arguments. Provide `query`, `q`, `repo`, or `owner` and `repo`."
            case .requestFailed(let message):
                return "GitHub search request failed: \(message)"
            case .httpError(let status, let message):
                return "GitHub search returned HTTP \(status): \(message)"
            case .invalidResponse:
                return "GitHub search returned an unreadable response."
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
        requestTimeout: TimeInterval = GitHubConnectorSearchService.requestTimeout
    ) {
        self.connectors = connectors
        self.contextText = contextText
        self.store = store
        self.transport = transport
        self.cancellationToken = cancellationToken
        self.requestTimeout = requestTimeout
    }

    func search(arguments: [String: LocalModelJSONValue]) async -> Result<[GitHubSearchResult], SearchError> {
        guard cancellationToken?.isCancelled != true else {
            return .failure(.requestFailed("cancelled"))
        }
        let ranked = ConnectorPreflightService.preferredRuntimeConnectors(
            from: connectors.filter { $0.serviceType.caseInsensitiveCompare("github") == .orderedSame },
            contextText: contextText,
            store: store
        )
        guard let connector = ranked.first else {
            return .failure(.missingConnector)
        }
        let baseURLString = connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBaseURL = baseURLString.isEmpty ? "https://api.github.com" : baseURLString
        guard let baseURL = URL(string: effectiveBaseURL) else {
            return .failure(.invalidBaseURL(connector.name))
        }

        if connector.authMethod != "none", !connector.missingCredentialKeys(store: store).isEmpty {
            return .failure(.missingCredentials(connector.name))
        }

        guard let query = buildQuery(arguments: arguments, connector: connector) else {
            return .failure(.invalidQuery)
        }
        let maxResults = min(max(arguments["max_results"]?.intValue ?? 10, 1), 20)
        var request = URLRequest(url: ConnectorRequestBuilder.url(
            base: baseURL,
            path: "/search/issues",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "per_page", value: String(maxResults)),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc")
            ]
        ))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
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
            guard let payload = try? JSONDecoder().decode(GitHubSearchPayload.self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(payload.items.map(\.result))
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func observation(from result: Result<[GitHubSearchResult], SearchError>) -> LocalAgentToolObservation {
        switch result {
        case .success(let items):
            if items.isEmpty {
                return .init(status: "ok", content: "No GitHub issues or pull requests matched the query.")
            }
            return .init(
                status: "ok",
                content: items.map(Self.resultLine).joined(separator: "\n")
            )
        case .failure(let error):
            return .init(status: "error", content: error.localizedDescription)
        }
    }

    private func buildQuery(arguments: [String: LocalModelJSONValue], connector: Connector) -> String? {
        var terms: [String] = []
        if let q = cleaned(arguments["q"]?.stringValue), !q.isEmpty {
            terms.append(q)
        } else if let query = cleaned(arguments["query"]?.stringValue), !query.isEmpty {
            terms.append(query)
        }

        if let repository = repositoryQualifier(arguments: arguments, connector: connector) {
            terms.append("repo:\(repository)")
        }

        if let type = cleaned(arguments["type"]?.stringValue)?.lowercased() {
            switch type {
            case "pr", "pull", "pull_request", "pull request", "pull-request":
                terms.append("is:pr")
            case "issue", "issues":
                terms.append("is:issue")
            default:
                break
            }
        }

        if let state = cleaned(arguments["state"]?.stringValue)?.lowercased(),
           ["open", "closed"].contains(state) {
            terms.append("state:\(state)")
        }

        let query = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return query.isEmpty ? nil : query
    }

    private func repositoryQualifier(
        arguments: [String: LocalModelJSONValue],
        connector: Connector
    ) -> String? {
        if let repo = cleaned(arguments["repo"]?.stringValue), !repo.isEmpty {
            if repo.contains("/") {
                return repo
            }
            if let owner = cleaned(arguments["owner"]?.stringValue), !owner.isEmpty {
                return "\(owner)/\(repo)"
            }
            return repo
        }
        if let configured = configuredRepositories(connector: connector).first {
            return configured
        }
        return nil
    }

    private func configuredRepositories(connector: Connector) -> [String] {
        let raw = connector.config["GITHUB_REPOS"] ?? connector.config["REPOSITORIES"] ?? connector.config["REPOS"] ?? ""
        return raw.split { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("/") }
    }

    private func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "empty response" }
        if let error = try? JSONDecoder().decode(GitHubErrorPayload.self, from: data),
           !error.message.isEmpty {
            return error.message
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "unreadable response"
    }

    private static func resultLine(_ result: GitHubSearchResult) -> String {
        var details = [result.kind, result.state]
        if let author = result.author, !author.isEmpty {
            details.append("author: \(author)")
        }
        if let updated = result.updated, !updated.isEmpty {
            details.append("updated: \(updated)")
        }
        if let url = result.url, !url.isEmpty {
            details.append(url)
        }
        return "- \(result.repository)#\(result.number): \(result.title) (\(details.joined(separator: ", ")))"
    }
}

private struct GitHubSearchPayload: Decodable {
    var items: [GitHubIssuePayload]
}

private struct GitHubIssuePayload: Decodable {
    var number: Int
    var title: String
    var state: String
    var htmlURL: String?
    var repositoryURL: String?
    var pullRequest: PullRequest?
    var user: User?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case number
        case title
        case state
        case htmlURL = "html_url"
        case repositoryURL = "repository_url"
        case pullRequest = "pull_request"
        case user
        case updatedAt = "updated_at"
    }

    var result: GitHubSearchResult {
        GitHubSearchResult(
            repository: repositoryName(from: repositoryURL),
            number: number,
            title: title,
            state: state,
            kind: pullRequest == nil ? "issue" : "pull_request",
            author: user?.login,
            updated: updatedAt,
            url: htmlURL
        )
    }

    private func repositoryName(from value: String?) -> String {
        guard let value,
              let url = URL(string: value) else {
            return "unknown/repository"
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else {
            return "unknown/repository"
        }
        return components.suffix(2).joined(separator: "/")
    }

    struct PullRequest: Decodable {}

    struct User: Decodable {
        var login: String?
    }
}

private struct GitHubErrorPayload: Decodable {
    var message: String
}
