import Foundation

struct BrowserFlightPageSnapshot: Equatable {
    let url: String
    let title: String
    let pageType: String

    init(url: String, title: String, pageType: String) {
        self.url = Self.redactedURLString(url)
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.pageType = pageType
    }

    var host: String {
        URL(string: url)?.host?.lowercased() ?? ""
    }

    var jsonObject: [String: Any] {
        [
            "url": url,
            "host": host,
            "title": title,
            "pageType": pageType
        ]
    }

    static func redactedURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var components = URLComponents(string: trimmed) else {
            return String(trimmed.prefix(200))
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return String((components.string ?? trimmed).prefix(200))
    }
}

struct BrowserFlightRecorder {
    private(set) var totalSteps = 0
    private var entries: [[String: Any]] = []
    private let retainedLimit: Int

    init(retainedLimit: Int = 40) {
        self.retainedLimit = max(1, retainedLimit)
    }

    mutating func reset() {
        totalSteps = 0
        entries = []
    }

    mutating func record(
        request: BrowserBridgeRequest,
        statusCode: Int,
        before: BrowserFlightPageSnapshot,
        after: BrowserFlightPageSnapshot,
        duration: TimeInterval,
        result: [String: Any]?,
        runGuard: [String: Any]? = nil,
        lastBrowserTraceID: String? = nil,
        debugCapture: [String: Any]? = nil
    ) -> [String: Any] {
        totalSteps += 1
        var entry: [String: Any] = [
            "id": "bflight_\(UUID().uuidString.prefix(8).lowercased())",
            "sequence": totalSteps,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "command": "\(request.method) \(request.path)",
            "method": request.method,
            "path": request.path,
            "request": Self.requestSummary(for: request),
            "statusCode": statusCode,
            "durationMs": Int((duration * 1_000).rounded()),
            "before": before.jsonObject,
            "after": after.jsonObject,
            "urlChanged": before.url != after.url,
            "hostChanged": before.host != after.host
        ]

        if let result {
            entry["ok"] = Self.boolValue(result["ok"])
            if let error = result["error"] as? String, !error.isEmpty {
                entry["error"] = error
            }
            if let message = result["message"] as? String, !message.isEmpty {
                entry["message"] = String(message.prefix(240))
            }
            if let outcome = result["outcome"] as? [String: Any] {
                entry["goalSatisfied"] = Self.boolValue(outcome["goalSatisfied"])
                entry["outcomeVerified"] = Self.boolValue(outcome["outcomeVerified"])
                entry["observedOutcome"] = outcome["observedOutcome"] as? String ?? ""
                entry["expectedOutcome"] = outcome["expectedOutcome"] as? String ?? ""
                entry["outcomeReason"] = outcome["outcomeReason"] as? String ?? ""
            } else {
                entry["goalSatisfied"] = Self.boolValue(result["goalSatisfied"])
                entry["outcomeVerified"] = Self.boolValue(result["outcomeVerified"])
                if let observedOutcome = result["observedOutcome"] as? String {
                    entry["observedOutcome"] = observedOutcome
                }
            }
            if let loopWarning = result["loopWarning"] as? String {
                entry["loopWarning"] = loopWarning
            }
            if let strategyHint = result["strategyHint"] as? String {
                entry["strategyHint"] = strategyHint
            }
        } else {
            entry["ok"] = statusCode < 400
        }

        if let runGuard {
            entry["runGuard"] = runGuard
        }
        if let lastBrowserTraceID, !lastBrowserTraceID.isEmpty {
            entry["browserTraceID"] = lastBrowserTraceID
        }
        if let debugCapture {
            entry["debugCapture"] = debugCapture
        }

        entries.append(entry)
        if entries.count > retainedLimit {
            entries.removeFirst(entries.count - retainedLimit)
        }
        return entry
    }

    func snapshot() -> [String: Any] {
        var object: [String: Any] = [
            "ok": true,
            "totalSteps": totalSteps,
            "retainedSteps": entries.count,
            "retainedLimit": retainedLimit,
            "firstSteps": Array(entries.prefix(3)),
            "recentSteps": Array(entries.suffix(12))
        ]
        if let last = entries.last {
            object["lastStep"] = last
            if let after = last["after"] as? [String: Any] {
                object["finalURL"] = after["url"] as? String ?? ""
                object["finalTitle"] = after["title"] as? String ?? ""
                object["finalPageType"] = after["pageType"] as? String ?? ""
            }
            if let error = last["error"] as? String, !error.isEmpty {
                object["lastError"] = error
            }
        }
        return object
    }

    static func requestSummary(for request: BrowserBridgeRequest) -> [String: Any] {
        var summary: [String: Any] = [:]
        if !request.queryItems.isEmpty {
            summary["queryKeys"] = request.queryItems.keys.sorted()
            for key in ["mode", "version", "v2", "full", "debug", "limit", "role"] {
                if let value = request.queryItems[key] {
                    summary[key] = String(value.prefix(80))
                }
            }
            if let query = request.queryItems["query"] {
                summary["queryLength"] = query.count
                summary["queryHash"] = stableHash(query)
            }
        }

        guard !request.body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return summary
        }
        summary["bodyKeys"] = object.keys.sorted()
        for key in ["analysisID", "controlID", "action", "key", "role", "allowDangerous", "all", "absent", "clear", "waitSaved", "closeFindBar"] {
            if let value = object[key] {
                summary[key] = value
            }
        }
        for key in ["timeoutSeconds", "intervalMilliseconds", "x", "y"] {
            if let value = object[key] {
                summary[key] = value
            }
        }
        if let modifiers = object["modifiers"] as? [String] {
            summary["modifiers"] = modifiers
        }
        if let url = object["url"] as? String {
            summary["navigationTarget"] = BrowserFlightPageSnapshot.redactedURLString(url)
            summary["navigationTargetKind"] = URL(string: url)?.scheme == nil ? "text" : "url"
        }
        for key in ["text", "replacement", "find", "query", "name", "verifyText", "selector", "label", "placeholder", "testID"] {
            if let value = object[key] as? String, !value.isEmpty {
                summary["\(key)Length"] = value.count
                summary["\(key)Hash"] = stableHash(value)
            }
        }
        return summary
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return string.lowercased() == "true" }
        return false
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
