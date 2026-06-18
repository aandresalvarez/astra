import Foundation

enum BrowserAutomationEnginePublicState {
    static func controlledBrowser(
        isRunning: Bool,
        runState: String,
        statusMessage: String,
        hasDebugPort: Bool,
        hasProcessID: Bool,
        lastErrorMessage: String?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "running": isRunning,
            "state": runState,
            "status": statusMessage,
            "profile": "astra-managed",
            "debugEndpoint": hasDebugPort ? "internal" : "unavailable",
            "process": hasProcessID ? "running" : "unavailable",
            "rawDebugEndpointExposed": false
        ]
        if let lastErrorMessage, !lastErrorMessage.isEmpty {
            object["lastError"] = lastErrorMessage
        }
        return object
    }
}

enum BrowserAutomationTraceEvidence {
    static func settlementEvidence(from result: [String: Any]) -> [String: Any]? {
        guard let settlement = result["cdpSettlement"] as? [String: Any] else {
            return nil
        }
        let signals = stringArray(settlement["signals"])
        let errors = stringArray(settlement["errors"])
        var object: [String: Any] = [
            "settled": bool(settlement["settled"]),
            "signalCount": signals.count,
            "errorCount": errors.count,
            "signals": signals,
            "errors": errors
        ]
        if let elapsedMs = int(settlement["elapsedMs"]) {
            object["elapsedMs"] = elapsedMs
        }
        if let action = settlement["action"] as? String, !action.isEmpty {
            object["action"] = action
        }
        if let engine = settlement["engine"] as? String, !engine.isEmpty {
            object["engine"] = engine
        }
        return object
    }

    static func settlementFailureReason(from result: [String: Any]) -> String? {
        guard let evidence = settlementEvidence(from: result) else { return nil }
        guard bool(evidence["settled"]) == false else { return nil }
        let errors = stringArray(evidence["errors"])
        if errors.isEmpty {
            return "The controlled browser did not report a settled action."
        }
        return "The controlled browser reported a CDP settlement failure: \(errors.joined(separator: ", "))."
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap { item in
                if let string = item as? String { return string }
                if let number = item as? NSNumber { return number.stringValue }
                return nil
            }
        }
        return []
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["true", "yes", "1"].contains(string.lowercased())
        }
        return false
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
