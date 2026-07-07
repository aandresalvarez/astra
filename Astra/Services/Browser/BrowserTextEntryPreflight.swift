import Foundation

enum BrowserSensitiveControlClassifier {
    static func classify(
        selector: String,
        requestedSelector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        type: String,
        autocomplete: String,
        placeholder: String,
        testID: String,
        href: String,
        framePath: String = "",
        frameFocusUninspectable: Bool
    ) -> BrowserRisk {
        if frameFocusUninspectable {
            return .unknownHighImpact
        }
        let text = [
            selector,
            requestedSelector,
            label,
            name,
            role,
            tag,
            type,
            autocomplete,
            placeholder,
            testID,
            href,
            framePath
        ].joined(separator: " ").lowercased()

        let lowerTag = tag.lowercased()
        let lowerRole = role.lowercased()
        let lowerType = type.lowercased()
        let isEditableTextEntry = lowerTag == "input"
            || lowerTag == "textarea"
            || lowerRole.contains("textbox")
            || lowerType == "password"

        if lowerType == "password"
            || (isEditableTextEntry && containsAny(text, credentialTextEntryTokens))
            || isSecretRevealingControl(text: text, isEditableTextEntry: isEditableTextEntry) {
            return .credentialInput
        }
        if isEditableTextEntry,
           containsAny(text, ["mfa", "2fa", "two factor", "two-factor", "verification code", "security code", "otp", "one-time"]) {
            return .mfaInput
        }
        if containsAny(text, ["delete", "remove", "destroy", "discard", "revoke", "terminate", "erase"]) {
            return .destructive
        }
        if containsAny(text, ["purchase", "buy now", "place order", "checkout"]) {
            return .purchase
        }
        if containsAny(text, ["pay", "payment", "billing", "credit card", "card number"]) {
            return .payment
        }
        if containsAny(text, ["authorize", "approve", "grant", "allow access", "permission", "consent"]) {
            return .authorization
        }
        return .normal
    }

    static func classify(targetInfo: [String: Any]) -> BrowserRisk {
        classify(
            selector: string(targetInfo["selector"]),
            requestedSelector: string(targetInfo["requestedSelector"]),
            label: string(targetInfo["label"]),
            name: string(targetInfo["name"]),
            role: string(targetInfo["role"]),
            tag: string(targetInfo["tag"]),
            type: string(targetInfo["type"]),
            autocomplete: string(targetInfo["autocomplete"]),
            placeholder: string(targetInfo["placeholder"]),
            testID: string(targetInfo["testID"]),
            href: string(targetInfo["href"]),
            framePath: framePathString(targetInfo["framePath"]),
            frameFocusUninspectable: bool(targetInfo["frameFocusUninspectable"])
        )
    }

    private static func containsAny(_ text: String, _ tokens: [String]) -> Bool {
        tokens.contains { text.contains($0) }
    }

    private static func isSecretRevealingControl(text: String, isEditableTextEntry: Bool) -> Bool {
        guard !isEditableTextEntry else { return false }
        return containsAny(text, secretMaterialTokens) && containsAny(text, secretRevealActionTokens)
    }

    private static let secretMaterialTokens = [
        "password",
        "passcode",
        "secret",
        "api key",
        "apikey",
        "api_key",
        "token",
        "access token",
        "access_token",
        "refresh token",
        "refresh_token",
        "id token",
        "id_token",
        "bearer",
        "client secret",
        "client_secret",
        "credential",
        "recovery code"
    ]

    private static let credentialTextEntryTokens = secretMaterialTokens + [
        "current-password",
        "new-password",
        "personal access token"
    ]

    private static let secretRevealActionTokens = [
        "show",
        "reveal",
        "copy",
        "view",
        "display",
        "unmask"
    ]

    private static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    private static func framePathString(_ value: Any?) -> String {
        if let strings = value as? [String] {
            return strings.joined(separator: " ")
        }
        if let values = value as? [Any] {
            return values.map { string($0) }.joined(separator: " ")
        }
        return string(value)
    }
}

enum BrowserTextEntryPreflight {
    static func textEntryBlockResponse(action: String, targetInfo: [String: Any]) -> [String: Any]? {
        if let blocked = blockResponse(action: action, targetInfo: targetInfo) {
            return blocked
        }
        return activationConfirmationResponse(action: action, targetInfo: targetInfo, allowDangerous: false)
    }

