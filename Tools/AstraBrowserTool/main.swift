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
        case "navigate":
            let endpoint = try browserEndpoint()
            guard let url = args.next() ?? args.value(after: "--url") else {
                throw ToolError("navigate requires a URL or search phrase")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/navigate", object: ["url": url])
        case "click":
            let endpoint = try browserEndpoint()
            let selector = args.value(after: "--selector")
            let x = args.value(after: "--x").flatMap(Double.init)
            let y = args.value(after: "--y").flatMap(Double.init)
            var object: [String: Any] = ["allowDangerous": args.contains("--dangerous")]
            if let selector { object["selector"] = selector }
            if let x { object["x"] = x }
            if let y { object["y"] = y }
            return try await request(endpoint: endpoint, method: "POST", path: "/click", object: object)
        case "type":
            let endpoint = try browserEndpoint()
            guard let selector = args.value(after: "--selector"),
                  let text = args.value(after: "--text") ?? args.remainingText() else {
                throw ToolError("type requires --selector and --text")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/type", object: [
                "selector": selector,
                "text": text,
                "clear": !args.contains("--append")
            ])
        case "set-value", "setvalue":
            let endpoint = try browserEndpoint()
            guard let selector = args.value(after: "--selector"),
                  let text = args.value(after: "--text") ?? args.remainingText() else {
                throw ToolError("set-value requires --selector and --text")
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/setValue", object: [
                "selector": selector,
                "text": text
            ])
        case "replace-text", "replacetext":
            let endpoint = try browserEndpoint()
            guard let find = args.value(after: "--find") ?? args.value(after: "--old"),
                  let replacement = args.value(after: "--with") ?? args.value(after: "--replacement") ?? args.value(after: "--text") else {
                throw ToolError("replace-text requires --find and --with")
            }
            var object: [String: Any] = [
                "find": find,
                "replacement": replacement,
                "all": !args.contains("--first")
            ]
            if let selector = args.value(after: "--selector") {
                object["selector"] = selector
            }
            return try await request(endpoint: endpoint, method: "POST", path: "/replaceText", object: object)
        case "find-control", "findcontrol":
            let endpoint = try browserEndpoint()
            guard let query = args.value(after: "--query") ?? args.value(after: "--label") ?? args.remainingText() else {
                throw ToolError("find-control requires --query or label text")
            }
            var items = [URLQueryItem(name: "query", value: query)]
            if let role = args.value(after: "--role") {
                items.append(URLQueryItem(name: "role", value: role))
            }
            if let limit = args.value(after: "--limit") {
                items.append(URLQueryItem(name: "limit", value: limit))
            }
            return try await request(endpoint: endpoint, method: "GET", path: "/findControl", queryItems: items)
        case "click-control", "clickcontrol":
            let endpoint = try browserEndpoint()
            guard let label = args.value(after: "--label") ?? args.value(after: "--query") ?? args.remainingText() else {
                throw ToolError("click-control requires --label or label text")
            }
            var object: [String: Any] = [
                "label": label,
                "allowDangerous": args.contains("--dangerous")
            ]
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
        case "act":
            let endpoint = try browserEndpoint()
            var object: [String: Any] = [:]
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
                "astra-browser snapshot --mode summary|text|controls|full [--query text] [--limit n]",
                "astra-browser click --selector '#id'",
                "astra-browser click --x 0.5 --y 0.5",
                "astra-browser set-value --selector '#field' --text 'replacement text'",
                "astra-browser replace-text --find 'old text' --with 'new text' [--selector '#field']",
                "astra-browser find-control --label 'Replace all'",
                "astra-browser click-control --label 'Replace all'",
                "astra-browser verify-text 'expected text' [--absent]",
                "astra-browser wait-saved --timeout 8",
                "astra-browser google-find-replace --find 'old text' --with 'new text'",
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
