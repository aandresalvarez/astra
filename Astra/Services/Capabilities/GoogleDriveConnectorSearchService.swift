import Foundation
import ASTRACore

struct GoogleDriveFileSearchResult: Sendable, Equatable {
    var id: String
    var name: String
    var mimeType: String
    var webViewLink: String?
    var modifiedTime: String?
    var owner: String?
    var size: String?
}

struct GoogleDriveFileReadSummary: Sendable, Equatable {
    var id: String
    var name: String
    var mimeType: String
    var webViewLink: String?
    var modifiedTime: String?
    var text: String
    var truncated: Bool
}

@MainActor
struct GoogleDriveConnectorSearchService {
    nonisolated static let requestTimeout: TimeInterval = 15

    enum SearchError: LocalizedError, Equatable {
        case missingConnector
        case invalidBaseURL(String)
        case missingCredentials(String)
        case invalidQuery
        case missingFileID
        case requestFailed(String)
        case httpError(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingConnector:
                return "No configured Google Drive connector is available for this task."
            case .invalidBaseURL(let name):
                return "Google Drive connector `\(name)` does not have a valid API base URL."
            case .missingCredentials(let name):
                return "Google Drive connector `\(name)` is missing required credentials."
            case .invalidQuery:
                return "Missing Google Drive search arguments. Provide `query`, `name`, `q`, or `drive_query`."
            case .missingFileID:
                return "Missing Google Drive file ID. Provide `file_id`, `id`, or a Drive file URL."
            case .requestFailed(let message):
                return "Google Drive request failed: \(message)"
            case .httpError(let status, let message):
                return "Google Drive returned HTTP \(status): \(message)"
            case .invalidResponse:
                return "Google Drive returned an unreadable response."
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
        requestTimeout: TimeInterval = GoogleDriveConnectorSearchService.requestTimeout
    ) {
        self.connectors = connectors
        self.contextText = contextText
        self.store = store
        self.transport = transport
        self.cancellationToken = cancellationToken
        self.requestTimeout = requestTimeout
    }