    static func blockResponse(action: String, targetInfo: [String: Any]) -> [String: Any]? {
        let risk = BrowserSensitiveControlClassifier.classify(targetInfo: targetInfo)
        let code: String
        let summary: String
        switch risk {
        case .unknownHighImpact:
            code = "focused_frame_uninspectable"
            summary = "ASTRA will not type into a focused frame whose active element cannot be inspected. The user should confirm or enter this directly in the browser."
        case .credentialInput:
            code = "credential_input_blocked"
            summary = "ASTRA will not type passwords or secrets. The user should enter this directly in the browser."
        case .mfaInput:
            code = "mfa_input_blocked"
            summary = "ASTRA will not type MFA or verification codes. The user should enter this directly in the browser."
        default:
            return nil
        }

        return [
            "ok": false,
            "error": code,
            "action": action,
            "summary": summary,
            "risk": risk.rawValue,
            "target": sanitizedTarget(targetInfo, risk: risk)
        ]
    }

    static func activationConfirmationResponse(
        action: String,
        targetInfo: [String: Any],
        allowDangerous: Bool
    ) -> [String: Any]? {
        let risk = BrowserSensitiveControlClassifier.classify(targetInfo: targetInfo)
        guard risk.requiresUserConfirmation, !allowDangerous else { return nil }

        return [
            "ok": false,
            "error": "dangerous_confirmation_required",
            "action": action,
            "summary": "This \(risk.rawValue) action requires explicit user confirmation before execution.",
            "risk": risk.rawValue,
            "target": sanitizedTarget(targetInfo, risk: risk)
        ]
    }

    static func redactedTargetAttachment(for blockedResponse: [String: Any]) -> [String: Any] {
        blockedResponse["target"] as? [String: Any] ?? [:]
    }

    static func missingFocusedTargetBlockResponse(action: String, targetInfo: [String: Any]) -> [String: Any] {
        [
            "ok": false,
            "error": "text_entry_target_not_bound",
            "action": action,
            "summary": "ASTRA could not bind a focused text-entry target before dispatch, so ASTRA did not send raw browser input.",
            "risk": BrowserRisk.unknownHighImpact.rawValue,
            "target": sanitizedTarget(targetInfo, risk: .unknownHighImpact)
        ]
    }

    static func sanitizedTargetAttachment(for targetInfo: [String: Any]) -> [String: Any] {
        let risk = BrowserSensitiveControlClassifier.classify(targetInfo: targetInfo)
        return sanitizedTarget(targetInfo, risk: risk)
    }

    static func isTerminalBlockResponse(_ response: [String: Any]) -> Bool {
        guard isExplicitFalse(response["ok"]) else { return false }
        switch string(response["error"]) {
        case "credential_input_blocked", "mfa_input_blocked", "focused_frame_uninspectable", "text_entry_target_changed", "text_entry_target_not_bound", "dangerous_confirmation_required":
            return true
        default:
            switch string(response["stopReason"]) {
            case "credential_input_blocked", "mfa_input_blocked", "focused_frame_uninspectable", "text_entry_target_changed", "text_entry_target_not_bound", "dangerous_confirmation_required":
                return true
            default:
                return false
            }
        }
    }

    static func terminalStopReason(for response: [String: Any]) -> String? {
        guard isTerminalBlockResponse(response) else { return nil }
        let error = string(response["error"])
        return error.isEmpty ? string(response["stopReason"]) : error
    }

    static func stoppedResponse(results: [[String: Any]]) -> [String: Any] {
        guard let stopReason = results.lazy.compactMap(terminalStopReason(for:)).first else {
            return ["ok": false, "results": results]
        }
        return [
            "ok": false,
            "stopReason": stopReason,
            "results": results
        ]
    }

    static func targetSignature(for targetInfo: [String: Any]) -> String? {
        guard bool(targetInfo["ok"]) else { return nil }
        if let signature = targetInfo["targetSignature"] as? String, !signature.isEmpty {
            return signature
        }
        return [
            string(targetInfo["selector"]),
            string(targetInfo["tag"]),
            string(targetInfo["type"]),
            string(targetInfo["name"]),
            string(targetInfo["role"]),
            string(targetInfo["autocomplete"]),
            framePathString(targetInfo["framePath"]),
            string(targetInfo["shadowDepth"]),
            signatureURL(string(targetInfo["url"]))
        ].joined(separator: "\u{1f}")
    }

