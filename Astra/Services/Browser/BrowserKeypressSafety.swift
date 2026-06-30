import Foundation

struct BrowserKeypressSafetyDecision: Equatable {
    let allowed: Bool
    let error: String?
    let hint: String?

    static let allowed = BrowserKeypressSafetyDecision(allowed: true, error: nil, hint: nil)
}

struct BrowserKeypressSafetyState: Equatable {
    var lastSelectAll: BrowserKeypressSafety.SelectAllEvent?
}

enum BrowserKeypressSafety {
    struct SelectAllEvent: Equatable {
        let url: String
        let timestamp: Date
    }

    static let destructiveSequenceWindow: TimeInterval = 8

    static func requiresTextEntryPreflight(key: String, modifiers: [String]) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedModifiers = Set(modifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let isMeta = normalizedModifiers.contains("command")
            || normalizedModifiers.contains("cmd")
            || normalizedModifiers.contains("meta")
        let isControl = normalizedModifiers.contains("control") || normalizedModifiers.contains("ctrl")

        if (isMeta || isControl) && normalizedKey == "v" {
            return true
        }
        if isMeta || isControl {
            return false
        }
        if safeNavigationKeys.contains(normalizedKey) {
            return false
        }
        return normalizedKey.count == 1 || textEditingKeys.contains(normalizedKey)
    }

    static func evaluate(
        key: String,
        modifiers: [String],
        currentURL: String,
        isGoogleWorkspaceEditor: Bool,
        state: inout BrowserKeypressSafetyState,
        now: Date = Date()
    ) -> BrowserKeypressSafetyDecision {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedModifiers = Set(modifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let isMeta = normalizedModifiers.contains("command")
            || normalizedModifiers.contains("cmd")
            || normalizedModifiers.contains("meta")
        let isSelectAll = isMeta && normalizedKey == "a"
        let isDestructiveDelete = normalizedKey == "backspace"
            || normalizedKey == "delete"
            || normalizedKey == "del"

        if isSelectAll {
            if isGoogleWorkspaceEditor {
                state.lastSelectAll = SelectAllEvent(url: currentURL, timestamp: now)
            } else {
                state.lastSelectAll = nil
            }
            return .allowed
        }

        defer {
            if !isDestructiveDelete {
                state.lastSelectAll = nil
            }
        }

        guard isDestructiveDelete,
              isGoogleWorkspaceEditor,
              let lastSelectAll = state.lastSelectAll,
              lastSelectAll.url == currentURL,
              now.timeIntervalSince(lastSelectAll.timestamp) <= destructiveSequenceWindow else {
            return .allowed
        }

        return BrowserKeypressSafetyDecision(
            allowed: false,
            error: "dangerous_keypress_sequence",
            hint: "Blocked Cmd+A followed by Delete/Backspace in a Google editor. Use google-docs-read-document plus google-docs-replace-document when available, or stop for user confirmation instead of erasing document content with raw keyboard events."
        )
    }

    private static let safeNavigationKeys: Set<String> = [
        "arrowdown", "arrowleft", "arrowright", "arrowup",
        "escape", "home", "end", "pagedown", "pageup", "tab"
    ]

    private static let textEditingKeys: Set<String> = [
        "backspace", "delete", "del", "enter", "return", "space"
    ]
}
