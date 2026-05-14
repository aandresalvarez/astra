import Darwin
import Foundation

@main
struct AstraBrowserTool {
    static func main() async {
        do {
            let result = try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            print(result)
        } catch {
            fputs(errorJSON(error.localizedDescription) + "\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws -> String {
        var args = ArgumentCursor(arguments)
        guard let command = args.next() else {
            return usageJSON()
        }

        switch command.lowercased() {
        case "help", "--help", "-h":
            return usageJSON()
        case "health":
            let endpoint = try browserEndpoint()
            return try await request(endpoint: endpoint, method: "GET", path: "/health")
        case "actions":
            let endpoint = try browserEndpoint()
            return try await request(endpoint: endpoint, method: "GET", path: "/actions")
        case "trace":
            let endpoint = try browserEndpoint()
            return try await request(endpoint: endpoint, method: "GET", path: "/trace")
        case "benchmark":
            let endpoint = try browserEndpoint()
            return try await request(endpoint: endpoint, method: "GET", path: "/benchmark")
        case "analyze", "analyse":
            let endpoint = try browserEndpoint()
            var items: [URLQueryItem] = []
            if args.contains("--v2") {
                items.append(URLQueryItem(name: "v2", value: "true"))
            }
            if let version = args.value(after: "--version") ?? args.value(after: "--analysis-version") {
                items.append(URLQueryItem(name: "version", value: version))
            }
            if args.contains("--full") {
                items.append(URLQueryItem(name: "full", value: "true"))
            }
            if args.contains("--debug") {
                items.append(URLQueryItem(name: "debug", value: "true"))
            }
            if let limit = args.value(after: "--limit") {
                items.append(URLQueryItem(name: "limit", value: limit))
            }
            if let query = args.value(after: "--query") ?? args.value(after: "--label") ?? args.value(after: "--text") ?? args.remainingText() {
                items.append(URLQueryItem(name: "query", value: query))
            }
            return try await request(endpoint: endpoint, method: "GET", path: "/analyze", queryItems: items)
        case "preflight":
            let endpoint = try browserEndpoint()
            guard let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id"),
                  let controlID = args.value(after: "--control") ?? args.value(after: "--control-id") else {
                throw ToolError("preflight requires --analysis and --control")
            }
            let action = args.value(after: "--action") ?? args.value(after: "--kind") ?? "click"
            return try await request(endpoint: endpoint, method: "POST", path: "/preflight", object: [
                "analysisID": analysisID,
                "controlID": controlID,
                "action": action,
                "allowDangerous": args.contains("--dangerous")
            ])
        case "snapshot":
            let endpoint = try browserEndpoint()
            let mode = args.value(after: "--mode") ?? "summary"
            let query = args.value(after: "--query")
            let limit = args.value(after: "--limit")
            var items = [URLQueryItem(name: "mode", value: mode)]
            if let query, !query.isEmpty {
                items.append(URLQueryItem(name: "query", value: query))
            }
            if let limit, !limit.isEmpty {
                items.append(URLQueryItem(name: "limit", value: limit))
            }
            return try await request(endpoint: endpoint, method: "GET", path: "/snapshot", queryItems: items)
        case "page", "read":
            let endpoint = try browserEndpoint()
            let query = args.value(after: "--query")
            let limit = args.value(after: "--limit") ?? "2000"
            var items = [
                URLQueryItem(name: "mode", value: "text"),
                URLQueryItem(name: "limit", value: limit)
            ]
            if let query, !query.isEmpty {
                items.append(URLQueryItem(name: "query", value: query))
            }
            return try await request(endpoint: endpoint, method: "GET", path: "/snapshot", queryItems: items)
        case "navigate":
            let endpoint = try browserEndpoint()
            guard let url = args.next() ?? args.value(after: "--url") else {
                throw ToolError("navigate requires a URL or search phrase")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/navigate", object: ["url": url])
        case "open":
            let endpoint = try browserEndpoint()
            guard let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id"),
                  let controlID = args.value(after: "--control") ?? args.value(after: "--control-id") else {
                throw ToolError("open requires --analysis and --control")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/open", object: [
                "analysisID": analysisID,
                "controlID": controlID,
                "allowDangerous": args.contains("--dangerous")
            ])
        case "double-click", "doubleclick", "double_click":
            let endpoint = try browserEndpoint()
            let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id")
            let controlID = args.value(after: "--control") ?? args.value(after: "--control-id")
            let selector = args.value(after: "--selector")
            let label = args.value(after: "--label") ?? args.value(after: "--name")
            let role = args.value(after: "--role")
            let text = args.value(after: "--text")
            let placeholder = args.value(after: "--placeholder")
            let testID = args.value(after: "--testid") ?? args.value(after: "--test-id")
            let x = args.value(after: "--x").flatMap(Double.init)
            let y = args.value(after: "--y").flatMap(Double.init)
            guard (analysisID != nil && controlID != nil) || selector != nil || label != nil || role != nil || placeholder != nil || testID != nil || (x != nil && y != nil) else {
                throw ToolError("double-click requires --analysis/--control, --selector, --label, --role, --placeholder, --testid, or --x/--y")
            }
            var object: [String: Any] = ["allowDangerous": args.contains("--dangerous")]
            if let analysisID { object["analysisID"] = analysisID }
            if let controlID { object["controlID"] = controlID }
            if let selector { object["selector"] = selector }
            if let label { object["label"] = label }
            if let role { object["role"] = role }
            if let text { object["text"] = text }
            if let placeholder { object["placeholder"] = placeholder }
            if let testID { object["testID"] = testID }
            if let x { object["x"] = x }
            if let y { object["y"] = y }
            return try await request(endpoint: endpoint, method: "POST", path: "/doubleClick", object: object)
        case "click":
            let endpoint = try browserEndpoint()
            let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id")
            let controlID = args.value(after: "--control") ?? args.value(after: "--control-id")
            let selector = args.value(after: "--selector")
            let label = args.value(after: "--label") ?? args.value(after: "--name")
            let role = args.value(after: "--role")
            let text = args.value(after: "--text")
            let placeholder = args.value(after: "--placeholder")
            let testID = args.value(after: "--testid") ?? args.value(after: "--test-id")
            let x = args.value(after: "--x").flatMap(Double.init)
            let y = args.value(after: "--y").flatMap(Double.init)
            var object: [String: Any] = ["allowDangerous": args.contains("--dangerous")]
            if let analysisID { object["analysisID"] = analysisID }
            if let controlID { object["controlID"] = controlID }
            if let selector { object["selector"] = selector }
            if let label { object["label"] = label }
            if let role { object["role"] = role }
            if let text { object["text"] = text }
            if let placeholder { object["placeholder"] = placeholder }
            if let testID { object["testID"] = testID }
            if let x { object["x"] = x }
            if let y { object["y"] = y }
            return try await request(endpoint: endpoint, method: "POST", path: "/click", object: object)
        case "type", "fill":
            let endpoint = try browserEndpoint()
            let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id")
            let controlID = args.value(after: "--control") ?? args.value(after: "--control-id")
            let selector = args.value(after: "--selector")
            let label = args.value(after: "--label") ?? args.value(after: "--name")
            let role = args.value(after: "--role")
            let placeholder = args.value(after: "--placeholder")
            let testID = args.value(after: "--testid") ?? args.value(after: "--test-id")
            guard let text = args.value(after: "--text") ?? args.remainingText() else {
                throw ToolError("\(command) requires --text")
            }
            guard (analysisID != nil && controlID != nil) || selector != nil || label != nil || role != nil || placeholder != nil || testID != nil else {
                throw ToolError("\(command) requires --analysis/--control, --selector, --label, --role, --placeholder, or --testid")
            }
            var object: [String: Any] = [
                "text": text,
                "clear": !args.contains("--append"),
                "allowDangerous": args.contains("--dangerous")
            ]
            if let analysisID { object["analysisID"] = analysisID }
            if let controlID { object["controlID"] = controlID }
            if let selector { object["selector"] = selector }
            if let label { object["label"] = label }
            if let role { object["role"] = role }
            if let placeholder { object["placeholder"] = placeholder }
            if let testID { object["testID"] = testID }
            return try await request(endpoint: endpoint, method: "POST", path: command.lowercased() == "fill" ? "/fill" : "/type", object: object)
        case "set-value", "setvalue":
            let endpoint = try browserEndpoint()
            let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id")
            let controlID = args.value(after: "--control") ?? args.value(after: "--control-id")
            let selector = args.value(after: "--selector")
            let label = args.value(after: "--label") ?? args.value(after: "--name")
            let role = args.value(after: "--role")
            let placeholder = args.value(after: "--placeholder")
            let testID = args.value(after: "--testid") ?? args.value(after: "--test-id")
            guard let text = args.value(after: "--text") ?? args.remainingText() else {
                throw ToolError("set-value requires --text")
            }
            guard (analysisID != nil && controlID != nil) || selector != nil || label != nil || role != nil || placeholder != nil || testID != nil else {
                throw ToolError("set-value requires --analysis/--control, --selector, --label, --role, --placeholder, or --testid")
            }
            var object: [String: Any] = [
                "text": text,
                "allowDangerous": args.contains("--dangerous")
            ]
            if let analysisID { object["analysisID"] = analysisID }
            if let controlID { object["controlID"] = controlID }
            if let selector { object["selector"] = selector }
            if let label { object["label"] = label }
            if let role { object["role"] = role }
            if let placeholder { object["placeholder"] = placeholder }
            if let testID { object["testID"] = testID }
            return try await request(endpoint: endpoint, method: "POST", path: "/setValue", object: object)
        case "replace-text", "replacetext":
            let endpoint = try browserEndpoint()
            let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id")
            let controlID = args.value(after: "--control") ?? args.value(after: "--control-id")
            guard let find = args.value(after: "--find") ?? args.value(after: "--old"),
                  let replacement = args.value(after: "--with") ?? args.value(after: "--replacement") ?? args.value(after: "--text") else {
                throw ToolError("replace-text requires --find and --with")
            }
            var object: [String: Any] = [
                "find": find,
                "replacement": replacement,
                "all": !args.contains("--first"),
                "allowDangerous": args.contains("--dangerous")
            ]
            if let analysisID { object["analysisID"] = analysisID }
            if let controlID { object["controlID"] = controlID }
            if let selector = args.value(after: "--selector") {
                object["selector"] = selector
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/replaceText", object: object)
        case "find-control", "findcontrol", "locator":
            let endpoint = try browserEndpoint()
            guard let query = args.value(after: "--query")
                ?? args.value(after: "--label")
                ?? args.value(after: "--name")
                ?? args.value(after: "--text")
                ?? args.value(after: "--placeholder")
                ?? args.value(after: "--testid")
                ?? args.value(after: "--test-id")
                ?? args.remainingText() else {
                throw ToolError("\(command) requires --query or locator text")
            }
            var items = [URLQueryItem(name: "query", value: query)]
            if let role = args.value(after: "--role") {
                items.append(URLQueryItem(name: "role", value: role))
            }
            if let limit = args.value(after: "--limit") {
                items.append(URLQueryItem(name: "limit", value: limit))
            }
            return try await request(endpoint: endpoint, method: "GET", path: command.lowercased() == "locator" ? "/locator" : "/findControl", queryItems: items)
        case "click-control", "clickcontrol":
            let endpoint = try browserEndpoint()
            let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id")
            let controlID = args.value(after: "--control") ?? args.value(after: "--control-id")
            let label = args.value(after: "--label") ?? args.value(after: "--query") ?? args.remainingText()
            guard label != nil || (analysisID != nil && controlID != nil) else {
                throw ToolError("click-control requires --label or --analysis/--control")
            }
            var object: [String: Any] = [
                "allowDangerous": args.contains("--dangerous")
            ]
            if let label { object["label"] = label }
            if let analysisID { object["analysisID"] = analysisID }
            if let controlID { object["controlID"] = controlID }
            if let role = args.value(after: "--role") {
                object["role"] = role
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/clickControl", object: object)
        case "verify-text", "verifytext":
            let endpoint = try browserEndpoint()
            guard let text = args.value(after: "--text") ?? args.remainingText() else {
                throw ToolError("verify-text requires text")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/verifyText", object: [
                "text": text,
                "absent": args.contains("--absent")
            ])
        case "wait-saved", "waitsaved":
            let endpoint = try browserEndpoint()
            var object: [String: Any] = [:]
            if let timeout = args.value(after: "--timeout").flatMap(Double.init) {
                object["timeoutSeconds"] = timeout
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/waitSaved", object: object)
        case "google-find-replace", "googlefindreplace":
            let endpoint = try browserEndpoint()
            guard let find = args.value(after: "--find") ?? args.value(after: "--old"),
                  let replacement = args.value(after: "--with") ?? args.value(after: "--replacement") ?? args.value(after: "--text") else {
                throw ToolError("google-find-replace requires --find and --with")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/googleFindReplace", object: [
                "find": find,
                "replacement": replacement,
                "all": !args.contains("--first")
            ])
        case "google-docs-find", "googledocsfind":
            let endpoint = try browserEndpoint()
            guard let query = args.value(after: "--query") ?? args.value(after: "--text") ?? args.remainingText() else {
                throw ToolError("google-docs-find requires --query")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/googleDocsFind", object: [
                "query": query,
                "closeFindBar": !args.contains("--keep-open")
            ])
        case "google-docs-insert", "googledocsinsert":
            let endpoint = try browserEndpoint()
            let verify = args.value(after: "--verify")
            guard let text = args.value(after: "--text") ?? args.value(after: "--body") ?? args.remainingText() else {
                throw ToolError("google-docs-insert requires --text")
            }
            var object: [String: Any] = [
                "text": text,
                "waitSaved": !args.contains("--no-wait-saved")
            ]
            if let verify {
                object["verifyText"] = verify
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/googleDocsInsert", object: object)
        case "google-drive-open", "googledriveopen", "drive-open":
            let endpoint = try browserEndpoint()
            guard let name = args.value(after: "--name")
                ?? args.value(after: "--title")
                ?? args.value(after: "--text")
                ?? args.remainingText() else {
                throw ToolError("google-drive-open requires --name")
            }
            var object: [String: Any] = ["name": name]
            if let timeout = args.value(after: "--timeout").flatMap(Double.init) {
                object["timeoutSeconds"] = timeout
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/googleDriveOpen", object: object)
        case "act":
            let endpoint = try browserEndpoint()
            var object: [String: Any] = [:]
            if let analysisID = args.value(after: "--analysis") ?? args.value(after: "--analysis-id") {
                object["analysisID"] = analysisID
            }
            if let controlID = args.value(after: "--control") ?? args.value(after: "--control-id") {
                object["controlID"] = controlID
            }
            if let analysisID = args.value(after: "--set-analysis") ?? args.value(after: "--set-analysis-id") {
                object["setAnalysisID"] = analysisID
            }
            if let controlID = args.value(after: "--set-control") ?? args.value(after: "--set-control-id") {
                object["setControlID"] = controlID
            }
            if let analysisID = args.value(after: "--click-analysis") ?? args.value(after: "--click-analysis-id") {
                object["clickAnalysisID"] = analysisID
            }
            if let controlID = args.value(after: "--click-control") ?? args.value(after: "--click-control-id") {
                object["clickControlID"] = controlID
            }
            if let find = args.value(after: "--find") {
                object["find"] = find
            }
            if let set = args.value(after: "--set") ?? args.value(after: "--text") {
                object["set"] = set
            }
            if let role = args.value(after: "--role") {
                object["role"] = role
            }
            if let click = args.value(after: "--click") {
                object["click"] = click
            }
            if let clickRole = args.value(after: "--click-role") {
                object["clickRole"] = clickRole
            }
            if args.contains("--dangerous") {
                object["allowDangerous"] = true
            }
            if args.contains("--wait-saved") {
                object["waitSaved"] = true
            }
            if let verify = args.value(after: "--verify") {
                object["verify"] = verify
            }
            if let absent = args.value(after: "--absent") {
                object["absent"] = absent
            }
            if let timeout = args.value(after: "--timeout").flatMap(Double.init) {
                object["timeoutSeconds"] = timeout
            }
            guard !object.isEmpty else {
                throw ToolError("act requires at least one of --find/--set, --click, --wait-saved, --verify, or --absent")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/act", object: object)
        case "keypress":
            let endpoint = try browserEndpoint()
            guard let key = args.value(after: "--key") ?? args.next() else {
                throw ToolError("keypress requires --key")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/keypress", object: [
                "key": key,
                "modifiers": args.values(after: "--mod") + args.values(after: "--modifier")
            ])
        case "text", "insert-text":
            let endpoint = try browserEndpoint()
            guard let text = args.value(after: "--text") ?? args.remainingText() else {
                throw ToolError("text requires text content")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/text", object: ["text": text])
        case "wait-text":
            let endpoint = try browserEndpoint()
            let timeout = args.value(after: "--timeout").flatMap(Double.init) ?? 5
            guard let text = args.value(after: "--text") ?? args.remainingText() else {
                throw ToolError("wait-text requires text content")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/waitForText", object: [
                "text": text,
                "timeoutSeconds": timeout
            ])
        case "wait-selector":
            let endpoint = try browserEndpoint()
            let timeout = args.value(after: "--timeout").flatMap(Double.init) ?? 5
            guard let selector = args.value(after: "--selector") ?? args.next() else {
                throw ToolError("wait-selector requires a selector")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/waitForSelector", object: [
                "selector": selector,
                "timeoutSeconds": timeout
            ])
        case "batch":
            let endpoint = try browserEndpoint()
            let json = args.value(after: "--json")
                ?? args.value(after: "--file").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                ?? args.remainingText()
            guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("batch requires --json, --file, or a JSON argument")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/batch", rawJSON: json)
        default:
            throw ToolError("unknown command: \(command)")
        }
    }

    private static func browserEndpoint() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["ASTRA_BROWSER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw) else {
            throw ToolError("ASTRA_BROWSER_URL is not set. Open Shelf browser and enable Agent control.")
        }
        return url
    }

    private static func request(
        endpoint: URL,
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        object: [String: Any]? = nil,
        rawJSON: String? = nil
    ) async throws -> String {
        var components = URLComponents(url: endpoint.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw ToolError("invalid bridge URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 35
        if let object {
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let rawJSON {
            request.httpBody = Data(rawJSON.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else {
            throw ToolError(body.isEmpty ? "bridge returned HTTP \(status)" : body)
        }
        return body
    }

    private static func usageJSON() -> String {
        let usage: [String: Any] = [
                "ok": true,
                "usage": [
                "astra-browser health",
                "astra-browser analyze [--v2|--version v1] [--query text] [--full] [--debug] [--limit n]",
                "astra-browser trace",
                "astra-browser benchmark",
                "astra-browser preflight --analysis ana_... --control ctl_... --action click",
                "astra-browser page [--query text] [--limit n]",
                "astra-browser snapshot --mode summary|text|controls|full [--query text] [--limit n]",
                "astra-browser locator --role button --name Save",
                "astra-browser open --analysis ana_... --control ctl_...",
                "astra-browser double-click --analysis ana_... --control ctl_...",
                "astra-browser click --analysis ana_... --control ctl_...",
                "astra-browser click --selector '#id'",
                "astra-browser click --role button --name Save",
                "astra-browser click --x 0.5 --y 0.5",
                "astra-browser fill --analysis ana_... --control ctl_... --text 'user@example.com'",
                "astra-browser fill --label Email --text 'user@example.com'",
                "astra-browser set-value --analysis ana_... --control ctl_... --text 'replacement text'",
                "astra-browser set-value --selector '#field' --text 'replacement text'",
                "astra-browser replace-text --find 'old text' --with 'new text' [--selector '#field']",
                "astra-browser find-control --label 'Replace all'",
                "astra-browser click-control --label 'Replace all'",
                "astra-browser verify-text 'expected text' [--absent]",
                "astra-browser wait-saved --timeout 8",
                "astra-browser google-find-replace --find 'old text' --with 'new text'",
                "astra-browser google-docs-find --query 'unique phrase'",
                "astra-browser google-docs-insert --verify 'unique phrase' --text 'content to insert'",
                "astra-browser google-drive-open --name 'Untitled document'  # requires Google Drive Browser capability",
                "astra-browser act --find 'Replace with' --set 'new text' --click 'Replace all' --wait-saved --verify 'new text'",
                "astra-browser keypress --key h --mod command --mod shift",
                "astra-browser text 'replacement text'",
                "astra-browser wait-text 'Saved' --timeout 5",
                "astra-browser batch '{\"actions\":[...]}'"
            ]
        ]
        return (try? jsonString(usage)) ?? #"{"ok":true}"#
    }

    private static func errorJSON(_ message: String) -> String {
        (try? jsonString(["ok": false, "error": message])) ?? #"{"ok":false}"#
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
    }

    private struct ToolError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }
}

private struct ArgumentCursor {
    private let arguments: [String]
    private var consumed: Set<Int> = []
    private var cursor = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> String? {
        while cursor < arguments.count {
            defer { cursor += 1 }
            guard !consumed.contains(cursor) else { continue }
            consumed.insert(cursor)
            return arguments[cursor]
        }
        return nil
    }

    mutating func contains(_ flag: String) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        consumed.insert(index)
        return true
    }

    mutating func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        consumed.insert(index)
        consumed.insert(index + 1)
        return arguments[index + 1]
    }

    mutating func values(after flag: String) -> [String] {
        var values: [String] = []
        for index in arguments.indices where arguments[index] == flag && arguments.indices.contains(index + 1) {
            consumed.insert(index)
            consumed.insert(index + 1)
            values.append(arguments[index + 1])
        }
        return values
    }

    mutating func remainingText() -> String? {
        let rest = arguments.indices
            .filter { !consumed.contains($0) }
            .map { arguments[$0] }
            .filter { !$0.hasPrefix("--") }
        for index in arguments.indices where !consumed.contains(index) {
            consumed.insert(index)
        }
        let text = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
