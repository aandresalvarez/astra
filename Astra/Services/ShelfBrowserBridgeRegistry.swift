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
        if !isPresented, taskID == nil, self.taskID != nil, self.isPresented {
            let activeTaskID = self.taskID
            let fields = [
                "event": "inactive_unbound_update_ignored",
                "incoming_has_endpoint": String(endpoint != nil),
                "incoming_has_current_url": String(currentURL?.isEmpty == false),
                "active_task_id": self.taskID?.uuidString ?? "",
                "active_has_endpoint": String(self.endpoint != nil),
                "active_has_current_url": String(self.currentURL?.isEmpty == false),
                "backend": backend
            ]
            lock.unlock()
            AppLogger.audit(
                .shelfBrowserContext,
                category: "Browser",
                taskID: activeTaskID,
                fields: fields,
                level: .debug
            )
            return
        }

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
        lock.lock()
        endpoint = nil
        currentURL = nil
        currentTitle = nil
        backend = "embedded WebKit"
        taskID = nil
        isPresented = false
        isEnabled = false
        lock.unlock()
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

        let isTaskBound = boundTaskID == taskID
        let isExposed = shouldExpose && isTaskBound && endpoint != nil
        AppLogger.audit(.shelfBrowserContext, category: "Browser", taskID: taskID, fields: [
            "event": "prompt_context_requested",
            "exposed": String(isExposed),
            "is_presented": String(shouldExpose),
            "is_task_bound": String(isTaskBound),
            "has_endpoint": String(endpoint != nil),
            "has_current_url": String(currentURL?.isEmpty == false),
            "backend": backend
        ])

        guard isExposed, let endpoint else { return nil }

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
        - Read current page content: `astra-browser page --limit 2000`
        - Snapshot compact page state: `astra-browser snapshot --mode summary`
        - Locate controls by role/name/text: `astra-browser locator --role button --name "Save"`
        - Search controls or text: `astra-browser snapshot --mode controls --query "Find"` or `astra-browser snapshot --mode text --query "Saved"`
        - Navigate: `astra-browser navigate "https://example.com"`
        - Fill a field: `astra-browser type --selector 'input[name=email]' --text 'user@example.com'`
        - Fill by label/placeholder/test id: `astra-browser fill --label Email --text 'user@example.com'`
        - Set a known field without click/selection steps: `astra-browser set-value --selector '#c7' --text '05/07/2026'`
        - Replace text in editable controls: `astra-browser replace-text --find '05/08/2027' --with '05/07/2026'`
        - Find a specific control without a broad snapshot: `astra-browser find-control --label 'Replace all'`
        - Click a visible control by label: `astra-browser click-control --label 'Replace all'`
        - Verify compact text conditions: `astra-browser verify-text '05/07/2026'` or `astra-browser verify-text --absent '05/08/2027'`
        - Wait for editor save state: `astra-browser wait-saved --timeout 8`
        - For Google Docs/Sheets/Slides text replacement: `astra-browser google-find-replace --find '05/08/2027' --with '05/07/2026'`
        - For Google Docs insertion: `astra-browser google-docs-insert --verify 'A Gentle Morning' --text 'A Gentle Morning\n...'`
        - For Google Docs verification: `astra-browser google-docs-find --query 'A Gentle Morning'`
        - For Google Drive file opening by visible name: `astra-browser google-drive-open --name 'Untitled document'`
        - Combine common steps in one compact turn: `astra-browser act --find 'Replace with' --set '05/07/2026' --click 'Replace all' --wait-saved --verify '05/07/2026'`
        - Click a control: `astra-browser click --selector 'button.primary'`
        - Click by role/name: `astra-browser click --role button --name "Save"`
        - Click a point, such as a canvas/editor surface: `astra-browser click --x 0.5 --y 0.5`
        - Send a keyboard shortcut: `astra-browser keypress --key h --mod command --mod shift`
        - Insert text into the current focused element: `astra-browser text '05/09/2026'`
        - Wait for page state: `astra-browser wait-text 'Saved' --timeout 5` or `astra-browser wait-selector '#c4' --timeout 5`
        - Batch actions to reduce round trips: `astra-browser batch '{"actions":[{"action":"keypress","key":"h","modifiers":["command","shift"]}],"snapshotMode":"summary"}'`

        Safety rules:
        - Use only this bridge for browser operation. Do not use osascript, System Events, AppleScript, macOS UI automation, or external browser automation as a fallback. If a needed browser action is missing, report the missing bridge capability.
        - Never ask the user for passwords, MFA codes, or OAuth secrets. Let the user enter those directly in the browser.
        - Do not send emails, submit tickets/forms, delete data, approve access, make purchases, or commit externally visible changes without explicit user confirmation in the chat.
        - For questions about what is on the current page, start with `astra-browser page --limit 2000`; use controls snapshots only when you need to select, click, or fill a control.
        - On Google Drive, use `google-drive-open` before manual row clicks, double-clicks, context menus, or broad control snapshots.
        - Prefer `locator` or `/snapshot` before acting, then use selectors, role/name locators, or bounds from the response.
        - When a selector or label is known, prefer `fill`, `set-value`, or `type` instead of click + Cmd+A + text. If a response includes loopWarning, stop repeating the same click/snapshot path and switch strategy.
        - For Google Docs, Sheets, or Slides editing, prefer Controlled mode when available. For Google Docs writing, use `google-docs-insert` instead of manual click + text + Find verification. For date/text swaps, try `google-find-replace` first, then `wait-saved`, then `verify-text`; use manual compact control queries only if the helper reports missing fields. Avoid AppleScript/System Events, repeated menu clicks, and synthetic selection shortcuts when snapshots are unchanged.
        """
    }
}
