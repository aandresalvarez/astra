import Foundation

enum BrowserSensitiveControlClassifier {
    static func classify(
        selector: String,
        label: String,
        role: String,
        tag: String,
        type: String,
        placeholder: String,
        testID: String,
        href: String
    ) -> BrowserRisk {
        let text = [
            selector,
            label,
            role,
            tag,
            type,
            placeholder,
            testID,
            href
        ].joined(separator: " ").lowercased()

        if type.lowercased() == "password" || containsAny(text, ["password", "passcode", "secret"]) {
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
            label: string(targetInfo["label"]),
            role: string(targetInfo["role"]),
            tag: string(targetInfo["tag"]),
            type: string(targetInfo["type"]),
            placeholder: string(targetInfo["placeholder"]),
            testID: string(targetInfo["testID"]),
            href: string(targetInfo["href"])
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
}

enum BrowserTextEntryPreflight {
    static func blockResponse(action: String, targetInfo: [String: Any]) -> [String: Any]? {
        guard bool(targetInfo["ok"]) else { return nil }

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
            "target": redactedTarget(targetInfo)
        ]
    }

    private static func redactedTarget(_ targetInfo: [String: Any]) -> [String: Any] {
        [
            "selector": string(targetInfo["selector"]),
            "label": string(targetInfo["label"]),
            "role": string(targetInfo["role"]),
            "tag": string(targetInfo["tag"]),
            "type": string(targetInfo["type"]),
            "placeholder": string(targetInfo["placeholder"]),
            "testID": string(targetInfo["testID"]),
            "url": string(targetInfo["url"])
        ]
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
        return false
    }

    private static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}
