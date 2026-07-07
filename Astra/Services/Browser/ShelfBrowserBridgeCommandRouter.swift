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

protocol ShelfBrowserBridgeCommandHandling {
    var route: ShelfBrowserBridgeRoute { get }
    var method: String { get }
    var path: String { get }
    var batchAliases: [String] { get }

    func metadata(
        canUseGoogleDriveOpen: Bool,
        googleDriveOpenDefaultTimeoutSeconds: Double
    ) -> [String: Any]
}

struct ShelfBrowserBridgeCommandSpec: ShelfBrowserBridgeCommandHandling {
    let route: ShelfBrowserBridgeRoute
    let method: String
    let path: String
    let batchAliases: [String]

    private let description: String
    private let query: [String: String]?
    private let body: [String: Any]?
    private let extraMetadata: (Bool, Double) -> [String: Any]

    init(
        route: ShelfBrowserBridgeRoute,
        method: String,
        path: String,
        description: String,
        query: [String: String]? = nil,
        body: [String: Any]? = nil,
        batchAliases: [String] = [],
        extraMetadata: @escaping (Bool, Double) -> [String: Any] = { _, _ in [:] }
    ) {
        self.route = route
        self.method = method.uppercased()
        self.path = path
        self.description = description
        self.query = query
        self.body = body
        self.batchAliases = batchAliases
        self.extraMetadata = extraMetadata
    }

    func matches(method candidateMethod: String, path candidatePath: String) -> Bool {
        method == candidateMethod.uppercased() && path == candidatePath
    }

    func matches(batchAction action: String) -> Bool {
        let normalized = Self.normalizedBatchAction(action)
        return batchAliases.contains { Self.normalizedBatchAction($0) == normalized }
    }

    func metadata(
        canUseGoogleDriveOpen: Bool,
        googleDriveOpenDefaultTimeoutSeconds: Double
    ) -> [String: Any] {
        var object: [String: Any] = [
            "method": method,
            "path": path,
            "description": description
        ]
        if let query {
            object["query"] = query
        }
        if let body {
            object["body"] = body
        }
        let dynamic = extraMetadata(canUseGoogleDriveOpen, googleDriveOpenDefaultTimeoutSeconds)
        for (key, value) in dynamic {
            object[key] = value
        }
        return object
    }

