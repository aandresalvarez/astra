import Foundation

enum ShelfBrowserBridgeRoute: CaseIterable, Equatable {
    case health
    case actions
    case analyze
    case trace
    case benchmark
    case preflight
    case snapshot
    case readPage
    case navigate
    case type
    case setValue
    case replaceText
    case findControl
    case locator
    case clickControl
    case verifyText
    case waitSaved
    case googleFindReplace
    case googleDocsFind
    case googleDocsInsert
    case googleDocsReadVisiblePage
    case googleDocsReadDocument
    case googleDocsReplaceDocument
    case googleDriveOpen
    case act
    case click
    case open
    case doubleClick
    case fill
    case keypress
    case text
    case waitForText
    case waitForSelector
    case batch

    var isAvailableWhenBridgeDisabled: Bool {
        switch self {
        case .health, .actions:
            return true
        default:
            return false
        }
    }

    var isFlightRecorded: Bool {
        switch self {
        case .health, .actions, .trace, .benchmark:
            return false
        default:
            return true
        }
    }

    var isRunGuarded: Bool {
        switch self {
        case .health, .actions, .trace, .benchmark:
            return false
        default:
            return true
        }
    }
}

enum ShelfBrowserBridgeCommandRouter {
    static func route(method: String, path: String) -> ShelfBrowserBridgeRoute? {
        switch (method.uppercased(), path) {
        case ("GET", "/health"): .health
        case ("GET", "/actions"): .actions
        case ("GET", "/analyze"): .analyze
        case ("GET", "/trace"): .trace
        case ("GET", "/benchmark"): .benchmark
        case ("POST", "/preflight"): .preflight
        case ("GET", "/snapshot"): .snapshot
        case ("GET", "/readPage"): .readPage
        case ("POST", "/navigate"): .navigate
        case ("POST", "/type"): .type
        case ("POST", "/setValue"): .setValue
        case ("POST", "/replaceText"): .replaceText
        case ("GET", "/findControl"): .findControl
        case ("GET", "/locator"): .locator
        case ("POST", "/clickControl"): .clickControl
        case ("POST", "/verifyText"): .verifyText
        case ("POST", "/waitSaved"): .waitSaved
        case ("POST", "/googleFindReplace"): .googleFindReplace
        case ("POST", "/googleDocsFind"): .googleDocsFind
        case ("POST", "/googleDocsInsert"): .googleDocsInsert
        case ("POST", "/googleDocsReadVisiblePage"): .googleDocsReadVisiblePage
        case ("POST", "/googleDocsReadDocument"): .googleDocsReadDocument
        case ("POST", "/googleDocsReplaceDocument"): .googleDocsReplaceDocument
        case ("POST", "/googleDriveOpen"): .googleDriveOpen
        case ("POST", "/act"): .act
        case ("POST", "/click"): .click
        case ("POST", "/open"): .open
        case ("POST", "/doubleClick"): .doubleClick
        case ("POST", "/fill"): .fill
        case ("POST", "/keypress"): .keypress
        case ("POST", "/text"): .text
        case ("POST", "/waitForText"): .waitForText
        case ("POST", "/waitForSelector"): .waitForSelector
        case ("POST", "/batch"): .batch
        default: nil
        }
    }

    static func actionsResponse(
        backend: String,
        automationEngine: BrowserAutomationEngineDescriptor,
        capabilities: [String],
        canUseGoogleDriveOpen: Bool,
        googleDriveOpenDefaultTimeoutSeconds: Double
    ) -> [String: Any] {
        [
            "ok": true,
            "backend": backend,
            "automationEngine": automationEngine.jsonObject,
            "capabilities": capabilities,
            "actionMetadataVersion": 1,
            "actions": BrowserBridgeActionMetadata.enriched(actionMetadata(
                canUseGoogleDriveOpen: canUseGoogleDriveOpen,
                googleDriveOpenDefaultTimeoutSeconds: googleDriveOpenDefaultTimeoutSeconds
            ))
        ]
    }

