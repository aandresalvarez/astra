import Foundation

extension BrowserControl {
    var providerVisibleRedaction: (object: [String: Any], didRedact: Bool, sensitiveValues: [String]) {
        BrowserSensitiveInputRedactionPolicy.redactControlObject(rawControlObject, risk: risk)
    }

    var rawControlObject: [String: Any] {
        [
            "selector": selector,
            "label": label,
            "name": name,
            "role": role,
            "tag": tag,
            "type": type,
            "placeholder": placeholder,
            "testID": testID,
            "value": value,
            "href": href,
            "autocomplete": autocomplete
        ]
    }

    func providerVisibleString(_ key: String, fallback: String) -> String {
        providerVisibleRedaction.object[key] as? String ?? fallback
    }

    func redactedAccessibilityText(_ text: String) -> String {
        guard hasProviderVisibleRedaction else {
            return text
        }
        let metadataRedacted = redactedDisplayText(text)
        if metadataRedacted != text {
            return metadataRedacted
        }
        if providerVisibleSensitiveValues.isEmpty {
            return redactedUnknownSensitiveAccessibilityText(text)
        }
        if value == BrowserSensitiveInputRedactionPolicy.redactedInputValue {
            return knownSafeAccessibilityText(text)
                ? text
                : redactedUnknownSensitiveAccessibilityText(text)
        }
        return BrowserSensitiveInputRedactionPolicy.redactedDisplayText(text, sensitiveValue: value)
    }

    func redactedAccessibilityValue(_ text: String) -> String {
        guard hasProviderVisibleRedaction else {
            return text
        }
        if providerVisibleSensitiveValues.isEmpty {
            return redactedUnknownSensitiveAccessibilityText(text)
        }
        if value == BrowserSensitiveInputRedactionPolicy.redactedInputValue {
            return redactedUnknownSensitiveAccessibilityText(text)
        }
        return BrowserSensitiveInputRedactionPolicy.redactedDisplayText(text, sensitiveValue: value)
    }

    func redactedAccessibilityNodeObject(_ node: BrowserAccessibilityNode) -> [String: Any] {
        var object = node.jsonObject
        object["name"] = redactedAccessibilityText(node.name)
        object["value"] = redactedAccessibilityValue(node.value)
        object["description"] = redactedAccessibilityText(node.description)
        object["properties"] = node.properties.mapValues(redactedAccessibilityValue)
        return object
    }

    var hasProviderVisibleRedaction: Bool {
        providerVisibleValue == BrowserSensitiveInputRedactionPolicy.redactedInputValue
            || redactedLabel != label
            || redactedName != name
            || redactedDisplayText(selector) != selector
            || redactedDisplayText(placeholder) != placeholder
            || redactedDisplayText(testID) != testID
            || redactedDisplayText(href) != href
    }

    var providerVisibleSensitiveValues: [String] {
        providerVisibleRedaction.sensitiveValues
    }

    private func knownSafeAccessibilityText(_ text: String) -> Bool {
        let normalizedText = BrowserAnalysisBuilder.normalizedName(text)
        guard !normalizedText.isEmpty else { return true }
        return [label, name, placeholder]
            .map(BrowserAnalysisBuilder.normalizedName)
            .contains(normalizedText)
    }

    private func redactedUnknownSensitiveAccessibilityText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? text
            : BrowserSensitiveInputRedactionPolicy.redactedInputValue
    }
}
