import Foundation

final class ShelfBrowserBridgeRegistry: @unchecked Sendable {
    static let shared = ShelfBrowserBridgeRegistry()

    struct PromptState: Sendable, Equatable {
        var isEnabled: Bool
        var isPresented: Bool
        var isTaskBound: Bool
        var hasEndpoint: Bool
        var hasCurrentURL: Bool
        var enabledBrowserAdapters: [String]

        var isExposed: Bool {
            isEnabled && isTaskBound && hasEndpoint
        }
    }

    private let lock = NSLock()
    private var endpoint: String?
    private var currentURL: String?
    private var currentTitle: String?
    private var backend = "embedded WebKit"
    private var taskID: UUID?
    private var accessToken: String?
    private var isPresented = false
    private var isEnabled = false
    private var enabledBrowserAdapters: [String] = []

    private init() {}

    func update(
        endpoint: String?,
        currentURL: String?,
        currentTitle: String?,
        backend: String = "embedded WebKit",
        taskID: UUID?,
        accessToken: String? = nil,
        isPresented: Bool,
        isEnabled: Bool,
        enabledBrowserAdapters: [String] = []
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
        self.accessToken = accessToken
        self.isPresented = isPresented
        self.isEnabled = isEnabled
        self.enabledBrowserAdapters = normalizedAdapterList(enabledBrowserAdapters)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        endpoint = nil
        currentURL = nil
        currentTitle = nil
        backend = "embedded WebKit"
        taskID = nil
        accessToken = nil
        isPresented = false
        isEnabled = false
        enabledBrowserAdapters = []
        lock.unlock()
    }

