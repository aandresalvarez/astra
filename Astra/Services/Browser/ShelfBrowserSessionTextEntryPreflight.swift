import Foundation

struct BrowserTextEntryLogContext {
    let started: Date
    let action: String
    let selector: String?
    let label: String?
    let role: String?
    let placeholder: String?
    let testID: String?
    let fields: [String: String]

    init(
        started: Date,
        action: String,
        selector: String? = nil,
        label: String? = nil,
        role: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil,
        fields: [String: String]
    ) {
        self.started = started
        self.action = action
        self.selector = selector
        self.label = label
        self.role = role
        self.placeholder = placeholder
        self.testID = testID
        self.fields = fields
    }

    var blockedFields: [String: String] {
        var result = fields
        result["blocked"] = "true"
        return result
    }
}

extension ShelfBrowserSession {
    func blockedFocusedTextEntryResult(
        action: String,
        logContext: BrowserTextEntryLogContext
    ) async throws -> String? {
        let targetInfo = try await focusedTextEntryTargetInfo()
        return try blockedTextEntryResult(
            action: action,
            targetInfo: targetInfo,
            attachmentKey: "focusedTarget",
            logContext: logContext
        )
    }

    func blockedTextEntryResult(
        action: String,
        targetInfo: [String: Any],
        attachmentKey: String,
        logContext: BrowserTextEntryLogContext
    ) throws -> String? {
        guard var blocked = BrowserTextEntryPreflight.blockResponse(action: action, targetInfo: targetInfo) else {
            return nil
        }
        blocked[attachmentKey] = BrowserTextEntryPreflight.redactedTargetAttachment(for: blocked)
        let result = try Self.jsonString(blocked)
        logBrowserAction(
            phase: "completed",
            action: logContext.action,
            selector: logContext.selector,
            label: logContext.label,
            role: logContext.role,
            text: nil,
            placeholder: logContext.placeholder,
            testID: logContext.testID,
            fields: logContext.blockedFields,
            resultJSON: result,
            started: logContext.started
        )
        return result
    }

    func blockedReplacementTextEntryResult(find: String, selector: String) async throws -> [String: Any]? {
        guard !selector.isEmpty else {
            return [
                "ok": false,
                "error": "text_entry_target_required",
                "summary": "Text replacement requires a concrete editable target selector before ASTRA can safely mutate page text.",
                "find": find,
                "url": currentURL
            ]
        }

        let targetInfo = try await waitForActionableTarget(
            selector: selector,
            x: nil,
            y: nil,
            allowDangerous: true,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil
        )
        if let blocked = BrowserTextEntryPreflight.blockResponse(
            action: BrowserActionKind.setValue.rawValue,
            targetInfo: targetInfo
        ) {
            return blocked
        }
        let ok = (targetInfo["ok"] as? Bool) ?? (targetInfo["ok"] as? NSNumber)?.boolValue ?? false
        guard ok else {
            return targetInfo
        }
        return nil
    }

    func focusedTextEntryTargetInfo() async throws -> [String: Any] {
        let json: String
        if isUsingControlledBrowser {
            json = try await controlledBrowser.focusedTargetInfo()
            syncDisplayedStateForEngine()
            publishBridgeState()
        } else {
            json = try await evaluateJavaScriptString(BrowserAutomationScripts.focusedTargetInfoScript())
        }
        return try Self.jsonObject(from: json)
    }
}