    func search(arguments: [String: LocalModelJSONValue]) async -> Result<[GoogleDriveFileSearchResult], SearchError> {
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
        guard let query = buildDriveQuery(arguments: arguments) else {
            return .failure(.invalidQuery)
        }

        let maxResults = min(max(arguments["max_results"]?.intValue ?? 10, 1), 20)
        var request = URLRequest(url: ConnectorRequestBuilder.url(
            base: baseURL,
            path: "/drive/v3/files",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "pageSize", value: String(maxResults)),
                URLQueryItem(name: "fields", value: "files(id,name,mimeType,webViewLink,modifiedTime,owners(displayName),size)")
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
            guard let payload = try? JSONDecoder().decode(GoogleDriveFileListPayload.self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(payload.files.map(\.result))
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    func read(arguments: [String: LocalModelJSONValue]) async -> Result<GoogleDriveFileReadSummary, SearchError> {
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
        guard let fileID = fileID(from: arguments) else {
            return .failure(.missingFileID)
        }

        var metadataRequest = URLRequest(url: ConnectorRequestBuilder.urlWithPercentEncodedPath(
            base: baseURL,
            path: "/drive/v3/files/\(escapedPathComponent(fileID))",
            queryItems: [
                URLQueryItem(name: "fields", value: "id,name,mimeType,webViewLink,modifiedTime,size")
            ]
        ))
        prepare(&metadataRequest, connector: connector)

        do {
            let (metadataData, metadataResponse) = try await transport.data(for: metadataRequest, cancellationToken: cancellationToken)
            guard cancellationToken?.isCancelled != true else {
                return .failure(.requestFailed("cancelled"))
            }
            if let http = metadataResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.httpError(http.statusCode, errorMessage(from: metadataData)))
            }
            guard let metadata = try? JSONDecoder().decode(GoogleDriveFilePayload.self, from: metadataData) else {
                return .failure(.invalidResponse)
            }

            var contentRequest = URLRequest(url: contentURL(baseURL: baseURL, fileID: fileID, mimeType: metadata.mimeType))
            prepare(&contentRequest, connector: connector)
            let maxBytes = min(max(arguments["max_bytes"]?.intValue ?? 4_000, 1), 12_000)
            let contentResult = try await transport.boundedData(
                for: contentRequest,
                maxBytes: maxBytes,
                cancellationToken: cancellationToken
            )
            let contentData = contentResult.data
            let contentResponse = contentResult.response
            guard cancellationToken?.isCancelled != true else {
                return .failure(.requestFailed("cancelled"))
            }
            if let http = contentResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.httpError(http.statusCode, errorMessage(from: contentData)))
            }

            // Clipping to maxBytes can sever a multi-byte UTF-8 scalar at the boundary; step
            // back up to 3 bytes to a valid boundary so truncated text still renders instead of
            // being misreported as non-UTF-8.
            var text = "File content is not UTF-8 text; metadata only."
            for trailingDrop in 0...min(3, contentData.count) {
                if let decoded = String(data: contentData.dropLast(trailingDrop), encoding: .utf8) {
                    text = decoded
                    break
                }
            }
            return .success(GoogleDriveFileReadSummary(
                id: metadata.id,
                name: metadata.name,
                mimeType: metadata.mimeType,
                webViewLink: metadata.webViewLink,
                modifiedTime: metadata.modifiedTime,
                text: text,
                truncated: contentResult.truncated
            ))
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func searchObservation(from result: Result<[GoogleDriveFileSearchResult], SearchError>) -> LocalAgentToolObservation {
        switch result {
        case .success(let files):
            if files.isEmpty {
                return .init(status: "ok", content: "No Google Drive files matched the query.")
            }
            return .init(status: "ok", content: files.map(Self.fileLine).joined(separator: "\n"))
        case .failure(let error):
            return .init(status: "error", content: error.localizedDescription)
        }
    }

    static func readObservation(from result: Result<GoogleDriveFileReadSummary, SearchError>) -> LocalAgentToolObservation {
        switch result {
        case .success(let summary):
            var details = [summary.mimeType]
            if let modifiedTime = summary.modifiedTime, !modifiedTime.isEmpty {
                details.append("modified: \(modifiedTime)")
            }
            if let webViewLink = summary.webViewLink, !webViewLink.isEmpty {
                details.append(webViewLink)
            }
            let suffix = summary.truncated ? "\n... (truncated)" : ""
            return .init(
                status: "ok",
                content: "Google Drive file: \(summary.name) [\(summary.id)] (\(details.joined(separator: ", ")))\n\(summary.text)\(suffix)"
            )
        case .failure(let error):
            return .init(status: "error", content: error.localizedDescription)
        }
    }

    private func preferredConnector() -> Result<Connector, SearchError> {
        let ranked = ConnectorPreflightService.preferredRuntimeConnectors(
            from: connectors.filter { Self.isGoogleDriveServiceType($0.serviceType) },
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

    private static func isGoogleDriveServiceType(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return ["googledrive", "drive", "gdrive"].contains(normalized)
    }

    private func apiBaseURL(for connector: Connector) -> URL? {
        let raw = connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.isEmpty ? "https://www.googleapis.com" : raw)
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

    private func buildDriveQuery(arguments: [String: LocalModelJSONValue]) -> String? {
        if let driveQuery = cleaned(arguments["drive_query"]?.stringValue), !driveQuery.isEmpty {
            return driveQuery
        }
        if let q = cleaned(arguments["q"]?.stringValue), !q.isEmpty {
            return q
        }
        if let name = cleaned(arguments["name"]?.stringValue), !name.isEmpty {
            return "name contains '\(escapeDriveQuery(name))' and trashed = false"
        }
        if let query = cleaned(arguments["query"]?.stringValue), !query.isEmpty {
            let escaped = escapeDriveQuery(query)
            return "(name contains '\(escaped)' or fullText contains '\(escaped)') and trashed = false"
        }
        return nil
    }

    private func fileID(from arguments: [String: LocalModelJSONValue]) -> String? {
        for key in ["file_id", "id"] {
            if let value = cleaned(arguments[key]?.stringValue), !value.isEmpty {
                return value
            }
        }
        guard let urlString = cleaned(arguments["url"]?.stringValue),
              let url = URL(string: urlString) else {
            return nil
        }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "id" })?
            .value,
            !id.isEmpty {
            return id
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if let dIndex = parts.firstIndex(of: "d"), parts.indices.contains(dIndex + 1) {
            return parts[dIndex + 1]
        }
        return nil
    }

    private func contentURL(baseURL: URL, fileID: String, mimeType: String) -> URL {
        if let exportType = exportMimeType(for: mimeType) {
            return ConnectorRequestBuilder.urlWithPercentEncodedPath(
                base: baseURL,
                path: "/drive/v3/files/\(escapedPathComponent(fileID))/export",
                queryItems: [URLQueryItem(name: "mimeType", value: exportType)]
            )
        }
        return ConnectorRequestBuilder.urlWithPercentEncodedPath(
            base: baseURL,
            path: "/drive/v3/files/\(escapedPathComponent(fileID))",
            queryItems: [URLQueryItem(name: "alt", value: "media")]
        )
    }

    private func exportMimeType(for mimeType: String) -> String? {
        switch mimeType {
        case "application/vnd.google-apps.document",
             "application/vnd.google-apps.presentation":
            return "text/plain"
        case "application/vnd.google-apps.spreadsheet":
            return "text/csv"
        default:
            return nil
        }
    }

    private func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escapeDriveQuery(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "'", with: #"\'"#)
    }

    private func escapedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "empty response" }
        if let error = try? JSONDecoder().decode(GoogleDriveErrorPayload.self, from: data),
           let message = error.error?.message,
           !message.isEmpty {
            return message
        }
        return ConnectorResponseSnippet.text(from: data)
    }

    private static func fileLine(_ file: GoogleDriveFileSearchResult) -> String {
        var details = [file.mimeType]
        if let modifiedTime = file.modifiedTime, !modifiedTime.isEmpty {
            details.append("modified: \(modifiedTime)")
        }
        if let owner = file.owner, !owner.isEmpty {
            details.append("owner: \(owner)")
        }
        if let size = file.size, !size.isEmpty {
            details.append("size: \(size)")
        }
        if let webViewLink = file.webViewLink, !webViewLink.isEmpty {
            details.append(webViewLink)
        }
        return "- \(file.name) [\(file.id)] (\(details.joined(separator: ", ")))"
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private struct GoogleDriveFileListPayload: Decodable {
    var files: [GoogleDriveFilePayload]
}

private struct GoogleDriveFilePayload: Decodable {
    var id: String
    var name: String
    var mimeType: String
    var webViewLink: String?
    var modifiedTime: String?
    var owners: [Owner]?
    var size: String?

    var result: GoogleDriveFileSearchResult {
        GoogleDriveFileSearchResult(
            id: id,
            name: name,
            mimeType: mimeType,
            webViewLink: webViewLink,
            modifiedTime: modifiedTime,
            owner: owners?.first?.displayName,
            size: size
        )
    }

    struct Owner: Decodable {
        var displayName: String?
    }
}

private struct GoogleDriveErrorPayload: Decodable {
    var error: ErrorBody?

    struct ErrorBody: Decodable {
        var message: String?
    }
}
