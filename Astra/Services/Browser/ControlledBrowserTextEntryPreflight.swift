import Foundation

extension ControlledBrowserController {
    nonisolated static func validateFocusedTextEntryTarget(
        action: String,
        expectedSignature: String?,
        client: OperationCDPClient
    ) async throws -> [String: Any]? {
        guard let expectedSignature, !expectedSignature.isEmpty else {
            return nil
        }
        let targetInfo = try await focusedTextEntryTargetInfo(client: client)
        if var blocked = BrowserTextEntryPreflight.blockResponse(action: action, targetInfo: targetInfo) {
            blocked["focusedTarget"] = BrowserTextEntryPreflight.redactedTargetAttachment(for: blocked)
            return blocked
        }
        guard BrowserTextEntryPreflight.targetSignature(for: targetInfo) == expectedSignature else {
            var blocked = BrowserTextEntryPreflight.focusChangedBlockResponse(action: action, targetInfo: targetInfo)
            blocked["focusedTarget"] = BrowserTextEntryPreflight.redactedTargetAttachment(for: blocked)
            return blocked
        }
        return nil
    }

    private nonisolated static func focusedTextEntryTargetInfo(client: OperationCDPClient) async throws -> [String: Any] {
        let response = try await client.send(
            method: "Runtime.evaluate",
            params: [
                "expression": BrowserAutomationScripts.focusedTargetInfoScript(),
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
        if let value = remoteObject["value"] as? String {
            return try jsonObject(from: value)
        }
        if let value = remoteObject["value"] {
            return ["ok": true, "value": value]
        }
        return ["ok": true]
    }

    private nonisolated static func jsonObject(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        return object
    }
}
