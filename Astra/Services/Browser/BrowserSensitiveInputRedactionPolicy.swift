import Foundation

enum BrowserSensitiveInputRedactionPolicy {
    static let redactedInputValue = "[redacted-sensitive-input]"

    static func redactSnapshotObject(_ object: [String: Any]) -> (object: [String: Any], didRedact: Bool) {
        var redacted = object
        var didRedact = false

        if let controls = object["controls"] as? [[String: Any]] {
            var nextControls: [[String: Any]] = []
            nextControls.reserveCapacity(controls.count)
            for control in controls {
                let result = redactControlObject(control)
                didRedact = didRedact || result.didRedact
                nextControls.append(result.object)
            }
            redacted["controls"] = nextControls
        }

        if let focused = object["focusedElement"] as? [String: Any] {
            let result = redactControlObject(focused)
            didRedact = didRedact || result.didRedact
            redacted["focusedElement"] = result.object
        }

        return (redacted, didRedact)
    }

    static func redactControlObject(_ control: [String: Any]) -> (object: [String: Any], didRedact: Bool) {
        let value = string(control["value"])
        guard !value.isEmpty else { return (control, false) }

        let shouldRedact = isSensitiveControl(
            selector: string(control["selector"]),
            label: string(control["label"]),
            name: string(control["name"]),
            role: string(control["role"]),
            tag: string(control["tag"]),
            type: string(control["type"]),
            placeholder: string(control["placeholder"]),
            testID: string(control["testID"]),
            href: string(control["href"]),
            autocomplete: string(control["autocomplete"]),
            risk: nil
        )
        guard shouldRedact else { return (control, false) }

        var redacted = control
        redacted["value"] = redactedInputValue
        return (redacted, true)
    }

    static func redactedValue(
        _ value: String,
        selector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        type: String,
        placeholder: String,
        testID: String,
        href: String,
        autocomplete: String = "",
        risk: BrowserRisk? = nil
    ) -> String {
        guard !value.isEmpty else { return value }
        return isSensitiveControl(
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            type: type,
            placeholder: placeholder,
            testID: testID,
            href: href,
            autocomplete: autocomplete,
            risk: risk
        ) ? redactedInputValue : value
    }

    static func isSensitiveControl(
        selector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        type: String,
        placeholder: String,
        testID: String,
        href: String,
        autocomplete: String = "",
        risk: BrowserRisk? = nil
    ) -> Bool {
        if let risk, [.credentialInput, .mfaInput, .privacySensitive].contains(risk) {
            return true
        }

        let lowerType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["password", "hidden"].contains(lowerType) {
            return true
        }

        let lowerAutocomplete = autocomplete.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if containsAny(lowerAutocomplete, sensitiveAutocompleteTokens) {
            return true
        }

        let text = [
            selector,
            label,
            name,
            role,
            tag,
            lowerType,
            placeholder,
            testID,
            href,
            lowerAutocomplete
        ].joined(separator: " ").lowercased()
        return containsAny(text, sensitiveFieldTerms)
    }

    private static let sensitiveAutocompleteTokens = [
        "current-password",
        "new-password",
        "one-time-code",
        "cc-number",
        "cc-csc",
        "cc-exp",
        "webauthn"
    ]

    private static let sensitiveFieldTerms = [
        "password",
        "passcode",
        "secret",
        "token",
        "api key",
        "api-key",
        "api_token",
        "apikey",
        "access token",
        "refresh token",
        "auth token",
        "bearer token",
        "oauth",
        "client secret",
        "private key",
        "mfa",
        "2fa",
        "two factor",
        "two-factor",
        "verification code",
        "security code",
        "one-time",
        "one time",
        "otp",
        "totp",
        "ssn",
        "social security",
        "credit card",
        "card number",
        "cvv",
        "cvc"
    ]

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return ""
    }
}
