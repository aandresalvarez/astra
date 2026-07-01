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

struct BrowserFocusedTextEntryPreflightResult {
    let blockedResultJSON: String?
    let targetSignature: String?
}

struct BrowserKeypressDispatchValidation {
    let blockedResultJSON: String?
    let targetSignature: String?
    let allowUnboundFocusedTargetDispatch: Bool

    static let none = BrowserKeypressDispatchValidation(
        blockedResultJSON: nil,
        targetSignature: nil,
        allowUnboundFocusedTargetDispatch: false
    )
}

extension ShelfBrowserSession {
    func textEntryPreflightReplacementTargets(selector: String, find: String, all: Bool) async throws -> [String: Any] {
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

    func textEntryPreflightFocusedTargetInfo() async throws -> [String: Any] {
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

    func keypressTextEntryDispatchValidation(
        key: String,
        modifiers: [String],
        started: Date,
        skipTextEntryPreflight: Bool
    ) async throws -> BrowserKeypressDispatchValidation {
        guard !skipTextEntryPreflight,
              BrowserKeypressSafety.requiresTextEntryPreflight(key: key, modifiers: modifiers) else {
            return .none
        }
        let preflight = try await focusedTextEntryPreflight(
            action: "keypress",
            logContext: BrowserTextEntryLogContext(
                started: started,
                action: "keypress",
                fields: ["key_length": String(key.count), "modifier_count": String(modifiers.count)]
            )
        )
        guard let result = preflight.blockedResultJSON else {
            return BrowserKeypressDispatchValidation(
                blockedResultJSON: nil,
                targetSignature: preflight.targetSignature,
                allowUnboundFocusedTargetDispatch: false
            )
        }
        guard BrowserKeypressSafety.canDispatchBlockedPreflightWithoutFocusedTarget(
            key: key,
            modifiers: modifiers,
            blockedPreflightJSON: result
        ) else {
            return BrowserKeypressDispatchValidation(
                blockedResultJSON: result,
                targetSignature: nil,
                allowUnboundFocusedTargetDispatch: false
            )
        }
        return BrowserKeypressDispatchValidation(
            blockedResultJSON: nil,
            targetSignature: nil,
            allowUnboundFocusedTargetDispatch: true
        )
    }

    func focusedTextEntryPreflight(
        action: String,
        logContext: BrowserTextEntryLogContext
    ) async throws -> BrowserFocusedTextEntryPreflightResult {
        let targetInfo = try await textEntryPreflightFocusedTargetInfo()
        if let blocked = try blockedTextEntryResult(
            action: action,
            targetInfo: targetInfo,
            attachmentKey: "focusedTarget",
            logContext: logContext
        ) {
            return BrowserFocusedTextEntryPreflightResult(blockedResultJSON: blocked, targetSignature: nil)
        }
        guard let targetSignature = BrowserTextEntryPreflight.targetSignature(for: targetInfo) else {
            let blocked = BrowserTextEntryPreflight.missingFocusedTargetBlockResponse(action: action, targetInfo: targetInfo)
            let result = try BrowserTextEntryPreflightJSON.string(blocked)
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
            return BrowserFocusedTextEntryPreflightResult(blockedResultJSON: result, targetSignature: nil)
        }
        return BrowserFocusedTextEntryPreflightResult(
            blockedResultJSON: nil,
            targetSignature: targetSignature
        )
    }

    func blockedFocusedTextEntryResult(
        action: String,
        logContext: BrowserTextEntryLogContext
    ) async throws -> String? {
        let preflight = try await focusedTextEntryPreflight(
            action: action,
            logContext: logContext
        )
        return preflight.blockedResultJSON
    }

    func blockedTextEntryResult(
        action: String,
        targetInfo: [String: Any],
        attachmentKey: String,
        logContext: BrowserTextEntryLogContext
    ) throws -> String? {
        guard var blocked = BrowserTextEntryPreflight.textEntryBlockResponse(action: action, targetInfo: targetInfo) else {
            return nil
        }
        blocked[attachmentKey] = BrowserTextEntryPreflight.redactedTargetAttachment(for: blocked)
        let result = try BrowserTextEntryPreflightJSON.string(blocked)
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
        let targetInfo = try await textEntryPreflightReplacementTargets(selector: selector, find: find, all: all)
        let ok = (targetInfo["ok"] as? Bool) ?? (targetInfo["ok"] as? NSNumber)?.boolValue ?? false
        guard ok else { return targetInfo }
        let redactedCurrentURL = BrowserFlightPageSnapshot.redactedURLString(currentURL)

        let targetCount = BrowserTextEntryPreflightJSON.intValue(targetInfo["targetCount"]) ?? 0
        let targets = targetInfo["targets"] as? [[String: Any]] ?? []
        guard targetCount > 0 else {
            if GoogleWorkspaceBrowserService.isGoogleWorkspaceEditorURL(currentURL) {
                return [
                    "ok": false,
                    "error": "editor_surface_requires_find_replace",
                    "summary": "Google editor canvas text is not directly editable through DOM replacement.",
                    "find": find,
                    "selector": selector,
                    "url": redactedCurrentURL,
                    "hint": "Google editor canvas text is not directly editable through DOM replacement. Open Find and replace, then use astra-browser set-value on the Find and Replace fields by selector."
                ]
            }
            return [
                "ok": false,
                "error": "text_entry_target_not_found",
                "summary": "Text replacement requires at least one visible editable target before ASTRA can safely mutate page text.",
                "find": find,
                "selector": selector,
                "url": redactedCurrentURL
            ]
        }
        guard !targets.isEmpty else { return nil }
        for target in targets {
            if let blocked = BrowserTextEntryPreflight.blockResponse(
                action: "replaceText",
                targetInfo: target
            ) {
                return blocked
            }
        }
        return nil
    }
}

private enum BrowserTextEntryPreflightJSON {
    static func string(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
