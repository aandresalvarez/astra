import Foundation

enum BrowserSensitiveInputRedactionPolicy {
    static let redactedInputValue = "[redacted-sensitive-input]"

    static func riskForAutocomplete(_ autocomplete: String) -> BrowserRisk? {
        let lowerAutocomplete = autocomplete.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerAutocomplete.isEmpty else { return nil }
        if containsAny(lowerAutocomplete, ["current-password", "new-password"]) {
            return .credentialInput
        }
        if containsAny(lowerAutocomplete, ["one-time-code"]) {
            return .mfaInput
        }
        if containsAny(lowerAutocomplete, paymentAutocompleteTokens) {
            return .payment
        }
        return nil
    }

    static func redactSnapshotObject(_ object: [String: Any]) -> (object: [String: Any], didRedact: Bool) {
        var redacted = object
        var didRedact = false
        var sensitiveValues: [String] = []

        if let controls = object["controls"] as? [[String: Any]] {
            var nextControls: [[String: Any]] = []
            nextControls.reserveCapacity(controls.count)
            for control in controls {
                let result = redactControlObject(control)
                didRedact = didRedact || result.didRedact
                sensitiveValues.append(contentsOf: result.sensitiveValues)
                nextControls.append(result.object)
            }
            redacted["controls"] = nextControls
        }

        if let focused = object["focusedElement"] as? [String: Any] {
            let result = redactControlObject(focused)
            didRedact = didRedact || result.didRedact
            sensitiveValues.append(contentsOf: result.sensitiveValues)
            redacted["focusedElement"] = result.object
        }

        if let text = object["text"] as? String {
            let nextText = redactedText(text, sensitiveValues: sensitiveValues)
            if nextText != text {
                redacted["text"] = nextText
                didRedact = true
            }
        }

        return (redacted, didRedact)
    }

    static func redactControlObject(
        _ control: [String: Any],
        risk: BrowserRisk? = nil
    ) -> (object: [String: Any], didRedact: Bool, sensitiveValues: [String]) {
        let value = string(control["value"])
        let valueAlreadyRedacted = value == redactedInputValue

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
            risk: risk
        )
        guard shouldRedact else { return (control, false, []) }
        let sensitiveValues = uniqueSensitiveValues(
            (value.isEmpty || valueAlreadyRedacted ? [] : [value]) + sensitiveMetadataValues(from: control)
        )

