import Foundation
import Darwin
import MailToolSupport

private let defaultTenant = ProcessInfo.processInfo.environment["ASTRA_GRAPH_MAIL_TENANT"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "stanfordhealthcare.org"
private let defaultAccount = ProcessInfo.processInfo.environment["ASTRA_GRAPH_MAIL_ACCOUNT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
private let defaultDomain = (ProcessInfo.processInfo.environment["ASTRA_GRAPH_MAIL_DOMAIN"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "stanfordhealthcare.org")
    .lowercased()
    .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
private let powershellPath = ProcessInfo.processInfo.environment["ASTRA_GRAPH_MAIL_PWSH"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "pwsh"
private let scopes = "\"User.Read\",\"Mail.Read\""

private struct GraphOptions {
    var tenant = defaultTenant
    var account = defaultAccount
    var domain = defaultDomain
}

@main
struct StanfordGraphMailTool {
    static func main() {
        let code: Int32
        do {
            try run()
            code = 0
        } catch let error as DecodingError {
            code = exitWithError(prefix: "stanford-graph-mail", error: ToolError("invalid Microsoft Graph response: \(error)"))
        } catch {
            code = exitWithError(prefix: "stanford-graph-mail", error: error)
        }
        if code != 0 {
            Darwin.exit(code)
        }
    }

    private static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            throw ToolError(usage())
        }

        var options = GraphOptions()
        try parseGlobalOptions(args: &args, options: &options)
        guard !args.isEmpty else {
            throw ToolError(usage())
        }

        let command = args.removeFirst()
        switch command {
        case "login":
            try requireNoExtraArgs(args)
            try cmdLogin(options)
        case "logout":
            try requireNoExtraArgs(args)
            try cmdLogout()
        case "accounts":
            try requireNoExtraArgs(args)
            try cmdAccounts(options)
        case "folders":
            let limit = try parseLimit(args, defaultLimit: 50)
            try cmdFolders(options, limit: limit)
        case "search":
            let parsed = try parseSearch(args)
            try cmdSearch(options, query: parsed.query, limit: parsed.limit)
        case "get":
            let messageID = try parseGet(args)
            try cmdGet(options, messageID: messageID)
        case "-h", "--help", "help":
            print(usage())
        default:
            throw ToolError("Unknown command \(command).\n\n\(usage())")
        }
    }

    private static func usage() -> String {
        """
        stanford-graph-mail - read-only Microsoft Graph mail helper via Graph PowerShell.

        Commands:
          stanford-graph-mail login
          stanford-graph-mail logout
          stanford-graph-mail accounts
          stanford-graph-mail folders
          stanford-graph-mail search --query "term" [--limit 10]
          stanford-graph-mail get --message-id MESSAGE_ID
        """
    }

    private static func parseGlobalOptions(args: inout [String], options: inout GraphOptions) throws {
        var parsed: [String] = []
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--tenant":
                options.tenant = try requireValue(after: arg, in: &args)
            case "--account":
                options.account = try requireValue(after: arg, in: &args)
            case "--domain":
                options.domain = try requireValue(after: arg, in: &args)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            default:
                parsed.append(arg)
                parsed.append(contentsOf: args)
                args = parsed
                return
            }
        }
        args = parsed
    }

    private static func requireNoExtraArgs(_ args: [String]) throws {
        guard args.isEmpty else {
            throw ToolError("Unexpected arguments: \(args.joined(separator: " ")).")
        }
    }

    private static func psQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func graphURL(_ path: String, query: [String: String] = [:]) throws -> String {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0" + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw ToolError("Could not build Microsoft Graph URL.")
        }
        return url.absoluteString
    }

    private static func runPowerShell(_ script: String, timeout: TimeInterval = 60) throws -> String {
        do {
            let result = try runProcess(
                powershellPath,
                arguments: ["-NoProfile", "-Command", script],
                timeout: timeout,
                timeoutMessage: "Microsoft Graph PowerShell did not return in time. Run `stanford-graph-mail login` first and complete browser sign-in."
            )
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? "exit \(result.exitCode)"
                if result.exitCode == 127 ||
                    detail.localizedCaseInsensitiveContains("no such file") ||
                    detail.localizedCaseInsensitiveContains("not found") {
                    throw ToolError("PowerShell is not installed. Install with: brew install powershell")
                }
                throw ToolError(detail)
            }
            return result.stdout
        } catch CocoaError.fileNoSuchFile {
            throw ToolError("PowerShell is not installed. Install with: brew install powershell")
        } catch let error as POSIXError where error.code == .ENOENT {
            throw ToolError("PowerShell is not installed. Install with: brew install powershell")
        }
    }

    private static func graphGet(
        tenant: String,
        url: String,
        preferTextBody: Bool = false,
        consistencyLevelEventual: Bool = false
    ) throws -> Any {
        var headerLines: [String] = []
        if preferTextBody {
            headerLines.append(#"$headers['Prefer'] = 'outlook.body-content-type="text"'"#)
        }
        if consistencyLevelEventual {
            headerLines.append(#"$headers['ConsistencyLevel'] = 'eventual'"#)
        }
        let headerScript = headerLines.joined(separator: "\n")
        let script = """
        $ErrorActionPreference = 'Stop'
        Import-Module Microsoft.Graph.Authentication
        Connect-MgGraph -TenantId \(psQuote(tenant)) -Scopes \(scopes) -NoWelcome | Out-Null
        $headers = @{}
        \(headerScript)
        if ($headers.Count -gt 0) {
          $result = Invoke-MgGraphRequest -Method GET -Uri \(psQuote(url)) -Headers $headers
        } else {
          $result = Invoke-MgGraphRequest -Method GET -Uri \(psQuote(url))
        }
        $result | ConvertTo-Json -Depth 32 -Compress
        """
        let output = try runPowerShell(script, timeout: 75).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw ToolError("Microsoft Graph returned no output.")
        }
        return try jsonObject(from: output)
    }

    private static func currentAccount(_ tenant: String) throws -> [String: Any] {
        try dictionaryValue(graphGet(
            tenant: tenant,
            url: graphURL("/me", query: ["$select": "id,displayName,userPrincipalName,mail"])
        ))
    }

    private static func accountLabel(_ payload: [String: Any]) -> String {
        (payload["mail"] as? String)?.nilIfEmpty
            ?? (payload["userPrincipalName"] as? String)?.nilIfEmpty
            ?? (payload["displayName"] as? String)?.nilIfEmpty
            ?? "unknown account"
    }

    private static func accountAliases(_ payload: [String: Any]) -> Set<String> {
        Set([
            payload["mail"] as? String,
            payload["userPrincipalName"] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty })
    }

    @discardableResult
    private static func validateAccount(_ options: GraphOptions, payload provided: [String: Any]? = nil) throws -> [String: Any] {
        let payload = try provided ?? currentAccount(options.tenant)
        let aliases = accountAliases(payload)
        if !options.domain.isEmpty, !aliases.contains(where: { $0.hasSuffix("@\(options.domain)") }) {
            throw ToolError(
                "Signed-in Graph account is '\(accountLabel(payload))', not an @\(options.domain) mailbox. " +
                "Run `stanford-graph-mail logout`, then run `stanford-graph-mail login` with your Stanford Health Care account."
            )
        }
        if !options.account.isEmpty {
            let requested = options.account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !aliases.contains(requested) {
                throw ToolError(
                    "Signed-in Graph account is '\(accountLabel(payload))', not '\(options.account)'. " +
                    "Run `stanford-graph-mail logout`, then run `stanford-graph-mail login` again."
                )
            }
        }
        return payload
    }

    private static func cmdLogin(_ options: GraphOptions) throws {
        let payload = try validateAccount(options, payload: currentAccount(options.tenant))
        try printJSON([
            "account": compactDictionary([
                ("displayName", payload["displayName"] as? String),
                ("mail", payload["mail"] as? String),
                ("userPrincipalName", payload["userPrincipalName"] as? String),
                ("tenant", options.tenant)
            ]),
            "status": "signed-in"
        ])
    }

    private static func cmdLogout() throws {
        let script = """
        $ErrorActionPreference = 'Stop'
        Import-Module Microsoft.Graph.Authentication
        try {
          Connect-MgGraph -Scopes "User.Read" -NoWelcome | Out-Null
        } catch {
        }
        Disconnect-MgGraph | Out-Null
        """
        _ = try runPowerShell(script, timeout: 30)
        try printJSON(["status": "signed-out"])
    }

    private static func cmdAccounts(_ options: GraphOptions) throws {
        let payload = try validateAccount(options, payload: currentAccount(options.tenant))
        try printJSON([
            "accounts": [
                compactDictionary([
                    ("displayName", payload["displayName"] as? String),
                    ("id", payload["id"] as? String),
                    ("mail", payload["mail"] as? String),
                    ("tenant", options.tenant),
                    ("userPrincipalName", payload["userPrincipalName"] as? String)
                ])
            ]
        ])
    }

    private static func cmdFolders(_ options: GraphOptions, limit: Int) throws {
        try validateAccount(options)
        let url = try graphURL("/me/mailFolders", query: [
            "$top": String(clamp(limit, min: 1, max: 100)),
            "$select": "id,displayName,totalItemCount,unreadItemCount"
        ])
        try printJSON(graphGet(tenant: options.tenant, url: url))
    }

    private static func cmdSearch(_ options: GraphOptions, query searchText: String, limit: Int) throws {
        try validateAccount(options)
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
        try printJSON(graphGet(
            tenant: options.tenant,
            url: graphURL("/me/messages", query: query),
            consistencyLevelEventual: consistency
        ))
    }

    private static func cmdGet(_ options: GraphOptions, messageID: String) throws {
        try validateAccount(options)
        try printJSON(graphGet(
            tenant: options.tenant,
            url: graphURL(
                "/me/messages/\(percentEncodePathComponent(messageID))",
                query: [
                    "$select": "id,subject,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,body,hasAttachments,webLink"
                ]
            ),
            preferTextBody: true
        ))
    }

    private static func parseLimit(_ rawArgs: [String], defaultLimit: Int) throws -> Int {
        var args = rawArgs
        var limit = defaultLimit
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--limit":
                limit = parseInt(try requireValue(after: arg, in: &args), default: defaultLimit)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
        return limit
    }

    private static func parseSearch(_ rawArgs: [String]) throws -> (query: String, limit: Int) {
        var args = rawArgs
        var query = ""
        var limit = 10
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--query":
                query = try requireValue(after: arg, in: &args)
            case "--limit":
                limit = parseInt(try requireValue(after: arg, in: &args), default: 10)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
        return (query, limit)
    }

    private static func parseGet(_ rawArgs: [String]) throws -> String {
        var args = rawArgs
        var messageID: String?
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--message-id":
                messageID = try requireValue(after: arg, in: &args)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
        guard let messageID, !messageID.isEmpty else {
            throw ToolError("get requires --message-id MESSAGE_ID.")
        }
        return messageID
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