    static func focusedTargetBindBlockResponse(
        action: String,
        targetInfo: [String: Any],
        expectedSignature: String
    ) -> [String: Any]? {
        guard let targetSignature = targetSignature(for: targetInfo) else {
            return missingFocusedTargetBlockResponse(action: action, targetInfo: targetInfo)
        }
        guard targetSignature == expectedSignature else {
            return focusChangedBlockResponse(action: action, targetInfo: targetInfo)
        }
        return nil
    }

    static func focusChangedBlockResponse(action: String, targetInfo: [String: Any]) -> [String: Any] {
        [
            "ok": false,
            "error": "text_entry_target_changed",
            "action": action,
            "summary": "The focused text-entry target changed after ASTRA inspected it, so ASTRA did not send raw browser input.",
            "risk": BrowserRisk.unknownHighImpact.rawValue,
            "target": sanitizedTarget(targetInfo, risk: .unknownHighImpact)
        ]
    }

    private static func sanitizedTarget(_ targetInfo: [String: Any], risk: BrowserRisk) -> [String: Any] {
        let redactText = risk == .credentialInput || risk == .mfaInput || risk == .unknownHighImpact
        var target: [String: Any] = [
            "selector": redactText
                ? sanitizedSensitiveSelector(string(targetInfo["selector"]), tag: string(targetInfo["tag"]))
                : string(targetInfo["selector"]),
            "requestedSelector": redactText
                ? sanitizedSensitiveSelector(string(targetInfo["requestedSelector"]), tag: string(targetInfo["tag"]))
                : string(targetInfo["requestedSelector"]),
            "label": redactText ? "[redacted]" : string(targetInfo["label"]),
            "name": redactText ? "[redacted]" : string(targetInfo["name"]),
            "role": string(targetInfo["role"]),
            "tag": string(targetInfo["tag"]),
            "type": string(targetInfo["type"]),
            "autocomplete": redactText ? "[redacted]" : string(targetInfo["autocomplete"]),
            "placeholder": redactText ? "[redacted]" : string(targetInfo["placeholder"]),
            "testID": redactText ? "[redacted-sensitive-input]" : string(targetInfo["testID"]),
            "href": redactText ? sanitizedSensitiveURL(string(targetInfo["href"])) : string(targetInfo["href"]),
            "url": redactText ? sanitizedSensitiveURL(string(targetInfo["url"])) : string(targetInfo["url"])
        ]
        if let framePath = targetInfo["framePath"] {
            target["framePath"] = sanitizedFramePath(framePath, redact: redactText)
        }
        if let shadowDepth = targetInfo["shadowDepth"] {
            target["shadowDepth"] = shadowDepth
        }
        if let uninspectable = targetInfo["frameFocusUninspectable"] {
            target["frameFocusUninspectable"] = uninspectable
        }
        return target
    }

    private static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return ""
    }

    private static func isExplicitFalse(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return !bool }
        if let number = value as? NSNumber { return !number.boolValue }
        if let string = value as? String {
            return ["false", "0", "no"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    private static func framePathString(_ value: Any?) -> String {
        if let strings = value as? [String] {
            return strings.joined(separator: " ")
        }
        if let values = value as? [Any] {
            return values.map { string($0) }.joined(separator: " ")
        }
        return string(value)
    }

    private static func signatureURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed) else { return trimmed }
        components.query = nil
        components.fragment = nil
        return components.string ?? trimmed
    }

    private static func sanitizedFramePath(_ value: Any, redact: Bool) -> [String] {
        let entries: [String]
        if let strings = value as? [String] {
            entries = strings
        } else if let values = value as? [Any] {
            entries = values.map { string($0) }
        } else {
            entries = [string(value)]
        }
        guard redact else {
            return entries
        }
        return entries.map(sanitizedSensitiveFramePathEntry)
    }

    private static func sanitizedSensitiveFramePathEntry(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "[redacted frame]" }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host else {
            return "[redacted frame]"
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func sanitizedSensitiveSelector(_ value: String, tag: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTag.isEmpty else { return "[redacted selector]" }
        return "\(normalizedTag)[redacted-selector]"
    }

    private static func sanitizedSensitiveURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host else {
            return "[redacted url]"
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
