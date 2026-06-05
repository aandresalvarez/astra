import Foundation

enum BrowserControlActionService {
    static func targetIdentifier(
        selector: String?,
        x: Double?,
        y: Double?,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) -> String {
        if let selector, !selector.isEmpty { return "selector:\(selector.hashValue)" }
        if let label, !label.isEmpty { return "label:\(label.lowercased().hashValue)" }
        if let role, !role.isEmpty { return "role:\(role.lowercased())" }
        if let text, !text.isEmpty { return "text:\(text.lowercased().hashValue)" }
        if let placeholder, !placeholder.isEmpty { return "placeholder:\(placeholder.lowercased().hashValue)" }
        if let testID, !testID.isEmpty { return "testid:\(testID.lowercased().hashValue)" }
        return "point:\(x ?? -1),\(y ?? -1)"
    }

    static func actionabilityWaitSummary(
        object: [String: Any],
        attempts: Int,
        stableBoundsSamples: Int,
        timedOut: Bool,
        started: Date,
        now: Date = Date()
    ) -> [String: Any] {
        let ok = boolValue(object["ok"])
        let signature = boundsSignature(object["bounds"])
        var summary: [String: Any] = [
            "ok": ok,
            "error": object["error"] as? String ?? "",
            "attempts": attempts,
            "elapsedMs": Int(now.timeIntervalSince(started) * 1_000),
            "timedOut": timedOut,
            "visible": boolValue(object["visible"]),
            "disabled": boolValue(object["disabled"]),
            "actionable": boolValue(object["actionable"]),
            "stableBounds": ok && (stableBoundsSamples >= 1 || signature.isEmpty),
            "stableBoundsSamples": stableBoundsSamples,
            "coveredBy": object["coveredBy"] as? String ?? "",
            "selector": object["selector"] as? String ?? "",
            "requestedSelector": object["requestedSelector"] as? String ?? "",
            "role": object["role"] as? String ?? "",
            "tag": object["tag"] as? String ?? ""
        ]
        if let bounds = object["bounds"] as? [String: Any] {
            summary["bounds"] = bounds
        }
        return summary
    }

    static func boundsSignature(_ value: Any?) -> String {
        guard let bounds = value as? [String: Any] else { return "" }
        let x = intValue(bounds["x"]) ?? 0
        let y = intValue(bounds["y"]) ?? 0
        let width = intValue(bounds["width"]) ?? 0
        let height = intValue(bounds["height"]) ?? 0
        return "\(x),\(y),\(width),\(height)"
    }

    static func isRetryableActionabilityError(_ error: String) -> Bool {
        [
            "selector_not_found",
            "target_not_found",
            "target_not_visible",
            "target_obscured",
            "target_outside_viewport"
        ].contains(error)
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
