import Foundation
import Darwin
import MailToolSupport

private let accessTokenKey = "ASTRA_MAIL_ACCESS_TOKEN"
private let refreshTokenKey = "ASTRA_MAIL_REFRESH_TOKEN"
private let expiresAtKey = "ASTRA_MAIL_EXPIRES_AT"
private let graphBase = "https://graph.microsoft.com/v1.0"
private let defaultScopes = "https://graph.microsoft.com/User.Read https://graph.microsoft.com/Mail.Read offline_access openid profile"

private struct MailAccount: Decodable {
    let email: String?
    let tenantDomain: String?
    let name: String?
    let displayName: String?
    let channel: String?
    let connectorID: String?
    let keychainService: String?
    let clientID: String?
}

@main
struct StanfordMailTool {
    static func main() async {
        let code: Int32
        do {
            try await run()
            code = 0
        } catch {
            code = exitWithError(prefix: "stanford-mail", error: error, asJSON: true, code: 2)
        }
        if code != 0 {
            Darwin.exit(code)
        }
    }

    private static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            throw ToolError(usage())
        }

        let command = args.removeFirst()
        switch command {
        case "accounts":
            try cmdAccounts(args)
        case "folders":
            let options = try parseAccountOptions(args, defaultLimit: 50)
            try await cmdFolders(accountSelector: options.account, limit: options.limit)
        case "search":
            let options = try parseAccountOptions(args, defaultLimit: 10, includeQuery: true)
            try await cmdSearch(accountSelector: options.account, query: options.query, limit: options.limit)
        case "get":
            let options = try parseGetOptions(args)
            try await cmdGet(accountSelector: options.account, messageID: options.messageID)
        case "-h", "--help", "help":
            print(usage())
        default:
            throw ToolError("Unknown command \(command).\n\n\(usage())")
        }
    }

    private static func usage() -> String {
        """
        stanford-mail - read-only Microsoft Graph mail helper for ASTRA agents.

        Commands:
          stanford-mail accounts
          stanford-mail folders --account email@example.org
          stanford-mail search --account email@example.org --query "term" [--limit 10]
          stanford-mail get --account email@example.org --message-id MESSAGE_ID
        """
    }

    private static func registryCandidates() throws -> [String] {
        if let configured = ProcessInfo.processInfo.environment["ASTRA_MAIL_REGISTRY_PATH"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [configured]
        }
        throw ToolError(
            "ASTRA mail registry is not available for this task. " +
            "Enable the Stanford Outlook Mail capability in ASTRA and run this helper from that task."
        )
    }

    private static func loadAccounts() throws -> [MailAccount] {
        let decoder = JSONDecoder()
        for path in try registryCandidates() {
            if FileManager.default.fileExists(atPath: path) {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                return try decoder.decode([MailAccount].self, from: data)
            }
        }
        return []
    }

    private static func selectedAccount(_ accounts: [MailAccount], selector: String?) throws -> MailAccount {
        if let selector, !selector.isEmpty {
            let lowered = selector.lowercased()
            let matches = accounts.filter { account in
                [
                    account.email?.lowercased(),
                    account.connectorID?.lowercased(),
                    account.name?.lowercased()
                ].contains(lowered)
            }
            if matches.count == 1 {
                return matches[0]
            }
            if matches.isEmpty {
                throw ToolError("No configured mail account matches '\(selector)'.")
            }
            throw ToolError("More than one mail account matches '\(selector)'; use the full email address.")
        }

        if accounts.count == 1 {
            return accounts[0]
        }
        if accounts.isEmpty {
            throw ToolError("No Stanford Outlook mail accounts are configured in ASTRA.")
        }
        throw ToolError("Multiple mail accounts are configured; pass --account with the email address.")
    }

    private static func securityFind(service: String, account: String) -> String? {
        guard let result = try? runProcess(
            "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"],
            timeout: 15
        ), result.exitCode == 0 else {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func securitySave(service: String, account: String, value: String) throws {
        let result = try runProcess(
            "/usr/bin/security",
            arguments: ["add-generic-password", "-U", "-s", service, "-a", account, "-w", value],
            timeout: 15
        )
        guard result.exitCode == 0 else {
            throw ToolError("Could not update Keychain item \(account).")
        }
    }

    private static func tokenEndpoint(for account: MailAccount) -> URL {
        let tenant = account.tenantDomain?.isEmpty == false ? account.tenantDomain! : "stanford.edu"
        return URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
    }

    private static func refreshAccessToken(for account: MailAccount) async throws -> String {
        guard let service = account.keychainService, !service.isEmpty else {
            throw ToolError("Mail account is missing a Keychain service.")
        }
        guard let clientID = account.clientID, !clientID.isEmpty else {
            throw ToolError("Mail account is missing a Microsoft client ID.")
        }
        guard let refreshToken = securityFind(service: service, account: refreshTokenKey), !refreshToken.isEmpty else {
            throw ToolError("\(account.email ?? "account") is not connected. Reconnect it in ASTRA.")
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "scope", value: defaultScopes)
        ]
        let body = components.percentEncodedQuery?.data(using: .utf8) ?? Data()

        var request = URLRequest(url: tokenEndpoint(for: account))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let details = String(data: data, encoding: .utf8) ?? ""
            throw ToolError("Microsoft token refresh failed: HTTP \(http.statusCode) \(details)")
        }

        let payload = dictionaryValue(try jsonObject(from: data))
        guard let accessToken = payload["access_token"] as? String, !accessToken.isEmpty else {
            throw ToolError("Microsoft token refresh did not return an access token.")
        }

        try securitySave(service: service, account: accessTokenKey, value: accessToken)
        if let refreshToken = payload["refresh_token"] as? String, !refreshToken.isEmpty {
            try securitySave(service: service, account: refreshTokenKey, value: refreshToken)
        }
        let expiresIn = payload["expires_in"] as? Int ?? 3600
        let expiresAt = String(Date().timeIntervalSince1970 + Double(expiresIn))
        try securitySave(service: service, account: expiresAtKey, value: expiresAt)
        return accessToken
    }

    private static func validAccessToken(for account: MailAccount) async throws -> String {
        guard let service = account.keychainService, !service.isEmpty else {
            throw ToolError("Mail account is missing a Keychain service.")
        }
        let token = securityFind(service: service, account: accessTokenKey)
        let expiresRaw = securityFind(service: service, account: expiresAtKey) ?? "0"
        let expiresAt = Double(expiresRaw) ?? 0
        if let token, !token.isEmpty, expiresAt - Date().timeIntervalSince1970 > 120 {
            return token
        }
        return try await refreshAccessToken(for: account)
    }

    private static func graphGet(
        account: MailAccount,
        path: String,
        query: [String: String] = [:],
        preferTextBody: Bool = false,
        consistencyLevelEventual: Bool = false
    ) async throws -> Any {
        let token = try await validAccessToken(for: account)
        var components = URLComponents(string: graphBase + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw ToolError("Could not build Microsoft Graph URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if preferTextBody {
            request.setValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
        }
        if consistencyLevelEventual {
            request.setValue("eventual", forHTTPHeaderField: "ConsistencyLevel")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let details = String(data: data, encoding: .utf8) ?? ""
            throw ToolError("Microsoft Graph failed: HTTP \(http.statusCode) \(details)")
        }
        return try jsonObject(from: data)
    }

    private static func cmdAccounts(_ args: [String]) throws {
        guard args.isEmpty else {
            throw ToolError("accounts does not accept arguments.")
        }
        let accounts = try loadAccounts().map { account in
            compactDictionary([
                ("email", account.email),
                ("tenantDomain", account.tenantDomain),
                ("name", account.name),
                ("displayName", account.displayName),
                ("channel", account.channel),
                ("connectorID", account.connectorID)
            ])
        }
        try printJSON(["accounts": accounts])
    }

    private static func cmdFolders(accountSelector: String?, limit: Int) async throws {
        let account = try selectedAccount(loadAccounts(), selector: accountSelector)
        let payload = try await graphGet(
            account: account,
            path: "/me/mailFolders",
            query: [
                "$top": String(clamp(limit, min: 1, max: 100)),
                "$select": "id,displayName,totalItemCount,unreadItemCount"
            ]
        )
        try printJSON(payload)
    }

    private static func cmdSearch(accountSelector: String?, query searchText: String, limit: Int) async throws {
        let account = try selectedAccount(loadAccounts(), selector: accountSelector)
        var query = [
            "$top": String(clamp(limit, min: 1, max: 25)),
            "$select": "id,subject,from,receivedDateTime,bodyPreview,hasAttachments,webLink"
        ]
        var consistency = false
        if searchText.isEmpty {
            query["$orderby"] = "receivedDateTime desc"
        } else {
            query["$search"] = "\"\(searchText)\""
            consistency = true
        }
        let payload = try await graphGet(
            account: account,
            path: "/me/messages",
            query: query,
            consistencyLevelEventual: consistency
        )
        try printJSON(payload)
    }

    private static func cmdGet(accountSelector: String?, messageID: String) async throws {
        let account = try selectedAccount(loadAccounts(), selector: accountSelector)
        let payload = try await graphGet(
            account: account,
            path: "/me/messages/\(percentEncodePathComponent(messageID))",
            query: [
                "$select": "id,subject,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,body,hasAttachments,webLink"
            ],
            preferTextBody: true
        )
        try printJSON(payload)
    }

    private static func parseAccountOptions(
        _ rawArgs: [String],
        defaultLimit: Int,
        includeQuery: Bool = false
    ) throws -> (account: String?, query: String, limit: Int) {
        var args = rawArgs
        var account: String?
        var query = ""
        var limit = defaultLimit
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--account":
                account = try requireValue(after: arg, in: &args)
            case "--limit":
                limit = parseInt(try requireValue(after: arg, in: &args), default: defaultLimit)
            case "--query" where includeQuery:
                query = try requireValue(after: arg, in: &args)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
        return (account, query, limit)
    }

    private static func parseGetOptions(_ rawArgs: [String]) throws -> (account: String?, messageID: String) {
        var args = rawArgs
        var account: String?
        var messageID: String?
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--account":
                account = try requireValue(after: arg, in: &args)
            case "--message-id":
                messageID = try requireValue(after: arg, in: &args)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
        guard let messageID, !messageID.isEmpty else {
            throw ToolError("get requires --message-id MESSAGE_ID.")
        }
        return (account, messageID)
    }
}
