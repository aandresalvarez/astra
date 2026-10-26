import Foundation

struct ControlledBrowserCDPCapabilityReport: Equatable {
    let browser: String
    let protocolVersion: String
    let domains: [String: Bool]
    let errors: [String: String]

    var jsonObject: [String: Any] {
        [
            "browser": browser,
            "protocolVersion": protocolVersion,
            "domains": domains,
            "errors": errors
        ]
    }
}

enum ControlledBrowserCDPDiagnosticsFormatter {
    static func diagnosticsObject(
        url: String,
        title: String,
        events: [[String: Any]],
        capabilities: ControlledBrowserCDPCapabilityReport
    ) -> [String: Any] {
        [
            "ok": true,
            "captureMode": "cdp_event_stream",
            "url": url,
            "title": title,
            "capabilities": capabilities.jsonObject,
            "consoleEvents": consoleEvents(from: events),
            "navigationEvents": navigationEvents(from: events),
            "networkEvents": networkEvents(from: events)
        ]
    }

    private static func consoleEvents(from events: [[String: Any]]) -> [[String: Any]] {
        events.compactMap { event in
            let method = stringValue(event["method"])
            let params = event["params"] as? [String: Any] ?? [:]
            switch method {
            case "Runtime.consoleAPICalled":
                let args = params["args"] as? [[String: Any]] ?? []
                let message = args.map { arg in
                    stringValue(arg["value"]).isEmpty ? stringValue(arg["description"]) : stringValue(arg["value"])
                }.joined(separator: " ")
                return [
                    "source": "cdp.Runtime.consoleAPICalled",
                    "level": stringValue(params["type"]),
                    "message": message
                ]
            case "Runtime.exceptionThrown":
                let details = params["exceptionDetails"] as? [String: Any] ?? [:]
                let exception = details["exception"] as? [String: Any] ?? [:]
                return [
                    "source": stringValue(details["url"]).isEmpty ? "cdp.Runtime.exceptionThrown" : stringValue(details["url"]),
                    "level": "exception",
                    "message": stringValue(details["text"]).isEmpty ? stringValue(exception["description"]) : stringValue(details["text"]),
                    "line": intValue(details["lineNumber"]) ?? 0,
                    "column": intValue(details["columnNumber"]) ?? 0
                ]
            case "Log.entryAdded":
                let entry = params["entry"] as? [String: Any] ?? [:]
                return [
                    "source": stringValue(entry["url"]).isEmpty ? "cdp.Log.entryAdded" : stringValue(entry["url"]),
                    "level": stringValue(entry["level"]),
                    "message": stringValue(entry["text"]),
                    "line": intValue(entry["lineNumber"]) ?? 0
                ]
            default:
                return nil
            }
        }
    }

    private static func navigationEvents(from events: [[String: Any]]) -> [[String: Any]] {
        events.compactMap { event in
            let method = stringValue(event["method"])
            let params = event["params"] as? [String: Any] ?? [:]
            switch method {
            case "Page.frameNavigated":
                let frame = params["frame"] as? [String: Any] ?? [:]
                return [
                    "source": "cdp.Page.frameNavigated",
                    "type": "frameNavigated",
                    "url": stringValue(frame["url"])
                ]
            case "Page.domContentEventFired":
                return ["source": "cdp.Page.domContentEventFired", "type": "DOMContentLoaded"]
            case "Page.loadEventFired":
                return ["source": "cdp.Page.loadEventFired", "type": "load"]
            case "Page.lifecycleEvent":
                return [
                    "source": "cdp.Page.lifecycleEvent",
                    "type": stringValue(params["name"]),
                    "frameId": stringValue(params["frameId"])
                ]
            default:
                return nil
            }
        }
    }

    private static func networkEvents(from events: [[String: Any]]) -> [[String: Any]] {
        events.compactMap { event in
            let method = stringValue(event["method"])
            let params = event["params"] as? [String: Any] ?? [:]
            switch method {
            case "Network.responseReceived":
                let response = params["response"] as? [String: Any] ?? [:]
                let status = intValue(response["status"]) ?? 0
                guard status >= 400 else { return nil }
                return [
                    "source": "cdp.Network.responseReceived",
                    "type": stringValue(params["type"]).isEmpty ? "response" : stringValue(params["type"]),
                    "method": "",
                    "url": stringValue(response["url"]),
                    "status": status
                ]
            case "Network.loadingFailed":
                return [
                    "source": "cdp.Network.loadingFailed",
                    "type": stringValue(params["type"]).isEmpty ? "request" : stringValue(params["type"]),
                    "method": "",
                    "url": "",
                    "error": stringValue(params["errorText"])
                ]
            default:
                return nil
            }
        }
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