    func environmentVariables(for taskID: UUID) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled, self.taskID == taskID, let endpoint else { return [:] }
        var variables = [
            "ASTRA_BROWSER_URL": endpoint
        ]
        if let accessToken, !accessToken.isEmpty {
            variables["ASTRA_BROWSER_TOKEN"] = accessToken
        }
        if BrowserFailureDebugCapture.isEnabledByDefault() {
            variables[BrowserFailureDebugCapture.environmentVariable] = "1"
        }
        return variables
    }

    func promptState(for taskID: UUID, enabledBrowserAdapters override: [String]? = nil) -> PromptState {
        lock.lock()
        let boundTaskID = self.taskID
        let isPresented = self.isPresented
        let isEnabled = self.isEnabled
        let hasEndpoint = endpoint != nil
        let hasCurrentURL = currentURL?.isEmpty == false
        let storedAdapterIDs = enabledBrowserAdapters
        lock.unlock()

        return PromptState(
            isEnabled: isEnabled,
            isPresented: isPresented,
            isTaskBound: boundTaskID == taskID,
            hasEndpoint: hasEndpoint,
            hasCurrentURL: hasCurrentURL,
            enabledBrowserAdapters: override.map(normalizedAdapterList) ?? storedAdapterIDs
        )
    }

    func promptContext(for taskID: UUID, enabledBrowserAdapters override: [String]? = nil) -> String? {
        lock.lock()
        let endpoint = endpoint
        let currentURL = currentURL
        let currentTitle = currentTitle
        let backend = backend
        let boundTaskID = self.taskID
        let isVisible = isPresented
        let shouldExpose = isEnabled
        let storedAdapterIDs = enabledBrowserAdapters
        lock.unlock()
        let adapterIDs = override.map(normalizedAdapterList) ?? storedAdapterIDs
        let hasGoogleDriveAdapter = adapterIDs.contains(BrowserSiteAdapterID.googleDrive)
        let currentHost = currentURL.flatMap { URL(string: $0)?.host?.lowercased() } ?? ""
        let isGoogleDriveOrDocsPage = currentHost == "drive.google.com" || currentHost == "docs.google.com"
        let shouldSurfaceGoogleDriveHelper = hasGoogleDriveAdapter || isGoogleDriveOrDocsPage
        let hasGitHubAdapter = adapterIDs.contains(BrowserSiteAdapterID.github)

        let isTaskBound = boundTaskID == taskID
        let isExposed = shouldExpose && isTaskBound && endpoint != nil
        AppLogger.audit(.shelfBrowserContext, category: "Browser", taskID: taskID, fields: [
            "event": "prompt_context_requested",
            "exposed": String(isExposed),
            "is_presented": String(isVisible),
            "is_enabled": String(isEnabled),
            "is_task_bound": String(isTaskBound),
            "has_endpoint": String(endpoint != nil),
            "has_current_url": String(currentURL?.isEmpty == false),
            "browser_adapter_ids": adapterIDs.isEmpty ? "none" : adapterIDs.joined(separator: ","),
            "backend": backend
        ])

        guard isExposed, let endpoint else { return nil }

        var pageLine = "Current page: none loaded."
        if let currentURL, !currentURL.isEmpty {
            pageLine = "Current page: \(currentTitle?.isEmpty == false ? "\(currentTitle!) — " : "")\(currentURL)"
        }

        let driveCommandLine = shouldSurfaceGoogleDriveHelper
            ? "- For Google Drive file opening by visible name: `astra-browser google-drive-open --name 'Untitled document'`; the helper respects the selected browser engine unless Settings > Appearance > Privacy & Logging > Auto-promote Google Workspace helpers is enabled."
            : ""
        let githubCommandLine = hasGitHubAdapter
            ? "- On GitHub pages, prefer the GitHub capability (`gh` CLI/API) for durable issue, PR, repository, and Actions reads; use browser control for authenticated visual state or page navigation."
            : ""
        let driveSafetyLine = shouldSurfaceGoogleDriveHelper
            ? "- On Google Drive, use `google-drive-open` before manual row clicks, double-clicks, context menus, or broad control snapshots. A Drive row click commonly selects a file without opening it; if `drive_file_not_opened`, `drive_file_name_mismatch`, or `controlled_browser_unavailable` is returned, stop instead of probing rows or editing the opened page."
            : "- Site-specific helpers are capability-gated. If `analyze` reports an enabled `siteAdapters` entry, prefer its listed adapter actions; otherwise use generic control IDs and preflight."
        let adapterLine = adapterIDs.isEmpty
            ? "Enabled browser site adapters: none"
            : "Enabled browser site adapters: \(adapterIDs.joined(separator: ", "))"

        return """
        Shelf Browser Session:
        A user-controlled browser is open in ASTRA's Shelf. It may contain authenticated pages the user opened manually.
        Backend: \(backend)
        Task thread: \(taskID.uuidString)
        Bridge endpoint: \(endpoint)
        \(adapterLine)
        \(pageLine)

        Use the provider-neutral `astra-browser` command. It talks to ASTRA_BROWSER_URL and returns compact JSON without curl progress noise:
        - List supported actions: `astra-browser actions`
        - Inspect compact navigation/action diagnostics: `astra-browser trace`; failed actions retain a screenshot thumbnail, compact tree, and console/navigation/network events when Browser Debug Capture is enabled in Settings > Appearance > Privacy & Logging. Prefix one command with `ASTRA_BROWSER_DEBUG_CAPTURE=0` to suppress capture for that command.
        - Build a deterministic action map: `astra-browser analyze` or `astra-browser analyze --query "Save"`; v2 semantic controlRefs/source evidence are the default.
        - Inspect every discovered control when debugging: `astra-browser analyze --full --debug`
        - Validate a cached action without executing it: `astra-browser preflight --analysis ana_... --control ctl_... --action click`
        - Prefer control IDs from analyze when acting: `astra-browser click --analysis ana_... --control ctl_...`; action responses include actionability and postActionWait diagnostics.
        - Open an analyzed control through its primary open behavior: `astra-browser open --analysis ana_... --control ctl_...`
        - Double-click an analyzed control when that is the listed action: `astra-browser double-click --analysis ana_... --control ctl_...`
        - After a controlID action, read `goalSatisfied`, `observedOutcome`, and `suggestedNextActions`; `ok` only means the browser command executed.
        - Fill analyzed fields by ID: `astra-browser fill --analysis ana_... --control ctl_... --text 'user@example.com'`
        - Read current page content with coverage/frame warnings: `astra-browser read-page --format markdown --limit 50000`
        - Quick compact text read: `astra-browser page --limit 2000`
        - Snapshot compact page state: `astra-browser snapshot --mode summary`
        - Locate controls by role/name/text: `astra-browser locator --role button --name "Save"`
        - Search controls or text: `astra-browser snapshot --mode controls --query "Find"` or `astra-browser snapshot --mode text --query "Saved"`
        - Navigate: `astra-browser navigate "https://example.com"`; navigation waits for URL/title/loading state to settle before returning.
        - Fill a field: `astra-browser type --selector 'input[name=email]' --text 'user@example.com'`
        - Fill by label/placeholder/test id: `astra-browser fill --label Email --text 'user@example.com'`
        - Set a known field without click/selection steps: `astra-browser set-value --selector '#c7' --text '05/07/2026'`
        - Replace text in editable controls: `astra-browser replace-text --find '05/08/2027' --with '05/07/2026'`
        - Find a specific control without a broad snapshot: `astra-browser find-control --label 'Replace all'`
        - Click a visible control by exact label: `astra-browser click-control --label 'Replace all'`; if labels are ambiguous or only loosely related, use `analyze` plus `controlID` instead.
        - Verify compact text conditions: `astra-browser verify-text '05/07/2026'` or `astra-browser verify-text --absent '05/08/2027'`
        - Wait for editor save state: `astra-browser wait-saved --timeout 8`
        - For Google Docs/Sheets/Slides text replacement: `astra-browser google-find-replace --find '05/08/2027' --with '05/07/2026'`
        - For Google Docs insertion: `astra-browser google-docs-insert --verify 'A Gentle Morning' --text 'A Gentle Morning\n...'`
        - For read-only Google Docs page summaries: `astra-browser google-docs-read-visible-page --format markdown --limit 50000`; this uses page-read coverage metadata, is partial by design, and must be summarized as visible/returned content only.
        - For full Google Docs reads: `astra-browser google-docs-read-document`; it uses the browser like a person: focus the editor, select all, copy, read the clipboard, then restore the clipboard. Full-document copy requires Controlled mode, or Settings > Appearance > Privacy & Logging > Auto-promote Google Workspace helpers. If it returns `google_docs_controlled_browser_required` or `google_docs_browser_copy_unavailable`, stop instead of probing the editor.
        - For full Google Docs replacement: `astra-browser google-docs-replace-document --verify 'A Gentle Morning' --text 'full replacement content'`; it backs up by browser copy, selects all, pastes the replacement, waits for Saved, verifies, and rolls back if verification fails. Full-document replacement requires Controlled mode, or Auto-promote. If it returns `google_docs_controlled_browser_required`, `google_docs_safe_edit_unavailable`, or verification fails, stop instead of using raw keyboard deletion.
        - For Google Docs verification: `astra-browser google-docs-find --query 'A Gentle Morning'`
        \(driveCommandLine)
        \(githubCommandLine)
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
        - On mail pages, read-only tasks must not click Reply, Reply all, Forward, Send, Delete, Archive, Move, Mark read/unread, Junk, Report phishing, or Discard; these controls are blocked unless the user explicitly confirms the mailbox mutation.
        - For questions about what is on the current page, start with `astra-browser read-page --format markdown --limit 50000` and inspect `coverage`, `truncated`, `frames`, and `warnings`; for Google Docs read-only page summaries, prefer `astra-browser google-docs-read-visible-page --format markdown --limit 50000` and do not escalate to `google-docs-read-document` just because coverage is partial. When you need to select, click, or fill a control, start with `astra-browser analyze` and use returned control IDs.
        \(driveSafetyLine)
        - Prefer `analyze` before acting, then use `analysisID` + `controlID`. Use `locator` or `/snapshot` only when analysis is too broad or you need raw evidence.
        - When `analyze` reports `ambiguity`, compare labels, roles, bounds, file type, and folder/opened metadata before selecting a controlID.
        - When a selector or label is known, prefer `fill`, `set-value`, or `type` instead of click + Cmd+A + text. If a response includes loopWarning, stop repeating the same click/snapshot path and switch strategy.
        - Cached analysis is a hint, not authority. If an action returns `stale_analysis`, `control_changed`, `target_obscured`, or `dangerous_confirmation_required`, stop and re-analyze or ask for confirmation as directed.
        - For Google Docs, Sheets, or Slides editing, use the site-specific helpers; they respect the selected browser engine unless Settings > Appearance > Privacy & Logging > Auto-promote Google Workspace helpers is enabled. For Google Docs writing, use `google-docs-insert` for insertion and `google-docs-replace-document` for full-document replacement. The full-document helper is the allowed browser copy/select-all/paste workflow and requires Controlled mode for reliable Docs iframe clipboard access; do not improvise your own raw select-all/delete sequence. For read-only summaries in embedded mode, use `google-docs-read-visible-page` once and clearly state partial coverage instead of trying export URLs, curl, or repeated editor probing. For date/text swaps, try `google-find-replace` first, then `wait-saved`, then `verify-text`; use manual compact control queries only if the helper reports missing fields. Never use `keypress --key a --mod command` followed by Backspace/Delete in Google editors; the bridge blocks that sequence to prevent data loss.
        """
    }

    private func normalizedAdapterList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let normalized = BrowserSiteAdapterID.normalized(value),
                  seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
