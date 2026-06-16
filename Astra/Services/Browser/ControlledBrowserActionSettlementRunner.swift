import Foundation

struct ControlledBrowserActionSettlementSample {
    let events: [[String: Any]]
    let accessibilityNodeCount: Int
    let elapsedMs: Int
}

enum ControlledBrowserActionSettlementRunner {
    static func dispatchMouseClick(
        webSocketURL: URL,
        x: Double,
        y: Double,
        clickCount: Int = 1
    ) async throws -> ControlledBrowserActionSettlementSample {
        try await run(webSocketURL: webSocketURL) { client in
            _ = try await client.send(method: "Input.dispatchMouseEvent", params: [
                "type": "mouseMoved",
                "x": x,
                "y": y,
                "button": "none"
            ])
            for count in 1...max(1, clickCount) {
                _ = try await client.send(method: "Input.dispatchMouseEvent", params: [
                    "type": "mousePressed",
                    "x": x,
                    "y": y,
                    "button": "left",
                    "clickCount": count
                ])
                _ = try await client.send(method: "Input.dispatchMouseEvent", params: [
                    "type": "mouseReleased",
                    "x": x,
                    "y": y,
                    "button": "left",
                    "clickCount": count
                ])
                if count < clickCount {
                    try? await Task.sleep(nanoseconds: 90_000_000)
                }
            }
        }
    }

    static func evaluate(
        webSocketURL: URL,
        script: String
    ) async throws -> (value: String, sample: ControlledBrowserActionSettlementSample) {
        var value = ""
        let sample = try await run(webSocketURL: webSocketURL) { client in
            let response = try await client.send(
                method: "Runtime.evaluate",
                params: [
                    "expression": script,
                    "awaitPromise": true,
                    "returnByValue": true,
                    "timeout": 5_000
                ]
            )
            guard let result = response["result"] as? [String: Any],
                  let remoteObject = result["result"] as? [String: Any] else {
                throw ControlledBrowserError.invalidDevToolsResponse
            }
            if let exception = result["exceptionDetails"] as? [String: Any] {
                throw ControlledBrowserError.commandFailed(String(describing: exception))
            }
            if let string = remoteObject["value"] as? String {
                value = string
            } else if let rawValue = remoteObject["value"] {
                value = try jsonString(["ok": true, "value": rawValue])
            } else {
                value = #"{"ok":true}"#
            }
        }
        return (value, sample)
    }

    static func run(
        webSocketURL: URL,
        operation: (OperationCDPClient) async throws -> Void
    ) async throws -> ControlledBrowserActionSettlementSample {
        let started = Date()
        let client = OperationCDPClient(webSocketURL: webSocketURL)
        try await client.connect()
        defer { client.close() }

        _ = try? await client.send(method: "Page.enable")
        _ = try? await client.send(method: "Page.setLifecycleEventsEnabled", params: ["enabled": true])
        _ = try? await client.send(method: "Runtime.enable")
        _ = try? await client.send(method: "Network.enable")
        _ = client.drainEvents()

        try await operation(client)

        var observedEvents: [[String: Any]] = []
        var accessibilityNodeCount = 0
        let maxWaitMs = 1_500
        while true {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let response = try? await client.send(
                method: "Accessibility.getFullAXTree",
                params: ["interestingOnly": true]
            ) {
                let nodes = ((response["result"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                accessibilityNodeCount = max(accessibilityNodeCount, nodes.count)
            }
            observedEvents.append(contentsOf: client.drainEvents())

            let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
            let decision = ControlledBrowserActionSettlement.waitDecision(
                events: observedEvents,
                accessibilityNodeCount: accessibilityNodeCount,
                elapsedMs: elapsedMs,
                maxWaitMs: maxWaitMs
            )
            if !decision.shouldContinue {
                return ControlledBrowserActionSettlementSample(
                    events: observedEvents,
                    accessibilityNodeCount: accessibilityNodeCount,
                    elapsedMs: elapsedMs
                )
            }
        }
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        return string
    }
}
