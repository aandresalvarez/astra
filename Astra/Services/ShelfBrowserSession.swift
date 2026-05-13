import AppKit
import Combine
import Foundation
import WebKit

enum ShelfBrowserAddress {
    static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        let expandedPath = (trimmed as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }

        if trimmed.contains(".") || trimmed.contains(":") || trimmed == "localhost" {
            return URL(string: "https://\(trimmed)") ?? URL(string: "http://\(trimmed)")
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }
}

enum ShelfBrowserEngine: String, CaseIterable, Identifiable {
    case embedded
    case controlled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedded: "Embedded"
        case .controlled: "Controlled"
        }
    }

    var bridgeBackendLabel: String {
        switch self {
        case .embedded: "embedded WebKit"
        case .controlled: "controlled Chromium profile"
        }
    }
}

@MainActor
final class ShelfBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var engine: ShelfBrowserEngine = .embedded {
        didSet {
            guard oldValue != engine else { return }
            let controlledHandoffAddress = oldValue == .embedded && engine == .controlled
                ? Self.controlledBrowserHandoffAddress(currentURL: currentURL, webViewURL: webView.url)
                : nil
            let embeddedHandoffAddress = oldValue == .controlled && engine == .embedded
                ? Self.embeddedBrowserHandoffAddress(currentURL: currentURL, controlledURL: controlledBrowser.currentURL)
                : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.engine == .controlled, self.isAgentBridgeEnabled {
                    self.presentAgentControlPermissionGuide(source: "engine_switch")
                }
                if self.engine == .controlled, let controlledHandoffAddress {
                    await self.openControlledBrowser(initialAddress: controlledHandoffAddress)
                } else if self.engine == .embedded, let embeddedHandoffAddress {
                    self.openEmbeddedBrowser(address: embeddedHandoffAddress)
                } else {
                    self.syncDisplayedStateForEngine()
                    self.publishBridgeState()
                    if self.engine == .controlled {
                        await self.refreshControlledBrowserStatus()
                    }
                }
            }
        }
    }
    @Published private(set) var currentURL = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var bridgeEndpoint: String?
    @Published private(set) var boundTaskID: UUID?
    @Published var isAgentBridgeEnabled = true {
        didSet { publishBridgeState() }
    }
    @Published private(set) var isAgentControlPermissionGuideVisible = false

    let webView: WKWebView
    let controlledBrowser = ControlledBrowserController()

    private var observations: [NSKeyValueObservation] = []
    private var controlledBrowserCancellable: AnyCancellable?
    private var bridgeServer: BrowserBridgeServer?
    private var isPresented = false
    private var browserActionLoopCounts: [String: (state: String, count: Int)] = [:]
    private var lastPageFingerprint: String?
    private var lastLoggedURL = ""

    var isUsingControlledBrowser: Bool {
        engine == .controlled
    }

    var hasDisplayablePage: Bool {
        Self.isDisplayablePageURL(currentURL)
    }

    var isGoogleWorkspaceEditor: Bool {
        guard let url = URL(string: currentURL),
              url.host?.lowercased() == "docs.google.com" else {
            return false
        }
        return url.path.hasPrefix("/document/")
            || url.path.hasPrefix("/presentation/")
            || url.path.hasPrefix("/spreadsheets/")
    }

    var isGoogleDocsEditor: Bool {
        guard let url = URL(string: currentURL),
              url.host?.lowercased() == "docs.google.com" else {
            return false
        }
        return url.path.hasPrefix("/document/")
    }

    var bridgeCapabilities: [String] {
        [
            "health",
            "actions",
            "snapshot",
            "locator",
            "navigate",
            "click.selector",
            "click.locator",
            "click.coordinates",
            "type.selector",
            "fill.locator",
            "set.value",
            "replace.text",
            "find.control",
            "click.control",
            "verify.text",
            "wait.saved",
            "google.find.replace",
            "google.docs.find",
            "google.docs.insert",
            "google.drive.open",
            "act",
            "keypress",
            "text.focused",
            "page.compact",
            "snapshot.compact",
            "batch",
            "wait.text",
            "wait.selector"
        ]
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        controlledBrowserCancellable = controlledBrowser.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isUsingControlledBrowser else { return }
                self.syncDisplayedStateForEngine()
                self.publishBridgeState()
                self.objectWillChange.send()
            }
        }
        installObservers()
        startBridge()
    }

    deinit {
        bridgeServer?.stop()
        ShelfBrowserBridgeRegistry.shared.reset()
    }

    func setPresented(_ isPresented: Bool) {
        self.isPresented = isPresented
        publishBridgeState()
    }

    func bindToTask(_ taskID: UUID?) {
        guard boundTaskID != taskID else { return }
        boundTaskID = taskID
        publishBridgeState()
    }

    static func isDisplayablePageURL(_ value: String) -> Bool {
        let normalizedURL = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedURL.isEmpty && normalizedURL != "about:blank"
    }

    static func controlledBrowserHandoffAddress(currentURL: String, webViewURL: URL?) -> String? {
        let candidates = [
            webViewURL?.absoluteString,
            currentURL
        ]

        return firstDisplayableHandoffAddress(candidates)
    }

    static func embeddedBrowserHandoffAddress(currentURL: String, controlledURL: String) -> String? {
        firstDisplayableHandoffAddress([controlledURL, currentURL])
    }

    private static func firstDisplayableHandoffAddress(_ candidates: [String?]) -> String? {
        for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard isDisplayablePageURL(candidate),
                  let normalized = ShelfBrowserAddress.normalizedURL(from: candidate) else {
                continue
            }
            return normalized.absoluteString
        }
        return nil
    }

    func load(_ address: String, source: String = "app") {
        guard let url = ShelfBrowserAddress.normalizedURL(from: address) else { return }
        load(url, source: source)
    }

    func load(_ url: URL, source: String = "app") {
        logNavigation(phase: "requested", source: source, url: url)
        if isUsingControlledBrowser {
            Task { await navigateControlledBrowser(to: url.absoluteString) }
        } else if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() {
        guard !isUsingControlledBrowser else { return }
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard !isUsingControlledBrowser else { return }
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reload() {
        if isUsingControlledBrowser {
            Task { await reloadControlledBrowser() }
        } else {
            webView.reload()
        }
    }

    func stopLoading() {
        guard !isUsingControlledBrowser else { return }
        webView.stopLoading()
    }

    func openExternal() {
        if isUsingControlledBrowser {
            Task { await controlledBrowser.showWindow() }
        } else if let url = webView.url {
            NSWorkspace.shared.open(url)
        }
    }

    func launchControlledBrowser() {
        let initialAddress = Self.controlledBrowserHandoffAddress(currentURL: currentURL, webViewURL: webView.url)
        if isAgentBridgeEnabled {
            presentAgentControlPermissionGuide(source: "launch_controlled_browser")
        }
        guard engine == .controlled else {
            engine = .controlled
            return
        }

        Task {
            await openControlledBrowser(initialAddress: initialAddress)
        }
    }

    private func openControlledBrowser(initialAddress: String?) async {
        if let initialAddress {
            currentURL = initialAddress
            if let url = URL(string: initialAddress) {
                logNavigation(phase: "handoff", source: "controlled_browser", url: url)
            }
        }
        isLoading = true
        estimatedProgress = 0.1
        canGoBack = false
        canGoForward = false
        engine = .controlled
        await controlledBrowser.launch(initialAddress: initialAddress)
        syncDisplayedStateForEngine()
        publishBridgeState()
    }

    private func openEmbeddedBrowser(address: String) {
        guard let url = ShelfBrowserAddress.normalizedURL(from: address) else {
            syncDisplayedStateForEngine()
            publishBridgeState()
            return
        }

        currentURL = url.absoluteString
        isLoading = true
        estimatedProgress = 0.1
        logNavigation(phase: "handoff", source: "embedded_browser", url: url)
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        publishBridgeState()
    }

    func stopControlledBrowser() {
        controlledBrowser.stop()
        syncDisplayedStateForEngine()
        publishBridgeState()
    }

    func refreshControlledBrowserStatus() async {
        await controlledBrowser.refreshStatus()
        syncDisplayedStateForEngine()
        publishBridgeState()
    }

    func copyBridgeEndpointToPasteboard() {
        guard let bridgeEndpoint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bridgeEndpoint, forType: .string)
    }

    func setAgentBridgeEnabled(_ isEnabled: Bool, source: String = "ui") {
        guard isAgentBridgeEnabled != isEnabled else {
            if isEnabled {
                presentAgentControlPermissionGuide(source: "\(source)_repeat")
            }
            return
        }

        isAgentBridgeEnabled = isEnabled
        logAgentControlState(isEnabled: isEnabled, source: source)
        if isEnabled {
            presentAgentControlPermissionGuide(source: source)
        } else {
            isAgentControlPermissionGuideVisible = false
        }
    }

    func presentAgentControlPermissionGuide(source: String) {
        guard isAgentBridgeEnabled else { return }
        if !isAgentControlPermissionGuideVisible {
            isAgentControlPermissionGuideVisible = true
        }
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "action": "agent_control_permission_guide",
                "phase": "shown",
                "source": source,
                "engine": engine.rawValue,
                "controlled_browser_state": controlledBrowser.runState.rawValue
            ],
            level: .info
        )
    }

    func dismissAgentControlPermissionGuide(source: String = "user") {
        guard isAgentControlPermissionGuideVisible else { return }
        isAgentControlPermissionGuideVisible = false
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "action": "agent_control_permission_guide",
                "phase": "dismissed",
                "source": source,
                "engine": engine.rawValue,
                "controlled_browser_state": controlledBrowser.runState.rawValue
            ],
            level: .info
        )
    }

    func openAgentControlPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        let opened = candidates
            .compactMap(URL.init(string:))
            .contains { NSWorkspace.shared.open($0) }
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "action": "agent_control_privacy_settings",
                "result": opened ? "opened" : "failed",
                "engine": engine.rawValue,
                "controlled_browser_state": controlledBrowser.runState.rawValue
            ],
            level: opened ? .info : .warning
        )
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let credential = CardinalKeyClientCertificateProvider.credential(for: challenge) {
            completionHandler(.useCredential, credential)
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    private func installObservers() {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let nextURL = webView.url?.absoluteString ?? ""
                    self.currentURL = nextURL
                    self.logObservedURLChange(nextURL)
                    self.publishBridgeState()
                }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.pageTitle = webView.title ?? ""
                    self?.publishBridgeState()
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.isLoading = webView.isLoading
                }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.estimatedProgress = webView.estimatedProgress
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.canGoBack = webView.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.canGoForward = webView.canGoForward
                }
            }
        ]
    }

    private func startBridge() {
        let server = BrowserBridgeServer(route: { [weak self] request in
            guard let self else {
                return .json(["ok": false, "error": "browser_session_unavailable"], statusCode: 404)
            }
            return await self.handleBridgeRequest(request)
        }, onEndpointChanged: { [weak self] endpoint in
            Task { @MainActor in
                self?.bridgeEndpoint = endpoint
                self?.publishBridgeState()
            }
        })
        bridgeServer = server
        server.start()
    }

    private func publishBridgeState() {
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: bridgeEndpoint,
            currentURL: currentURL.isEmpty ? nil : currentURL,
            currentTitle: pageTitle.isEmpty ? nil : pageTitle,
            backend: engine.bridgeBackendLabel,
            taskID: boundTaskID,
            isPresented: isPresented,
            isEnabled: isAgentBridgeEnabled
        )
    }

    private func logNavigation(phase: String, source: String, url: URL, level: LogLevel = .info) {
        var fields = ShelfBrowserURLLogFields.fields(for: url)
        fields["phase"] = phase
        fields["source"] = source
        fields["engine"] = engine.rawValue
        fields["bridge_enabled"] = String(isAgentBridgeEnabled)
        fields["is_presented"] = String(isPresented)
        AppLogger.audit(
            .shelfBrowserNavigation,
            category: "Browser",
            taskID: boundTaskID,
            fields: fields,
            level: level
        )
    }

    private func logObservedURLChange(_ urlString: String) {
        guard urlString != lastLoggedURL else { return }
        lastLoggedURL = urlString
        var fields = ShelfBrowserURLLogFields.fields(for: urlString)
        fields["phase"] = "url_changed"
        fields["source"] = "webview"
        fields["engine"] = engine.rawValue
        fields["bridge_enabled"] = String(isAgentBridgeEnabled)
        fields["is_presented"] = String(isPresented)
        AppLogger.audit(
            .shelfBrowserNavigation,
            category: "Browser",
            taskID: boundTaskID,
            fields: fields,
            level: .info
        )
    }

    private func logAgentControlState(isEnabled: Bool, source: String) {
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "action": "agent_control",
                "enabled": String(isEnabled),
                "source": source,
                "engine": engine.rawValue,
                "controlled_browser_state": controlledBrowser.runState.rawValue
            ],
            level: .info
        )
    }

    private func syncDisplayedStateForEngine() {
        if isUsingControlledBrowser {
            currentURL = controlledBrowser.currentURL
            pageTitle = controlledBrowser.pageTitle
            isLoading = controlledBrowser.isLaunching
            estimatedProgress = controlledBrowser.isRunning ? 1 : 0
            canGoBack = false
            canGoForward = false
        } else {
            currentURL = webView.url?.absoluteString ?? ""
            pageTitle = webView.title ?? ""
            isLoading = webView.isLoading
            estimatedProgress = webView.estimatedProgress
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
        }
    }

    private func navigateControlledBrowser(to address: String) async {
        do {
            try await controlledBrowser.navigate(to: address)
        } catch {
            await controlledBrowser.launch(initialAddress: address)
        }
        syncDisplayedStateForEngine()
        publishBridgeState()
    }

    private func reloadControlledBrowser() async {
        do {
            try await controlledBrowser.reload()
        } catch {
            await controlledBrowser.launch(initialAddress: currentURL.isEmpty ? nil : currentURL)
        }
        syncDisplayedStateForEngine()
        publishBridgeState()
    }

    private func handleBridgeRequest(_ request: BrowserBridgeRequest) async -> BrowserBridgeResponse {
        if request.method == "GET", request.path == "/health" {
            var health: [String: Any] = [
                "ok": true,
                "url": currentURL,
                "title": pageTitle,
                "backend": engine.bridgeBackendLabel,
                "controlledBrowserRunning": controlledBrowser.isRunning,
                "controlledBrowserState": controlledBrowser.runState.rawValue,
                "controlledBrowserStatus": controlledBrowser.statusMessage,
                "controlledBrowserProfilePath": controlledBrowser.profilePath,
                "bridgeEnabled": isAgentBridgeEnabled,
                "capabilities": bridgeCapabilities
            ]
            if let debugPort = controlledBrowser.debugPort {
                health["controlledBrowserDebugPort"] = Int(debugPort)
            }
            if let processID = controlledBrowser.processID {
                health["controlledBrowserProcessID"] = Int(processID)
            }
            if let error = controlledBrowser.lastErrorMessage {
                health["controlledBrowserLastError"] = error
            }
            if let boundTaskID {
                health["taskID"] = boundTaskID.uuidString
            }
            return .json(health)
        }

        if request.method == "GET", request.path == "/actions" {
            return .json([
                "ok": true,
                "backend": engine.bridgeBackendLabel,
                "capabilities": bridgeCapabilities,
                "actions": [
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
                        "path": "/snapshot",
                        "query": ["mode": "summary|text|controls|full", "query": "optional text", "limit": "optional number"],
                        "description": "Read current page URL, title, viewport, focused element, visible text, and actionable controls. Use compact modes to reduce provider context."
                    ],
                    [
                        "method": "POST",
                        "path": "/navigate",
                        "body": ["url": "https://example.com"],
                        "description": "Navigate the browser to a URL or search phrase."
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
                        "path": "/googleDriveOpen",
                        "body": ["name": "Untitled document", "timeoutSeconds": 12],
                        "description": "Open a Google Drive file by visible name using Drive search, submit, and a compact load verification. Prefer this over manual Drive row clicks."
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
                        "description": "Click a selector, locator, or viewport point after visibility, enabled, viewport, and obstruction checks. Submit/send/delete/payment-style controls require explicit allowDangerous true after user confirmation."
                    ],
                    [
                        "method": "POST",
                        "path": "/fill",
                        "body": ["label": "Email", "text": "user@example.com"],
                        "description": "Fill an editable control by selector, label, role, placeholder, or test id with actionability checks."
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
                                ["action": "keypress", "key": "h", "modifiers": ["command", "shift"]],
                                ["action": "set-value", "selector": "#c7", "text": "05/09/2026"]
                            ],
                            "snapshotMode": "summary"
                        ],
                        "description": "Run multiple browser actions in one bridge request, then optionally return a compact snapshot."
                    ]
                ]
            ])
        }

        guard isAgentBridgeEnabled else {
            return .json(["ok": false, "error": "browser_bridge_disabled"], statusCode: 403)
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/snapshot"):
                let mode = SnapshotMode(rawValue: request.queryValue("mode") ?? "full") ?? .full
                let query = request.queryValue("query")
                let limit = request.queryValue("limit").flatMap(Int.init)
                let json = try await snapshot(mode: mode, query: query, limit: limit)
                return .rawJSON(json)
            case ("POST", "/navigate"):
                let command = try request.decodeJSON(NavigateCommand.self)
                guard let url = ShelfBrowserAddress.normalizedURL(from: command.url) else {
                    return .json(["ok": false, "error": "invalid_url"], statusCode: 400)
                }
                load(url, source: "bridge")
                return .json(["ok": true, "url": url.absoluteString])
            case ("POST", "/click"):
                let command = try request.decodeJSON(ClickCommand.self)
                let json = try await click(
                    selector: command.normalizedSelector,
                    x: command.x,
                    y: command.y,
                    allowDangerous: command.allowDangerous ?? false,
                    label: command.normalizedLabel,
                    role: command.normalizedRole,
                    text: command.normalizedText,
                    placeholder: command.normalizedPlaceholder,
                    testID: command.normalizedTestID
                )
                return .rawJSON(json)
            case ("POST", "/type"), ("POST", "/fill"):
                let command = try request.decodeJSON(TypeCommand.self)
                let json = try await type(
                    selector: command.normalizedSelector,
                    text: command.text,
                    clear: command.clear ?? true,
                    label: command.normalizedLabel,
                    role: command.normalizedRole,
                    placeholder: command.normalizedPlaceholder,
                    testID: command.normalizedTestID
                )
                return .rawJSON(json)
            case ("POST", "/setValue"):
                let command = try request.decodeJSON(TypeCommand.self)
                let json = try await type(
                    selector: command.normalizedSelector,
                    text: command.text,
                    clear: true,
                    label: command.normalizedLabel,
                    role: command.normalizedRole,
                    placeholder: command.normalizedPlaceholder,
                    testID: command.normalizedTestID
                )
                return .rawJSON(json)
            case ("POST", "/replaceText"):
                let command = try request.decodeJSON(ReplaceTextCommand.self)
                let json = try await replaceText(
                    find: command.find,
                    replacement: command.replacement,
                    selector: command.normalizedSelector,
                    all: command.all ?? true
                )
                return .rawJSON(json)
            case ("GET", "/findControl"), ("GET", "/locator"):
                let query = request.queryValue("query") ?? ""
                let role = request.queryValue("role")
                let limit = request.queryValue("limit").flatMap(Int.init) ?? 10
                return .json(try await findControl(query: query, role: role, limit: limit))
            case ("POST", "/clickControl"):
                let command = try request.decodeJSON(ClickControlCommand.self)
                return .json(try await clickControl(
                    label: command.label,
                    role: command.role,
                    allowDangerous: command.allowDangerous ?? false
                ))
            case ("POST", "/verifyText"):
                let command = try request.decodeJSON(VerifyTextCommand.self)
                return .json(try await verifyText(command.text, absent: command.absent ?? false))
            case ("POST", "/waitSaved"):
                let command = try request.decodeJSON(WaitSavedCommand.self)
                return .json(try await waitSaved(
                    timeoutSeconds: command.timeoutSeconds ?? 8,
                    intervalMilliseconds: command.intervalMilliseconds ?? 500
                ))
            case ("POST", "/googleFindReplace"):
                let command = try request.decodeJSON(GoogleFindReplaceCommand.self)
                return .json(try await googleFindReplace(
                    find: command.find,
                    replacement: command.replacement,
                    all: command.all ?? true
                ))
            case ("POST", "/googleDocsFind"):
                let command = try request.decodeJSON(GoogleDocsFindCommand.self)
                return .json(try await googleDocsFind(
                    query: command.query,
                    closeFindBar: command.closeFindBar ?? true
                ))
            case ("POST", "/googleDocsInsert"):
                let command = try request.decodeJSON(GoogleDocsInsertCommand.self)
                return .json(try await googleDocsInsert(
                    text: command.text,
                    verifyText: command.normalizedVerifyText,
                    waitSaved: command.waitSaved ?? true
                ))
            case ("POST", "/googleDriveOpen"):
                let command = try request.decodeJSON(GoogleDriveOpenCommand.self)
                return .json(try await googleDriveOpen(
                    name: command.normalizedName,
                    timeoutSeconds: command.timeoutSeconds ?? 12,
                    intervalMilliseconds: command.intervalMilliseconds ?? 500
                ))
            case ("POST", "/act"):
                let command = try request.decodeJSON(ActCommand.self)
                return .json(try await act(command))
            case ("POST", "/keypress"):
                let command = try request.decodeJSON(KeypressCommand.self)
                let json = try await keypress(key: command.key, modifiers: command.modifiers ?? [])
                return .rawJSON(json)
            case ("POST", "/text"):
                let command = try request.decodeJSON(TextCommand.self)
                let json = try await insertText(command.text)
                return .rawJSON(json)
            case ("POST", "/waitForText"):
                let command = try request.decodeJSON(WaitTextCommand.self)
                let result = try await waitForText(
                    command.text,
                    timeoutSeconds: command.timeoutSeconds ?? 5,
                    intervalMilliseconds: command.intervalMilliseconds ?? 250
                )
                return .json(result)
            case ("POST", "/waitForSelector"):
                let command = try request.decodeJSON(WaitSelectorCommand.self)
                let result = try await waitForSelector(
                    command.selector,
                    timeoutSeconds: command.timeoutSeconds ?? 5,
                    intervalMilliseconds: command.intervalMilliseconds ?? 250
                )
                return .json(result)
            case ("POST", "/batch"):
                let command = try request.decodeJSON(BatchCommand.self)
                let result = try await runBatch(command)
                return .json(result)
            default:
                return .json(["ok": false, "error": "not_found"], statusCode: 404)
            }
        } catch {
            return .json([
                "ok": false,
                "error": "browser_bridge_error",
                "message": error.localizedDescription
            ], statusCode: 400)
        }
    }

    private func snapshot(mode: SnapshotMode = .full, query: String? = nil, limit: Int? = nil) async throws -> String {
        let started = Date()
        do {
            let json: String
            if isUsingControlledBrowser {
                json = try await controlledBrowser.snapshot()
                syncDisplayedStateForEngine()
                publishBridgeState()
            } else {
                json = try await evaluateJavaScriptString(BrowserAutomationScripts.snapshotScript)
            }

            let result: String
            if mode == .full && (query ?? "").isEmpty && limit == nil {
                result = json
            } else {
                result = try Self.compactSnapshot(json: json, mode: mode, query: query, limit: limit)
            }
            let annotated = try annotateBrowserLoopHint(
                json: result,
                action: "snapshot",
                target: "\(mode.rawValue):\(query ?? "")",
                updatePageFingerprint: true
            )
            logBrowserSnapshot(
                phase: "completed",
                mode: mode,
                query: query,
                limit: limit,
                resultJSON: annotated,
                started: started
            )
            return annotated
        } catch {
            logBrowserSnapshot(
                phase: "failed",
                mode: mode,
                query: query,
                limit: limit,
                started: started,
                error: error
            )
            throw error
        }
    }

    private func click(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String? = nil,
        role: String? = nil,
        text: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil
    ) async throws -> String {
        let started = Date()
        let action = "click"
        logBrowserAction(
            phase: "requested",
            action: action,
            selector: selector,
            label: label,
            role: role,
            text: text,
            placeholder: placeholder,
            testID: testID,
            fields: [
                "has_point": String(x != nil && y != nil),
                "allow_dangerous": String(allowDangerous)
            ]
        )

        do {
            if !isUsingControlledBrowser {
                _ = try await waitForEmbeddedActionableTarget(
                    selector: selector,
                    x: x,
                    y: y,
                    allowDangerous: allowDangerous,
                    label: label,
                    role: role,
                    text: text,
                    placeholder: placeholder,
                    testID: testID
                )
            }

            let json: String
            if isUsingControlledBrowser {
                json = try await controlledBrowser.click(
                    selector: selector,
                    x: x,
                    y: y,
                    allowDangerous: allowDangerous,
                    label: label,
                    role: role,
                    text: text,
                    placeholder: placeholder,
                    testID: testID
                )
                syncDisplayedStateForEngine()
                publishBridgeState()
            } else {
                json = try await evaluateJavaScriptString(BrowserAutomationScripts.clickScript(
                    selector: selector,
                    x: x,
                    y: y,
                    allowDangerous: allowDangerous,
                    label: label,
                    role: role,
                    text: text,
                    placeholder: placeholder,
                    testID: testID
                ))
            }

            let annotated = try annotateBrowserLoopHint(json: json, action: action, target: browserActionTarget(
                selector: selector,
                x: x,
                y: y,
                label: label,
                role: role,
                text: text,
                placeholder: placeholder,
                testID: testID
            ))
            logBrowserAction(
                phase: "completed",
                action: action,
                selector: selector,
                label: label,
                role: role,
                text: text,
                placeholder: placeholder,
                testID: testID,
                resultJSON: annotated,
                started: started
            )
            return annotated
        } catch {
            logBrowserAction(
                phase: "failed",
                action: action,
                selector: selector,
                label: label,
                role: role,
                text: text,
                placeholder: placeholder,
                testID: testID,
                started: started,
                error: error
            )
            throw error
        }
    }

    private func type(
        selector: String?,
        text: String,
        clear: Bool,
        label: String? = nil,
        role: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil
    ) async throws -> String {
        let started = Date()
        let action = clear ? "setValue" : "type"
        logBrowserAction(
            phase: "requested",
            action: action,
            selector: selector,
            label: label,
            role: role,
            text: nil,
            placeholder: placeholder,
            testID: testID,
            fields: [
                "clear": String(clear),
                "text_length": String(text.count)
            ]
        )

        do {
            if !isUsingControlledBrowser {
                _ = try await waitForEmbeddedActionableTarget(
                    selector: selector,
                    x: nil,
                    y: nil,
                    allowDangerous: true,
                    label: label,
                    role: role,
                    text: nil,
                    placeholder: placeholder,
                    testID: testID
                )
            }

            let json: String
            if isUsingControlledBrowser {
                json = try await controlledBrowser.type(
                    selector: selector,
                    text: text,
                    clear: clear,
                    label: label,
                    role: role,
                    placeholder: placeholder,
                    testID: testID
                )
                syncDisplayedStateForEngine()
                publishBridgeState()
            } else {
                json = try await evaluateJavaScriptString(BrowserAutomationScripts.typeScript(
                    selector: selector,
                    text: text,
                    clear: clear,
                    label: label,
                    role: role,
                    placeholder: placeholder,
                    testID: testID
                ))
            }

            let annotated = try annotateBrowserLoopHint(json: json, action: action, target: browserActionTarget(
                selector: selector,
                x: nil,
                y: nil,
                label: label,
                role: role,
                text: nil,
                placeholder: placeholder,
                testID: testID
            ))
            logBrowserAction(
                phase: "completed",
                action: action,
                selector: selector,
                label: label,
                role: role,
                text: nil,
                placeholder: placeholder,
                testID: testID,
                resultJSON: annotated,
                started: started
            )
            return annotated
        } catch {
            logBrowserAction(
                phase: "failed",
                action: action,
                selector: selector,
                label: label,
                role: role,
                text: nil,
                placeholder: placeholder,
                testID: testID,
                started: started,
                error: error
            )
            throw error
        }
    }

    private func waitForEmbeddedActionableTarget(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws {
        let started = Date()
        let timeout: TimeInterval = 3
        var lastError = ""

        while Date().timeIntervalSince(started) < timeout {
            let json = try await evaluateJavaScriptString(BrowserAutomationScripts.targetInfoScript(
                selector: selector,
                x: x,
                y: y,
                allowDangerous: allowDangerous,
                label: label,
                role: role,
                text: text,
                placeholder: placeholder,
                testID: testID
            ))
            let object = try Self.jsonObject(from: json)
            if Self.boolValue(object["ok"]) {
                return
            }
            lastError = object["error"] as? String ?? ""
            if !Self.isRetryableActionabilityError(lastError) {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if !lastError.isEmpty {
            logBrowserAction(
                phase: "auto_wait_timeout",
                action: "actionability",
                selector: selector,
                label: label,
                role: role,
                text: text,
                placeholder: placeholder,
                testID: testID,
                fields: ["last_error": lastError]
            )
        }
    }

    private static func isRetryableActionabilityError(_ error: String) -> Bool {
        [
            "selector_not_found",
            "target_not_found",
            "target_not_visible",
            "target_obscured",
            "target_outside_viewport"
        ].contains(error)
    }

    private func browserActionTarget(
        selector: String?,
        x: Double?,
        y: Double?,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) -> String {
        if let selector, !selector.isEmpty { return "selector:\(selector.hashValue)" }
        if let label, !label.isEmpty { return "label:\(label.lowercased().hashValue)" }
        if let role, !role.isEmpty { return "role:\(role.lowercased())" }
        if let text, !text.isEmpty { return "text:\(text.lowercased().hashValue)" }
        if let placeholder, !placeholder.isEmpty { return "placeholder:\(placeholder.lowercased().hashValue)" }
        if let testID, !testID.isEmpty { return "testid:\(testID.lowercased().hashValue)" }
        return "point:\(x ?? -1),\(y ?? -1)"
    }

    private func logBrowserAction(
        phase: String,
        action: String,
        selector: String?,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?,
        fields extraFields: [String: String] = [:],
        resultJSON: String? = nil,
        started: Date? = nil,
        error: Error? = nil
    ) {
        var fields: [String: String] = [
            "phase": phase,
            "action": action,
            "engine": engine.rawValue,
            "backend": engine.bridgeBackendLabel,
            "has_selector": String(selector?.isEmpty == false),
            "has_label": String(label?.isEmpty == false),
            "has_role": String(role?.isEmpty == false),
            "has_text_locator": String(text?.isEmpty == false),
            "has_placeholder": String(placeholder?.isEmpty == false),
            "has_test_id": String(testID?.isEmpty == false)
        ]
        fields.merge(ShelfBrowserURLLogFields.fields(for: currentURL, prefix: "current"), uniquingKeysWith: { current, _ in current })
        if let selector {
            fields["selector_length"] = String(selector.count)
        }
        if let label {
            fields["label_length"] = String(label.count)
        }
        if let role, !role.isEmpty {
            fields["role"] = role
        }
        if let text {
            fields["text_locator_length"] = String(text.count)
        }
        if let placeholder {
            fields["placeholder_length"] = String(placeholder.count)
        }
        if let testID {
            fields["test_id_length"] = String(testID.count)
        }
        if let started {
            fields["elapsed_ms"] = String(Int(Date().timeIntervalSince(started) * 1000))
        }
        if let resultJSON,
           let object = try? Self.jsonObject(from: resultJSON) {
            fields["ok"] = String(Self.boolValue(object["ok"]))
            fields["error"] = object["error"] as? String ?? ""
            fields["target_tag"] = object["tag"] as? String ?? ""
            fields["target_role"] = object["role"] as? String ?? ""
            fields["target_visible"] = String(Self.boolValue(object["visible"]))
            fields["target_actionable"] = String(Self.boolValue(object["actionable"]))
            fields["target_disabled"] = String(Self.boolValue(object["disabled"]))
            if let matchedLabel = object["label"] as? String {
                fields["target_label_length"] = String(matchedLabel.count)
            }
        }
        if let error {
            fields["error"] = error.localizedDescription
            fields["error_type"] = String(describing: Swift.type(of: error))
        }
        fields.merge(extraFields, uniquingKeysWith: { _, new in new })

        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: fields,
            level: phase == "failed" ? .warning : .info
        )
    }

    private func logBrowserSnapshot(
        phase: String,
        mode: SnapshotMode,
        query: String?,
        limit: Int?,
        resultJSON: String? = nil,
        started: Date,
        error: Error? = nil
    ) {
        var fields: [String: String] = [
            "phase": phase,
            "action": "snapshot",
            "engine": engine.rawValue,
            "backend": engine.bridgeBackendLabel,
            "mode": mode.rawValue,
            "has_query": String(query?.isEmpty == false),
            "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000))
        ]
        fields.merge(ShelfBrowserURLLogFields.fields(for: currentURL, prefix: "current"), uniquingKeysWith: { current, _ in current })
        if let query {
            fields["query_length"] = String(query.count)
        }
        if let limit {
            fields["limit"] = String(limit)
        }
        if let resultJSON,
           let object = try? Self.jsonObject(from: resultJSON) {
            fields["ok"] = String(Self.boolValue(object["ok"]))
            fields["control_count"] = String(Self.intValue(object["controlCount"]) ?? 0)
            fields["text_length"] = String((object["text"] as? String ?? "").count)
            fields["result_chars"] = String(resultJSON.count)
        }
        if let error {
            fields["error"] = error.localizedDescription
            fields["error_type"] = String(describing: Swift.type(of: error))
        }

        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: fields,
            level: phase == "failed" ? .warning : .debug
        )
    }

    private func replaceText(find: String, replacement: String, selector: String?, all: Bool) async throws -> String {
        if isUsingControlledBrowser {
            let json = try await controlledBrowser.replaceText(find: find, replacement: replacement, selector: selector, all: all)
            syncDisplayedStateForEngine()
            publishBridgeState()
            return try annotateBrowserLoopHint(json: json, action: "replaceText", target: selector ?? find)
        }
        let json = try await evaluateJavaScriptString(BrowserAutomationScripts.replaceTextScript(
            find: find,
            replacement: replacement,
            selector: selector,
            all: all
        ))
        return try annotateBrowserLoopHint(json: json, action: "replaceText", target: selector ?? find)
    }

    private func keypress(key: String, modifiers: [String]) async throws -> String {
        let started = Date()
        logBrowserAction(
            phase: "requested",
            action: "keypress",
            selector: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil,
            fields: [
                "key_length": String(key.count),
                "modifier_count": String(modifiers.count)
            ]
        )
        do {
            let json: String
            if isUsingControlledBrowser {
                json = try await controlledBrowser.keypress(key: key, modifiers: modifiers)
                syncDisplayedStateForEngine()
                publishBridgeState()
            } else {
                json = try await evaluateJavaScriptString(BrowserAutomationScripts.keypressScript(key: key, modifiers: modifiers))
            }
            logBrowserAction(
                phase: "completed",
                action: "keypress",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: [
                    "key_length": String(key.count),
                    "modifier_count": String(modifiers.count)
                ],
                resultJSON: json,
                started: started
            )
            return json
        } catch {
            logBrowserAction(
                phase: "failed",
                action: "keypress",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: [
                    "key_length": String(key.count),
                    "modifier_count": String(modifiers.count)
                ],
                started: started,
                error: error
            )
            throw error
        }
    }

    private func insertText(_ text: String) async throws -> String {
        let started = Date()
        logBrowserAction(
            phase: "requested",
            action: "insertText",
            selector: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil,
            fields: ["text_length": String(text.count)]
        )
        do {
            let json: String
            if isUsingControlledBrowser {
                json = try await controlledBrowser.insertText(text)
                syncDisplayedStateForEngine()
                publishBridgeState()
            } else {
                json = try await evaluateJavaScriptString(BrowserAutomationScripts.insertTextScript(text))
            }
            logBrowserAction(
                phase: "completed",
                action: "insertText",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: ["text_length": String(text.count)],
                resultJSON: json,
                started: started
            )
            return json
        } catch {
            logBrowserAction(
                phase: "failed",
                action: "insertText",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: ["text_length": String(text.count)],
                started: started,
                error: error
            )
            throw error
        }
    }

    private func waitForText(
        _ text: String,
        timeoutSeconds: Double,
        intervalMilliseconds: Int
    ) async throws -> [String: Any] {
        let started = Date()
        let timeout = max(0.1, min(timeoutSeconds, 30))
        let interval = UInt64(max(50, min(intervalMilliseconds, 2_000))) * 1_000_000
        while Date().timeIntervalSince(started) <= timeout {
            let json = try await snapshot(mode: .text, query: text, limit: 1_500)
            let object = try Self.jsonObject(from: json)
            let matches = object["matches"] as? [[String: Any]] ?? []
            if !matches.isEmpty {
                return [
                    "ok": true,
                    "text": text,
                    "elapsedSeconds": Date().timeIntervalSince(started),
                    "matches": matches
                ]
            }
            try await Task.sleep(nanoseconds: interval)
        }
        return [
            "ok": false,
            "error": "text_not_found",
            "text": text,
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func waitForSelector(
        _ selector: String,
        timeoutSeconds: Double,
        intervalMilliseconds: Int
    ) async throws -> [String: Any] {
        let started = Date()
        let timeout = max(0.1, min(timeoutSeconds, 30))
        let interval = UInt64(max(50, min(intervalMilliseconds, 2_000))) * 1_000_000
        while Date().timeIntervalSince(started) <= timeout {
            let json = try await snapshot(mode: .controls, query: selector, limit: 25)
            let object = try Self.jsonObject(from: json)
            let controls = object["controls"] as? [[String: Any]] ?? []
            if let control = controls.first(where: { ($0["selector"] as? String) == selector }) {
                return [
                    "ok": true,
                    "selector": selector,
                    "elapsedSeconds": Date().timeIntervalSince(started),
                    "control": control
                ]
            }
            try await Task.sleep(nanoseconds: interval)
        }
        return [
            "ok": false,
            "error": "selector_not_found",
            "selector": selector,
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func googleDriveOpen(
        name: String,
        timeoutSeconds: Double,
        intervalMilliseconds: Int
    ) async throws -> [String: Any] {
        let started = Date()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        logBrowserAction(
            phase: "requested",
            action: "googleDriveOpen",
            selector: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil,
            fields: [
                "name_length": String(trimmedName.count),
                "timeout_seconds": String(timeoutSeconds)
            ]
        )

        guard !trimmedName.isEmpty else {
            let result: [String: Any] = [
                "ok": false,
                "error": "missing_name"
            ]
            logBrowserAction(
                phase: "completed",
                action: "googleDriveOpen",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                resultJSON: try Self.jsonString(result),
                started: started
            )
            return result
        }

        do {
            if Self.isOpenedDriveTarget(urlString: currentURL, title: pageTitle, name: trimmedName, startURL: nil) {
                let result: [String: Any] = [
                    "ok": true,
                    "opened": true,
                    "alreadyOpen": true,
                    "name": trimmedName,
                    "url": currentURL,
                    "title": pageTitle,
                    "elapsedSeconds": Date().timeIntervalSince(started)
                ]
                logBrowserAction(
                    phase: "completed",
                    action: "googleDriveOpen",
                    selector: nil,
                    label: nil,
                    role: nil,
                    text: nil,
                    placeholder: nil,
                    testID: nil,
                    resultJSON: try Self.jsonString(result),
                    started: started
                )
                return result
            }

            let startURL = currentURL
            let fillResult = try await fillGoogleDriveSearch(with: trimmedName)
            guard Self.boolValue(fillResult["ok"]) else {
                let result: [String: Any] = [
                    "ok": false,
                    "opened": false,
                    "error": "drive_search_field_not_found",
                    "name": trimmedName,
                    "url": currentURL,
                    "title": pageTitle,
                    "elapsedSeconds": Date().timeIntervalSince(started)
                ]
                logBrowserAction(
                    phase: "completed",
                    action: "googleDriveOpen",
                    selector: nil,
                    label: nil,
                    role: nil,
                    text: nil,
                    placeholder: nil,
                    testID: nil,
                    resultJSON: try Self.jsonString(result),
                    started: started
                )
                return result
            }

            _ = try await keypress(key: "Enter", modifiers: [])
            var result = try await waitForGoogleDriveOpen(
                name: trimmedName,
                startURL: startURL,
                started: started,
                timeoutSeconds: timeoutSeconds,
                intervalMilliseconds: intervalMilliseconds
            )
            result["searchMethod"] = fillResult["method"] as? String ?? "unknown"
            logBrowserAction(
                phase: "completed",
                action: "googleDriveOpen",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: [
                    "opened": String(Self.boolValue(result["opened"])),
                    "search_method": result["searchMethod"] as? String ?? "unknown"
                ],
                resultJSON: try Self.jsonString(result),
                started: started
            )
            return result
        } catch {
            logBrowserAction(
                phase: "failed",
                action: "googleDriveOpen",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                started: started,
                error: error
            )
            throw error
        }
    }

    private func fillGoogleDriveSearch(with name: String) async throws -> [String: Any] {
        struct SearchTarget {
            let method: String
            let selector: String?
            let label: String?
            let placeholder: String?
        }

        let targets = [
            SearchTarget(method: "label", selector: nil, label: "Search in Drive", placeholder: nil),
            SearchTarget(method: "placeholder", selector: nil, label: nil, placeholder: "Search in Drive"),
            SearchTarget(method: "selector", selector: #"input[aria-label="Search in Drive"], input[placeholder="Search in Drive"]"#, label: nil, placeholder: nil)
        ]

        var lastResult: [String: Any] = [
            "ok": false,
            "error": "not_attempted"
        ]

        for target in targets {
            let json = try await type(
                selector: target.selector,
                text: name,
                clear: true,
                label: target.label,
                role: nil,
                placeholder: target.placeholder,
                testID: nil
            )
            var result = try Self.jsonObject(from: json)
            result["method"] = target.method
            lastResult = result
            if Self.boolValue(result["ok"]) {
                return result
            }
        }

        return lastResult
    }

    private func waitForGoogleDriveOpen(
        name: String,
        startURL: String,
        started: Date,
        timeoutSeconds: Double,
        intervalMilliseconds: Int
    ) async throws -> [String: Any] {
        let timeout = max(0.5, min(timeoutSeconds, 30))
        let interval = UInt64(max(100, min(intervalMilliseconds, 2_000))) * 1_000_000
        var lastURL = currentURL
        var lastTitle = pageTitle
        var lastMatchCount = 0
        var retriedOpenKey = false

        while Date().timeIntervalSince(started) <= timeout {
            try await Task.sleep(nanoseconds: interval)

            let json = try await snapshot(mode: .text, query: name, limit: 1_500)
            let object = try Self.jsonObject(from: json)
            lastURL = object["url"] as? String ?? currentURL
            lastTitle = object["title"] as? String ?? pageTitle
            let matches = object["matches"] as? [[String: Any]] ?? []
            lastMatchCount = matches.count

            if Self.isOpenedDriveTarget(urlString: lastURL, title: lastTitle, name: name, startURL: startURL) {
                return [
                    "ok": true,
                    "opened": true,
                    "name": name,
                    "url": lastURL,
                    "title": lastTitle,
                    "matchedName": lastMatchCount > 0 || Self.containsNormalized(lastTitle, name),
                    "elapsedSeconds": Date().timeIntervalSince(started)
                ]
            }

            if !retriedOpenKey, Date().timeIntervalSince(started) >= 2.0 {
                _ = try? await keypress(key: "Enter", modifiers: [])
                retriedOpenKey = true
            }
        }

        return [
            "ok": false,
            "opened": false,
            "error": "drive_file_not_opened",
            "name": name,
            "url": lastURL,
            "title": lastTitle,
            "matchedName": lastMatchCount > 0 || Self.containsNormalized(lastTitle, name),
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func findControl(query: String, role: String?, limit: Int) async throws -> [String: Any] {
        let json = try await snapshot(mode: .controls, query: query, limit: max(1, min(limit, 50)))
        let object = try Self.jsonObject(from: json)
        let controls = object["controls"] as? [[String: Any]] ?? []
        let filtered = Self.controlsMatching(controls, label: query, role: role)
        return [
            "ok": true,
            "query": query,
            "role": role ?? "",
            "count": filtered.count,
            "controls": Array(filtered.prefix(max(1, min(limit, 50))))
        ]
    }

    private func clickControl(label: String, role: String?, allowDangerous: Bool) async throws -> [String: Any] {
        let matches = try await findControl(query: label, role: role, limit: 8)
        let controls = matches["controls"] as? [[String: Any]] ?? []
        guard let control = controls.first else {
            return [
                "ok": false,
                "error": "control_not_found",
                "label": label,
                "role": role ?? ""
            ]
        }
        let selector = control["selector"] as? String
        let bounds = control["bounds"] as? [String: Any]
        let x = Self.doubleValue(bounds?["centerX"])
        let y = Self.doubleValue(bounds?["centerY"])
        let json = try await click(selector: selector, x: selector == nil ? x : nil, y: selector == nil ? y : nil, allowDangerous: allowDangerous)
        var result = try Self.jsonObject(from: json)
        result["matchedControl"] = control
        return result
    }

    private func verifyText(_ text: String, absent: Bool) async throws -> [String: Any] {
        let json = try await snapshot(mode: .text, query: text, limit: 5)
        let object = try Self.jsonObject(from: json)
        let matches = object["matches"] as? [[String: Any]] ?? []
        let found = !matches.isEmpty
        return [
            "ok": absent ? !found : found,
            "text": text,
            "absent": absent,
            "found": found,
            "matches": Array(matches.prefix(5)),
            "url": object["url"] as? String ?? "",
            "title": object["title"] as? String ?? ""
        ]
    }

    private func waitSaved(timeoutSeconds: Double, intervalMilliseconds: Int) async throws -> [String: Any] {
        let started = Date()
        let timeout = max(0.1, min(timeoutSeconds, 60))
        let interval = UInt64(max(100, min(intervalMilliseconds, 2_000))) * 1_000_000
        var lastState: [String: Any] = [:]

        while Date().timeIntervalSince(started) <= timeout {
            let json = try await snapshot(mode: .text, query: nil, limit: 2_000)
            let object = try Self.jsonObject(from: json)
            let text = (object["text"] as? String ?? "").lowercased()
            let title = (object["title"] as? String ?? "").lowercased()
            let combined = "\(title)\n\(text)"
            let saving = combined.contains("saving") || combined.contains("syncing")
            let saved = combined.contains("all changes saved")
                || combined.contains("saved to")
                || combined.contains("saved in")
                || combined.contains("last edit")
                || combined.contains("saved")
            lastState = [
                "url": object["url"] as? String ?? "",
                "title": object["title"] as? String ?? "",
                "saving": saving,
                "savedIndicator": saved
            ]
            if saved && !saving {
                return [
                    "ok": true,
                    "saved": true,
                    "elapsedSeconds": Date().timeIntervalSince(started),
                    "state": lastState
                ]
            }
            try await Task.sleep(nanoseconds: interval)
        }

        return [
            "ok": false,
            "saved": false,
            "error": "saved_indicator_not_found",
            "elapsedSeconds": Date().timeIntervalSince(started),
            "state": lastState
        ]
    }

    private func googleFindReplace(find: String, replacement: String, all: Bool) async throws -> [String: Any] {
        guard isGoogleWorkspaceEditor else {
            return [
                "ok": false,
                "error": "not_google_workspace_editor",
                "hint": "Use replace-text for normal editable controls, or open a Google Docs, Sheets, or Slides editor page first."
            ]
        }

        _ = try await keypress(key: "h", modifiers: ["command", "shift"])
        try await Task.sleep(nanoseconds: 500_000_000)

        let controlsJSON = try await snapshot(mode: .controls, query: nil, limit: 80)
        let controlsObject = try Self.jsonObject(from: controlsJSON)
        let controls = controlsObject["controls"] as? [[String: Any]] ?? []
        let editableControls = controls.filter { control in
            let tag = (control["tag"] as? String ?? "").lowercased()
            return tag == "input" || tag == "textarea" || (control["role"] as? String ?? "").lowercased().contains("textbox")
        }

        guard editableControls.count >= 2,
              let findSelector = editableControls.first?["selector"] as? String,
              let replaceSelector = editableControls.dropFirst().first?["selector"] as? String else {
            return [
                "ok": false,
                "error": "find_replace_fields_not_found",
                "hint": "Open the Find and Replace dialog, then use find-control and set-value on the Find and Replace fields.",
                "controls": Array(controls.prefix(12))
            ]
        }

        let findJSON = try await type(selector: findSelector, text: find, clear: true)
        let replaceJSON = try await type(selector: replaceSelector, text: replacement, clear: true)
        let buttonLabel = all ? "Replace all" : "Replace"
        let clickResult = try await clickControl(label: buttonLabel, role: nil, allowDangerous: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        let saved = try await waitSaved(timeoutSeconds: 8, intervalMilliseconds: 500)
        let present = try await verifyText(replacement, absent: false)
        let oldAbsent = try await verifyText(find, absent: true)

        return [
            "ok": Self.boolValue(clickResult["ok"]) && Self.boolValue(present["ok"]),
            "find": find,
            "replacement": replacement,
            "findField": try Self.jsonObject(from: findJSON),
            "replaceField": try Self.jsonObject(from: replaceJSON),
            "click": clickResult,
            "saved": saved,
            "verification": [
                "replacementPresent": present,
                "oldTextAbsent": oldAbsent
            ]
        ]
    }

    private func googleDocsFind(query: String, closeFindBar: Bool) async throws -> [String: Any] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return ["ok": false, "error": "empty_query"]
        }
        guard isGoogleDocsEditor else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        let started = Date()
        logBrowserAction(
            phase: "requested",
            action: "googleDocsFind",
            selector: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil,
            fields: [
                "query_length": String(normalizedQuery.count),
                "close_find_bar": String(closeFindBar)
            ]
        )

        do {
            _ = try await keypress(key: "f", modifiers: ["command"])
            try await Task.sleep(nanoseconds: 250_000_000)
            let findFieldJSON = try await type(
                selector: nil,
                text: normalizedQuery,
                clear: true,
                label: "Find in document",
                role: nil,
                placeholder: nil,
                testID: nil
            )
            _ = try await keypress(key: "Enter", modifiers: [])
            try await Task.sleep(nanoseconds: 300_000_000)

            let snapshotJSON = try await snapshot(mode: .text, query: normalizedQuery, limit: 2_000)
            let snapshot = try Self.jsonObject(from: snapshotJSON)
            let text = snapshot["text"] as? String ?? ""
            let matches = snapshot["matches"] as? [[String: Any]] ?? []
            let countText = Self.googleFindCountText(in: text)
            let foundByCount = countText.map { !$0.hasPrefix("0 of ") } ?? false
            let found = foundByCount || !matches.isEmpty || text.localizedCaseInsensitiveContains(normalizedQuery)
            var closeResult: [String: Any]?
            if closeFindBar,
               let closeJSON = try? await keypress(key: "Escape", modifiers: []) {
                closeResult = try? Self.jsonObject(from: closeJSON)
            }

            let result: [String: Any] = [
                "ok": found,
                "query": normalizedQuery,
                "found": found,
                "matchCountText": countText ?? "",
                "findField": try Self.jsonObject(from: findFieldJSON),
                "close": closeResult ?? [:],
                "elapsedSeconds": Date().timeIntervalSince(started),
                "url": snapshot["url"] as? String ?? "",
                "title": snapshot["title"] as? String ?? ""
            ]
            logBrowserAction(
                phase: "completed",
                action: "googleDocsFind",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: [
                    "query_length": String(normalizedQuery.count),
                    "found": String(found),
                    "match_count_present": String(countText != nil)
                ],
                resultJSON: try Self.jsonString(result),
                started: started
            )
            return result
        } catch {
            logBrowserAction(
                phase: "failed",
                action: "googleDocsFind",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: ["query_length": String(normalizedQuery.count)],
                started: started,
                error: error
            )
            throw error
        }
    }

    private func googleDocsInsert(text: String, verifyText: String?, waitSaved shouldWaitSaved: Bool) async throws -> [String: Any] {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return ["ok": false, "error": "empty_text"]
        }
        guard isGoogleDocsEditor else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        let started = Date()
        logBrowserAction(
            phase: "requested",
            action: "googleDocsInsert",
            selector: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil,
            fields: [
                "text_length": String(normalizedText.count),
                "verify_text_length": String(verifyText?.count ?? 0),
                "wait_saved": String(shouldWaitSaved)
            ]
        )

        do {
            let focusJSON = try await click(
                selector: nil,
                x: 0.47,
                y: 0.45,
                allowDangerous: false
            )
            let insertJSON = try await insertText(normalizedText)
            let saved: [String: Any] = shouldWaitSaved
                ? try await waitSaved(timeoutSeconds: 10, intervalMilliseconds: 500)
                : ["ok": true, "skipped": true]
            let verification: [String: Any]
            if let verifyText, !verifyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                verification = try await googleDocsFind(query: verifyText, closeFindBar: true)
            } else {
                verification = ["ok": true, "skipped": true]
            }

            let focus = try Self.jsonObject(from: focusJSON)
            let insert = try Self.jsonObject(from: insertJSON)
            let ok = Self.boolValue(focus["ok"])
                && Self.boolValue(insert["ok"])
                && Self.boolValue(saved["ok"])
                && Self.boolValue(verification["ok"])
            let result: [String: Any] = [
                "ok": ok,
                "textLength": normalizedText.count,
                "verifyText": verifyText ?? "",
                "focus": focus,
                "insert": insert,
                "saved": saved,
                "verification": verification,
                "elapsedSeconds": Date().timeIntervalSince(started)
            ]
            logBrowserAction(
                phase: "completed",
                action: "googleDocsInsert",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: [
                    "text_length": String(normalizedText.count),
                    "verified": String(Self.boolValue(verification["ok"]))
                ],
                resultJSON: try Self.jsonString(result),
                started: started
            )
            return result
        } catch {
            logBrowserAction(
                phase: "failed",
                action: "googleDocsInsert",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: ["text_length": String(normalizedText.count)],
                started: started,
                error: error
            )
            throw error
        }
    }

    private func act(_ command: ActCommand) async throws -> [String: Any] {
        var results: [[String: Any]] = []

        if let find = command.find, let set = command.set {
            let matches = try await findControl(query: find, role: command.role, limit: 8)
            let controls = matches["controls"] as? [[String: Any]] ?? []
            let editable = controls.first { control in
                let tag = (control["tag"] as? String ?? "").lowercased()
                let role = (control["role"] as? String ?? "").lowercased()
                return tag == "input" || tag == "textarea" || role.contains("textbox")
            } ?? controls.first
            guard let selector = editable?["selector"] as? String else {
                results.append(["ok": false, "action": "set", "error": "control_not_found", "query": find])
                return ["ok": false, "results": results]
            }
            let json = try await type(selector: selector, text: set, clear: true)
            results.append(try Self.jsonObject(from: json).merging([
                "action": "set",
                "matchedControl": editable ?? [:]
            ], uniquingKeysWith: { current, _ in current }))
        }

        if let click = command.click {
            let result = try await clickControl(
                label: click,
                role: command.clickRole,
                allowDangerous: command.allowDangerous ?? false
            )
            results.append(result.merging(["action": "click"], uniquingKeysWith: { current, _ in current }))
        }

        if command.waitSaved == true {
            let result = try await waitSaved(
                timeoutSeconds: command.timeoutSeconds ?? 8,
                intervalMilliseconds: command.intervalMilliseconds ?? 500
            )
            results.append(result.merging(["action": "waitSaved"], uniquingKeysWith: { current, _ in current }))
        }

        if let verify = command.verify {
            let result = try await verifyText(verify, absent: false)
            results.append(result.merging(["action": "verify"], uniquingKeysWith: { current, _ in current }))
        }

        if let absent = command.absent {
            let result = try await verifyText(absent, absent: true)
            results.append(result.merging(["action": "verifyAbsent"], uniquingKeysWith: { current, _ in current }))
        }

        return [
            "ok": !results.isEmpty && results.allSatisfy { Self.boolValue($0["ok"]) },
            "results": results
        ]
    }

    private func runBatch(_ command: BatchCommand) async throws -> [String: Any] {
        var results: [[String: Any]] = []
        for action in command.actions.prefix(20) {
            switch action.normalizedAction {
            case "navigate":
                guard let urlText = action.url,
                      let url = ShelfBrowserAddress.normalizedURL(from: urlText) else {
                    results.append(["ok": false, "action": action.action, "error": "invalid_url"])
                    continue
                }
                load(url, source: "bridge_batch")
                results.append(["ok": true, "action": action.action, "url": url.absoluteString])
            case "click":
                let json = try await click(
                    selector: action.normalizedSelector,
                    x: action.x,
                    y: action.y,
                    allowDangerous: action.allowDangerous ?? false,
                    label: action.normalizedLabel,
                    role: action.normalizedRole,
                    text: action.text,
                    placeholder: action.normalizedPlaceholder,
                    testID: action.normalizedTestID
                )
                results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "type":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                let json = try await type(
                    selector: action.normalizedSelector,
                    text: text,
                    clear: action.clear ?? true,
                    label: action.normalizedLabel,
                    role: action.normalizedRole,
                    placeholder: action.normalizedPlaceholder,
                    testID: action.normalizedTestID
                )
                results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "setvalue", "set-value", "fill":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                let json = try await type(
                    selector: action.normalizedSelector,
                    text: text,
                    clear: true,
                    label: action.normalizedLabel,
                    role: action.normalizedRole,
                    placeholder: action.normalizedPlaceholder,
                    testID: action.normalizedTestID
                )
                results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "replacetext", "replace-text":
                guard let find = action.find,
                      let replacement = action.replacement ?? action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_find_or_replacement"])
                    continue
                }
                let json = try await replaceText(
                    find: find,
                    replacement: replacement,
                    selector: action.normalizedSelector,
                    all: action.all ?? true
                )
                results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "findcontrol", "find-control":
                let result = try await findControl(
                    query: action.query ?? action.label ?? "",
                    role: action.role,
                    limit: action.limit ?? 10
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "clickcontrol", "click-control":
                guard let label = action.label ?? action.query else {
                    results.append(["ok": false, "action": action.action, "error": "missing_label"])
                    continue
                }
                let result = try await clickControl(
                    label: label,
                    role: action.role,
                    allowDangerous: action.allowDangerous ?? false
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "verifytext", "verify-text":
                guard let text = action.text ?? action.query else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                let result = try await verifyText(text, absent: action.absent ?? false)
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "waitsaved", "wait-saved":
                let result = try await waitSaved(
                    timeoutSeconds: action.timeoutSeconds ?? 8,
                    intervalMilliseconds: action.intervalMilliseconds ?? 500
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "googlefindreplace", "google-find-replace":
                guard let find = action.find,
                      let replacement = action.replacement ?? action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_find_or_replacement"])
                    continue
                }
                let result = try await googleFindReplace(find: find, replacement: replacement, all: action.all ?? true)
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "googledocsfind", "google-docs-find":
                guard let query = action.query ?? action.text ?? action.verify else {
                    results.append(["ok": false, "action": action.action, "error": "missing_query"])
                    continue
                }
                let result = try await googleDocsFind(query: query, closeFindBar: action.closeFindBar ?? true)
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "googledocsinsert", "google-docs-insert":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                let result = try await googleDocsInsert(
                    text: text,
                    verifyText: action.verify ?? action.query,
                    waitSaved: action.waitSaved ?? true
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "googledriveopen", "google-drive-open", "drive-open":
                guard let name = action.name ?? action.query ?? action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_name"])
                    continue
                }
                let result = try await googleDriveOpen(
                    name: name,
                    timeoutSeconds: action.timeoutSeconds ?? 12,
                    intervalMilliseconds: action.intervalMilliseconds ?? 500
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "act":
                let result = try await act(ActCommand(
                    find: action.find ?? action.query,
                    set: action.set ?? action.text,
                    role: action.role,
                    click: action.click ?? action.label,
                    clickRole: action.clickRole,
                    allowDangerous: action.allowDangerous,
                    waitSaved: action.waitSaved,
                    verify: action.verify,
                    absent: action.absentText ?? (action.absent == true ? action.text : nil),
                    timeoutSeconds: action.timeoutSeconds,
                    intervalMilliseconds: action.intervalMilliseconds
                ))
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "keypress":
                guard let key = action.key else {
                    results.append(["ok": false, "action": action.action, "error": "missing_key"])
                    continue
                }
                let json = try await keypress(key: key, modifiers: action.modifiers ?? [])
                results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "text", "inserttext":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                let json = try await insertText(text)
                results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "waitfortext", "wait-text":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                let result = try await waitForText(
                    text,
                    timeoutSeconds: action.timeoutSeconds ?? 5,
                    intervalMilliseconds: action.intervalMilliseconds ?? 250
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "waitforselector", "wait-selector":
                guard let selector = action.normalizedSelector else {
                    results.append(["ok": false, "action": action.action, "error": "missing_selector"])
                    continue
                }
                let result = try await waitForSelector(
                    selector,
                    timeoutSeconds: action.timeoutSeconds ?? 5,
                    intervalMilliseconds: action.intervalMilliseconds ?? 250
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "snapshot":
                let json = try await snapshot(
                    mode: SnapshotMode(rawValue: action.mode ?? "summary") ?? .summary,
                    query: action.query,
                    limit: action.limit
                )
                results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            default:
                results.append(["ok": false, "action": action.action, "error": "unknown_action"])
            }
        }

        var response: [String: Any] = [
            "ok": results.allSatisfy { Self.boolValue($0["ok"]) },
            "results": results
        ]
        if let snapshotMode = command.snapshotMode {
            let snapshotJSON = try await snapshot(
                mode: SnapshotMode(rawValue: snapshotMode) ?? .summary,
                query: command.snapshotQuery,
                limit: command.snapshotLimit
            )
            response["snapshot"] = try Self.jsonObject(from: snapshotJSON)
        }
        return response
    }

    private func evaluateJavaScriptString(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let string = result as? String {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(returning: #"{"ok":true}"#)
                }
            }
        }
    }

    private static func compactSnapshot(json: String, mode: SnapshotMode, query: String?, limit: Int?) throws -> String {
        let object = try jsonObject(from: json)
        let queryText = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let controls = object["controls"] as? [[String: Any]] ?? []
        let filteredControls = filteredControls(controls, query: queryText)

        var compact: [String: Any] = [
            "ok": boolValue(object["ok"]),
            "url": object["url"] as? String ?? "",
            "title": object["title"] as? String ?? ""
        ]

        if let viewport = object["viewport"] {
            compact["viewport"] = viewport
        }
        if let focused = object["focusedElement"] {
            compact["focusedElement"] = focused
        }

        switch mode {
        case .full:
            return json
        case .text:
            let text = object["text"] as? String ?? ""
            compact["text"] = String(text.prefix(max(0, limit ?? 1_500)))
            if let queryText, !queryText.isEmpty {
                compact["matches"] = textMatches(in: text, query: queryText, limit: limit ?? 8)
            }
        case .controls:
            compact["controlCount"] = controls.count
            compact["controls"] = Array(filteredControls.prefix(max(1, limit ?? 40)))
        case .summary:
            let text = object["text"] as? String ?? ""
            compact["text"] = String(text.prefix(max(0, limit ?? 1_200)))
            compact["controlCount"] = controls.count
            compact["controls"] = Array(filteredControls.prefix(20))
            if let queryText, !queryText.isEmpty {
                compact["matches"] = textMatches(in: text, query: queryText, limit: 5)
            }
        }

        return try jsonString(compact)
    }

    private static func filteredControls(_ controls: [[String: Any]], query: String?) -> [[String: Any]] {
        guard let query, !query.isEmpty else { return controls }
        let lowerQuery = query.lowercased()
        return controls.filter { control in
            ["selector", "label", "value", "role", "type", "href"].contains { key in
                (control[key] as? String)?.lowercased().contains(lowerQuery) == true
            }
        }
    }

    private static func controlsMatching(_ controls: [[String: Any]], label: String, role: String?) -> [[String: Any]] {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedRole = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = controls.filter { control in
            let roleMatches: Bool
            if let normalizedRole, !normalizedRole.isEmpty {
                roleMatches = (control["role"] as? String)?.lowercased().contains(normalizedRole) == true
                    || (control["tag"] as? String)?.lowercased().contains(normalizedRole) == true
                    || (control["type"] as? String)?.lowercased().contains(normalizedRole) == true
            } else {
                roleMatches = true
            }
            guard roleMatches else { return false }
            guard !normalizedLabel.isEmpty else { return true }
            return ["label", "name", "value", "selector", "role", "type", "href", "placeholder", "testID"].contains { key in
                (control[key] as? String)?.lowercased().contains(normalizedLabel) == true
            }
        }
        return matches.sorted { left, right in
            controlMatchScore(left, query: normalizedLabel, role: normalizedRole) > controlMatchScore(right, query: normalizedLabel, role: normalizedRole)
        }
    }

    private static func controlMatchScore(_ control: [String: Any], query: String, role: String?) -> Int {
        var score = 0
        let label = (control["label"] as? String ?? "").lowercased()
        let name = (control["name"] as? String ?? "").lowercased()
        let value = (control["value"] as? String ?? "").lowercased()
        let selector = (control["selector"] as? String ?? "").lowercased()
        let controlRole = (control["role"] as? String ?? "").lowercased()
        let placeholder = (control["placeholder"] as? String ?? "").lowercased()
        let testID = (control["testID"] as? String ?? "").lowercased()

        if let role, !role.isEmpty, controlRole == role { score += 25 }
        if !query.isEmpty {
            if label == query || name == query { score += 50 }
            if label.hasPrefix(query) || name.hasPrefix(query) { score += 25 }
            if value == query || placeholder == query || testID == query { score += 20 }
            if selector.contains(query) { score += 5 }
        }
        if boolValue(control["actionable"]) { score += 10 }
        if !boolValue(control["disabled"]) { score += 5 }
        return score
    }

    private static func textMatches(in text: String, query: String, limit: Int) -> [[String: Any]] {
        guard !query.isEmpty else { return [] }
        var matches: [[String: Any]] = []
        var searchStart = text.startIndex
        while matches.count < max(1, limit),
              let range = text.range(of: query, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let lowerBound = text.index(range.lowerBound, offsetBy: -120, limitedBy: text.startIndex) ?? text.startIndex
            let upperBound = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
            matches.append([
                "index": text.distance(from: text.startIndex, to: range.lowerBound),
                "snippet": String(text[lowerBound..<upperBound])
            ])
            searchStart = range.upperBound
        }
        return matches
    }

    private static func isOpenedDriveTarget(urlString: String, title: String, name: String, startURL: String?) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return false
        }
        if host == "docs.google.com" {
            guard url.path.hasPrefix("/document/")
                || url.path.hasPrefix("/spreadsheets/")
                || url.path.hasPrefix("/presentation/") else {
                return false
            }
            if let startURL, !startURL.isEmpty, urlString != startURL {
                return true
            }
            return containsNormalized(title, name)
        }
        guard host != "drive.google.com" else {
            return false
        }
        if let startURL, !startURL.isEmpty, urlString == startURL {
            return false
        }
        return url.scheme == "https" || url.scheme == "http"
    }

    private static func containsNormalized(_ text: String, _ query: String) -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedQuery.isEmpty && normalizedText.contains(normalizedQuery)
    }

    private static func googleFindCountText(in text: String) -> String? {
        guard let range = text.range(
            of: #"(?i)\b\d+\s+of\s+\d+\b"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(text[range])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func jsonObject(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? #"{"ok":false,"error":"encoding_failed"}"#
    }

    private func annotateBrowserLoopHint(
        json: String,
        action: String,
        target: String,
        updatePageFingerprint: Bool = false
    ) throws -> String {
        var object = try Self.jsonObject(from: json)
        let fingerprint = Self.pageFingerprint(from: object)
        if updatePageFingerprint {
            lastPageFingerprint = fingerprint
        }
        let state = updatePageFingerprint ? fingerprint : (lastPageFingerprint ?? fingerprint)
        let signature = "\(action):\(target)"

        let count: Int
        if let current = browserActionLoopCounts[signature], current.state == state {
            count = current.count + 1
        } else {
            count = 1
        }
        browserActionLoopCounts[signature] = (state: state, count: count)
        if browserActionLoopCounts.count > 24 {
            browserActionLoopCounts.removeValue(forKey: browserActionLoopCounts.keys.sorted().first ?? signature)
        }

        if count >= 3 {
            object["loopWarning"] = "Repeated browser actions are not changing the page state."
            object["strategyHint"] = isGoogleWorkspaceEditor
                ? "For Google Docs, Sheets, or Slides, switch strategy: use astra-browser snapshot --mode controls --query \"Find\", then use astra-browser set-value on known input selectors. Avoid repeated menu clicks or synthetic Cmd+A if the snapshot is unchanged."
                : "Switch strategy: query controls, use set-value when a selector is known, or batch the next action with a compact snapshot."
            object["repeatedActionCount"] = count
        }

        return try Self.jsonString(object)
    }

    private static func pageFingerprint(from object: [String: Any]) -> String {
        let focused = object["focusedElement"] as? [String: Any]
        let controls = object["controls"] as? [[String: Any]] ?? []
        let controlSummary = controls.prefix(8).map { control in
            [
                control["selector"] as? String ?? "",
                control["label"] as? String ?? "",
                control["value"] as? String ?? ""
            ].joined(separator: "|")
        }.joined(separator: "||")
        return [
            object["url"] as? String ?? "",
            object["title"] as? String ?? "",
            focused?["selector"] as? String ?? "",
            focused?["label"] as? String ?? "",
            focused?["value"] as? String ?? "",
            String((object["text"] as? String ?? "").prefix(300)),
            String(controls.count),
            controlSummary
        ].joined(separator: "\u{1f}")
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private enum SnapshotMode: String {
        case full
        case summary
        case text
        case controls
    }

    private struct NavigateCommand: Decodable {
        let url: String
    }

    private struct ClickCommand: Decodable {
        let selector: String?
        let label: String?
        let role: String?
        let text: String?
        let placeholder: String?
        let testID: String?
        let x: Double?
        let y: Double?
        let allowDangerous: Bool?

        var normalizedSelector: String? {
            let trimmed = selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        var normalizedLabel: String? { ShelfBrowserSession.normalized(label) }
        var normalizedRole: String? { ShelfBrowserSession.normalized(role) }
        var normalizedText: String? { ShelfBrowserSession.normalized(text) }
        var normalizedPlaceholder: String? { ShelfBrowserSession.normalized(placeholder) }
        var normalizedTestID: String? { ShelfBrowserSession.normalized(testID) }
    }

    private struct TypeCommand: Decodable {
        let selector: String?
        let text: String
        let clear: Bool?
        let label: String?
        let role: String?
        let placeholder: String?
        let testID: String?

        var normalizedSelector: String? { ShelfBrowserSession.normalized(selector) }
        var normalizedLabel: String? { ShelfBrowserSession.normalized(label) }
        var normalizedRole: String? { ShelfBrowserSession.normalized(role) }
        var normalizedPlaceholder: String? { ShelfBrowserSession.normalized(placeholder) }
        var normalizedTestID: String? { ShelfBrowserSession.normalized(testID) }
    }

    private struct ReplaceTextCommand: Decodable {
        let find: String
        let replacement: String
        let selector: String?
        let all: Bool?

        var normalizedSelector: String? {
            ShelfBrowserSession.normalized(selector)
        }
    }

    private struct ClickControlCommand: Decodable {
        let label: String
        let role: String?
        let allowDangerous: Bool?
    }

    private struct VerifyTextCommand: Decodable {
        let text: String
        let absent: Bool?
    }

    private struct WaitSavedCommand: Decodable {
        let timeoutSeconds: Double?
        let intervalMilliseconds: Int?
    }

    private struct GoogleFindReplaceCommand: Decodable {
        let find: String
        let replacement: String
        let all: Bool?
    }

    private struct GoogleDocsFindCommand: Decodable {
        let query: String
        let closeFindBar: Bool?
    }

    private struct GoogleDocsInsertCommand: Decodable {
        let text: String
        let verifyText: String?
        let waitSaved: Bool?

        var normalizedVerifyText: String? {
            ShelfBrowserSession.normalized(verifyText)
        }
    }

    private struct GoogleDriveOpenCommand: Decodable {
        let name: String
        let timeoutSeconds: Double?
        let intervalMilliseconds: Int?

        var normalizedName: String {
            name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct ActCommand: Decodable {
        let find: String?
        let set: String?
        let role: String?
        let click: String?
        let clickRole: String?
        let allowDangerous: Bool?
        let waitSaved: Bool?
        let verify: String?
        let absent: String?
        let timeoutSeconds: Double?
        let intervalMilliseconds: Int?
    }

    private struct KeypressCommand: Decodable {
        let key: String
        let modifiers: [String]?
    }

    private struct TextCommand: Decodable {
        let text: String
    }

    private struct WaitTextCommand: Decodable {
        let text: String
        let timeoutSeconds: Double?
        let intervalMilliseconds: Int?
    }

    private struct WaitSelectorCommand: Decodable {
        let selector: String
        let timeoutSeconds: Double?
        let intervalMilliseconds: Int?
    }

    private struct BatchCommand: Decodable {
        let actions: [BatchActionCommand]
        let snapshotMode: String?
        let snapshotQuery: String?
        let snapshotLimit: Int?
    }

    private struct BatchActionCommand: Decodable {
        let action: String
        let url: String?
        let selector: String?
        let label: String?
        let role: String?
        let placeholder: String?
        let testID: String?
        let x: Double?
        let y: Double?
        let allowDangerous: Bool?
        let name: String?
        let text: String?
        let find: String?
        let replacement: String?
        let set: String?
        let click: String?
        let clickRole: String?
        let waitSaved: Bool?
        let verify: String?
        let absentText: String?
        let all: Bool?
        let absent: Bool?
        let clear: Bool?
        let key: String?
        let modifiers: [String]?
        let timeoutSeconds: Double?
        let intervalMilliseconds: Int?
        let mode: String?
        let query: String?
        let limit: Int?
        let closeFindBar: Bool?

        var normalizedAction: String {
            action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var normalizedSelector: String? {
            ShelfBrowserSession.normalized(selector)
        }

        var normalizedLabel: String? { ShelfBrowserSession.normalized(label) }
        var normalizedRole: String? { ShelfBrowserSession.normalized(role) }
        var normalizedPlaceholder: String? { ShelfBrowserSession.normalized(placeholder) }
        var normalizedTestID: String? { ShelfBrowserSession.normalized(testID) }
    }

    nonisolated private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