    static func actionMetadata(
        canUseGoogleDriveOpen: Bool,
        googleDriveOpenDefaultTimeoutSeconds: Double
    ) -> [[String: Any]] {
        [
            [
                "method": "GET",
                "path": "/health",
                "description": "Check bridge status, current URL, title, backend, and whether agent control is enabled."
            ],
            [
                "method": "GET",
                "path": "/actions",
                "description": "List supported browser bridge actions."
            ],
            [
                "method": "GET",
                "path": "/analyze",
                "query": ["query": "optional text", "full": "optional true|false", "limit": "optional number", "debug": "optional true|false", "v2": "optional true|false", "version": "optional v1|v2"],
                "description": "Deterministically scan the current rendered page and return a cached action map with analysisID, controlIDs, valid actions, primary action, expected outcomes, ambiguity hints, risk, confidence, and concise evidence. v2 semantic controlRefs, source breakdown, and accessibility matching are enabled by default. ASTRA_BROWSER_ANALYSIS_V2 or user defaults can set off/shadow/on rollout."
            ],
            [
                "method": "GET",
                "path": "/trace",
                "description": "Return the most recent compact browser action trace and the retained per-task browser flight timeline for supervision. When Browser Debug Capture is enabled, failed browser actions also retain a privacy-redacted screenshot thumbnail, compact tree, and console/navigation/network events. Use ASTRA_BROWSER_DEBUG_CAPTURE=0 to suppress capture for one command."
            ],
            [
                "method": "GET",
                "path": "/benchmark",
                "description": "Return the built-in Browser Control V2 benchmark suite definition and metric schema."
            ],
            [
                "method": "POST",
                "path": "/preflight",
                "body": ["analysisID": "ana_...", "controlID": "ctl_...", "action": "click", "allowDangerous": false],
                "description": "Validate a cached control action against the live page without executing it. Mutating controlID actions run this check automatically."
            ],
            [
                "method": "GET",
                "path": "/snapshot",
                "query": ["mode": "summary|text|controls|full", "query": "optional text", "limit": "optional number"],
                "description": "Read current page URL, title, viewport, focused element, visible text, and actionable controls. Use compact modes to reduce provider context."
            ],
            [
                "method": "GET",
                "path": "/readPage",
                "query": ["format": "text|markdown|json", "limit": "optional character count", "chunkSize": "optional character count"],
                "description": "Read page content with explicit coverage, truncation, frame, and warning metadata. Prefer this for content questions; use analyze for action planning."
            ],
            [
                "method": "POST",
                "path": "/navigate",
                "body": ["url": "https://example.com"],
                "description": "Navigate the browser to a URL or search phrase, then wait briefly for URL/title/loading state to settle."
            ],
            [
                "method": "POST",
                "path": "/type",
                "body": ["selector": "input[name=email]", "text": "user@example.com", "clear": true],
                "description": "Focus a selector, type text, and dispatch input/change events."
            ],
            [
                "method": "POST",
                "path": "/setValue",
                "body": ["selector": "input[name=email]", "text": "user@example.com"],
                "description": "Set an input, textarea, select, or contenteditable value in one reliable action. Prefer this over click plus text when a selector is known."
            ],
            [
                "method": "POST",
                "path": "/replaceText",
                "body": ["find": "old text", "replacement": "new text", "selector": "optional", "all": true],
                "description": "Replace text inside editable controls. For Google Docs, Sheets, and Slides canvas text, use the returned hint to drive the Find and Replace dialog with setValue."
            ],
            [
                "method": "GET",
                "path": "/findControl",
                "query": ["query": "visible label/value text", "role": "optional", "limit": "optional number"],
                "description": "Return only matching controls. Prefer this over broad snapshots when looking for a button or field."
            ],
            [
                "method": "GET",
                "path": "/locator",
                "query": ["query": "visible label/text", "role": "optional", "limit": "optional number"],
                "description": "Playwright-style locator lookup over visible controls by role, label, placeholder, test id, text, or selector."
            ],
            [
                "method": "POST",
                "path": "/clickControl",
                "body": ["label": "Replace all", "role": "optional", "allowDangerous": false],
                "description": "Find a visible control by label/value/role and click it in one compact action."
            ],
            [
                "method": "POST",
                "path": "/verifyText",
                "body": ["text": "expected text", "absent": false],
                "description": "Compactly assert whether page text contains or does not contain a string."
            ],
            [
                "method": "POST",
                "path": "/waitSaved",
                "body": ["timeoutSeconds": 8],
                "description": "Wait for editor save indicators such as Saved, All changes saved, Last edit, or for Saving to disappear."
            ],
            [
                "method": "POST",
                "path": "/googleFindReplace",
                "body": ["find": "05/08/2027", "replacement": "05/07/2026", "all": true],
                "description": "Best-effort Google Docs/Sheets/Slides Find and Replace workflow using compact control queries and direct field setting."
            ],
            [
                "method": "POST",
                "path": "/googleDocsFind",
                "body": ["query": "Gentle Morning", "closeFindBar": true],
                "description": "Verify text in a Google Docs document using the in-document Find bar, which can see canvas-rendered document content."
            ],
            [
                "method": "POST",
                "path": "/googleDocsInsert",
                "body": ["text": "Text to insert", "verifyText": "short unique phrase", "waitSaved": true],
                "description": "Focus the current Google Docs editor, insert text, wait for Drive save, and verify via in-document Find in one call."
            ],
            [
                "method": "POST",
                "path": "/googleDocsReadVisiblePage",
                "body": ["format": "text|markdown|json", "limit": "optional character count", "chunkSize": "optional character count"],
                "description": "Read visible Google Docs page content through the page-read service. This is read-only and may be partial; use it for partial summaries when full-document copy is unavailable."
            ],
            [
                "method": "POST",
                "path": "/googleDocsReadDocument",
                "body": [:],
                "description": "Read the full current Google Docs document through the browser using focus, select-all, copy, and clipboard restore. If browser copy is unavailable, may fall back to an authenticated Docs API read path."
            ],
            [
                "method": "POST",
                "path": "/googleDocsReplaceDocument",
                "body": ["text": "Full replacement content", "verifyText": "short unique phrase"],
                "description": "Replace the full current Google Docs document through the browser using backup copy, select-all, paste, wait-saved, verify, and rollback on verification failure. It never uses raw select-all/delete."
            ],
            [
                "method": "POST",
                "path": "/googleDriveOpen",
                "body": ["name": "Untitled document", "timeoutSeconds": googleDriveOpenDefaultTimeoutSeconds],
                "enabled": canUseGoogleDriveOpen,
                "adapterID": BrowserSiteAdapterID.googleDrive,
                "description": "Open a Google Drive file by visible name using Drive search, submit, and a compact load verification. Available on Drive pages and through the Google Drive Browser capability."
            ],
            [
                "method": "POST",
                "path": "/act",
                "body": ["find": "Replace with", "set": "05/07/2026", "click": "Replace all", "waitSaved": true, "verify": "05/07/2026"],
                "description": "Run a compact multi-step browser action: find and set a control, click a control, wait for save, and verify text."
            ],
            [
                "method": "POST",
                "path": "/click",
                "body": ["selector": "button.primary", "label": "Save", "role": "button", "x": 0.5, "y": 0.5, "allowDangerous": false],
                "description": "Click a selector, locator, viewport point, or analyzed controlID after visibility, enabled, stable-bounds, viewport, and obstruction checks. Submit/send/delete/payment-style controls require explicit allowDangerous true after user confirmation. Responses include actionability and postActionWait diagnostics; controlID responses also include outcome fields."
            ],
            [
                "method": "POST",
                "path": "/open",
                "body": ["analysisID": "ana_...", "controlID": "ctl_...", "allowDangerous": false],
                "description": "Open an analyzed controlID using the control's primary open behavior. Enabled site adapters may provide specialized open behavior."
            ],
            [
                "method": "POST",
                "path": "/doubleClick",
                "body": ["analysisID": "ana_...", "controlID": "ctl_...", "allowDangerous": false],
                "description": "Double-click a selector, locator, point, or analyzed controlID and return outcome fields for controlID usage."
            ],
            [
                "method": "POST",
                "path": "/fill",
                "body": ["label": "Email", "text": "user@example.com"],
                "description": "Fill an editable control by selector, label, role, placeholder, or test id with actionability checks and a post-action settle wait."
            ],
            [
                "method": "POST",
                "path": "/keypress",
                "body": ["key": "h", "modifiers": ["command", "shift"]],
                "description": "Send a keyboard shortcut or keypress to the current page or focused element."
            ],
            [
                "method": "POST",
                "path": "/text",
                "body": ["text": "05/09/2026"],
                "description": "Insert text at the currently focused field or editor insertion point."
            ],
            [
                "method": "POST",
                "path": "/waitForText",
                "body": ["text": "Saved", "timeoutSeconds": 5],
                "description": "Poll compact page text until matching text appears or the timeout is reached."
            ],
            [
                "method": "POST",
                "path": "/waitForSelector",
                "body": ["selector": "input[name=q]", "timeoutSeconds": 5],
                "description": "Poll actionable controls until a selector appears or the timeout is reached."
            ],
            [
                "method": "POST",
                "path": "/batch",
                "body": [
                    "actions": [
                        ["action": "analyze"],
                        ["action": "set-value", "analysisID": "ana_...", "controlID": "ctl_...", "text": "05/09/2026"]
                    ],
                    "snapshotMode": "summary"
                ],
                "description": "Run multiple browser actions in one bridge request, including controlID actions. Each mutating controlID step preflights live state, returns outcome fields, and stops on stale, blocked, or dangerous failures."
            ]
        ]
    }
}
