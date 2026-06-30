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

    func blockedReplacementTextEntryResult(find: String, selector: String, all: Bool) async throws -> [String: Any]? {
        guard !selector.isEmpty else {
            return [
                "ok": false,
                "error": "text_entry_target_required",
                "summary": "Text replacement requires a concrete editable target selector before ASTRA can safely mutate page text.",
                "find": find,
                "url": currentURL
            ]
        }

        let targetInfo = try await replacementTextEntryTargets(selector: selector, find: find, all: all)
        let ok = (targetInfo["ok"] as? Bool) ?? (targetInfo["ok"] as? NSNumber)?.boolValue ?? false
        guard ok else { return targetInfo }

        let targetCount = Self.textEntryPreflightIntValue(targetInfo["targetCount"]) ?? 0
        let targets = targetInfo["targets"] as? [[String: Any]] ?? []
        guard targetCount > 0 else {
            return [
                "ok": false,
                "error": "text_entry_target_not_found",
                "summary": "Text replacement requires at least one visible editable target before ASTRA can safely mutate page text.",
                "find": find,
                "selector": selector,
                "url": currentURL
            ]
        }
        guard !targets.isEmpty else { return nil }
        for target in targets {
            if let blocked = BrowserTextEntryPreflight.blockResponse(
                action: BrowserActionKind.setValue.rawValue,
                targetInfo: target
            ) {
                return blocked
            }
        }
        return nil
    }

    func replacementTextEntryTargets(selector: String, find: String, all: Bool) async throws -> [String: Any] {
        let json: String
        if isUsingControlledBrowser {
            json = try await controlledBrowser.replaceTextTargetsInfo(selector: selector, find: find, all: all)
            syncDisplayedStateForEngine()
            publishBridgeState()
        } else {
            json = try await evaluateJavaScriptString(BrowserAutomationScripts.replaceTextTargetsInfoScript(selector: selector, find: find, all: all))
        }
        return try Self.jsonObject(from: json)
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

    private static func textEntryPreflightIntValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
