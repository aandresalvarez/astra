import Foundation

enum BrowserSnapshotMode: String {
    case full
    case summary
    case text
    case controls
}

enum BrowserPageSnapshotService {
    static func compactSnapshot(json: String, mode: BrowserSnapshotMode, query: String?, limit: Int?) throws -> String {
        let snapshot = BrowserSensitiveInputRedactionPolicy.redactSnapshotObject(try jsonObject(from: json))
        let object = snapshot.object
        let queryText = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let controls = object["controls"] as? [[String: Any]] ?? []
        let filteredControls = filteredControls(controls, query: queryText)

        var compact: [String: Any] = [
            "ok": boolValue(object["ok"]),
            "url": object["url"] as? String ?? "",
            "title": object["title"] as? String ?? ""
        ]

        if let viewport = object["viewport"] {
            compact["viewport"] = viewport
        }
        if let focused = object["focusedElement"] {
            compact["focusedElement"] = focused
        }

        switch mode {
        case .full:
            return snapshot.didRedact ? try jsonString(object) : json
        case .text:
            let text = object["text"] as? String ?? ""
            compact["text"] = String(text.prefix(max(0, limit ?? 1_500)))
            if let queryText, !queryText.isEmpty {
                compact["matches"] = textMatches(in: text, query: queryText, limit: limit ?? 8)
            }
        case .controls:
            compact["controlCount"] = controls.count
            compact["controls"] = Array(filteredControls.prefix(max(1, limit ?? 40)))
        case .summary:
            let text = object["text"] as? String ?? ""
            compact["text"] = String(text.prefix(max(0, limit ?? 1_200)))
            compact["controlCount"] = controls.count
            compact["controls"] = Array(filteredControls.prefix(20))
            if let queryText, !queryText.isEmpty {
                compact["matches"] = textMatches(in: text, query: queryText, limit: 5)
            }
        }

        return try jsonString(compact)
    }

    private static func filteredControls(_ controls: [[String: Any]], query: String?) -> [[String: Any]] {
        guard let query, !query.isEmpty else { return controls }
        let lowerQuery = query.lowercased()
        return controls.filter { control in
            ["selector", "label", "value", "role", "type", "href"].contains { key in
                (control[key] as? String)?.lowercased().contains(lowerQuery) == true
            }
        }
    }

    private static func textMatches(in text: String, query: String, limit: Int) -> [[String: Any]] {
        guard !query.isEmpty else { return [] }
        var matches: [[String: Any]] = []
        var searchStart = text.startIndex
        while matches.count < max(1, limit),
              let range = text.range(of: query, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let lowerBound = text.index(range.lowerBound, offsetBy: -120, limitedBy: text.startIndex) ?? text.startIndex
            let upperBound = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
            matches.append([
                "index": text.distance(from: text.startIndex, to: range.lowerBound),
                "snippet": String(text[lowerBound..<upperBound])
            ])
            searchStart = range.upperBound
        }
        return matches
    }

    private static func jsonObject(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? #"{"ok":false,"error":"encoding_failed"}"#
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
