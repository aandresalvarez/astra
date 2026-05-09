import Foundation

final class ShelfBrowserBridgeRegistry: @unchecked Sendable {
    static let shared = ShelfBrowserBridgeRegistry()

    private let lock = NSLock()
    private var endpoint: String?
    private var currentURL: String?
    private var currentTitle: String?
    private var backend = "embedded WebKit"
    private var taskID: UUID?
    private var isPresented = false
    private var isEnabled = false

    private init() {}

    func update(
        endpoint: String?,
        currentURL: String?,
        currentTitle: String?,
        backend: String = "embedded WebKit",
        taskID: UUID?,
        isPresented: Bool,
        isEnabled: Bool
    ) {
        lock.lock()
        self.endpoint = endpoint
        self.currentURL = currentURL
        self.currentTitle = currentTitle
        self.backend = backend
        self.taskID = taskID
        self.isPresented = isPresented
        self.isEnabled = isEnabled
        lock.unlock()
    }

    func reset() {
        update(endpoint: nil, currentURL: nil, currentTitle: nil, taskID: nil, isPresented: false, isEnabled: false)
    }

    func environmentVariables(for taskID: UUID) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard isPresented, isEnabled, self.taskID == taskID, let endpoint else { return [:] }
        return [
            "ASTRA_BROWSER_URL": endpoint
        ]
    }

    func promptContext(for taskID: UUID) -> String? {
        lock.lock()
        let endpoint = endpoint
        let currentURL = currentURL
        let currentTitle = currentTitle
        let backend = backend
        let boundTaskID = self.taskID
        let shouldExpose = isPresented && isEnabled
        lock.unlock()

        guard shouldExpose, boundTaskID == taskID, let endpoint else { return nil }

        var pageLine = "Current page: none loaded."
        if let currentURL, !currentURL.isEmpty {
            pageLine = "Current page: \(currentTitle?.isEmpty == false ? "\(currentTitle!) — " : "")\(currentURL)"
        }

        return """
        Shelf Browser Session:
        A user-controlled browser is open in ASTRA's Shelf. It may contain authenticated pages the user opened manually.
        Backend: \(backend)
        Task thread: \(taskID.uuidString)
        Bridge endpoint: \(endpoint)
        \(pageLine)

        Use the provider-neutral `astra-browser` command. It talks to ASTRA_BROWSER_URL and returns compact JSON without curl progress noise:
        - List supported actions: `astra-browser actions`
        - Snapshot compact page state: `astra-browser snapshot --mode summary`
        - Search controls or text: `astra-browser snapshot --mode controls --query "Find"` or `astra-browser snapshot --mode text --query "Saved"`
        - Navigate: `astra-browser navigate "https://example.com"`
        - Fill a field: `astra-browser type --selector 'input[name=email]' --text 'user@example.com'`
        - Set a known field without click/selection steps: `astra-browser set-value --selector '#c7' --text '05/07/2026'`
        - Replace text in editable controls: `astra-browser replace-text --find '05/08/2027' --with '05/07/2026'`
        - Find a specific control without a broad snapshot: `astra-browser find-control --label 'Replace all'`
        - Click a visible control by label: `astra-browser click-control --label 'Replace all'`
        - Verify compact text conditions: `astra-browser verify-text '05/07/2026'` or `astra-browser verify-text --absent '05/08/2027'`
        - Wait for editor save state: `astra-browser wait-saved --timeout 8`
        - For Google Docs/Sheets/Slides text replacement: `astra-browser google-find-replace --find '05/08/2027' --with '05/07/2026'`
        - Combine common steps in one compact turn: `astra-browser act --find 'Replace with' --set '05/07/2026' --click 'Replace all' --wait-saved --verify '05/07/2026'`
        - Click a control: `astra-browser click --selector 'button.primary'`
        - Click a point, such as a canvas/editor surface: `astra-browser click --x 0.5 --y 0.5`
        - Send a keyboard shortcut: `astra-browser keypress --key h --mod command --mod shift`
        - Insert text into the current focused element: `astra-browser text '05/09/2026'`
        - Wait for page state: `astra-browser wait-text 'Saved' --timeout 5` or `astra-browser wait-selector '#c4' --timeout 5`
        - Batch actions to reduce round trips: `astra-browser batch '{"actions":[{"action":"keypress","key":"h","modifiers":["command","shift"]}],"snapshotMode":"summary"}'`

        Safety rules:
        - Use only this bridge for browser operation. Do not use osascript, System Events, AppleScript, macOS UI automation, or external browser automation as a fallback. If a needed browser action is missing, report the missing bridge capability.
        - Never ask the user for passwords, MFA codes, or OAuth secrets. Let the user enter those directly in the browser.
        - Do not send emails, submit tickets/forms, delete data, approve access, make purchases, or commit externally visible changes without explicit user confirmation in the chat.
        - Prefer `/snapshot` before acting, then use selectors or bounds from the snapshot response.
        - When a selector is known, prefer `set-value` or `type --selector` instead of click + Cmd+A + text. If a response includes loopWarning, stop repeating the same click/snapshot path and switch strategy.
        - For Google Docs, Sheets, or Slides editing, prefer Controlled mode when available. For date/text swaps, try `google-find-replace` first, then `wait-saved`, then `verify-text`; use manual compact control queries only if the helper reports missing fields. Avoid AppleScript/System Events, repeated menu clicks, and synthetic selection shortcuts when snapshots are unchanged.
        """
    }
}