        var redacted = control
        var didRedact = false
        if !value.isEmpty, !valueAlreadyRedacted {
            redacted["value"] = redactedInputValue
            didRedact = true
        }
        for key in ["selector", "label", "name", "placeholder", "testID", "href"] {
            let original = string(control[key])
            let valueRedacted = sensitiveValues.isEmpty
                ? original
                : redactedDisplayText(original, sensitiveValues: sensitiveValues)
            let next = valueRedacted == original
                ? redactedSensitiveMetadataText(original)
                : valueRedacted
            redacted[key] = next
            didRedact = didRedact || next != original
        }
        return (redacted, didRedact, sensitiveValues)
    }

    static func controlIDSlugSource(
        label: String,
        role: String,
        tag: String,
        redactedLabel: String
    ) -> String {
        let fallback = role.isEmpty ? tag : role
        guard !label.isEmpty else {
            return fallback
        }
        return redactedLabel == redactedInputValue ? fallback : label
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

    static func redactedDisplayText(_ text: String, sensitiveValue: String) -> String {
        let trimmedValue = sensitiveValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return text }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return text }

        if textContainsSensitiveValue(trimmedText, sensitiveValue: trimmedValue) {
            return redactedInputValue
        }
        return text
    }

    static func redactedDisplayText(_ text: String, sensitiveValues: [String]) -> String {
        sensitiveValues.contains { textContainsSensitiveValue(text, sensitiveValue: $0) } ? redactedInputValue : text
    }

    static func redactedSensitiveMetadataText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let lower = trimmed.lowercased()
        let spaced = lower
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "#", with: " ")
        return containsAny(lower, sensitiveFieldTerms)
            || containsAny(lower, paymentFieldTerms)
            || containsAny(spaced, sensitiveFieldTerms)
            || containsAny(spaced, paymentFieldTerms)
            ? redactedInputValue
            : text
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
        if risk == .payment {
            return isEditablePaymentField(tag: tag, role: role, type: lowerType)
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
            || (isEditablePaymentField(tag: tag, role: role, type: lowerType) && containsAny(text, paymentFieldTerms))
    }

    private static func isEditablePaymentField(tag: String, role: String, type: String) -> Bool {
        let lowerTag = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["textarea", "select"].contains(lowerTag) {
            return true
        }
        if lowerRole == "textbox" || lowerRole == "combobox" {
            return true
        }
        guard lowerTag == "input" else {
            return false
        }
        let nonEditableInputTypes: Set<String> = [
            "button",
            "checkbox",
            "color",
            "file",
            "image",
            "radio",
            "range",
            "reset",
            "submit"
        ]
        return !nonEditableInputTypes.contains(type)
    }

    private static let sensitiveAutocompleteTokens = [
        "current-password",
        "new-password",
        "one-time-code",
        "cc-name",
        "cc-given-name",
        "cc-additional-name",
        "cc-family-name",
        "cc-number",
        "cc-exp",
        "cc-exp-month",
        "cc-exp-year",
        "cc-csc",
        "cc-type"
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
        "dob",
        "date of birth",
        "birth date",
        "birthdate",
        "mrn",
        "medical record",
        "medical record number",
        "patient id",
        "patient identifier",
        "health record"
    ]

    private static let paymentFieldTerms = [
        "credit card",
        "card number",
        "cardholder",
        "card holder",
        "name on card",
        "cc-name",
        "cc-given-name",
        "cc-additional-name",
        "cc-family-name",
        "cc-number",
        "cc-exp",
        "cc-exp-month",
        "cc-exp-year",
        "cc-csc",
        "cc-type",
        "cvv",
        "cvc",
        "payment",
        "billing"
    ]

    private static let paymentAutocompleteTokens = [
        "cc-name",
        "cc-given-name",
        "cc-additional-name",
        "cc-family-name",
        "cc-number",
        "cc-exp",
        "cc-exp-month",
        "cc-exp-year",
        "cc-csc",
        "cc-type"
    ]

    private static func redactedText(_ text: String, sensitiveValues: [String]) -> String {
        var redacted = text
        for value in sensitiveValues {
            guard shouldRedactFreeText(for: value) else { continue }
            for candidate in sensitiveComparisonValues(for: value).sorted(by: { $0.count > $1.count }) {
                redacted = redacted.replacingOccurrences(of: candidate, with: redactedInputValue, options: [.caseInsensitive])
            }
            if let digitPattern = formattedDigitPattern(for: value) {
                redacted = replacingMatches(in: redacted, pattern: digitPattern, with: redactedInputValue)
            }
        }
        return redacted
    }

    private static func uniqueSensitiveValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func sensitiveMetadataValues(from control: [String: Any]) -> [String] {
        let fields = [
            string(control["selector"]),
            string(control["label"]),
            string(control["name"]),
            string(control["placeholder"]),
            string(control["testID"]),
            string(control["href"])
        ]
        var seen: Set<String> = []
        return fields.flatMap(sensitiveMetadataCandidates)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func sensitiveMetadataCandidates(from text: String) -> [String] {
        let variants = sensitiveComparisonValues(for: text)
            .flatMap { [$0, strippedSelectorPrefix($0)] }
        return variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isSensitiveMetadataCandidate($0) }
    }

    private static func isSensitiveMetadataCandidate(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard containsAny(lower, sensitiveFieldTerms) || containsAny(lower, paymentFieldTerms) else { return false }
        return lower.contains { $0.isNumber }
            || lower.contains("-")
            || lower.contains("_")
            || lower.contains("%")
            || lower.contains("\\")
            || lower.count > 20
    }

    private static func textContainsSensitiveValue(_ text: String, sensitiveValue: String) -> Bool {
        let textVariants = sensitiveComparisonValues(for: text)
        let valueVariants = sensitiveComparisonValues(for: sensitiveValue)
        return textVariants.contains { textVariant in
            valueVariants.contains { valueVariant in
                textVariant == valueVariant || textVariant.contains(valueVariant)
            }
        }
    }

    private static func sensitiveComparisonValues(for value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var variants: [String] = [trimmed]
        if let percentDecoded = trimmed.removingPercentEncoding {
            variants.append(percentDecoded)
        }
        variants.append(cssUnescaped(trimmed))
        if let percentDecoded = trimmed.removingPercentEncoding {
            variants.append(cssUnescaped(percentDecoded))
        }
        variants.append(contentsOf: variants.map(compactedSensitiveComparisonValue))
        var seen: Set<String> = []
        return variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func shouldRedactFreeText(for value: String) -> Bool {
        sensitiveComparisonValues(for: value).contains { candidate in
            candidate.count >= 4 || candidate.filter(\.isNumber).count >= 6
        }
    }

    private static func formattedDigitPattern(for value: String) -> String? {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 6 else { return nil }
        let allowedSeparators = CharacterSet(charactersIn: " -")
        let nonDigitScalars = value.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) }
        guard nonDigitScalars.allSatisfy({ allowedSeparators.contains($0) }) else { return nil }
        let body = digits.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\\s-]*")
        return "(?<!\\d)\(body)(?!\\d)"
    }

    private static func replacingMatches(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private static func compactedSensitiveComparisonValue(_ value: String) -> String {
        let compacted = String(value.filter { $0.isLetter || $0.isNumber })
        guard value.contains(where: \.isNumber) || compacted.count > 20 else { return "" }
        return compacted
    }

    private static func cssUnescaped(_ value: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "\\" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }

            var next = value.index(after: index)
            var hex = ""
            while next < value.endIndex,
                  hex.count < 6,
                  value[next].isHexDigit {
                hex.append(value[next])
                next = value.index(after: next)
            }

            if !hex.isEmpty,
               let scalarValue = UInt32(hex, radix: 16),
               let scalar = UnicodeScalar(scalarValue) {
                result.append(Character(scalar))
                if next < value.endIndex, value[next].isWhitespace {
                    next = value.index(after: next)
                }
                index = next
                continue
            }

            if next < value.endIndex {
                result.append(value[next])
                index = value.index(after: next)
            } else {
                result.append("\\")
                index = next
            }
        }
        return result
    }

    private static func strippedSelectorPrefix(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "#."))
    }

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
