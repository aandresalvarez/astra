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
        frameFocusUninspectable: Bool
    ) -> BrowserRisk {
        if frameFocusUninspectable {
            return .credentialInput
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
            href
        ].joined(separator: " ").lowercased()

        if type.lowercased() == "password"
            || containsAny(text, ["password", "passcode", "secret", "current-password", "new-password"]) {
            return .credentialInput
        }
        if containsAny(text, ["mfa", "2fa", "two factor", "two-factor", "verification code", "security code", "otp", "one-time"]) {
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
            frameFocusUninspectable: bool(targetInfo["frameFocusUninspectable"])
        )
    }

    private static func containsAny(_ text: String, _ tokens: [String]) -> Bool {
        tokens.contains { text.contains($0) }
    }

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
}

enum BrowserTextEntryPreflight {
    static func blockResponse(action: String, targetInfo: [String: Any]) -> [String: Any]? {
        let risk = BrowserSensitiveControlClassifier.classify(targetInfo: targetInfo)
        let code: String
        let summary: String
        switch risk {
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

    static func redactedTargetAttachment(for blockedResponse: [String: Any]) -> [String: Any] {
        blockedResponse["target"] as? [String: Any] ?? [:]
    }

    static func sanitizedTargetAttachment(for targetInfo: [String: Any]) -> [String: Any] {
        let risk = BrowserSensitiveControlClassifier.classify(targetInfo: targetInfo)
        return sanitizedTarget(targetInfo, risk: risk)
    }

    static func isTerminalBlockResponse(_ response: [String: Any]) -> Bool {
        guard let ok = response["ok"] as? Bool, ok == false else { return false }
        switch string(response["error"]) {
        case "credential_input_blocked", "mfa_input_blocked":
            return true
        default:
            return false
        }
    }

    static func terminalStopReason(for response: [String: Any]) -> String? {
        isTerminalBlockResponse(response) ? string(response["error"]) : nil
    }

    private static func sanitizedTarget(_ targetInfo: [String: Any], risk: BrowserRisk) -> [String: Any] {
        let redactText = risk == .credentialInput || risk == .mfaInput
        var target: [String: Any] = [
            "selector": string(targetInfo["selector"]),
            "requestedSelector": string(targetInfo["requestedSelector"]),
            "label": redactText ? "[redacted]" : string(targetInfo["label"]),
            "name": redactText ? "[redacted]" : string(targetInfo["name"]),
            "role": string(targetInfo["role"]),
            "tag": string(targetInfo["tag"]),
            "type": string(targetInfo["type"]),
            "autocomplete": string(targetInfo["autocomplete"]),
            "placeholder": redactText ? "[redacted]" : string(targetInfo["placeholder"]),
            "testID": string(targetInfo["testID"]),
            "href": string(targetInfo["href"]),
            "url": string(targetInfo["url"])
        ]
        if let framePath = targetInfo["framePath"] {
            target["framePath"] = framePath
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
        return ""
    }
}
