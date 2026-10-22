import Foundation
import ASTRACore
import ASTRAModels
import HostControlToolSupport

struct StanfordOutlookMailGraphService: Sendable {
    private let transport: any OutlookHTTPTransport
    private let auth: StanfordOutlookMailAuthService
    init(transport: any OutlookHTTPTransport = URLSessionOutlookHTTPTransport()) {
        self.transport = transport
        auth = StanfordOutlookMailAuthService(transport: transport)
    }

    func identity(accessToken: String) async throws -> GraphMeResponse {
        let data = try await get(accessToken: accessToken, path: "/me", query: [
            .init(name: "$select", value: "id,displayName,userPrincipalName,mail")], maximumBytes: 1_024 * 1_024)
        let me = try JSONDecoder().decode(GraphMeResponse.self, from: data)
        guard !me.id.isEmpty else { throw StanfordOutlookMailError.invalidResponse }
        return me
    }

    @MainActor
    func testConnection(connector: Connector) async throws -> GraphMeResponse {
        let expected = PluginAccountRecord(connector)
        let context = try OutlookAuthorizationContext(connector)
        let token = try await auth.accessToken(context: context)
        let me = try await identity(accessToken: token)
        guard context.principalID == nil || context.principalID == me.id,
              !connector.isDeleted, PluginAccountRecord(connector) == expected else { throw StanfordOutlookMailError.invalidResponse }
        // A connection check observes the grant. Only verified sign-in may
        // publish its principal; filling a legacy unknown principal here
        // would make its immutable bundle fail the following check.
        connector.setConfigValue(StanfordOutlookMail.displayNameKey, value: me.displayName ?? "")
        if connector.outlookEmail.isEmpty {
            connector.setConfigValue(StanfordOutlookMail.emailKey, value: me.mail ?? me.userPrincipalName ?? "")
        }
        return me
    }

    @MainActor
    func message(connector: Connector, id messageID: String) async throws -> GraphMessage {
        guard let request = MailReadRequest.parse(["operation": "get", "message_id": messageID]) else { throw StanfordOutlookMailError.invalidResponse }
        let data = try await read(account: PluginAccountRecord(connector), request: request)
        return try JSONDecoder().decode(GraphMessage.self, from: data)
    }

    @MainActor
    func read(account: PluginAccountRecord, request: MailReadRequest) async throws -> Data {
        let context = try OutlookAuthorizationContext(account.makeAccount())
        var path: String
        var query: [URLQueryItem] = []
        var search = false
        switch request.operation {
        case .accounts: throw StanfordOutlookMailError.invalidResponse // Selection/metadata belongs to MailReadSession.
        case .folders:
            path = "/me/mailFolders"
            query = [.init(name: "$top", value: String(request.limit)),
                     .init(name: "$select", value: "id,displayName,totalItemCount,unreadItemCount")]
        case .search:
            path = "/me/messages"
            query = [.init(name: "$top", value: String(request.limit)),
                     .init(name: "$select", value: "id,subject,from,receivedDateTime,bodyPreview,hasAttachments,webLink")]
            if let value = request.query {
                search = true
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                query.append(.init(name: "$search", value: "\"" + escaped + "\""))
            } else { query.append(.init(name: "$orderby", value: "receivedDateTime desc")) }
        case .get:
            guard let id = request.messageID, id != ".", id != ".." else { throw StanfordOutlookMailError.invalidResponse }
            path = "/me/messages/" + OutlookOAuthClientContext.pathComponent(id)
            query = [.init(name: "$select", value: "id,subject,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,body,hasAttachments,webLink")]
        }
        let token = try await auth.accessToken(context: context)
        return try await get(accessToken: token, path: path, query: query, preferTextBody: request.operation == .get,
            consistencyLevelEventual: search, maximumBytes: 8 * 1_024 * 1_024)
    }

    private func get(accessToken: String, path: String, query: [URLQueryItem], preferTextBody: Bool = false,
                     consistencyLevelEventual: Bool = false, maximumBytes: Int) async throws -> Data {
        guard !accessToken.isEmpty else { throw StanfordOutlookMailError.missingRefreshToken }
        var components = URLComponents(string: StanfordOutlookMail.graphBaseURL)!
        components.percentEncodedPath = "/v1.0" + path
        components.queryItems = query
        guard let url = components.url, url.host == "graph.microsoft.com", url.scheme == "https" else { throw StanfordOutlookMailError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if preferTextBody { request.setValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer") }
        if consistencyLevelEventual { request.setValue("eventual", forHTTPHeaderField: "ConsistencyLevel") }
        let (data, response) = try await transport.data(for: request, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode) else {
            throw StanfordOutlookMailError.graph(response.statusCode, HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw StanfordOutlookMailError.invalidResponse }
        return data
    }
}