    static func normalizedBatchAction(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum ShelfBrowserBridgeCommandRouter {
    static let registeredCommands: [ShelfBrowserBridgeCommandSpec] = [
        ShelfBrowserBridgeCommandSpec(
            route: .health,
            method: "GET",
            path: "/health",
            description: "Check bridge status, current URL, title, backend, and whether agent control is enabled."
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .actions,
            method: "GET",
            path: "/actions",
            description: "List supported browser bridge actions."
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .analyze,
            method: "GET",
            path: "/analyze",
            description: "Deterministically scan the current rendered page and return a cached action map with analysisID, controlIDs, valid actions, primary action, expected outcomes, ambiguity hints, risk, confidence, and concise evidence. v2 semantic controlRefs, source breakdown, and accessibility matching are enabled by default. ASTRA_BROWSER_ANALYSIS_V2 or user defaults can set off/shadow/on rollout.",
            query: ["query": "optional text", "full": "optional true|false", "limit": "optional number", "debug": "optional true|false", "v2": "optional true|false", "version": "optional v1|v2"],
            batchAliases: ["analyze"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .trace,
            method: "GET",
            path: "/trace",
            description: "Return the most recent compact browser action trace and the retained per-task browser flight timeline for supervision. When Browser Debug Capture is enabled, failed browser actions also retain a privacy-redacted screenshot thumbnail, compact tree, and console/navigation/network events. Use ASTRA_BROWSER_DEBUG_CAPTURE=0 to suppress capture for one command."
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .benchmark,
            method: "GET",
            path: "/benchmark",
            description: "Return the built-in Browser Control V2 benchmark suite definition and metric schema."
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .preflight,
            method: "POST",
            path: "/preflight",
            description: "Validate a cached control action against the live page without executing it. Mutating controlID actions run this check automatically.",
            body: ["analysisID": "ana_...", "controlID": "ctl_...", "action": "click", "allowDangerous": false],
            batchAliases: ["preflight"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .snapshot,
            method: "GET",
            path: "/snapshot",
            description: "Read current page URL, title, viewport, focused element, visible text, and actionable controls. Use compact modes to reduce provider context.",
            query: ["mode": "summary|text|controls|full", "query": "optional text", "limit": "optional number"],
            batchAliases: ["snapshot"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .readPage,
            method: "GET",
            path: "/readPage",
            description: "Read page content with explicit coverage, truncation, frame, and warning metadata. Prefer this for content questions; use analyze for action planning.",
            query: ["format": "text|markdown|json", "limit": "optional character count", "chunkSize": "optional character count"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .navigate,
            method: "POST",
            path: "/navigate",
            description: "Navigate the browser to a URL or search phrase, then wait briefly for URL/title/loading state to settle.",
            body: ["url": "https://example.com"],
            batchAliases: ["navigate"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .type,
            method: "POST",
            path: "/type",
            description: "Focus a selector, type text, and dispatch input/change events.",
            body: ["selector": "input[name=email]", "text": "user@example.com", "clear": true],
            batchAliases: ["type"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .setValue,
            method: "POST",
            path: "/setValue",
            description: "Set an input, textarea, select, or contenteditable value in one reliable action. Prefer this over click plus text when a selector is known.",
            body: ["selector": "input[name=email]", "text": "user@example.com"],
            batchAliases: ["setvalue", "set-value"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .replaceText,
            method: "POST",
            path: "/replaceText",
            description: "Replace text inside editable controls. For Google Docs, Sheets, and Slides canvas text, use the returned hint to drive the Find and Replace dialog with setValue.",
            body: ["find": "old text", "replacement": "new text", "selector": "optional", "all": true],
            batchAliases: ["replacetext", "replace-text"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .findControl,
            method: "GET",
            path: "/findControl",
            description: "Return only matching controls. Prefer this over broad snapshots when looking for a button or field.",
            query: ["query": "visible label/value text", "role": "optional", "limit": "optional number"],
            batchAliases: ["findcontrol", "find-control"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .locator,
            method: "GET",
            path: "/locator",
            description: "Playwright-style locator lookup over visible controls by role, label, placeholder, test id, text, or selector.",
            query: ["query": "visible label/text", "role": "optional", "limit": "optional number"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .clickControl,
            method: "POST",
            path: "/clickControl",
            description: "Find a visible control by label/value/role and click it in one compact action.",
            body: ["label": "Replace all", "role": "optional", "allowDangerous": false],
            batchAliases: ["clickcontrol", "click-control"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .verifyText,
            method: "POST",
            path: "/verifyText",
            description: "Compactly assert whether page text contains or does not contain a string.",
            body: ["text": "expected text", "absent": false],
            batchAliases: ["verifytext", "verify-text"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .waitSaved,
            method: "POST",
            path: "/waitSaved",
            description: "Wait for editor save indicators such as Saved, All changes saved, Last edit, or for Saving to disappear.",
            body: ["timeoutSeconds": 8],
            batchAliases: ["waitsaved", "wait-saved"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .googleFindReplace,
            method: "POST",
            path: "/googleFindReplace",
            description: "Best-effort Google Docs/Sheets/Slides Find and Replace workflow using compact control queries and direct field setting.",
            body: ["find": "05/08/2027", "replacement": "05/07/2026", "all": true],
            batchAliases: ["googlefindreplace", "google-find-replace"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .googleDocsFind,
            method: "POST",
            path: "/googleDocsFind",
            description: "Verify text in a Google Docs document using the in-document Find bar, which can see canvas-rendered document content.",
            body: ["query": "Gentle Morning", "closeFindBar": true],
            batchAliases: ["googledocsfind", "google-docs-find"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .googleDocsInsert,
            method: "POST",
            path: "/googleDocsInsert",
            description: "Focus the current Google Docs editor, insert text, wait for Drive save, and verify via in-document Find in one call.",
            body: ["text": "Text to insert", "verifyText": "short unique phrase", "waitSaved": true],
            batchAliases: ["googledocsinsert", "google-docs-insert"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .googleDocsReadVisiblePage,
            method: "POST",
            path: "/googleDocsReadVisiblePage",
            description: "Read visible Google Docs page content through the page-read service. This is read-only and may be partial; use it for partial summaries when full-document copy is unavailable.",
            body: ["format": "text|markdown|json", "limit": "optional character count", "chunkSize": "optional character count"],
            batchAliases: ["googledocsreadvisiblepage", "google-docs-read-visible-page", "googledocsreadvisible", "google-docs-read-visible", "googledocsreadpage", "google-docs-read-page"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .googleDocsReadDocument,
            method: "POST",
            path: "/googleDocsReadDocument",
            description: "Read the full current Google Docs document through the browser using focus, select-all, copy, and clipboard restore. If browser copy is unavailable, may fall back to an authenticated Docs API read path.",
            body: [:],
            batchAliases: ["googledocsreaddocument", "google-docs-read-document", "googledocsread", "google-docs-read"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .googleDocsReplaceDocument,
            method: "POST",
            path: "/googleDocsReplaceDocument",
            description: "Replace the full current Google Docs document through the browser using backup copy, select-all, paste, wait-saved, verify, and rollback on verification failure. It never uses raw select-all/delete.",
            body: ["text": "Full replacement content", "verifyText": "short unique phrase"],
            batchAliases: ["googledocsreplacedocument", "google-docs-replace-document"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .googleDriveOpen,
            method: "POST",
            path: "/googleDriveOpen",
            description: "Open a Google Drive file by visible name using Drive search, submit, and a compact load verification. Available on Drive pages and through the Google Drive Browser capability.",
            batchAliases: ["googledriveopen", "google-drive-open", "drive-open"],
            extraMetadata: { canUseGoogleDriveOpen, googleDriveOpenDefaultTimeoutSeconds in
                [
                    "body": ["name": "Untitled document", "timeoutSeconds": googleDriveOpenDefaultTimeoutSeconds],
                    "enabled": canUseGoogleDriveOpen,
                    "adapterID": BrowserSiteAdapterID.googleDrive
                ]
            }
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .act,
            method: "POST",
            path: "/act",
            description: "Run a compact multi-step browser action: find and set a control, click a control, wait for save, and verify text.",
            body: ["find": "Replace with", "set": "05/07/2026", "click": "Replace all", "waitSaved": true, "verify": "05/07/2026"],
            batchAliases: ["act"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .click,
            method: "POST",
            path: "/click",
            description: "Click a selector, locator, viewport point, or analyzed controlID after visibility, enabled, stable-bounds, viewport, and obstruction checks. Submit/send/delete/payment-style controls require explicit allowDangerous true after user confirmation. Responses include actionability and postActionWait diagnostics; controlID responses also include outcome fields.",
            body: ["selector": "button.primary", "label": "Save", "role": "button", "x": 0.5, "y": 0.5, "allowDangerous": false],
            batchAliases: ["click"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .open,
            method: "POST",
            path: "/open",
            description: "Open an analyzed controlID using the control's primary open behavior. Enabled site adapters may provide specialized open behavior.",
            body: ["analysisID": "ana_...", "controlID": "ctl_...", "allowDangerous": false],
            batchAliases: ["open"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .doubleClick,
            method: "POST",
            path: "/doubleClick",
            description: "Double-click a selector, locator, point, or analyzed controlID and return outcome fields for controlID usage.",
            body: ["analysisID": "ana_...", "controlID": "ctl_...", "allowDangerous": false],
            batchAliases: ["doubleclick", "double-click", "double_click"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .fill,
            method: "POST",
            path: "/fill",
            description: "Fill an editable control by selector, label, role, placeholder, or test id with actionability checks and a post-action settle wait.",
            body: ["label": "Email", "text": "user@example.com"],
            batchAliases: ["fill"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .keypress,
            method: "POST",
            path: "/keypress",
            description: "Send a keyboard shortcut or keypress to the current page or focused element.",
            body: ["key": "h", "modifiers": ["command", "shift"]],
            batchAliases: ["keypress"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .text,
            method: "POST",
            path: "/text",
            description: "Insert text at the currently focused field or editor insertion point.",
            body: ["text": "05/09/2026"],
            batchAliases: ["text", "inserttext"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .waitForText,
            method: "POST",
            path: "/waitForText",
            description: "Poll compact page text until matching text appears or the timeout is reached.",
            body: ["text": "Saved", "timeoutSeconds": 5],
            batchAliases: ["waitfortext", "wait-text"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .waitForSelector,
            method: "POST",
            path: "/waitForSelector",
            description: "Poll actionable controls until a selector appears or the timeout is reached.",
            body: ["selector": "input[name=q]", "timeoutSeconds": 5],
            batchAliases: ["waitforselector", "wait-selector"]
        ),
        ShelfBrowserBridgeCommandSpec(
            route: .batch,
            method: "POST",
            path: "/batch",
            description: "Run multiple browser actions in one bridge request, including controlID actions. Each mutating controlID step preflights live state, returns outcome fields, and stops on stale, blocked, or dangerous failures.",
            body: [
                "actions": [
                    ["action": "analyze"],
                    ["action": "set-value", "analysisID": "ana_...", "controlID": "ctl_...", "text": "05/09/2026"]
                ],
                "snapshotMode": "summary"
            ]
        )
    ]

    static func route(method: String, path: String) -> ShelfBrowserBridgeRoute? {
        registeredCommands.first { $0.matches(method: method, path: path) }?.route
    }

    static func route(batchAction: String) -> ShelfBrowserBridgeRoute? {
        registeredCommands.first { $0.matches(batchAction: batchAction) }?.route
    }

    static func command(for route: ShelfBrowserBridgeRoute) -> ShelfBrowserBridgeCommandSpec? {
        registeredCommands.first { $0.route == route }
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
        registeredCommands.map {
            $0.metadata(
                canUseGoogleDriveOpen: canUseGoogleDriveOpen,
                googleDriveOpenDefaultTimeoutSeconds: googleDriveOpenDefaultTimeoutSeconds
            )
        }
    }
}
