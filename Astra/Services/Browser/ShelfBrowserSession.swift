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

enum ShelfBrowserPrivacyBoundary {
    static let blocksEmbeddedPreviewFilePickers = true
    static let blocksEmbeddedPreviewMediaCapture = true
    static let usesEphemeralEmbeddedPreviewDataStore = true
}

enum ShelfBrowserWebViewConfigurationFactory {
    @MainActor
    static func makeEmbeddedConfiguration(pageReadMessageHandler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // Keep the lightweight reporter installed in the preview WebView even when
        // Controlled mode is active, so switching back to Embedded does not require
        // rebuilding WebKit configuration or reloading the page.
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserAutomationScripts.embeddedPageReadReporterScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        configuration.userContentController.add(
            pageReadMessageHandler,
            name: BrowserAutomationScripts.pageReadMessageHandlerName
        )
        return configuration
    }
}

@MainActor
final class ShelfBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var engine: ShelfBrowserEngine = .embedded {
        didSet {
            guard oldValue != engine else { return }
            guard !suppressEngineTransitionHandler else { return }
            browserAnalysisCache.invalidate()
            let controlledHandoffAddress = oldValue == .embedded && engine == .controlled
                ? Self.controlledBrowserHandoffAddress(currentURL: currentURL, webViewURL: _webView?.url)
                : nil
            let embeddedHandoffAddress = oldValue == .controlled && engine == .embedded
                ? Self.embeddedBrowserHandoffAddress(currentURL: currentURL, controlledURL: controlledBrowser.currentURL)
                : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.engine == .controlled, let controlledHandoffAddress {
                    await self.openControlledBrowser(initialAddress: controlledHandoffAddress)
                } else if self.engine == .embedded, let embeddedHandoffAddress {
                    self.openEmbeddedBrowser(address: embeddedHandoffAddress)
                    self.refreshAgentControlPermissionIssue(source: "engine_switch")
                } else {
                    self.syncDisplayedStateForEngine()
                    self.publishBridgeState()
                    if self.engine == .controlled {
                        await self.refreshControlledBrowserStatus()
                    } else {
                        self.refreshAgentControlPermissionIssue(source: "engine_switch")
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
    @Published private(set) var lastPageReadCoverage: String?
    @Published private(set) var lastPageReadURL: String?
    @Published private(set) var lastPageReadWarnings: [String] = []
    @Published var isAgentBridgeEnabled = true {
        didSet {
            publishBridgeState()
            refreshAgentControlPermissionIssue(source: "bridge_toggle_state_changed")
        }
    }
    @Published private(set) var agentControlPermissionIssue: MacOSPermissionIssue?

    private var _webView: WKWebView?

    /// The embedded WebKit view, created lazily on first real use — rendering
    /// the browser panel or driving navigation. Deferring it keeps WebKit, and
    /// the Photos/Music media frameworks it transitively loads, off the launch
    /// path: simply holding a (usually off-screen) browser session no longer
    /// spins up WebKit and triggers media-library TCC prompts at app startup.
    /// Lifecycle code (teardown, state sync, engine handoff) reads `_webView`
    /// directly so it never forces creation of a view that was never shown.
    var webView: WKWebView {
        if let _webView { return _webView }
        let created = makeWebView()
        _webView = created
        return created
    }

    /// Whether the embedded WebKit view has actually been instantiated. False
    /// for a session that exists but was never shown — the state that keeps
    /// app launch off the Photos/Music media frameworks. Lets callers (and
    /// tests) observe lazy creation without forcing it.
    var isWebViewLoaded: Bool { _webView != nil }
    let controlledBrowser = ControlledBrowserController()

    private var observations: [NSKeyValueObservation] = []
    private var controlledBrowserCancellable: AnyCancellable?
    private var bridgeServer: BrowserBridgeServer?
    private let bridgeAccessToken = BrowserBridgeServer.generateAccessToken()
    private var isPresented = false
    /// Last time an agent hit this session's bridge. Used to keep an
    /// off-screen session that a background agent is actively driving from
    /// being evicted between commands.
    private var lastBridgeActivity = Date()
    /// Idle grace before a hidden session becomes eligible for eviction.
    static let evictionIdleGrace: TimeInterval = 120
    /// Plain mirror of `boundTaskID` (which is @Published and therefore not
    /// readable from the nonisolated deinit). Used only for the guarded
    /// registry reset on deallocation.
    private var lastBoundTaskID: UUID?
    private var browserActionLoopCounts: [String: (state: String, count: Int)] = [:]
    private let browserAnalysisCache = BrowserAnalysisCache()
    private var enabledBrowserAdapters: Set<String> = []
    private var lastBrowserTrace: [String: Any]?
    private var browserDiagnostics = BrowserDiagnosticsSessionState()
    private var lastPageFingerprint: String?
    private var embeddedPageReadRequests: [String: EmbeddedPageReadRequest] = [:]
    private var pageReadMessageHandler: WeakPageReadMessageHandler?
    private var lastLoggedURL = ""
    private var keypressSafetyState = BrowserKeypressSafetyState()
    private var browserRunGuard = BrowserRunGuard()
    private var isWebKitDebugInstrumentationScriptRegistered = false
    private var suppressEngineTransitionHandler = false

    var isUsingControlledBrowser: Bool {
        engine == .controlled
    }

    var isGoogleDriveAdapterEnabled: Bool {
        GoogleDriveBrowserAdapter.isEnabled(in: enabledBrowserAdapters)
    }

    var isGoogleDrivePage: Bool {
        guard let url = URL(string: currentURL) else { return false }
        return url.host?.lowercased() == "drive.google.com"
    }

    var canUseGoogleDriveOpen: Bool {
        isGoogleDriveAdapterEnabled || isGoogleDrivePage || isGoogleWorkspaceEditor
    }

    var activeBrowserSiteAdapters: [[String: Any]] {
        [
            GoogleDriveBrowserAdapter.activeMetadata(pageURL: currentURL, enabledAdapterIDs: enabledBrowserAdapters),
            GitHubBrowserAdapter.activeMetadata(pageURL: currentURL, enabledAdapterIDs: enabledBrowserAdapters)
        ].compactMap { $0 }
    }

    var isAgentControlPermissionGuideVisible: Bool {
        agentControlPermissionIssue != nil
    }

    var hasDisplayablePage: Bool {
        Self.isDisplayablePageURL(currentURL)
    }

    var isGoogleWorkspaceEditor: Bool {
        GoogleWorkspaceBrowserService.isGoogleWorkspaceEditorURL(currentURL)
    }

    var isGoogleDocsEditor: Bool {
        guard let url = URL(string: currentURL),
              url.host?.lowercased() == "docs.google.com" else {
            return false
        }
        return url.path.hasPrefix("/document/")
    }

    var bridgeCapabilities: [String] {
        var capabilities = [
            "health",
            "actions",
            "analyze",
            "preflight",
            "trace",
            "benchmark",
            "read.page",
            "snapshot",
            "locator",
            "navigate",
            "control.id",
            "analysis.cache",
            "analysis.preflight",
            "analysis.v2",
            "analysis.v2.rollout",
            "click.selector",
            "click.locator",
            "click.coordinates",
            "open.control",
            "double.click",
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
            "google.docs.read.visible.page",
            "google.docs.read.document",
            "google.docs.replace.document",
            "act",
            "keypress",
            "text.focused",
            "page.compact",
            "snapshot.compact",
            "batch",
            "wait.text",
            "wait.selector"
        ]
        if canUseGoogleDriveOpen {
            capabilities.append(contentsOf: [
                "google.drive.open"
            ])
        }
        if engine.automationDescriptor.kind == .controlledCDP {
            capabilities.append("action.settlement.cdp")
        }
        if isGoogleDriveAdapterEnabled {
            capabilities.append("browser.adapter.googleDrive")
        }
        return capabilities
    }

    override init() {
        super.init()
        controlledBrowserCancellable = controlledBrowser.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isUsingControlledBrowser else { return }
                self.syncDisplayedStateForEngine()
                self.publishBridgeState()
                self.objectWillChange.send()
            }
        }
        startBridge()
    }

    /// Builds the embedded WebKit view and wires its delegates and KVO
    /// observers. Invoked once, lazily, the first time `webView` is accessed —
    /// never during session construction — so WebKit (and the media frameworks
    /// it pulls in) stay off the launch path. The freshly built view is passed
    /// to `installObservers` so observer setup can't re-enter the lazy getter.
    private func makeWebView() -> WKWebView {
        let pageReadHandler = WeakPageReadMessageHandler()
        pageReadHandler.session = self
        pageReadMessageHandler = pageReadHandler
        let configuration = ShelfBrowserWebViewConfigurationFactory.makeEmbeddedConfiguration(
            pageReadMessageHandler: pageReadHandler
        )
        let created = WKWebView(frame: .zero, configuration: configuration)
        created.allowsBackForwardNavigationGestures = true
        created.navigationDelegate = self
        created.uiDelegate = self
        installObservers(on: created)
        return created
    }

    deinit {
        bridgeServer?.stop()
        // Only clear the shared registry if it still points at us, so a
        // non-active session being deallocated cannot wipe the registration
        // of the session an agent is currently driving. Uses the plain mirror
        // because the @Published boundTaskID isn't readable from deinit.
        ShelfBrowserBridgeRegistry.shared.resetIfActive(taskID: lastBoundTaskID)
    }

    /// True only when this session is safe to tear down: off screen, not
    /// loading, not bound to a live controlled browser, and idle past the
    /// bridge grace window — so eviction never interrupts in-flight agent
    /// browser automation running in a non-visible task.
    var isEvictable: Bool {
        !isPresented
            && !isLoading
            && !isUsingControlledBrowser
            && !controlledBrowser.isRunning
            && Date().timeIntervalSince(lastBridgeActivity) > Self.evictionIdleGrace
    }

    /// Release this session's heavy resources (WebContent process, localhost
    /// bridge listener, KVO observers) before the store drops it. Only call on
    /// an `isEvictable` session.
    func teardown() {
        _webView?.stopLoading()
        _webView?.navigationDelegate = nil
        _webView?.uiDelegate = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        controlledBrowserCancellable?.cancel()
        controlledBrowserCancellable = nil
        controlledBrowser.stop()
        bridgeServer?.stop()
        bridgeServer = nil
        ShelfBrowserBridgeRegistry.shared.resetIfActive(taskID: boundTaskID)
        // Release the WebContent process and message handler outright. Keeping a
        // strong `_webView` ref would hold WebKit (and its helper process) alive
        // for a session that's being evicted but not yet deallocated. A later
        // access — rare for an evicted session — lazily recreates a fresh view.
        pageReadMessageHandler = nil
        _webView = nil
    }

    func setPresented(_ isPresented: Bool) {
        self.isPresented = isPresented
        publishBridgeState()
    }

    func bindToTask(_ taskID: UUID?) {
        guard boundTaskID != taskID else { return }
        boundTaskID = taskID
        lastBoundTaskID = taskID
        keypressSafetyState = BrowserKeypressSafetyState()
        browserRunGuard.reset()
        browserDiagnostics.reset()
        lastBrowserTrace = nil
        publishBridgeState()
    }

    func setEnabledBrowserAdapters(_ adapterIDs: [String]) {
        let normalized = BrowserSiteAdapterID.normalizedSet(adapterIDs)
        guard normalized != enabledBrowserAdapters else { return }
        enabledBrowserAdapters = normalized
        browserAnalysisCache.invalidate()
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
        browserAnalysisCache.invalidate()
        invalidateLastPageReadState()
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
        guard engine == .controlled else {
            engine = .controlled
            return
        }

        Task {
            await openControlledBrowser(initialAddress: initialAddress)
        }
    }

    private func openControlledBrowser(initialAddress: String?) async {
        browserAnalysisCache.invalidate()
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
        if engine != .controlled {
            suppressEngineTransitionHandler = true
            engine = .controlled
            suppressEngineTransitionHandler = false
        }
        await controlledBrowser.launch(initialAddress: initialAddress)
        syncDisplayedStateForEngine()
        publishBridgeState()
        refreshAgentControlPermissionIssue(source: "controlled_browser_launch")
    }

    private func ensureControlledBrowserForGoogleWorkspaceAction(action: String, started: Date) async -> [String: Any]? {
        guard !isUsingControlledBrowser || !controlledBrowser.isRunning else { return nil }

        if !isUsingControlledBrowser {
            let autoPromote = UserDefaults.standard.bool(forKey: AppStorageKeys.browserAutoPromoteGoogleWorkspace)
            guard autoPromote else {
                logBrowserAction(
                    phase: "skipped",
                    action: "controlledBrowserPromotion",
                    selector: nil,
                    label: nil,
                    role: nil,
                    text: nil,
                    placeholder: nil,
                    testID: nil,
                    fields: ["source_action": action, "reason": "setting_disabled"],
                    started: started
                )
                return nil
            }
        }

        let initialAddress = Self.controlledBrowserHandoffAddress(currentURL: currentURL, webViewURL: webView.url)
        guard let initialAddress else {
            var response: [String: Any] = [
                "ok": false,
                "error": "controlled_browser_unavailable",
                "action": action,
                "url": currentURL,
                "title": pageTitle,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "hint": "Google Drive and Google Docs browser helpers require a displayable page to hand off to controlled Chromium."
            ]
            BrowserBridgeRecoveryHints.attach(
                to: &response,
                error: "controlled_browser_unavailable",
                action: action
            )
            return response
        }

        logBrowserAction(
            phase: "requested",
            action: "controlledBrowserPromotion",
            selector: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil,
            fields: ["source_action": action]
        )

        await openControlledBrowser(initialAddress: initialAddress)

        let ready = await waitForControlledBrowserReady(timeoutSeconds: 10)
        if ready {
            logBrowserAction(
                phase: "completed",
                action: "controlledBrowserPromotion",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: ["source_action": action, "promoted": "true"],
                started: started
            )
            return nil
        }

        var response: [String: Any] = [
            "ok": false,
            "error": "controlled_browser_unavailable",
            "action": action,
            "url": currentURL,
            "title": pageTitle,
            "controlledBrowserState": controlledBrowser.runState.rawValue,
            "controlledBrowserStatus": controlledBrowser.statusMessage,
            "controlledBrowserLastError": controlledBrowser.lastErrorMessage ?? "",
            "elapsedSeconds": Date().timeIntervalSince(started),
            "hint": "ASTRA could not launch or reach controlled Chromium. Stop browser probing and fix controlled browser setup or permissions before retrying Google Drive/Docs automation."
        ]
        BrowserBridgeRecoveryHints.attach(
            to: &response,
            error: "controlled_browser_unavailable",
            action: action
        )
        return response
    }

    private func waitForControlledBrowserReady(timeoutSeconds: Double) async -> Bool {
        let started = Date()
        let timeout = max(0.5, min(timeoutSeconds, 20))
        while Date().timeIntervalSince(started) <= timeout {
            syncDisplayedStateForEngine()
            if engine == .controlled, controlledBrowser.isRunning {
                publishBridgeState()
                return true
            }
            if controlledBrowser.runState == .failed {
                syncDisplayedStateForEngine()
                publishBridgeState()
                return false
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        syncDisplayedStateForEngine()
        publishBridgeState()
        return engine == .controlled && controlledBrowser.isRunning
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
        refreshAgentControlPermissionIssue(source: "controlled_browser_refresh")
    }

    func checkAgentControlPermissionAgain() async {
        guard engine == .controlled else {
            refreshAgentControlPermissionIssue(source: "permission_check_retry")
            return
        }

        let initialAddress = Self.controlledBrowserHandoffAddress(currentURL: currentURL, webViewURL: webView.url)
        await openControlledBrowser(initialAddress: initialAddress)
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
            refreshAgentControlPermissionIssue(source: source)
        } else {
            agentControlPermissionIssue = nil
        }
    }

    func presentAgentControlPermissionGuide(source: String) {
        refreshAgentControlPermissionIssue(source: source)
    }

    func dismissAgentControlPermissionGuide(source: String = "user") {
        guard isAgentControlPermissionGuideVisible else { return }
        let previousKind = agentControlPermissionIssue?.kind.rawValue ?? "unknown"
        agentControlPermissionIssue = nil
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "action": "agent_control_permission_guide",
                "phase": "dismissed",
                "source": source,
                "permission_kind": previousKind,
                "engine": engine.rawValue,
                "controlled_browser_state": controlledBrowser.runState.rawValue
            ],
            level: .info
        )
    }

    func openAgentControlPrivacySettings() {
        let kind = agentControlPermissionIssue?.kind ?? .appManagement
        let opened = MacOSPermissionDiagnostics.openSettings(for: kind)
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "action": "agent_control_privacy_settings",
                "permission_kind": kind.rawValue,
                "result": opened ? "opened" : "failed",
                "engine": engine.rawValue,
                "controlled_browser_state": controlledBrowser.runState.rawValue
            ],
            level: opened ? .info : .warning
        )
    }

    private var applicationDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? AppChannel.current.displayName
    }

    private func refreshAgentControlPermissionIssue(source: String) {
        let issue = MacOSPermissionDiagnostics.controlledBrowserAgentControlIssue(
            appDisplayName: applicationDisplayName,
            browserName: controlledBrowser.browserName,
            isRunning: controlledBrowser.isRunning,
            runState: controlledBrowser.runState,
            lastErrorMessage: controlledBrowser.lastErrorMessage
        )
        updateAgentControlPermissionIssue(issue, source: source)
    }

    private func updateAgentControlPermissionIssue(_ issue: MacOSPermissionIssue?, source: String) {
        let activeIssue = isAgentBridgeEnabled && engine == .controlled ? issue : nil
        guard activeIssue != agentControlPermissionIssue else { return }
        agentControlPermissionIssue = activeIssue

        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "action": "agent_control_permission_check",
                "result": activeIssue == nil ? "ok" : "missing",
                "permission_kind": activeIssue?.kind.rawValue ?? "none",
                "source": source,
                "engine": engine.rawValue,
                "controlled_browser_state": controlledBrowser.runState.rawValue
            ],
            level: activeIssue == nil ? .debug : .warning
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
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        logEmbeddedPrivacyRequestBlocked(action: "open_panel", sourceURL: frame.request.url)
        completionHandler(nil)
    }

    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        logEmbeddedPrivacyRequestBlocked(action: "media_capture", sourceURL: frame.request.url)
        decisionHandler(.deny)
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

    private func logEmbeddedPrivacyRequestBlocked(action: String, sourceURL: URL?) {
        var fields: [String: String] = [
            "action": action,
            "result": "blocked",
            "reason": "embedded_preview_privacy_boundary",
            "engine": engine.rawValue,
            "is_presented": String(isPresented)
        ]
        if let sourceURL {
            fields.merge(ShelfBrowserURLLogFields.fields(for: sourceURL, prefix: "source"), uniquingKeysWith: { current, _ in current })
        }
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: fields,
            level: .warning
        )
    }

    private func installObservers(on webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let nextURL = webView.url?.absoluteString ?? ""
                    if nextURL != self.currentURL {
                        self.browserAnalysisCache.invalidate()
                        self.invalidateLastPageReadState()
                    }
                    self.currentURL = nextURL
                    self.logObservedURLChange(nextURL)
                    self.publishBridgeState()
                }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor [weak self] in
                    self?.pageTitle = webView.title ?? ""
                    self?.publishBridgeState()
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor [weak self] in
                    self?.isLoading = webView.isLoading
                }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor [weak self] in
                    self?.estimatedProgress = webView.estimatedProgress
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor [weak self] in
                    self?.canGoBack = webView.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor [weak self] in
                    self?.canGoForward = webView.canGoForward
                }
            }
        ]
    }

    private func startBridge() {
        let server = BrowserBridgeServer(requiredAccessToken: bridgeAccessToken, route: { [weak self] request in
            guard let self else {
                return .json(["ok": false, "error": "browser_session_unavailable"], statusCode: 404)
            }
            return await self.handleBridgeRequest(request)
        }, onEndpointChanged: { [weak self] endpoint in
            Task { @MainActor [weak self] in
                self?.bridgeEndpoint = endpoint
                self?.publishBridgeState()
            }
        })
        bridgeServer = server
        server.start()
    }

    func publishBridgeState() {
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: bridgeEndpoint,
            currentURL: currentURL.isEmpty ? nil : currentURL,
            currentTitle: pageTitle.isEmpty ? nil : pageTitle,
            backend: engine.bridgeBackendLabel,
            taskID: boundTaskID,
            accessToken: bridgeAccessToken,
            isPresented: isPresented,
            isEnabled: isAgentBridgeEnabled,
            enabledBrowserAdapters: Array(enabledBrowserAdapters).sorted()
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

    func syncDisplayedStateForEngine() {
        if isUsingControlledBrowser {
            currentURL = controlledBrowser.currentURL
            pageTitle = controlledBrowser.pageTitle
            isLoading = controlledBrowser.isLaunching
            estimatedProgress = controlledBrowser.isRunning ? 1 : 0
            canGoBack = false
            canGoForward = false
        } else {
            currentURL = _webView?.url?.absoluteString ?? ""
            pageTitle = _webView?.title ?? ""
            isLoading = _webView?.isLoading ?? false
            estimatedProgress = _webView?.estimatedProgress ?? 0
            canGoBack = _webView?.canGoBack ?? false
            canGoForward = _webView?.canGoForward ?? false
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
        // Mark the session as actively driven so the store won't evict it
        // between an agent's bridge commands while it's off screen.
        lastBridgeActivity = Date()
        guard isFlightRecordedBridgeRequest(request) else {
            return await handleBridgeRequestCore(request)
        }

        let debugCapturePolicy = BrowserFailureDebugCapture.policy(for: request)
        await installBrowserDebugInstrumentationIfNeeded(policy: debugCapturePolicy)

        let started = Date()
        let before = browserFlightPageSnapshot()
        var response = await handleBridgeRequestCore(request)
        var result = Self.responseObject(from: response)
        if let guarded = browserRunGuardPostResponse(for: request, result: result, before: before) {
            response = .json(guarded, statusCode: 429)
            result = guarded
        }
        let debugCapture = await browserFailureDebugCapture(
            policy: debugCapturePolicy,
            request: request,
            response: response,
            result: result
        )
        recordBrowserFlightStep(
            request: request,
            response: response,
            result: result,
            debugCapture: debugCapture,
            before: before,
            started: started
        )
        return response
    }

    private func handleBridgeRequestCore(_ request: BrowserBridgeRequest) async -> BrowserBridgeResponse {
        let route = ShelfBrowserBridgeCommandRouter.route(method: request.method, path: request.path)

        if let response = browserEngineRequirementResponse(for: request) {
            return .json(response, statusCode: 409)
        }

        if route == .health {
            let automationEngine = engine.automationDescriptor
            let flightSnapshot = browserDiagnostics.flightSnapshot
            var health: [String: Any] = [
                "ok": true,
                "url": currentURL,
                "title": pageTitle,
                "backend": engine.bridgeBackendLabel,
                "automationEngine": automationEngine.jsonObject,
                "controlledBrowserRunning": controlledBrowser.isRunning,
                "controlledBrowserState": controlledBrowser.runState.rawValue,
                "controlledBrowserStatus": controlledBrowser.statusMessage,
                "controlledBrowserRuntime": BrowserAutomationEnginePublicState.controlledBrowser(
                    isRunning: controlledBrowser.isRunning,
                    runState: controlledBrowser.runState.rawValue,
                    statusMessage: controlledBrowser.statusMessage,
                    hasDebugPort: controlledBrowser.debugPort != nil,
                    hasProcessID: controlledBrowser.processID != nil,
                    lastErrorMessage: controlledBrowser.lastErrorMessage
                ),
                "bridgeEnabled": isAgentBridgeEnabled,
                "lastPageRead": [
                    "coverage": lastPageReadCoverage ?? "",
                    "url": lastPageReadURL ?? "",
                    "warnings": lastPageReadWarnings
                ],
                "browserAnalysisV2Mode": BrowserAnalysisV2RolloutMode.configured().rawValue,
                "enabledBrowserAdapters": Array(enabledBrowserAdapters).sorted(),
                "activeSiteAdapters": activeBrowserSiteAdapters,
                "browserRunGuard": [
                    "totalBrowserCalls": browserRunGuard.totalBrowserCalls,
                    "warningThreshold": 30,
                    "hardStopThreshold": 60
                ],
                "capabilities": bridgeCapabilities
            ]
            health["browserFlightRecorder"] = flightSnapshot
            health["statusSummary"] = BrowserBridgeStatusSummary.build(
                bridgeEnabled: isAgentBridgeEnabled,
                hasEndpoint: bridgeEndpoint != nil,
                backend: engine.bridgeBackendLabel,
                controlledState: controlledBrowser.runState.rawValue,
                controlledRunning: controlledBrowser.isRunning,
                hasDebugPort: controlledBrowser.debugPort != nil,
                activeAdapterCount: activeBrowserSiteAdapters.count,
                lastFailure: browserDiagnostics.lastFailure
            )
            if let lastBrowserTrace {
                health["lastBrowserTrace"] = lastBrowserTrace
            }
            if let lastDebugCapture = browserDiagnostics.lastDebugCapture {
                health["lastBrowserDebugCapture"] = lastDebugCapture
            }
            if let error = controlledBrowser.lastErrorMessage {
                health["controlledBrowserLastError"] = error
            }
            if let boundTaskID {
                health["taskID"] = boundTaskID.uuidString
            }
            return .json(health)
        }

        if route == .actions {
            return .json(ShelfBrowserBridgeCommandRouter.actionsResponse(
                backend: engine.bridgeBackendLabel,
                automationEngine: engine.automationDescriptor,
                capabilities: bridgeCapabilities,
                canUseGoogleDriveOpen: canUseGoogleDriveOpen,
                googleDriveOpenDefaultTimeoutSeconds: GoogleWorkspaceBrowserService.googleDriveOpenDefaultTimeoutSeconds
            ))
        }

        guard isAgentBridgeEnabled else {
            var response: [String: Any] = ["ok": false, "error": "browser_bridge_disabled"]
            BrowserBridgeRecoveryHints.attach(to: &response, error: "browser_bridge_disabled")
            return .json(response, statusCode: 403)
        }

        guard let route else {
            var response: [String: Any] = ["ok": false, "error": "not_found"]
            BrowserBridgeRecoveryHints.attach(to: &response, error: "not_found")
            return .json(response, statusCode: 404)
        }

        if let budgetResponse = browserRunGuardResponse(for: request) {
            return .json(budgetResponse, statusCode: 429)
        }

        do {
            switch route {
            case .analyze:
                let query = request.queryValue("query")
                let full = Self.boolQueryValue(request.queryValue("full")) ?? false
                let debug = Self.boolQueryValue(request.queryValue("debug")) ?? false
                let hasExplicitVersion = request.queryValue("v2") != nil || request.queryValue("version") != nil
                let requestedVersion = BrowserAnalysisVersion.requested(
                    version: request.queryValue("version"),
                    v2: Self.boolQueryValue(request.queryValue("v2")) ?? false
                )
                let rollout = BrowserAnalysisV2RolloutMode.configured()
                let version = rollout.effectiveVersion(requested: requestedVersion, explicit: hasExplicitVersion)
                let limit = request.queryValue("limit").flatMap(Int.init)
                return .json(try await analyze(
                    query: query,
                    full: full,
                    limit: limit,
                    debug: debug,
                    version: version,
                    rolloutMode: rollout,
                    includeShadowV2: rollout.shouldAttachShadowAnalysis && !hasExplicitVersion
                ))
            case .preflight:
                let command = try request.decodeJSON(BrowserPreflightCommand.self)
                return .json(try await preflightResponse(command))
            case .trace:
                return .json(browserDiagnostics.traceResponse(
                    lastBrowserTrace: lastBrowserTrace,
                    full: Self.boolQueryValue(request.queryValue("full")) ?? false
                ))
            case .benchmark:
                return .json(BrowserBenchmarkRunner.response(
                    suiteID: request.queryValue("suite"),
                    includeResults: Self.boolQueryValue(request.queryValue("run")) ?? true
                ))
            case .snapshot:
                let mode = BrowserSnapshotMode(rawValue: request.queryValue("mode") ?? "full") ?? .full
                let query = request.queryValue("query")
                let limit = request.queryValue("limit").flatMap(Int.init)
                let json = try await snapshot(mode: mode, query: query, limit: limit)
                return .rawJSON(json)
            case .readPage:
                return .json(try await readPage(
                    format: request.queryValue("format"),
                    limit: request.queryValue("limit").flatMap(Int.init),
                    chunkSize: request.queryValue("chunkSize").flatMap(Int.init)
                        ?? request.queryValue("chunk-size").flatMap(Int.init)
                ))
            case .navigate:
                let command = try request.decodeJSON(NavigateCommand.self)
                guard let url = ShelfBrowserAddress.normalizedURL(from: command.url) else {
                    return .json(["ok": false, "error": "invalid_url"], statusCode: 400)
                }
                let wait = await navigateForBridge(to: url, source: "bridge")
                return .json([
                    "ok": true,
                    "url": wait["url"] as? String ?? url.absoluteString,
                    "title": wait["title"] as? String ?? "",
                    "navigationWait": wait
                ])
            case .click:
                let command = try request.decodeJSON(ClickCommand.self)
                if command.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: command.analysisID,
                        controlID: command.controlID,
                        action: BrowserActionKind.click.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        return .json(resolved.response)
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await click(
                        selector: target.selector,
                        x: target.x,
                        y: target.y,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous),
                        label: target.label,
                        role: target.role,
                        text: nil,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .click, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    object["summary"] = "Clicked \(browserControlDescription(control))."
                    return .json(object)
                }
                let json = try await click(
                    selector: command.normalizedSelector,
                    x: command.x,
                    y: command.y,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous),
                    label: command.normalizedLabel,
                    role: command.normalizedRole,
                    text: command.normalizedText,
                    placeholder: command.normalizedPlaceholder,
                    testID: command.normalizedTestID
                )
                return .rawJSON(json)
            case .open:
                let command = try request.decodeJSON(ClickCommand.self)
                guard command.hasAnalysisControl else {
                    return .json(["ok": false, "error": "missing_analysis_or_control"])
                }
                let resolved = try await resolvePreflight(
                    analysisID: command.analysisID,
                    controlID: command.controlID,
                    action: BrowserActionKind.open.rawValue,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                )
                guard resolved.ok, let control = resolved.currentControl else {
                    return .json(resolved.response)
                }
                var object = try await openControl(
                    control,
                    controlRef: resolved.currentControlRef,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                )
                object["preflight"] = resolved.response
                return .json(object)
            case .doubleClick:
                let command = try request.decodeJSON(ClickCommand.self)
                if command.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: command.analysisID,
                        controlID: command.controlID,
                        action: BrowserActionKind.doubleClick.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        return .json(resolved.response)
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await doubleClick(
                        selector: target.selector,
                        x: target.x,
                        y: target.y,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous),
                        label: target.label,
                        role: target.role,
                        text: nil,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .doubleClick, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    object["summary"] = "Double-clicked \(browserControlDescription(control))."
                    return .json(object)
                }
                let json = try await doubleClick(
                    selector: command.normalizedSelector,
                    x: command.x,
                    y: command.y,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous),
                    label: command.normalizedLabel,
                    role: command.normalizedRole,
                    text: command.normalizedText,
                    placeholder: command.normalizedPlaceholder,
                    testID: command.normalizedTestID
                )
                return .rawJSON(json)
            case .type, .fill:
                let command = try request.decodeJSON(TypeCommand.self)
                if command.hasAnalysisControl {
                    let action = BrowserActionKind.fill.rawValue
                    let resolved = try await resolvePreflight(
                        analysisID: command.analysisID,
                        controlID: command.controlID,
                        action: action,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        return .json(resolved.response)
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await type(
                        selector: target.selector,
                        text: command.text,
                        clear: command.clear ?? true,
                        label: target.label,
                        role: target.role,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .fill, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    object["summary"] = "Filled \(browserControlDescription(control))."
                    return .json(object)
                }
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
            case .setValue:
                let command = try request.decodeJSON(TypeCommand.self)
                if command.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: command.analysisID,
                        controlID: command.controlID,
                        action: BrowserActionKind.setValue.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        return .json(resolved.response)
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await type(
                        selector: target.selector,
                        text: command.text,
                        clear: true,
                        label: target.label,
                        role: target.role,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .setValue, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    object["summary"] = "Set \(browserControlDescription(control))."
                    return .json(object)
                }
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
            case .replaceText:
                let command = try request.decodeJSON(ReplaceTextCommand.self)
                var selector = command.normalizedSelector
                var preflight: [String: Any]?
                var matchedControl: BrowserControl?
                if command.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: command.analysisID,
                        controlID: command.controlID,
                        action: BrowserActionKind.setValue.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        return .json(resolved.response)
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    selector = target.selector ?? selector
                    preflight = resolved.response
                    matchedControl = control
                }
                let before = command.hasAnalysisControl ? (try? await rawSnapshotObject()) : nil
                let json = try await replaceText(
                    find: command.find,
                    replacement: command.replacement,
                    selector: selector,
                    all: command.all ?? true
                )
                if let preflight {
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .setValue, control: matchedControl, before: before, after: after)
                    object["preflight"] = preflight
                    return .json(object)
                }
                return .rawJSON(json)
            case .findControl, .locator:
                let query = request.queryValue("query") ?? ""
                let role = request.queryValue("role")
                let limit = request.queryValue("limit").flatMap(Int.init) ?? 10
                return .json(try await findControl(query: query, role: role, limit: limit))
            case .clickControl:
                let command = try request.decodeJSON(ClickControlCommand.self)
                if command.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: command.analysisID,
                        controlID: command.controlID,
                        action: BrowserActionKind.click.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        return .json(resolved.response)
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await click(
                        selector: target.selector,
                        x: target.x,
                        y: target.y,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous),
                        label: target.label,
                        role: target.role,
                        text: nil,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .click, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    object["summary"] = "Clicked \(browserControlDescription(control))."
                    return .json(object)
                }
                guard let label = command.normalizedLabel else {
                    return .json(["ok": false, "error": "missing_label"])
                }
                return .json(try await clickControl(
                    label: label,
                    role: command.role,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
                ))
            case .verifyText:
                let command = try request.decodeJSON(VerifyTextCommand.self)
                return .json(try await verifyText(command.text, absent: command.absent ?? false))
            case .waitSaved:
                let command = try request.decodeJSON(WaitSavedCommand.self)
                return .json(try await waitSaved(
                    timeoutSeconds: command.timeoutSeconds ?? 8,
                    intervalMilliseconds: command.intervalMilliseconds ?? 500
                ))
            case .googleFindReplace:
                let command = try request.decodeJSON(GoogleFindReplaceCommand.self)
                return .json(try await googleFindReplace(
                    find: command.find,
                    replacement: command.replacement,
                    all: command.all ?? true
                ))
            case .googleDocsFind:
                let command = try request.decodeJSON(GoogleDocsFindCommand.self)
                return .json(try await googleDocsFind(
                    query: command.query,
                    closeFindBar: command.closeFindBar ?? true
                ))
            case .googleDocsInsert:
                let command = try request.decodeJSON(GoogleDocsInsertCommand.self)
                return .json(try await googleDocsInsert(
                    text: command.text,
                    verifyText: command.normalizedVerifyText,
                    waitSaved: command.waitSaved ?? true
                ))
            case .googleDocsReadVisiblePage:
                let command = try request.decodeJSON(PageReadCommand.self)
                return .json(try await googleDocsReadVisiblePage(
                    format: command.format,
                    limit: command.limit,
                    chunkSize: command.chunkSize
                ))
            case .googleDocsReadDocument:
                return .json(try await googleDocsReadDocument())
            case .googleDocsReplaceDocument:
                let command = try request.decodeJSON(GoogleDocsReplaceDocumentCommand.self)
                return .json(try await googleDocsReplaceDocument(
                    text: command.text,
                    verifyText: command.normalizedVerifyText
                ))
            case .googleDriveOpen:
                let command = try request.decodeJSON(GoogleDriveOpenCommand.self)
                return .json(try await googleDriveOpen(
                    name: command.normalizedName,
                    timeoutSeconds: command.timeoutSeconds ?? GoogleWorkspaceBrowserService.googleDriveOpenDefaultTimeoutSeconds,
                    intervalMilliseconds: command.intervalMilliseconds ?? 500
                ))
            case .act:
                let command = try request.decodeJSON(ActCommand.self)
                return .json(try await act(command))
            case .keypress:
                let command = try request.decodeJSON(KeypressCommand.self)
                let json = try await keypress(key: command.key, modifiers: command.modifiers ?? [])
                return .rawJSON(json)
            case .text:
                let command = try request.decodeJSON(TextCommand.self)
                let json = try await insertText(command.text)
                return .rawJSON(json)
            case .waitForText:
                let command = try request.decodeJSON(WaitTextCommand.self)
                let result = try await waitForText(
                    command.text,
                    timeoutSeconds: command.timeoutSeconds ?? 5,
                    intervalMilliseconds: command.intervalMilliseconds ?? 250
                )
                return .json(result)
            case .waitForSelector:
                let command = try request.decodeJSON(WaitSelectorCommand.self)
                let result = try await waitForSelector(
                    command.selector,
                    timeoutSeconds: command.timeoutSeconds ?? 5,
                    intervalMilliseconds: command.intervalMilliseconds ?? 250
                )
                return .json(result)
            case .batch:
                let command = try request.decodeJSON(BatchCommand.self)
                let result = try await runBatch(command)
                return .json(result)
            case .health, .actions:
                var response: [String: Any] = ["ok": false, "error": "not_found"]
                BrowserBridgeRecoveryHints.attach(to: &response, error: "not_found")
                return .json(response, statusCode: 404)
            }
        } catch {
            var response: [String: Any] = [
                "ok": false,
                "error": "browser_bridge_error",
                "message": error.localizedDescription
            ]
            BrowserBridgeRecoveryHints.attach(to: &response, error: "browser_bridge_error")
            return .json(response, statusCode: 400)
        }
    }

    private func browserEngineRequirementResponse(for request: BrowserBridgeRequest) -> [String: Any]? {
        BrowserAutomationEngineRequirementBridgePolicy.mismatchResponse(
            for: request,
            actual: engine.automationDescriptor,
            backend: engine.bridgeBackendLabel,
            controlledBrowserRunning: controlledBrowser.isRunning,
            controlledBrowserState: controlledBrowser.runState.rawValue,
            controlledBrowserStatus: controlledBrowser.statusMessage
        )
    }

    private func browserRunGuardResponse(for request: BrowserBridgeRequest) -> [String: Any]? {
        guard isRunGuardedBridgeRequest(request) else { return nil }
        let path = BrowserBridgeRecoveryHints.failedActionName(
            method: request.method,
            path: request.path
        )
        let decision = browserRunGuard.record(
            path: path,
            currentURL: currentURL,
            currentTitle: pageTitle,
            pageType: currentPageTypeLabel()
        )
        guard decision.shouldStop else { return nil }
        var response: [String: Any] = [
            "ok": false,
            "error": "browser_action_budget_exceeded",
            "message": "Browser control exceeded the per-task bridge call budget. Stop repeating browser actions and switch to a deterministic helper or ask the user for direction.",
            "runGuard": decision.diagnostics
        ]
        BrowserBridgeRecoveryHints.attach(
            to: &response,
            error: "browser_action_budget_exceeded",
            action: path
        )
        return response
    }

    private func browserRunGuardPostResponse(
        for request: BrowserBridgeRequest,
        result: [String: Any]?,
        before: BrowserFlightPageSnapshot
    ) -> [String: Any]? {
        guard isRunGuardedBridgeRequest(request),
              let result else { return nil }
        let path = BrowserBridgeRecoveryHints.failedActionName(
            method: request.method,
            path: request.path
        )
        let after = browserFlightPageSnapshot(result: result)
        let decision = browserRunGuard.recordOutcome(
            path: path,
            response: result,
            currentURL: after.url,
            currentTitle: after.title,
            pageType: after.pageType,
            urlChanged: before.url != after.url
        )
        guard decision.shouldStop else { return nil }
        var response: [String: Any] = [
            "ok": false,
            "error": "browser_action_budget_exceeded",
            "message": decision.warning ?? "Browser control repeated a failing action. Stop repeating browser actions and ask the user for direction.",
            "triggerError": result["error"] as? String ?? "",
            "triggerCommand": path,
            "runGuard": decision.diagnostics
        ]
        BrowserBridgeRecoveryHints.attach(
            to: &response,
            error: "browser_action_budget_exceeded",
            action: path
        )
        return response
    }

    private func isFlightRecordedBridgeRequest(_ request: BrowserBridgeRequest) -> Bool {
        ShelfBrowserBridgeCommandRouter.route(method: request.method, path: request.path)?.isFlightRecorded ?? true
    }

    private func browserFlightPageSnapshot(result: [String: Any]? = nil) -> BrowserFlightPageSnapshot {
        let url = result?["url"] as? String ?? currentURL
        return BrowserFlightPageSnapshot(
            url: url,
            title: result?["title"] as? String ?? pageTitle,
            pageType: currentPageTypeLabel(urlString: url)
        )
    }

    private func installBrowserDebugInstrumentationIfNeeded(policy: BrowserFailureDebugCapture.Policy) async {
        guard policy.isEnabled else { return }
        do {
            if isUsingControlledBrowser {
                try await controlledBrowser.installDebugInstrumentation()
            } else {
                if !isWebKitDebugInstrumentationScriptRegistered {
                    let userScript = WKUserScript(
                        source: BrowserAutomationScripts.debugInstrumentationScript,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: false
                    )
                    webView.configuration.userContentController.addUserScript(userScript)
                    isWebKitDebugInstrumentationScriptRegistered = true
                }
                _ = try await evaluateJavaScriptString(BrowserAutomationScripts.debugInstrumentationScript)
            }
        } catch {
            AppLogger.audit(
                .shelfBrowserAction,
                category: "Browser",
                taskID: boundTaskID,
                fields: [
                    "phase": "failed",
                    "action": "browser_debug_instrumentation",
                    "error": error.localizedDescription
                ],
                level: .debug
            )
        }
    }

    private func browserFailureDebugCapture(
        policy: BrowserFailureDebugCapture.Policy,
        request: BrowserBridgeRequest,
        response: BrowserBridgeResponse,
        result: [String: Any]?
    ) async -> [String: Any]? {
        guard BrowserFailureDebugCapture.shouldCapture(statusCode: response.statusCode, result: result) else {
            return nil
        }

        let page = browserFlightPageSnapshot(result: result)
        guard policy.isEnabled else {
            let capture = BrowserFailureDebugCapture.skippedCapture(
                policy: policy,
                request: request,
                statusCode: response.statusCode,
                result: result,
                page: page
            )
            browserDiagnostics.rememberDebugCapture(capture)
            return capture
        }

        var capture = BrowserFailureDebugCapture.captureEnvelope(
            policy: policy,
            request: request,
            statusCode: response.statusCode,
            result: result,
            page: page
        )
        var captureErrors: [String: String] = [:]

        do {
            let debugEventsJSON = isUsingControlledBrowser
                ? try await controlledBrowser.debugEvents()
                : try await evaluateJavaScriptString(BrowserAutomationScripts.debugReadScript)
            capture["debugEvents"] = BrowserFailureDebugCapture.compactDebugEvents(
                from: try Self.jsonObject(from: debugEventsJSON)
            )
        } catch {
            captureErrors["debugEvents"] = error.localizedDescription
        }

        do {
            if isUsingControlledBrowser {
                let base64 = try await controlledBrowser.screenshotJPEGBase64()
                if let screenshot = BrowserFailureDebugCapture.screenshotObject(
                    fromBase64JPEG: base64,
                    source: "controlled_chromium_viewport"
                ) {
                    capture["screenshot"] = screenshot
                } else {
                    captureErrors["screenshot"] = "controlled_browser_screenshot_decode_failed"
                }
            } else {
                let image = try await embeddedSnapshotImage()
                if let screenshot = BrowserFailureDebugCapture.screenshotObject(
                    from: image,
                    source: "embedded_webkit_viewport"
                ) {
                    capture["screenshot"] = screenshot
                } else {
                    captureErrors["screenshot"] = "embedded_webkit_screenshot_encode_failed"
                }
            }
        } catch {
            captureErrors["screenshot"] = error.localizedDescription
        }

        do {
            capture["snapshotTree"] = BrowserFailureDebugCapture.compactSnapshotTree(
                from: try await rawSnapshotObject()
            )
        } catch {
            captureErrors["snapshotTree"] = error.localizedDescription
        }

        if let accessibilitySnapshot = await rawAccessibilitySnapshotObject() {
            capture["accessibilityTree"] = BrowserFailureDebugCapture.compactAccessibilityTree(
                from: accessibilitySnapshot
            )
        } else if isUsingControlledBrowser {
            captureErrors["accessibilityTree"] = "accessibility_snapshot_unavailable"
        }

        if !captureErrors.isEmpty {
            capture["captureErrors"] = captureErrors
        }

        browserDiagnostics.rememberDebugCapture(capture)
        return capture
    }

    private func embeddedSnapshotImage() async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CocoaError(.coderInvalidValue))
                }
            }
        }
    }

    private static func responseObject(from response: BrowserBridgeResponse) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func recordBrowserFlightStep(
        request: BrowserBridgeRequest,
        response: BrowserBridgeResponse,
        result: [String: Any]?,
        debugCapture: [String: Any]?,
        before: BrowserFlightPageSnapshot,
        started: Date
    ) {
        let after = browserFlightPageSnapshot(result: result)
        let trace = result?["browserTrace"] as? [String: Any]
        let browserTraceID = trace?["id"] as? String ?? lastBrowserTrace?["id"] as? String
        let entry = browserDiagnostics.recordFlightStep(
            request: request,
            statusCode: response.statusCode,
            before: before,
            after: after,
            duration: Date().timeIntervalSince(started),
            result: result,
            lastBrowserTraceID: browserTraceID,
            debugCapture: debugCapture
        )
        AppLogger.appendBrowserFlightEntry(entry, taskID: boundTaskID)
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "phase": "completed",
                "action": "browser_flight_step",
                "flight_id": entry["id"] as? String ?? "",
                "sequence": String(entry["sequence"] as? Int ?? 0),
                "command": entry["command"] as? String ?? "",
                "status_code": String(response.statusCode),
                "ok": String(Self.boolValue(entry["ok"])),
                "url_changed": String(Self.boolValue(entry["urlChanged"])),
                "host_changed": String(Self.boolValue(entry["hostChanged"])),
                "error": entry["error"] as? String ?? ""
            ],
            level: response.statusCode >= 400 ? .warning : .debug
        )
    }

    private func isRunGuardedBridgeRequest(_ request: BrowserBridgeRequest) -> Bool {
        ShelfBrowserBridgeCommandRouter.route(method: request.method, path: request.path)?.isRunGuarded ?? true
    }

    private func currentPageTypeLabel(urlString: String? = nil) -> String {
        guard let url = URL(string: urlString ?? currentURL),
              let host = url.host?.lowercased() else {
            return "unknown"
        }
        if host == "drive.google.com" { return "googleDrive" }
        if host == "docs.google.com" {
            if url.path.hasPrefix("/document/") { return "googleDocsEditor" }
            if url.path.hasPrefix("/spreadsheets/") { return "googleSheetsEditor" }
            if url.path.hasPrefix("/presentation/") { return "googleSlidesEditor" }
            return "googleWorkspace"
        }
        return host
    }

    private func navigateForBridge(to url: URL, source: String) async -> [String: Any] {
        browserAnalysisCache.invalidate()
        logNavigation(phase: "requested", source: source, url: url)
        if isUsingControlledBrowser {
            await navigateControlledBrowser(to: url.absoluteString)
        } else if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        return await waitForNavigationSettle(targetURL: url.absoluteString, timeoutSeconds: 6)
    }

    private func waitForNavigationSettle(targetURL: String?, timeoutSeconds: TimeInterval) async -> [String: Any] {
        let started = Date()
        let timeout = max(0.2, min(timeoutSeconds, 15))
        var lastSignature = ""
        var stableSamples = 0
        var samples = 0

        while Date().timeIntervalSince(started) <= timeout {
            syncDisplayedStateForEngine()
            let signature = "\(currentURL)\u{1f}\(pageTitle)\u{1f}\(isLoading)"
            stableSamples = signature == lastSignature ? stableSamples + 1 : 0
            lastSignature = signature
            samples += 1

            let targetReached = targetURL.map { target in
                currentURL == target || BrowserFlightPageSnapshot.redactedURLString(currentURL) == BrowserFlightPageSnapshot.redactedURLString(target)
            } ?? true
            if targetReached && !isLoading && stableSamples >= 1 {
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        publishBridgeState()
        return [
            "ok": true,
            "url": currentURL,
            "title": pageTitle,
            "pageType": currentPageTypeLabel(),
            "targetURL": targetURL ?? "",
            "targetReached": targetURL.map { BrowserFlightPageSnapshot.redactedURLString(currentURL) == BrowserFlightPageSnapshot.redactedURLString($0) || currentURL == $0 } ?? true,
            "loading": isLoading,
            "stableSamples": stableSamples,
            "samples": samples,
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func rawSnapshotJSON() async throws -> String {
        if isUsingControlledBrowser {
            let json = try await controlledBrowser.snapshot()
            syncDisplayedStateForEngine()
            publishBridgeState()
            return json
        }
        return try await evaluateJavaScriptString(BrowserAutomationScripts.snapshotScript)
    }

    private func rawSnapshotObject() async throws -> [String: Any] {
        try Self.jsonObject(from: try await rawSnapshotJSON())
    }

    private func snapshot(mode: BrowserSnapshotMode = .full, query: String? = nil, limit: Int? = nil) async throws -> String {
        let started = Date()
        do {
            let json = try await rawSnapshotJSON()

            let result: String
            if mode == .full && (query ?? "").isEmpty && limit == nil {
                result = json
            } else {
                result = try BrowserPageSnapshotService.compactSnapshot(json: json, mode: mode, query: query, limit: limit)
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

    private func readPage(format: String?, limit: Int?, chunkSize: Int?) async throws -> [String: Any] {
        let started = Date()
        let normalizedFormat = BrowserPageReadService.normalizedFormat(format)
        let normalizedLimit = BrowserPageReadService.normalizedLimit(limit)
        let normalizedChunkSize = BrowserPageReadService.normalizedChunkSize(chunkSize)
        do {
            let response: [String: Any]
            if isUsingControlledBrowser {
                let json = try await controlledBrowser.readPage(
                    format: normalizedFormat,
                    limit: normalizedLimit,
                    chunkSize: normalizedChunkSize
                )
                syncDisplayedStateForEngine()
                publishBridgeState()
                response = try Self.jsonObject(from: json)
            } else {
                response = try await readEmbeddedPage(
                    format: normalizedFormat,
                    limit: normalizedLimit,
                    chunkSize: normalizedChunkSize
                )
            }
            updateLastPageReadState(from: response)
            logBrowserAction(
                phase: "completed",
                action: "readPage",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: [
                    "format": normalizedFormat,
                    "coverage": response["coverage"] as? String ?? "unknown",
                    "frame_count": String(Self.intValue(response["frameCount"]) ?? 0),
                    "truncated": String(Self.boolValue(response["truncated"]))
                ],
                resultJSON: #"{"ok":true}"#,
                started: started
            )
            return response
        } catch {
            logBrowserAction(
                phase: "failed",
                action: "readPage",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                fields: ["format": normalizedFormat],
                started: started,
                error: error
            )
            throw error
        }
    }

    private func readEmbeddedPage(format: String, limit: Int, chunkSize: Int) async throws -> [String: Any] {
        let requestID = UUID().uuidString
        let readResult = await embeddedPageReadFrames(requestID: requestID, limit: limit)
        let frames = readResult.frames
        let expandedFrames = embeddedFramesWithMissingChildren(frames)
        if expandedFrames.isEmpty {
            let snapshot = try await rawSnapshotObject()
            return BrowserPageReadService.responseFromSnapshot(
                snapshot,
                engine: ShelfBrowserEngine.embedded.rawValue,
                backend: ShelfBrowserEngine.embedded.bridgeBackendLabel,
                format: format,
                limit: limit,
                chunkSize: chunkSize,
                warnings: [
                    "Embedded frame reporter returned no frame reports; fell back to compact snapshot text."
                ] + readResult.warnings
            )
        }

        return BrowserPageReadService.response(
            url: currentURL,
            title: pageTitle,
            engine: ShelfBrowserEngine.embedded.rawValue,
            backend: ShelfBrowserEngine.embedded.bridgeBackendLabel,
            format: format,
            limit: limit,
            chunkSize: chunkSize,
            frames: expandedFrames,
            warnings: readResult.warnings + embeddedPageReadWarnings(for: expandedFrames)
        )
    }

    private func embeddedPageReadFrames(requestID: String, limit: Int) async -> EmbeddedPageReadResult {
        let pendingDispatchWarning = "Embedded page read dispatch did not complete before the read finished; reporter readiness is unknown."
        let reporterNotReadyWarning = "Embedded page read reporter was not ready; no frame reports were dispatched."
        return await withCheckedContinuation { continuation in
            let hardTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.finishEmbeddedPageReadRequest(requestID)
            }
            embeddedPageReadRequests[requestID] = EmbeddedPageReadRequest(
                frames: [],
                warnings: [pendingDispatchWarning],
                continuation: continuation,
                inactivityTask: nil,
                hardTimeoutTask: hardTimeoutTask
            )
            scheduleEmbeddedPageReadInactivityFinish(requestID, delayNanoseconds: 750_000_000)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let dispatchJSON = try await self.evaluateJavaScriptString(
                        BrowserAutomationScripts.embeddedPageReadDispatchScript(
                            requestID: requestID,
                            limit: limit
                        )
                    )
                    let dispatch = try? Self.jsonObject(from: dispatchJSON)
                    if !Self.boolValue(dispatch?["dispatched"]) {
                        self.removeEmbeddedPageReadWarning(requestID, pendingDispatchWarning)
                        self.appendEmbeddedPageReadWarning(requestID, reporterNotReadyWarning)
                    } else {
                        self.removeEmbeddedPageReadWarning(requestID, pendingDispatchWarning)
                    }
                } catch {
                    self.removeEmbeddedPageReadWarning(requestID, pendingDispatchWarning)
                    self.appendEmbeddedPageReadFrame([
                        "requestID": requestID,
                        "frameID": "main",
                        "url": self.currentURL,
                        "title": self.pageTitle,
                        "accessible": false,
                        "source": "embedded_webkit",
                        "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    private func appendEmbeddedPageReadWarning(_ requestID: String, _ warning: String) {
        guard var request = embeddedPageReadRequests[requestID] else { return }
        request.warnings.append(warning)
        embeddedPageReadRequests[requestID] = request
    }

    private func removeEmbeddedPageReadWarning(_ requestID: String, _ warning: String) {
        guard var request = embeddedPageReadRequests[requestID] else { return }
        request.warnings.removeAll { $0 == warning }
        embeddedPageReadRequests[requestID] = request
    }

    private func appendEmbeddedPageReadFrame(_ frame: [String: Any]) {
        guard let requestID = frame["requestID"] as? String,
              var request = embeddedPageReadRequests[requestID] else {
            return
        }
        var normalized = frame
        normalized.removeValue(forKey: "requestID")
        request.frames.append(normalized)
        embeddedPageReadRequests[requestID] = request
        scheduleEmbeddedPageReadInactivityFinish(requestID, delayNanoseconds: 250_000_000)
    }

    private func scheduleEmbeddedPageReadInactivityFinish(_ requestID: String, delayNanoseconds: UInt64) {
        guard var request = embeddedPageReadRequests[requestID] else { return }
        request.inactivityTask?.cancel()
        request.inactivityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            self?.finishEmbeddedPageReadRequest(requestID)
        }
        embeddedPageReadRequests[requestID] = request
    }

    private func finishEmbeddedPageReadRequest(_ requestID: String) {
        guard let request = embeddedPageReadRequests.removeValue(forKey: requestID) else { return }
        request.inactivityTask?.cancel()
        request.hardTimeoutTask?.cancel()
        request.continuation.resume(returning: EmbeddedPageReadResult(
            frames: request.frames,
            warnings: request.warnings
        ))
    }

    fileprivate func handleEmbeddedPageReadMessage(_ body: Any) {
        if let frame = body as? [String: Any] {
            appendEmbeddedPageReadFrame(frame)
        } else if let dictionary = body as? NSDictionary,
                  let frame = dictionary as? [String: Any] {
            appendEmbeddedPageReadFrame(frame)
        }
    }

    private func embeddedFramesWithMissingChildren(_ frames: [[String: Any]]) -> [[String: Any]] {
        var result = frames
        let reportedIDs = Set(frames.compactMap { $0["frameID"] as? String })
        for frame in frames {
            let parentID = frame["frameID"] as? String ?? "main"
            let children = frame["childFrames"] as? [[String: Any]] ?? []
            for child in children {
                let index = Self.intValue(child["index"]) ?? 0
                let childID = "\(parentID).\(index)"
                guard !reportedIDs.contains(childID) else { continue }
                let scriptsAllowed = child["scriptsAllowed"].map(Self.boolValue) ?? true
                result.append([
                    "frameID": childID,
                    "parentFrameID": parentID,
                    "url": child["url"] as? String ?? "",
                    "title": child["title"] as? String ?? "",
                    "accessible": false,
                    "source": "embedded_webkit",
                    "error": scriptsAllowed ? "frame_report_unavailable" : "frame_scripts_blocked"
                ])
            }
        }
        return result
    }

    private func embeddedPageReadWarnings(for frames: [[String: Any]]) -> [String] {
        var warnings: [String] = []
        if frames.contains(where: { !Self.boolValue($0["accessible"]) }) {
            warnings.append("One or more embedded frames did not return readable content.")
        }
        if isGoogleWorkspaceEditor {
            warnings.append("Google Workspace editors may render document content outside normal DOM text; use the Google Docs helpers for full-document reads or edits.")
        }
        return warnings
    }

    private func updateLastPageReadState(from response: [String: Any]) {
        lastPageReadCoverage = response["coverage"] as? String
        lastPageReadURL = response["url"] as? String
        lastPageReadWarnings = response["warnings"] as? [String] ?? []
    }

    private func invalidateLastPageReadState() {
        lastPageReadCoverage = nil
        lastPageReadURL = nil
        lastPageReadWarnings = []
    }

    private func analyze(
        query: String?,
        full: Bool,
        limit: Int?,
        debug: Bool,
        version: BrowserAnalysisVersion = .v1,
        rolloutMode: BrowserAnalysisV2RolloutMode = BrowserAnalysisV2RolloutMode.configured(),
        includeShadowV2: Bool = false
    ) async throws -> [String: Any] {
        let started = Date()
        let snapshot = try await rawSnapshotObject()
        let accessibilitySnapshot = version == .v2 ? await rawAccessibilitySnapshotObject() : nil
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: snapshot,
            backend: engine.bridgeBackendLabel,
            engine: engine.rawValue,
            enabledBrowserAdapters: Array(enabledBrowserAdapters),
            accessibilitySnapshotObject: accessibilitySnapshot
        )
        browserAnalysisCache.store(analysis)
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "phase": "completed",
                "action": "analyze",
                "analysis_id": analysis.analysisID,
                "fingerprint": analysis.fingerprint.value,
                "page_type": analysis.pageType,
                "control_count": String(analysis.controls.count),
                "analysis_version": version.rawValue,
                "accessibility_node_count": String(analysis.accessibilitySnapshot?.nodeCount ?? 0),
                "browser_adapter_ids": enabledBrowserAdapters.isEmpty ? "none" : Array(enabledBrowserAdapters).sorted().joined(separator: ","),
                "has_query": String(query?.isEmpty == false),
                "full": String(full),
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000))
            ],
            level: .info
        )
        var response = analysis.responseObject(query: query, full: full, limit: limit, debug: debug, version: version)
        response["browserAnalysisV2Mode"] = rolloutMode.rawValue

        if includeShadowV2, version == .v1 {
            let shadowAccessibilitySnapshot = await rawAccessibilitySnapshotObject()
            let shadowAnalysis = BrowserAnalysisBuilder.build(
                snapshot: snapshot,
                backend: engine.bridgeBackendLabel,
                engine: engine.rawValue,
                analysisID: "shadow_\(analysis.analysisID)",
                enabledBrowserAdapters: Array(enabledBrowserAdapters),
                accessibilitySnapshotObject: shadowAccessibilitySnapshot
            )
            response["shadowAnalysisV2"] = shadowAnalysis.shadowResponseObject(query: query, full: full, limit: limit, debug: debug)
        }

        return response
    }

    private func rawAccessibilitySnapshotObject() async -> [String: Any]? {
        guard isUsingControlledBrowser else { return nil }
        do {
            let json = try await controlledBrowser.accessibilitySnapshot()
            syncDisplayedStateForEngine()
            publishBridgeState()
            return try Self.jsonObject(from: json)
        } catch {
            AppLogger.audit(
                .shelfBrowserAction,
                category: "Browser",
                taskID: boundTaskID,
                fields: [
                    "phase": "failed",
                    "action": "accessibility_snapshot",
                    "error": error.localizedDescription
                ],
                level: .debug
            )
            return nil
        }
    }

    private func preflightResponse(_ command: BrowserPreflightCommand) async throws -> [String: Any] {
        let started = Date()
        let result = try await resolvePreflight(
            analysisID: command.analysisID,
            controlID: command.controlID,
            action: command.action,
            allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
        )
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "phase": "completed",
                "action": "preflight",
                "analysis_id_length": String(command.analysisID?.count ?? 0),
                "control_id_length": String(command.controlID?.count ?? 0),
                "preflight_action": command.action,
                "ok": String(Self.boolValue(result.response["ok"])),
                "error": result.response["error"] as? String ?? "",
                "risk": result.response["risk"] as? String ?? "",
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1000))
            ],
            level: Self.boolValue(result.response["ok"]) ? .info : .warning
        )
        return result.response
    }

    private func resolvePreflight(
        analysisID: String?,
        controlID: String?,
        action: String,
        allowDangerous: Bool
    ) async throws -> BrowserPreflightExecution {
        guard let analysisID = ShelfBrowserCommandNormalization.normalized(analysisID),
              let controlID = ShelfBrowserCommandNormalization.normalized(controlID) else {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: nil,
                currentControl: nil,
                currentControlRef: nil,
                resolutionStrategy: "missing",
                response: preflightFailure(
                    code: "missing_analysis_or_control",
                    analysisID: analysisID ?? "",
                    controlID: controlID ?? "",
                    action: action,
                    summary: "Preflight requires analysisID and controlID."
                )
            )
        }
        guard let actionKind = BrowserActionKind.normalized(action) else {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: nil,
                currentControl: nil,
                currentControlRef: nil,
                resolutionStrategy: "unsupported_action",
                response: preflightFailure(
                    code: "unsupported_action",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: action,
                    summary: "The requested browser action is not supported by controlID preflight."
                )
            )
        }
        guard let cachedAnalysis = browserAnalysisCache.lookup(analysisID),
              let cachedControl = cachedAnalysis.control(id: controlID) else {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: nil,
                currentControl: nil,
                currentControlRef: nil,
                resolutionStrategy: "missing_cache",
                response: preflightFailure(
                    code: "stale_analysis",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "The cached browser analysis is no longer available. Run astra-browser analyze again."
                )
            )
        }
        guard cachedAnalysis.isFresh() else {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: cachedControl,
                currentControl: nil,
                currentControlRef: nil,
                resolutionStrategy: "expired",
                response: preflightFailure(
                    code: "stale_analysis",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "The cached browser analysis expired. Run astra-browser analyze again.",
                    cachedControl: cachedControl
                )
            )
        }

        let liveSnapshot = try await rawSnapshotObject()
        let liveAccessibilitySnapshot = cachedAnalysis.accessibilitySnapshot == nil ? nil : await rawAccessibilitySnapshotObject()
        let liveAnalysis = BrowserAnalysisBuilder.build(
            snapshot: liveSnapshot,
            backend: engine.bridgeBackendLabel,
            engine: engine.rawValue,
            analysisID: "live_\(cachedAnalysis.analysisID)",
            enabledBrowserAdapters: Array(enabledBrowserAdapters),
            accessibilitySnapshotObject: liveAccessibilitySnapshot
        )
        guard BrowserAnalysisBuilder.fingerprintsCompatible(cachedAnalysis.fingerprint, liveAnalysis.fingerprint) else {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: cachedControl,
                currentControl: nil,
                currentControlRef: nil,
                resolutionStrategy: "stale_fingerprint",
                response: preflightFailure(
                    code: "stale_analysis",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "The page structure changed since analysis. Run astra-browser analyze again.",
                    cachedControl: cachedControl,
                    checks: [
                        ["name": "analysisFresh", "status": "passed"],
                        ["name": "fingerprintCompatible", "status": "failed", "expected": cachedAnalysis.fingerprint.value, "actual": liveAnalysis.fingerprint.value]
                    ]
                )
            )
        }

        guard let controlMatch = BrowserControlResolver.matchingLiveControl(
            cachedControl: cachedControl,
            cachedAnalysis: cachedAnalysis,
            liveAnalysis: liveAnalysis
        ) else {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: cachedControl,
                currentControl: nil,
                currentControlRef: nil,
                resolutionStrategy: "unresolved",
                response: preflightFailure(
                    code: "control_changed",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "The analyzed control is no longer present on the live page.",
                    cachedControl: cachedControl
                )
            )
        }
        let currentControl = controlMatch.control

        guard currentControl.supports(actionKind) else {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: cachedControl,
                currentControl: currentControl,
                currentControlRef: controlMatch.controlRef,
                resolutionStrategy: controlMatch.strategy,
                response: preflightFailure(
                    code: "unsupported_action",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "The live control does not support \(actionKind.rawValue).",
                    cachedControl: cachedControl,
                    currentControl: currentControl
                )
            )
        }

        if [.fill, .setValue, .insertText].contains(actionKind), currentControl.risk == .credentialInput {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: cachedControl,
                currentControl: currentControl,
                currentControlRef: controlMatch.controlRef,
                resolutionStrategy: controlMatch.strategy,
                response: preflightFailure(
                    code: "credential_input_blocked",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "ASTRA will not type passwords or secrets. The user should enter this directly in the browser.",
                    cachedControl: cachedControl,
                    currentControl: currentControl
                )
            )
        }

        if [.fill, .setValue, .insertText].contains(actionKind), currentControl.risk == .mfaInput {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: cachedControl,
                currentControl: currentControl,
                currentControlRef: controlMatch.controlRef,
                resolutionStrategy: controlMatch.strategy,
                response: preflightFailure(
                    code: "mfa_input_blocked",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "ASTRA will not type MFA or verification codes. The user should enter this directly in the browser.",
                    cachedControl: cachedControl,
                    currentControl: currentControl
                )
            )
        }

        if currentControl.requiresUserConfirmation && !allowDangerous {
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: cachedControl,
                currentControl: currentControl,
                currentControlRef: controlMatch.controlRef,
                resolutionStrategy: controlMatch.strategy,
                response: preflightFailure(
                    code: "dangerous_confirmation_required",
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "This \(currentControl.risk.rawValue) action requires explicit user confirmation before execution.",
                    cachedControl: cachedControl,
                    currentControl: currentControl
                )
            )
        }

        let targetJSON = try await targetInfo(for: currentControl, controlRef: controlMatch.controlRef, allowDangerous: true)
        let target = try Self.jsonObject(from: targetJSON)
        guard Self.boolValue(target["ok"]) else {
            let code = target["error"] as? String ?? "target_not_actionable"
            return BrowserPreflightExecution(
                ok: false,
                cachedControl: cachedControl,
                currentControl: currentControl,
                currentControlRef: controlMatch.controlRef,
                resolutionStrategy: controlMatch.strategy,
                response: preflightFailure(
                    code: code,
                    analysisID: analysisID,
                    controlID: controlID,
                    action: actionKind.rawValue,
                    summary: "The live target failed actionability preflight: \(code).",
                    cachedControl: cachedControl,
                    currentControl: currentControl,
                    checks: [
                        ["name": "analysisFresh", "status": "passed"],
                        ["name": "fingerprintCompatible", "status": "passed"],
                        ["name": "targetActionable", "status": "failed", "error": code]
                    ]
                )
            )
        }

        let response: [String: Any] = [
            "ok": true,
            "analysisID": analysisID,
            "controlID": controlID,
            "action": actionKind.rawValue,
            "matched": true,
            "controlRef": controlMatch.controlRef.jsonObject(debug: false),
            "resolutionStrategy": controlMatch.strategy,
            "usedSelectorFallback": controlMatch.usedSelectorFallback,
            "risk": currentControl.risk.rawValue,
            "requiresUserConfirmation": currentControl.requiresUserConfirmation,
            "matchedControl": currentControl.jsonObject(debug: false),
            "checks": [
                ["name": "analysisFresh", "status": "passed"],
                ["name": "fingerprintCompatible", "status": "passed"],
                ["name": "controlResolved", "status": "passed"],
                ["name": "controlRefResolved", "status": "passed"],
                ["name": "frameContext", "status": currentControl.framePath.isEmpty ? "not_applicable" : "tracked", "framePath": currentControl.framePath],
                ["name": "actionSupported", "status": "passed"],
                ["name": "visible", "status": "passed"],
                ["name": "enabled", "status": "passed"],
                ["name": "unobscured", "status": "passed"]
            ],
            "summary": "Ready to \(actionKind.rawValue) \(browserControlDescription(currentControl))."
        ]
        return BrowserPreflightExecution(
            ok: true,
            cachedControl: cachedControl,
            currentControl: currentControl,
            currentControlRef: controlMatch.controlRef,
            resolutionStrategy: controlMatch.strategy,
            response: response
        )
    }

    private func targetInfo(for control: BrowserControl, controlRef: BrowserControlRef?, allowDangerous: Bool) async throws -> String {
        let target = actionTarget(for: control, controlRef: controlRef)
        if isUsingControlledBrowser {
            return try await controlledBrowser.targetInfo(
                selector: target.selector,
                x: target.x,
                y: target.y,
                allowDangerous: allowDangerous,
                label: target.label,
                role: target.role,
                text: nil,
                placeholder: target.placeholder,
                testID: target.testID
            )
        }
        return try await evaluateJavaScriptString(BrowserAutomationScripts.targetInfoScript(
            selector: target.selector,
            x: target.x,
            y: target.y,
            allowDangerous: allowDangerous,
            label: target.label,
            role: target.role,
            text: nil,
            placeholder: target.placeholder,
            testID: target.testID
        ))
    }

    private func actionTarget(for control: BrowserControl, controlRef: BrowserControlRef?) -> BrowserControlActionTarget {
        let source = controlRef?.source ?? .dom
        let semanticName = BrowserControlTargetingPolicy.semanticName(for: control, source: source)
        let hasSemanticAnchor = !semanticName.isEmpty || !control.role.isEmpty || !control.placeholder.isEmpty || !control.testID.isEmpty
        let shouldUseSelector = source == .dom && !control.selector.isEmpty
        let shouldUseCoordinates = !shouldUseSelector && !hasSemanticAnchor
        let bounds = control.bounds
        return BrowserControlActionTarget(
            selector: shouldUseSelector ? control.selector : nil,
            x: shouldUseCoordinates ? Self.doubleValue(bounds["centerX"]) : nil,
            y: shouldUseCoordinates ? Self.doubleValue(bounds["centerY"]) : nil,
            label: shouldUseSelector ? nil : (semanticName.isEmpty ? nil : semanticName),
            role: shouldUseSelector ? nil : (control.role.isEmpty ? nil : control.role),
            placeholder: shouldUseSelector ? nil : (control.placeholder.isEmpty ? nil : control.placeholder),
            testID: shouldUseSelector ? nil : (control.testID.isEmpty ? nil : control.testID),
            source: source.rawValue,
            usedSelector: shouldUseSelector
        )
    }

    private func preflightFailure(
        code: String,
        analysisID: String,
        controlID: String,
        action: String,
        summary: String,
        cachedControl: BrowserControl? = nil,
        currentControl: BrowserControl? = nil,
        checks: [[String: Any]] = []
    ) -> [String: Any] {
        var response: [String: Any] = [
            "ok": false,
            "error": code,
            "analysisID": analysisID,
            "controlID": controlID,
            "action": action,
            "summary": summary,
            "checks": checks
        ]
        if let cachedControl {
            response["cachedControl"] = cachedControl.jsonObject(debug: false)
            response["cachedControlRef"] = BrowserControlRef(
                control: cachedControl,
                accessibilityNode: nil
            ).jsonObject(debug: false)
        }
        if let currentControl {
            response["matchedControl"] = currentControl.jsonObject(debug: false)
            response["controlRef"] = BrowserControlRef(
                control: currentControl,
                accessibilityNode: nil
            ).jsonObject(debug: false)
        }
        let recoveryControl = currentControl ?? cachedControl
        let recoveryLabel = Self.browserRecoveryControlLabel(recoveryControl)
        BrowserBridgeRecoveryHints.attach(
            to: &response,
            error: code,
            action: action,
            analysisID: analysisID,
            controlID: controlID,
            controlLabel: recoveryLabel,
            validActions: recoveryControl?.validActions.map(\.rawValue) ?? []
        )
        return response
    }

    private static func browserRecoveryControlLabel(_ control: BrowserControl?) -> String? {
        guard let control else { return nil }
        let label = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return label
        }
        let name = control.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        return nil
    }

    private func browserControlDescription(_ control: BrowserControl) -> String {
        let label = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return "\(control.role.isEmpty ? control.tag : control.role) \"\(label)\""
        }
        return control.role.isEmpty ? control.tag : control.role
    }

    private func snapshotAfterActionDelay() async -> [String: Any]? {
        try? await Task.sleep(nanoseconds: 350_000_000)
        return try? await rawSnapshotObject()
    }

    private func addOutcomeFields(
        to object: inout [String: Any],
        action: BrowserActionKind,
        control: BrowserControl?,
        before: [String: Any]?,
        after: [String: Any]?
    ) {
        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: action,
            control: control,
            result: object,
            before: before,
            after: after,
            enabledBrowserAdapters: Array(enabledBrowserAdapters)
        )
        object["outcome"] = outcome
        let trace = browserTraceRecord(
            action: action,
            control: control,
            result: object,
            outcome: outcome,
            before: before,
            after: after
        )
        object["browserTrace"] = trace
        lastBrowserTrace = trace
        for key in [
            "executed",
            "expectedOutcome",
            "observedOutcome",
            "goalSatisfied",
            "outcomeVerified",
            "outcomeReason",
            "suggestedNextActions"
        ] {
            if let value = outcome[key] {
                object[key] = value
            }
        }
    }

    private func browserTraceRecord(
        action: BrowserActionKind,
        control: BrowserControl?,
        result: [String: Any],
        outcome: [String: Any],
        before: [String: Any]?,
        after: [String: Any]?
    ) -> [String: Any] {
        let beforeFingerprint = before.map(Self.pageFingerprint(from:)) ?? ""
        let afterFingerprint = after.map(Self.pageFingerprint(from:)) ?? ""
        var trace: [String: Any] = [
            "id": "btrace_\(UUID().uuidString.prefix(8).lowercased())",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "action": action.rawValue,
            "engine": engine.rawValue,
            "backend": engine.bridgeBackendLabel,
            "executed": Self.boolValue(outcome["executed"]),
            "expectedOutcome": outcome["expectedOutcome"] as? String ?? "",
            "observedOutcome": outcome["observedOutcome"] as? String ?? "",
            "goalSatisfied": Self.boolValue(outcome["goalSatisfied"]),
            "outcomeVerified": Self.boolValue(outcome["outcomeVerified"]),
            "beforeURL": before?["url"] as? String ?? "",
            "afterURL": after?["url"] as? String ?? "",
            "beforeTitle": before?["title"] as? String ?? "",
            "afterTitle": after?["title"] as? String ?? "",
            "beforeFingerprint": beforeFingerprint,
            "afterFingerprint": afterFingerprint,
            "resultOK": Self.boolValue(result["ok"]),
            "resultError": result["error"] as? String ?? ""
        ]
        if let settlement = BrowserAutomationTraceEvidence.settlementEvidence(from: result) {
            trace["cdpSettlement"] = settlement
            trace["cdpSettled"] = settlement["settled"] as? Bool ?? false
            trace["cdpSettlementErrors"] = settlement["errors"] as? [String] ?? []
        }
        if let control {
            trace["controlID"] = control.controlID
            trace["controlRef"] = BrowserControlRef(control: control, accessibilityNode: nil).jsonObject(debug: false)
            trace["risk"] = control.risk.rawValue
            trace["requiresUserConfirmation"] = control.requiresUserConfirmation
        }
        AppLogger.audit(
            .shelfBrowserAction,
            category: "Browser",
            taskID: boundTaskID,
            fields: [
                "phase": "completed",
                "action": "browser_trace",
                "browser_action": action.rawValue,
                "trace_id": trace["id"] as? String ?? "",
                "goal_satisfied": String(Self.boolValue(outcome["goalSatisfied"])),
                "observed_outcome": outcome["observedOutcome"] as? String ?? "",
                "control_id_length": String((control?.controlID ?? "").count)
            ],
            level: Self.boolValue(outcome["goalSatisfied"]) ? .info : .debug
        )
        return trace
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
            let actionability = try await waitForActionableTarget(
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
            let beforeSettle = try? await rawSnapshotObject()

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

            var object = try Self.jsonObject(from: try annotateBrowserLoopHint(json: json, action: action, target: BrowserControlActionService.targetIdentifier(
                selector: selector,
                x: x,
                y: y,
                label: label,
                role: role,
                text: text,
                placeholder: placeholder,
                testID: testID
            )))
            object["actionability"] = actionability
            if Self.boolValue(object["ok"]) {
                object["postActionWait"] = await waitForPostActionSettle(before: beforeSettle, action: action)
            }
            let annotated = try Self.jsonString(object)
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

    private func doubleClick(
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
        let action = "doubleClick"
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
            let actionability = try await waitForActionableTarget(
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
            let beforeSettle = try? await rawSnapshotObject()

            let json: String
            if isUsingControlledBrowser {
                json = try await controlledBrowser.doubleClick(
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
                json = try await evaluateJavaScriptString(BrowserAutomationScripts.doubleClickScript(
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

            var object = try Self.jsonObject(from: try annotateBrowserLoopHint(json: json, action: action, target: BrowserControlActionService.targetIdentifier(
                selector: selector,
                x: x,
                y: y,
                label: label,
                role: role,
                text: text,
                placeholder: placeholder,
                testID: testID
            )))
            object["actionability"] = actionability
            if Self.boolValue(object["ok"]) {
                object["postActionWait"] = await waitForPostActionSettle(before: beforeSettle, action: action)
            }
            let annotated = try Self.jsonString(object)
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

    private func openControl(
        _ control: BrowserControl,
        controlRef: BrowserControlRef?,
        allowDangerous: Bool,
        timeoutSeconds: Double = 12,
        intervalMilliseconds: Int = 500
    ) async throws -> [String: Any] {
        let before = try? await rawSnapshotObject()
        let pageURL = (before?["url"] as? String) ?? currentURL
        var object: [String: Any]

        if isGoogleDriveAdapterEnabled, GoogleDriveBrowserAdapter.isFileControl(
            pageURL: pageURL,
            selector: control.selector,
            label: control.label,
            name: control.name,
            role: control.role,
            tag: control.tag,
            href: control.href
        ) {
            let nameHintSource = control.label.isEmpty ? control.name : control.label
            let nameHint = GoogleDriveBrowserAdapter.nameHint(from: nameHintSource)
            object = try await googleDriveOpen(
                name: nameHint.isEmpty ? nameHintSource : nameHint,
                timeoutSeconds: timeoutSeconds,
                intervalMilliseconds: intervalMilliseconds
            )
        } else if !control.href.isEmpty, let url = ShelfBrowserAddress.normalizedURL(from: control.href) {
            load(url, source: "bridge_open_control")
            object = [
                "ok": true,
                "opened": true,
                "url": url.absoluteString
            ]
        } else {
            let target = actionTarget(for: control, controlRef: controlRef)
            let json = try await doubleClick(
                selector: target.selector,
                x: target.x,
                y: target.y,
                allowDangerous: allowDangerous,
                label: target.label,
                role: target.role,
                text: nil,
                placeholder: target.placeholder,
                testID: target.testID
            )
            object = try Self.jsonObject(from: json)
        }

        let after = await snapshotAfterActionDelay()
        addOutcomeFields(to: &object, action: .open, control: control, before: before, after: after)
        object["matchedControl"] = control.jsonObject(debug: false)
        object["summary"] = "Opened \(browserControlDescription(control))."
        return object
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
            let actionability = try await waitForActionableTarget(
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
            if let result = try blockedTextEntryResult(
                action: action,
                targetInfo: actionability,
                attachmentKey: "actionability",
                logContext: BrowserTextEntryLogContext(
                    started: started,
                    action: action,
                    selector: selector,
                    label: label,
                    role: role,
                    placeholder: placeholder,
                    testID: testID,
                    fields: ["clear": String(clear), "text_length": String(text.count)]
                )
            ) {
                return result
            }
            let beforeSettle = try? await rawSnapshotObject()

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

            var object = try Self.jsonObject(from: try annotateBrowserLoopHint(json: json, action: action, target: BrowserControlActionService.targetIdentifier(
                selector: selector,
                x: nil,
                y: nil,
                label: label,
                role: role,
                text: nil,
                placeholder: placeholder,
                testID: testID
            )))
            object["actionability"] = actionability
            if Self.boolValue(object["ok"]) {
                object["postActionWait"] = await waitForPostActionSettle(before: beforeSettle, action: action)
            }
            let annotated = try Self.jsonString(object)
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

    func waitForActionableTarget(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> [String: Any] {
        let started = Date()
        let timeout: TimeInterval = 3
        var lastObject: [String: Any] = [:]
        var lastBoundsSignature = ""
        var stableBoundsSamples = 0
        var attempts = 0

        while Date().timeIntervalSince(started) < timeout {
            let object = try await targetInfoObject(
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
            attempts += 1
            lastObject = object
            if Self.boolValue(object["ok"]) {
                let boundsSignature = BrowserControlActionService.boundsSignature(object["bounds"])
                if !boundsSignature.isEmpty && boundsSignature == lastBoundsSignature {
                    stableBoundsSamples += 1
                } else {
                    stableBoundsSamples = 0
                }
                lastBoundsSignature = boundsSignature
                if boundsSignature.isEmpty || stableBoundsSamples >= 1 {
                    return BrowserControlActionService.actionabilityWaitSummary(
                        object: object,
                        attempts: attempts,
                        stableBoundsSamples: stableBoundsSamples,
                        timedOut: false,
                        started: started
                    )
                }
            }
            let lastError = object["error"] as? String ?? ""
            if !BrowserControlActionService.isRetryableActionabilityError(lastError) {
                return BrowserControlActionService.actionabilityWaitSummary(
                    object: object,
                    attempts: attempts,
                    stableBoundsSamples: stableBoundsSamples,
                    timedOut: false,
                    started: started
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let lastError = lastObject["error"] as? String ?? ""
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
        return BrowserControlActionService.actionabilityWaitSummary(
            object: lastObject,
            attempts: attempts,
            stableBoundsSamples: stableBoundsSamples,
            timedOut: true,
            started: started
        )
    }

    private func targetInfoObject(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> [String: Any] {
        let json: String
        if isUsingControlledBrowser {
            json = try await controlledBrowser.targetInfo(
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
            json = try await evaluateJavaScriptString(BrowserAutomationScripts.targetInfoScript(
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
        return try Self.jsonObject(from: json)
    }

    private func waitForPostActionSettle(before: [String: Any]?, action: String) async -> [String: Any] {
        let started = Date()
        let timeout: TimeInterval = 1.4
        let beforeURL = before?["url"] as? String ?? currentURL
        let beforeTitle = before?["title"] as? String ?? pageTitle
        let beforeFingerprint = before.map(Self.pageFingerprint(from:)) ?? ""
        var lastFingerprint = ""
        var stableSamples = 0
        var samples = 0
        var lastSnapshot: [String: Any]?

        while Date().timeIntervalSince(started) <= timeout {
            try? await Task.sleep(nanoseconds: 175_000_000)
            guard let snapshot = try? await rawSnapshotObject() else { continue }
            lastSnapshot = snapshot
            samples += 1
            let fingerprint = Self.pageFingerprint(from: snapshot)
            stableSamples = fingerprint == lastFingerprint ? stableSamples + 1 : 0
            lastFingerprint = fingerprint

            let urlChanged = (snapshot["url"] as? String ?? "") != beforeURL
            let titleChanged = (snapshot["title"] as? String ?? "") != beforeTitle
            let pageChanged = !beforeFingerprint.isEmpty && fingerprint != beforeFingerprint
            if (urlChanged || titleChanged || pageChanged) && stableSamples >= 1 {
                break
            }
            if !beforeFingerprint.isEmpty && stableSamples >= 2 {
                break
            }
        }

        let afterURL = lastSnapshot?["url"] as? String ?? currentURL
        let afterTitle = lastSnapshot?["title"] as? String ?? pageTitle
        let afterFingerprint = lastSnapshot.map(Self.pageFingerprint(from:)) ?? ""
        return [
            "action": action,
            "elapsedMs": Int(Date().timeIntervalSince(started) * 1_000),
            "samples": samples,
            "stableSamples": stableSamples,
            "urlChanged": afterURL != beforeURL,
            "titleChanged": afterTitle != beforeTitle,
            "pageFingerprintChanged": !beforeFingerprint.isEmpty && !afterFingerprint.isEmpty && beforeFingerprint != afterFingerprint,
            "url": BrowserFlightPageSnapshot.redactedURLString(afterURL),
            "title": String(afterTitle.prefix(160)),
            "pageType": currentPageTypeLabel(urlString: afterURL)
        ]
    }

    func logBrowserAction(
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
        mode: BrowserSnapshotMode,
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
        let resolvedSelector = ShelfBrowserCommandNormalization.normalized(selector)
        if let resolvedSelector, let blocked = try await blockedReplacementTextEntryResult(find: find, selector: resolvedSelector, all: all) {
            return try Self.jsonString(blocked)
        }
        if isUsingControlledBrowser {
            let json = try await controlledBrowser.replaceText(find: find, replacement: replacement, selector: resolvedSelector, all: all)
            syncDisplayedStateForEngine()
            publishBridgeState()
            return try annotateBrowserLoopHint(json: json, action: "replaceText", target: resolvedSelector ?? find)
        }
        let json = try await evaluateJavaScriptString(BrowserAutomationScripts.replaceTextScript(
            find: find,
            replacement: replacement,
            selector: resolvedSelector,
            all: all
        ))
        return try annotateBrowserLoopHint(json: json, action: "replaceText", target: resolvedSelector ?? find)
    }

    private func keypress(key: String, modifiers: [String]) async throws -> String {
        let started = Date()
        let safetyDecision = BrowserKeypressSafety.evaluate(
            key: key,
            modifiers: modifiers,
            currentURL: currentURL,
            isGoogleWorkspaceEditor: isGoogleWorkspaceEditor,
            state: &keypressSafetyState
        )
        guard safetyDecision.allowed else {
            let result = try Self.jsonString([
                "ok": false,
                "error": safetyDecision.error ?? "dangerous_keypress_sequence",
                "hint": safetyDecision.hint ?? "",
                "key": key,
                "modifiers": modifiers,
                "url": currentURL,
                "title": pageTitle
            ])
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
                    "blocked": "true",
                    "key_length": String(key.count),
                    "modifier_count": String(modifiers.count)
                ],
                resultJSON: result,
                started: started
            )
            return result
        }
        if let result = try await blockedFocusedTextEntryResult(
            action: "keypress",
            logContext: BrowserTextEntryLogContext(
                started: started,
                action: "keypress",
                fields: [
                    "key_length": String(key.count),
                    "modifier_count": String(modifiers.count)
                ]
            )
        ) {
            return result
        }
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
            if let result = try await blockedFocusedTextEntryResult(
                action: BrowserActionKind.insertText.rawValue,
                logContext: BrowserTextEntryLogContext(
                    started: started,
                    action: "insertText",
                    fields: ["text_length": String(text.count)]
                )
            ) {
                return result
            }
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

    private func browserAdapterDisabledResponse(adapterID: String, action: String) -> [String: Any] {
        [
            "ok": false,
            "error": "browser_adapter_disabled",
            "adapterID": adapterID,
            "action": action,
            "enabledBrowserAdapters": Array(enabledBrowserAdapters).sorted(),
            "capabilities": bridgeCapabilities,
            "summary": "Enable the matching browser capability for this workspace before using this site-specific action."
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

        guard canUseGoogleDriveOpen else {
            let result = browserAdapterDisabledResponse(
                adapterID: BrowserSiteAdapterID.googleDrive,
                action: "googleDriveOpen"
            )
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

        if let promotionError = await ensureControlledBrowserForGoogleWorkspaceAction(
            action: "googleDriveOpen",
            started: started
        ) {
            logBrowserAction(
                phase: "completed",
                action: "googleDriveOpen",
                selector: nil,
                label: nil,
                role: nil,
                text: nil,
                placeholder: nil,
                testID: nil,
                resultJSON: try Self.jsonString(promotionError),
                started: started
            )
            return promotionError
        }

        do {
            if GoogleWorkspaceBrowserService.isOpenedDriveTarget(urlString: currentURL, title: pageTitle, name: trimmedName, startURL: nil) {
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
            let searchURL = GoogleWorkspaceBrowserService.googleDriveSearchURL(for: trimmedName)
            let searchNavigation = await navigateForBridge(to: searchURL, source: "googleDriveOpenSearch")
            let searchStarted = Date()
            var result = try await waitForGoogleDriveOpen(
                name: trimmedName,
                startURL: startURL,
                started: started,
                waitStarted: searchStarted,
                timeoutSeconds: timeoutSeconds,
                intervalMilliseconds: intervalMilliseconds
            )
            result["searchMethod"] = "direct_url"
            result["searchNavigation"] = [
                "ok": Self.boolValue(searchNavigation["targetReached"]),
                "url": searchNavigation["url"] as? String ?? "",
                "title": searchNavigation["title"] as? String ?? ""
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
                fields: [
                    "opened": String(Self.boolValue(result["opened"])),
                    "search_method": result["searchMethod"] as? String ?? "unknown",
                    "candidate_count": String(Self.intValue(result["candidateCount"]) ?? 0),
                    "last_open_method": (result["lastOpenAttempt"] as? [String: Any])?["method"] as? String ?? "",
                    "last_open_error": (result["lastOpenAttempt"] as? [String: Any])?["error"] as? String ?? ""
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
        waitStarted: Date,
        timeoutSeconds: Double,
        intervalMilliseconds: Int
    ) async throws -> [String: Any] {
        let timeout = max(0.5, min(timeoutSeconds, GoogleWorkspaceBrowserService.googleDriveOpenMaximumTimeoutSeconds))
        let interval = UInt64(max(100, min(intervalMilliseconds, 2_000))) * 1_000_000
        var lastURL = currentURL
        var lastTitle = pageTitle
        var lastCandidateCount = 0
        var lastOpenAttempt: [String: Any]?
        var attemptedCandidateKeys = Set<String>()
        var retriedOpenKey = false
        var retriedDriveOpenShortcut = false

        while Date().timeIntervalSince(waitStarted) <= timeout {
            try await Task.sleep(nanoseconds: interval)

            let object = try await rawSnapshotObject()
            lastURL = object["url"] as? String ?? currentURL
            lastTitle = object["title"] as? String ?? pageTitle

            if GoogleWorkspaceBrowserService.isOpenedDriveTarget(urlString: lastURL, title: lastTitle, name: name, startURL: startURL) {
                return [
                    "ok": true,
                    "opened": true,
                    "name": name,
                    "url": lastURL,
                    "title": lastTitle,
                    "matchedName": GoogleWorkspaceBrowserService.googleDriveOpenedTitleMatches(lastTitle, name),
                    "elapsedSeconds": Date().timeIntervalSince(started)
                ]
            }
            if GoogleWorkspaceBrowserService.isGoogleWorkspaceEditorURL(lastURL),
               !GoogleWorkspaceBrowserService.isPendingGoogleWorkspaceTitle(lastTitle),
               !GoogleWorkspaceBrowserService.googleDriveOpenedTitleMatches(lastTitle, name) {
                return [
                    "ok": false,
                    "opened": false,
                    "error": "drive_file_name_mismatch",
                    "safeEditUnavailable": true,
                    "name": name,
                    "url": lastURL,
                    "title": lastTitle,
                    "matchedName": false,
                    "candidateCount": lastCandidateCount,
                    "lastOpenAttempt": lastOpenAttempt ?? [:],
                    "elapsedSeconds": Date().timeIntervalSince(started),
                    "hint": "Google Drive opened a different Google editor than the requested file. Stop before reading or editing the wrong file."
                ]
            }

            let controls = object["controls"] as? [[String: Any]] ?? []
            let candidates = GoogleWorkspaceBrowserService.googleDriveOpenCandidates(
                controls: controls,
                name: name,
                pageURL: lastURL
            )
            lastCandidateCount = candidates.count
            if let candidate = candidates.first {
                let candidateKey = GoogleWorkspaceBrowserService.googleDriveOpenCandidateKey(candidate)
                if !attemptedCandidateKeys.contains(candidateKey) {
                    attemptedCandidateKeys.insert(candidateKey)
                    lastOpenAttempt = try await openGoogleDriveCandidate(candidate)
                    let wait = await waitForNavigationSettle(targetURL: nil, timeoutSeconds: 3)
                    lastURL = wait["url"] as? String ?? currentURL
                    lastTitle = wait["title"] as? String ?? pageTitle

                    if GoogleWorkspaceBrowserService.isOpenedDriveTarget(urlString: lastURL, title: lastTitle, name: name, startURL: startURL) {
                        return [
                            "ok": true,
                            "opened": true,
                            "name": name,
                            "url": lastURL,
                            "title": lastTitle,
                            "matchedName": true,
                            "candidateCount": lastCandidateCount,
                            "openMethod": lastOpenAttempt?["method"] as? String ?? "drive_result",
                            "elapsedSeconds": Date().timeIntervalSince(started)
                        ]
                    }
                    if GoogleWorkspaceBrowserService.isGoogleWorkspaceEditorURL(lastURL),
                       !GoogleWorkspaceBrowserService.isPendingGoogleWorkspaceTitle(lastTitle),
                       !GoogleWorkspaceBrowserService.googleDriveOpenedTitleMatches(lastTitle, name) {
                        return [
                            "ok": false,
                            "opened": false,
                            "error": "drive_file_name_mismatch",
                            "safeEditUnavailable": true,
                            "name": name,
                            "url": lastURL,
                            "title": lastTitle,
                            "matchedName": false,
                            "candidateCount": lastCandidateCount,
                            "openMethod": lastOpenAttempt?["method"] as? String ?? "drive_result",
                            "lastOpenAttempt": lastOpenAttempt ?? [:],
                            "elapsedSeconds": Date().timeIntervalSince(started),
                            "hint": "Google Drive opened a different Google editor than the requested file. Stop before reading or editing the wrong file."
                        ]
                    }
                }
            }

            let waitElapsed = Date().timeIntervalSince(waitStarted)
            if !retriedOpenKey, !attemptedCandidateKeys.isEmpty, waitElapsed >= 2.0 {
                _ = try? await keypress(key: "Enter", modifiers: [])
                retriedOpenKey = true
            }
            if !retriedDriveOpenShortcut, !attemptedCandidateKeys.isEmpty, waitElapsed >= 4.0 {
                _ = try? await keypress(key: "o", modifiers: [])
                retriedDriveOpenShortcut = true
            }
        }

        return [
            "ok": false,
            "opened": false,
            "error": "drive_file_not_opened",
            "name": name,
            "url": lastURL,
            "title": lastTitle,
            "matchedName": GoogleWorkspaceBrowserService.googleDriveOpenedTitleMatches(lastTitle, name),
            "candidateCount": lastCandidateCount,
            "lastOpenAttempt": lastOpenAttempt ?? [:],
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func openGoogleDriveCandidate(_ control: [String: Any]) async throws -> [String: Any] {
        let selector = ShelfBrowserCommandNormalization.normalized(control["selector"] as? String)
        let bounds = control["bounds"] as? [String: Any]
        let x = Self.doubleValue(bounds?["centerX"])
        let y = Self.doubleValue(bounds?["centerY"])
        let canUseSelector = selector != nil
        let canUsePoint = x != nil && y != nil && (x ?? -1) >= 0 && (y ?? -1) >= 0

        let primaryJSON = try await doubleClick(
            selector: canUseSelector ? selector : nil,
            x: canUseSelector ? nil : x,
            y: canUseSelector ? nil : y,
            allowDangerous: false
        )
        var primary = try Self.jsonObject(from: primaryJSON)
        primary["method"] = canUseSelector ? "candidate_double_click_selector" : "candidate_double_click_point"
        primary["candidate"] = GoogleWorkspaceBrowserService.compactGoogleDriveCandidate(control)
        if Self.boolValue(primary["ok"]) {
            return primary
        }

        if canUseSelector && canUsePoint {
            let pointJSON = try await doubleClick(
                selector: nil,
                x: x,
                y: y,
                allowDangerous: false
            )
            var point = try Self.jsonObject(from: pointJSON)
            point["method"] = "candidate_double_click_point"
            point["candidate"] = GoogleWorkspaceBrowserService.compactGoogleDriveCandidate(control)
            if Self.boolValue(point["ok"]) {
                return point
            }
        }

        let fallbackJSON = try await click(
            selector: canUseSelector ? selector : nil,
            x: canUseSelector ? nil : x,
            y: canUseSelector ? nil : y,
            allowDangerous: false
        )
        var fallback = try Self.jsonObject(from: fallbackJSON)
        fallback["method"] = canUseSelector ? "candidate_click_enter_selector" : "candidate_click_enter_point"
        fallback["candidate"] = GoogleWorkspaceBrowserService.compactGoogleDriveCandidate(control)
        if Self.boolValue(fallback["ok"]) {
            _ = try? await keypress(key: "Enter", modifiers: [])
        }
        if canUseSelector && canUsePoint && !Self.boolValue(fallback["ok"]) {
            let pointFallbackJSON = try await click(
                selector: nil,
                x: x,
                y: y,
                allowDangerous: false
            )
            var pointFallback = try Self.jsonObject(from: pointFallbackJSON)
            pointFallback["method"] = "candidate_click_enter_point"
            pointFallback["candidate"] = GoogleWorkspaceBrowserService.compactGoogleDriveCandidate(control)
            if Self.boolValue(pointFallback["ok"]) {
                _ = try? await keypress(key: "Enter", modifiers: [])
            }
            return pointFallback
        }
        return fallback
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
        let strongMatches = controls.filter { Self.controlLabelStronglyMatches($0, requestedLabel: label) }
        guard !controls.isEmpty else {
            return [
                "ok": false,
                "error": "control_not_found",
                "label": label,
                "role": role ?? ""
            ]
        }
        guard !strongMatches.isEmpty else {
            return [
                "ok": false,
                "error": "control_label_mismatch",
                "requestedLabel": label,
                "role": role ?? "",
                "summary": "Best matching controls did not exactly match the requested label. Use analyze/controlID or a more specific selector.",
                "candidates": controls.prefix(5).map(Self.compactControlCandidate)
            ]
        }
        guard strongMatches.count == 1 else {
            return [
                "ok": false,
                "error": "ambiguous_control_label",
                "requestedLabel": label,
                "role": role ?? "",
                "summary": "Multiple controls exactly matched the requested label. Use analyze/controlID to choose one.",
                "candidates": strongMatches.prefix(5).map(Self.compactControlCandidate)
            ]
        }
        let control = strongMatches[0]
        if let blockedAction = Self.mailMutationControlAction(control), !allowDangerous {
            return [
                "ok": false,
                "error": "dangerous_confirmation_required",
                "needsConfirmation": true,
                "requestedLabel": label,
                "blockedAction": blockedAction,
                "summary": "This mail control can mutate the mailbox. Ask for explicit user confirmation before clicking it.",
                "matchedControl": control
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
        let started = Date()
        if let promotionError = await ensureControlledBrowserForGoogleWorkspaceAction(
            action: "googleFindReplace",
            started: started
        ) {
            return promotionError
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
        if let promotionError = await ensureControlledBrowserForGoogleWorkspaceAction(
            action: "googleDocsFind",
            started: started
        ) {
            return promotionError
        }
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
        if let promotionError = await ensureControlledBrowserForGoogleWorkspaceAction(
            action: "googleDocsInsert",
            started: started
        ) {
            return promotionError
        }
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

    private func googleDocsReadDocument() async throws -> [String: Any] {
        guard isGoogleDocsEditor else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        let started = Date()
        if let promotionError = await ensureControlledBrowserForGoogleWorkspaceAction(
            action: "googleDocsReadDocument",
            started: started
        ) {
            return promotionError
        }
        if let browserRequirement = googleDocsControlledBrowserRequiredResult(
            action: "googleDocsReadDocument",
            method: "browser_select_all_copy",
            started: started
        ) {
            return browserRequirement
        }

        let browserResult = try await googleDocsReadDocumentViaBrowser()
        if Self.boolValue(browserResult["ok"]) {
            return browserResult
        }

        var result = browserResult
        result["apiFallbackSkipped"] = true
        result["apiFallbackSkippedReason"] = "browser_use_mode"
        return result
    }

    private func googleDocsReadVisiblePage(format: String?, limit: Int?, chunkSize: Int?) async throws -> [String: Any] {
        guard isGoogleDocsEditor else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        var response = try await readPage(
            format: format ?? "markdown",
            limit: limit,
            chunkSize: chunkSize
        )
        response["source"] = "browser_page_read"
        response["googleDocsMode"] = "visible_page"
        response["fullDocument"] = false
        response["partialSummaryAllowed"] = true
        response["coverage"] = "partial"

        var warnings = response["warnings"] as? [String] ?? []
        warnings.append("Google Docs visible-page reads are partial by design; summarize only the returned content unless the user explicitly accepts that limitation.")
        warnings.append("Use google-docs-read-document in Controlled mode for a full-document summary.")
        response["warnings"] = Array(Set(warnings)).sorted()
        updateLastPageReadState(from: response)
        return response
    }

    private func googleDocsReplaceDocument(text: String, verifyText: String?) async throws -> [String: Any] {
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
        if let promotionError = await ensureControlledBrowserForGoogleWorkspaceAction(
            action: "googleDocsReplaceDocument",
            started: started
        ) {
            return promotionError
        }
        if let browserRequirement = googleDocsControlledBrowserRequiredResult(
            action: "googleDocsReplaceDocument",
            method: "browser_select_all_paste",
            started: started
        ) {
            return browserRequirement
        }

        return try await googleDocsReplaceDocumentViaBrowser(
            text: normalizedText,
            verifyText: verifyText
        )
    }

    private func googleDocsControlledBrowserRequiredResult(
        action: String,
        method: String,
        started: Date
    ) -> [String: Any]? {
        let autoPromote = UserDefaults.standard.bool(forKey: AppStorageKeys.browserAutoPromoteGoogleWorkspace)
        guard GoogleWorkspaceBrowserService.googleDocsFullDocumentClipboardRequiresControlled(
            engine: engine,
            autoPromoteGoogleWorkspace: autoPromote
        ) else {
            return nil
        }

        logBrowserAction(
            phase: "failed",
            action: action,
            selector: nil,
            label: nil,
            role: nil,
            text: nil,
            placeholder: nil,
            testID: nil,
            fields: [
                "error": "google_docs_controlled_browser_required",
                "reason": "embedded_webkit_clipboard_unavailable",
                "required_engine": ShelfBrowserEngine.controlled.rawValue,
                "selected_engine": engine.rawValue,
                "auto_promote_google_workspace": String(autoPromote)
            ],
            started: started
        )

        var response: [String: Any] = [
            "ok": false,
            "error": "google_docs_controlled_browser_required",
            "reason": "embedded_webkit_clipboard_unavailable",
            "safeEditUnavailable": true,
            "method": method,
            "url": currentURL,
            "title": pageTitle,
            "requiredEngine": ShelfBrowserEngine.controlled.rawValue,
            "selectedEngine": engine.rawValue,
            "autoPromoteGoogleWorkspace": autoPromote,
            "copyAttempted": false,
            "elapsedSeconds": Date().timeIntervalSince(started),
            "hint": "Full-document Google Docs browser read/replace requires Controlled mode, or Settings > Appearance > Privacy & Logging > Auto-promote Google Workspace helpers. Embedded WebKit does not expose a reliable fresh clipboard copy from the Docs editor iframe, so ASTRA stopped before selecting or replacing document content."
        ]
        BrowserBridgeRecoveryHints.attach(
            to: &response,
            error: "google_docs_controlled_browser_required",
            action: action
        )
        return response
    }

    private func googleDocsReadDocumentViaBrowser() async throws -> [String: Any] {
        let started = Date()
        let pasteboardSnapshot = Self.capturePasteboardSnapshot()
        defer { Self.restorePasteboardSnapshot(pasteboardSnapshot) }

        let closeJSON = try? await keypress(key: "Escape", modifiers: [])
        let focusJSON = try await click(
            selector: nil,
            x: 0.47,
            y: 0.45,
            allowDangerous: false
        )
        try await Task.sleep(nanoseconds: 250_000_000)
        let selectJSON = try await keypress(key: "a", modifiers: ["command"])
        try await Task.sleep(nanoseconds: 250_000_000)

        let copyStartChangeCount = NSPasteboard.general.changeCount
        let copyJSON = try await keypress(key: "c", modifiers: ["command"])
        let copiedText = await waitForPasteboardString(
            afterChangeCount: copyStartChangeCount,
            timeoutSeconds: 2.5,
            requireChange: true
        )
        _ = try? await keypress(key: "Escape", modifiers: [])

        let focus = try Self.jsonObject(from: focusJSON)
        let select = try Self.jsonObject(from: selectJSON)
        let copy = try Self.jsonObject(from: copyJSON)
        let close = closeJSON.flatMap { try? Self.jsonObject(from: $0) } ?? [:]
        let text = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return [
                "ok": false,
                "error": "google_docs_browser_copy_unavailable",
                "safeEditUnavailable": true,
                "method": "browser_select_all_copy",
                "url": currentURL,
                "title": pageTitle,
                "focus": focus,
                "selectAll": select,
                "copy": copy,
                "close": close,
                "copyChangeObserved": false,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "hint": "ASTRA could not copy a fresh non-empty document backup through the browser. Stop instead of editing without a verified backup."
            ]
        }

        return [
            "ok": true,
            "method": "browser_select_all_copy",
            "text": text,
            "textLength": text.count,
            "url": currentURL,
            "title": pageTitle,
            "focus": focus,
            "selectAll": select,
            "copy": copy,
            "close": close,
            "copyChangeObserved": true,
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func googleDocsReplaceDocumentViaBrowser(text: String, verifyText: String?) async throws -> [String: Any] {
        let started = Date()
        let backup = try await googleDocsReadDocumentViaBrowser()
        guard Self.boolValue(backup["ok"]),
              let originalText = backup["text"] as? String,
              !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [
                "ok": false,
                "error": "google_docs_safe_edit_unavailable",
                "safeEditUnavailable": true,
                "method": "browser_select_all_paste",
                "url": currentURL,
                "title": pageTitle,
                "backup": backup,
                "hint": "Full-document browser replacement requires a browser-copied backup first. ASTRA stopped instead of editing without rollback data."
            ]
        }

        let pasteboardSnapshot = Self.capturePasteboardSnapshot()
        defer { Self.restorePasteboardSnapshot(pasteboardSnapshot) }

        let paste = try await googleDocsPasteFullDocumentText(text)
        let saved = try await waitSaved(timeoutSeconds: 12, intervalMilliseconds: 500)
        let verificationQuery = GoogleWorkspaceBrowserService.googleDocsVerificationQuery(explicit: verifyText, text: text)
        let verification: [String: Any]
        if let verificationQuery {
            verification = try await googleDocsFind(query: verificationQuery, closeFindBar: true)
        } else {
            verification = ["ok": true, "skipped": true]
        }

        let pasteOK = Self.boolValue(paste["ok"])
        let savedOK = Self.boolValue(saved["ok"])
        let verified = Self.boolValue(verification["ok"])
        if pasteOK, verified, savedOK {
            return [
                "ok": true,
                "method": "browser_select_all_paste",
                "textLength": text.count,
                "verifyText": verificationQuery ?? "",
                "url": currentURL,
                "title": pageTitle,
                "backupTextLength": originalText.count,
                "backupMethod": backup["method"] as? String ?? "",
                "paste": paste,
                "saved": saved,
                "verification": verification,
                "elapsedSeconds": Date().timeIntervalSince(started)
            ]
        }

        if !verified {
            let rollback = try? await googleDocsPasteFullDocumentText(originalText)
            let rollbackSaved = try? await waitSaved(timeoutSeconds: 12, intervalMilliseconds: 500)
            return [
                "ok": false,
                "error": "google_docs_safe_edit_verification_failed",
                "method": "browser_select_all_paste",
                "textLength": text.count,
                "verifyText": verificationQuery ?? "",
                "url": currentURL,
                "title": pageTitle,
                "backupTextLength": originalText.count,
                "paste": paste,
                "saved": saved,
                "verification": verification,
                "rollback": rollback ?? [:],
                "rollbackSaved": rollbackSaved ?? [:],
                "elapsedSeconds": Date().timeIntervalSince(started),
                "hint": "ASTRA pasted the replacement but could not verify it, so it attempted to restore the browser-copied backup. Stop for user review."
            ]
        }

        return [
            "ok": false,
            "error": savedOK ? "google_docs_browser_paste_failed" : "saved_indicator_not_found",
            "method": "browser_select_all_paste",
            "textLength": text.count,
            "verifyText": verificationQuery ?? "",
            "url": currentURL,
            "title": pageTitle,
            "backupTextLength": originalText.count,
            "paste": paste,
            "saved": saved,
            "verification": verification,
            "elapsedSeconds": Date().timeIntervalSince(started),
            "hint": "ASTRA did not report success because the paste or save check did not complete cleanly. It did not use raw select-all/delete."
        ]
    }

    private func googleDocsPasteFullDocumentText(_ text: String) async throws -> [String: Any] {
        let started = Date()
        let closeJSON = try? await keypress(key: "Escape", modifiers: [])
        let focusJSON = try await click(
            selector: nil,
            x: 0.47,
            y: 0.45,
            allowDangerous: false
        )
        try await Task.sleep(nanoseconds: 250_000_000)
        let selectJSON = try await keypress(key: "a", modifiers: ["command"])
        try await Task.sleep(nanoseconds: 250_000_000)

        let inputJSON: String
        let method: String
        if isUsingControlledBrowser {
            guard Self.writePasteboardString(text) else {
                return [
                    "ok": false,
                    "error": "pasteboard_write_failed",
                    "method": "browser_select_all_paste",
                    "textLength": text.count
                ]
            }
            inputJSON = try await keypress(key: "v", modifiers: ["command"])
            method = "browser_select_all_paste"
            try await Task.sleep(nanoseconds: 500_000_000)
        } else {
            inputJSON = try await insertText(text)
            method = "browser_select_all_insert_text"
        }

        let focus = try Self.jsonObject(from: focusJSON)
        let select = try Self.jsonObject(from: selectJSON)
        let input = try Self.jsonObject(from: inputJSON)
        let close = closeJSON.flatMap { try? Self.jsonObject(from: $0) } ?? [:]
        return [
            "ok": Self.boolValue(focus["ok"]) && Self.boolValue(select["ok"]) && Self.boolValue(input["ok"]),
            "method": method,
            "textLength": text.count,
            "close": close,
            "focus": focus,
            "selectAll": select,
            "input": input,
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func waitForPasteboardString(
        afterChangeCount: Int,
        timeoutSeconds: Double,
        requireChange: Bool = false
    ) async -> String? {
        let started = Date()
        let timeout = max(0.1, min(timeoutSeconds, 10))
        var latest: String?
        while Date().timeIntervalSince(started) <= timeout {
            let pasteboard = NSPasteboard.general
            if let value = pasteboard.string(forType: .string),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if pasteboard.changeCount != afterChangeCount {
                    return value
                }
                if !requireChange {
                    latest = value
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return latest
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func capturePasteboardSnapshot() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    private static func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.compactMap { values -> NSPasteboardItem? in
            guard !values.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func writePasteboardString(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    private func act(_ command: ActCommand) async throws -> [String: Any] {
        var results: [[String: Any]] = []
        func appendActResult(_ result: [String: Any]) -> String? {
            results.append(result)
            return BrowserTextEntryPreflight.terminalStopReason(for: result)
        }
        let setAnalysisID = command.setAnalysisID ?? command.analysisID
        let setControlID = command.setControlID ?? command.controlID
        if let set = command.set,
           ShelfBrowserCommandNormalization.normalized(setAnalysisID) != nil,
           ShelfBrowserCommandNormalization.normalized(setControlID) != nil {
            let resolved = try await resolvePreflight(
                analysisID: setAnalysisID,
                controlID: setControlID,
                action: BrowserActionKind.setValue.rawValue,
                allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
            )
            guard resolved.ok, let control = resolved.currentControl else {
                results.append(resolved.response.merging(["action": "set"], uniquingKeysWith: { current, _ in current }))
                return BrowserTextEntryPreflight.stoppedResponse(results: results)
            }
            let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
            let before = try? await rawSnapshotObject()
            let json = try await type(
                selector: target.selector,
                text: set,
                clear: true,
                label: target.label,
                role: target.role,
                placeholder: target.placeholder,
                testID: target.testID
            )
            var object = try Self.jsonObject(from: json)
            let after = await snapshotAfterActionDelay()
            addOutcomeFields(to: &object, action: .setValue, control: control, before: before, after: after)
            object["action"] = "set"
            object["matchedControl"] = control.jsonObject(debug: false)
            object["preflight"] = resolved.response
            if let stopReason = appendActResult(object) {
                return ["ok": false, "stopReason": stopReason, "results": results]
            }
        } else if let find = command.find, let set = command.set {
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
            let result = try Self.jsonObject(from: json).merging([
                "action": "set",
                "matchedControl": editable ?? [:]
            ], uniquingKeysWith: { current, _ in current })
            if let stopReason = appendActResult(result) {
                return ["ok": false, "stopReason": stopReason, "results": results]
            }
        }
        let clickAnalysisID = command.clickAnalysisID ?? command.analysisID
        let clickControlID = command.clickControlID ?? command.controlID
        if ShelfBrowserCommandNormalization.normalized(clickAnalysisID) != nil,
           ShelfBrowserCommandNormalization.normalized(clickControlID) != nil {
            let resolved = try await resolvePreflight(
                analysisID: clickAnalysisID,
                controlID: clickControlID,
                action: BrowserActionKind.click.rawValue,
                allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
            )
            guard resolved.ok, let control = resolved.currentControl else {
                results.append(resolved.response.merging(["action": "click"], uniquingKeysWith: { current, _ in current }))
                return BrowserTextEntryPreflight.stoppedResponse(results: results)
            }
            let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
            let before = try? await rawSnapshotObject()
            let json = try await click(
                selector: target.selector,
                x: target.x,
                y: target.y,
                allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous),
                label: target.label,
                role: target.role,
                text: nil,
                placeholder: target.placeholder,
                testID: target.testID
            )
            var object = try Self.jsonObject(from: json)
            let after = await snapshotAfterActionDelay()
            addOutcomeFields(to: &object, action: .click, control: control, before: before, after: after)
            object["action"] = "click"
            object["matchedControl"] = control.jsonObject(debug: false)
            object["preflight"] = resolved.response
            results.append(object)
        } else if let click = command.click {
            let result = try await clickControl(
                label: click,
                role: command.clickRole,
                allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(command.allowDangerous)
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
        var stopReason: String?
        func appendBatchResult(_ result: [String: Any]) -> Bool {
            results.append(result)
            stopReason = BrowserTextEntryPreflight.terminalStopReason(for: result)
            return stopReason != nil
        }
        batchLoop: for action in command.actions.prefix(20) {
            switch action.normalizedAction {
            case "analyze":
                let hasExplicitVersion = action.v2 != nil || action.version != nil || action.analysisVersion != nil
                let requestedVersion = BrowserAnalysisVersion.requested(
                    version: action.analysisVersion ?? action.version,
                    v2: action.v2 ?? false
                )
                let rollout = BrowserAnalysisV2RolloutMode.configured()
                let version = rollout.effectiveVersion(requested: requestedVersion, explicit: hasExplicitVersion)
                let result = try await analyze(
                    query: action.query,
                    full: action.full ?? (action.mode?.lowercased() == "full"),
                    limit: action.limit,
                    debug: action.debug ?? false,
                    version: version,
                    rolloutMode: rollout,
                    includeShadowV2: rollout.shouldAttachShadowAnalysis && !hasExplicitVersion
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "preflight":
                guard action.hasAnalysisControl else {
                    results.append(["ok": false, "action": action.action, "error": "missing_analysis_or_control"])
                    stopReason = "missing_analysis_or_control"
                    break batchLoop
                }
                let result = try await preflightResponse(BrowserPreflightCommand(
                    analysisID: action.analysisID,
                    controlID: action.controlID,
                    action: action.preflightAction ?? action.action,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
                ))
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                if !Self.boolValue(result["ok"]) {
                    stopReason = result["error"] as? String ?? "preflight_failed"
                    break batchLoop
                }
            case "navigate":
                guard let urlText = action.url,
                      let url = ShelfBrowserAddress.normalizedURL(from: urlText) else {
                    results.append(["ok": false, "action": action.action, "error": "invalid_url"])
                    continue
                }
                let wait = await navigateForBridge(to: url, source: "bridge_batch")
                results.append([
                    "ok": true,
                    "action": action.action,
                    "url": wait["url"] as? String ?? url.absoluteString,
                    "title": wait["title"] as? String ?? "",
                    "navigationWait": wait
                ])
            case "click":
                if action.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: action.analysisID,
                        controlID: action.controlID,
                        action: BrowserActionKind.click.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        results.append(resolved.response.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                        stopReason = resolved.response["error"] as? String ?? "preflight_failed"
                        break batchLoop
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await click(
                        selector: target.selector,
                        x: target.x,
                        y: target.y,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous),
                        label: target.label,
                        role: target.role,
                        text: nil,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .click, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    results.append(object.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                } else {
                    let json = try await click(
                        selector: action.normalizedSelector,
                        x: action.x,
                        y: action.y,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous),
                        label: action.normalizedLabel,
                        role: action.normalizedRole,
                        text: action.text,
                        placeholder: action.normalizedPlaceholder,
                        testID: action.normalizedTestID
                    )
                    results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                }
            case "open":
                guard action.hasAnalysisControl else {
                    results.append(["ok": false, "action": action.action, "error": "missing_analysis_or_control"])
                    stopReason = "missing_analysis_or_control"
                    break batchLoop
                }
                let resolved = try await resolvePreflight(
                    analysisID: action.analysisID,
                    controlID: action.controlID,
                    action: BrowserActionKind.open.rawValue,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
                )
                guard resolved.ok, let control = resolved.currentControl else {
                    results.append(resolved.response.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                    stopReason = resolved.response["error"] as? String ?? "preflight_failed"
                    break batchLoop
                }
                var object = try await openControl(
                    control,
                    controlRef: resolved.currentControlRef,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous),
                    timeoutSeconds: action.timeoutSeconds ?? 12,
                    intervalMilliseconds: action.intervalMilliseconds ?? 500
                )
                object["preflight"] = resolved.response
                results.append(object.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "doubleclick", "double-click", "double_click":
                if action.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: action.analysisID,
                        controlID: action.controlID,
                        action: BrowserActionKind.doubleClick.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        results.append(resolved.response.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                        stopReason = resolved.response["error"] as? String ?? "preflight_failed"
                        break batchLoop
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await doubleClick(
                        selector: target.selector,
                        x: target.x,
                        y: target.y,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous),
                        label: target.label,
                        role: target.role,
                        text: nil,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .doubleClick, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    results.append(object.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                } else {
                    let json = try await doubleClick(
                        selector: action.normalizedSelector,
                        x: action.x,
                        y: action.y,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous),
                        label: action.normalizedLabel,
                        role: action.normalizedRole,
                        text: action.text,
                        placeholder: action.normalizedPlaceholder,
                        testID: action.normalizedTestID
                    )
                    results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                }
            case "type":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                if action.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: action.analysisID,
                        controlID: action.controlID,
                        action: BrowserActionKind.fill.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        results.append(resolved.response.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                        stopReason = resolved.response["error"] as? String ?? "preflight_failed"
                        break batchLoop
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await type(
                        selector: target.selector,
                        text: text,
                        clear: action.clear ?? true,
                        label: target.label,
                        role: target.role,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .fill, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    let result = object.merging(["action": action.action], uniquingKeysWith: { current, _ in current })
                    if appendBatchResult(result) { break batchLoop }
                } else {
                    let json = try await type(
                        selector: action.normalizedSelector,
                        text: text,
                        clear: action.clear ?? true,
                        label: action.normalizedLabel,
                        role: action.normalizedRole,
                        placeholder: action.normalizedPlaceholder,
                        testID: action.normalizedTestID
                    )
                    let result = try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current })
                    if appendBatchResult(result) { break batchLoop }
                }
            case "setvalue", "set-value", "fill":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                if action.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: action.analysisID,
                        controlID: action.controlID,
                        action: action.normalizedAction == "fill" ? BrowserActionKind.fill.rawValue : BrowserActionKind.setValue.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        results.append(resolved.response.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                        stopReason = resolved.response["error"] as? String ?? "preflight_failed"
                        break batchLoop
                    }
                    let browserAction = action.normalizedAction == "fill" ? BrowserActionKind.fill : BrowserActionKind.setValue
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await type(
                        selector: target.selector,
                        text: text,
                        clear: true,
                        label: target.label,
                        role: target.role,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: browserAction, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    let result = object.merging(["action": action.action], uniquingKeysWith: { current, _ in current })
                    if appendBatchResult(result) { break batchLoop }
                } else {
                    let json = try await type(
                        selector: action.normalizedSelector,
                        text: text,
                        clear: true,
                        label: action.normalizedLabel,
                        role: action.normalizedRole,
                        placeholder: action.normalizedPlaceholder,
                        testID: action.normalizedTestID
                    )
                    let result = try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current })
                    if appendBatchResult(result) { break batchLoop }
                }
            case "replacetext", "replace-text":
                guard let find = action.find,
                      let replacement = action.replacement ?? action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_find_or_replacement"])
                    continue
                }
                var selector = action.normalizedSelector
                var preflight: [String: Any]?
                var matchedControl: BrowserControl?
                if action.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: action.analysisID,
                        controlID: action.controlID,
                        action: BrowserActionKind.setValue.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        results.append(resolved.response.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                        stopReason = resolved.response["error"] as? String ?? "preflight_failed"
                        break batchLoop
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    selector = target.selector ?? selector
                    preflight = resolved.response
                    matchedControl = control
                }
                let before = matchedControl == nil ? nil : (try? await rawSnapshotObject())
                let json = try await replaceText(
                    find: find,
                    replacement: replacement,
                    selector: selector,
                    all: action.all ?? true
                )
                var object = try Self.jsonObject(from: json)
                if let preflight {
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .setValue, control: matchedControl, before: before, after: after)
                    object["preflight"] = preflight
                }
                let result = object.merging(["action": action.action], uniquingKeysWith: { current, _ in current })
                if appendBatchResult(result) { break batchLoop }
            case "findcontrol", "find-control":
                let result = try await findControl(
                    query: action.query ?? action.label ?? "",
                    role: action.role,
                    limit: action.limit ?? 10
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "clickcontrol", "click-control":
                if action.hasAnalysisControl {
                    let resolved = try await resolvePreflight(
                        analysisID: action.analysisID,
                        controlID: action.controlID,
                        action: BrowserActionKind.click.rawValue,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
                    )
                    guard resolved.ok, let control = resolved.currentControl else {
                        results.append(resolved.response.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                        stopReason = resolved.response["error"] as? String ?? "preflight_failed"
                        break batchLoop
                    }
                    let target = actionTarget(for: control, controlRef: resolved.currentControlRef)
                    let before = try? await rawSnapshotObject()
                    let json = try await click(
                        selector: target.selector,
                        x: target.x,
                        y: target.y,
                        allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous),
                        label: target.label,
                        role: target.role,
                        text: nil,
                        placeholder: target.placeholder,
                        testID: target.testID
                    )
                    var object = try Self.jsonObject(from: json)
                    let after = await snapshotAfterActionDelay()
                    addOutcomeFields(to: &object, action: .click, control: control, before: before, after: after)
                    object["preflight"] = resolved.response
                    results.append(object.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
                    break
                }
                guard let label = action.label ?? action.query else {
                    results.append(["ok": false, "action": action.action, "error": "missing_label"])
                    continue
                }
                let result = try await clickControl(
                    label: label,
                    role: action.role,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous)
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
            case "googledocsreaddocument", "google-docs-read-document", "googledocsread", "google-docs-read":
                let result = try await googleDocsReadDocument()
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "googledocsreadvisiblepage", "google-docs-read-visible-page", "googledocsreadvisible", "google-docs-read-visible", "googledocsreadpage", "google-docs-read-page":
                let result = try await googleDocsReadVisiblePage(
                    format: action.format ?? "markdown",
                    limit: action.limit,
                    chunkSize: action.chunkSize
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "googledocsreplacedocument", "google-docs-replace-document":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                let result = try await googleDocsReplaceDocument(
                    text: text,
                    verifyText: action.verify ?? action.query
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "googledriveopen", "google-drive-open", "drive-open":
                guard let name = action.name ?? action.query ?? action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_name"])
                    continue
                }
                let result = try await googleDriveOpen(
                    name: name,
                    timeoutSeconds: action.timeoutSeconds ?? GoogleWorkspaceBrowserService.googleDriveOpenDefaultTimeoutSeconds,
                    intervalMilliseconds: action.intervalMilliseconds ?? 500
                )
                results.append(result.merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            case "act":
                let result = try await act(ActCommand(
                    analysisID: action.analysisID,
                    controlID: action.controlID,
                    setAnalysisID: nil,
                    setControlID: nil,
                    clickAnalysisID: nil,
                    clickControlID: nil,
                    find: action.find ?? action.query,
                    set: action.set ?? action.text,
                    role: action.role,
                    click: action.click ?? action.label,
                    clickRole: action.clickRole,
                    allowDangerous: BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous),
                    waitSaved: action.waitSaved,
                    verify: action.verify,
                    absent: action.absentText ?? (action.absent == true ? action.text : nil),
                    timeoutSeconds: action.timeoutSeconds,
                    intervalMilliseconds: action.intervalMilliseconds
                ))
                let batchResult = result.merging(["action": action.action], uniquingKeysWith: { current, _ in current })
                if appendBatchResult(batchResult) { break batchLoop }
            case "keypress":
                guard let key = action.key else {
                    results.append(["ok": false, "action": action.action, "error": "missing_key"])
                    continue
                }
                let json = try await keypress(key: key, modifiers: action.modifiers ?? [])
                let result = try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current })
                if appendBatchResult(result) { break batchLoop }
            case "text", "inserttext":
                guard let text = action.text else {
                    results.append(["ok": false, "action": action.action, "error": "missing_text"])
                    continue
                }
                let json = try await insertText(text)
                let result = try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current })
                if appendBatchResult(result) { break batchLoop }
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
                    mode: BrowserSnapshotMode(rawValue: action.mode ?? "summary") ?? .summary,
                    query: action.query,
                    limit: action.limit
                )
                results.append(try Self.jsonObject(from: json).merging(["action": action.action], uniquingKeysWith: { current, _ in current }))
            default:
                results.append(["ok": false, "action": action.action, "error": "unknown_action"])
            }
        }
        var response: [String: Any] = [
            "ok": stopReason == nil && results.allSatisfy { Self.boolValue($0["ok"]) },
            "results": results
        ]
        if let stopReason {
            response["stopped"] = true
            response["stopReason"] = stopReason
        }
        if let snapshotMode = command.snapshotMode {
            let snapshotJSON = try await snapshot(
                mode: BrowserSnapshotMode(rawValue: snapshotMode) ?? .summary,
                query: command.snapshotQuery,
                limit: command.snapshotLimit
            )
            response["snapshot"] = try Self.jsonObject(from: snapshotJSON)
        }
        return response
    }
    func evaluateJavaScriptString(_ script: String) async throws -> String {
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
    static func controlLabelStronglyMatches(_ control: [String: Any], requestedLabel: String) -> Bool {
        let query = normalizedControlLabel(requestedLabel)
        guard !query.isEmpty else { return true }
        return ["label", "name", "value", "placeholder", "testID"].contains { key in
            normalizedControlLabel(control[key] as? String) == query
        }
    }
    static func mailMutationControlAction(_ control: [String: Any]) -> String? {
        let normalized = normalizedControlLabel([
            control["label"] as? String ?? "",
            control["name"] as? String ?? "",
            control["value"] as? String ?? "",
            control["placeholder"] as? String ?? "",
            control["testID"] as? String ?? "",
            control["selector"] as? String ?? "",
            control["type"] as? String ?? ""
        ].joined(separator: " "))
        let padded = " \(normalized) "
        for phrase in mailMutationControlPhrases where padded.contains(" \(phrase) ") {
            return phrase
        }
        return nil
    }

    private static func normalizedControlLabel(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactControlCandidate(_ control: [String: Any]) -> [String: Any] {
        var candidate: [String: Any] = [:]
        for key in ["label", "name", "role", "tag", "type", "selector", "placeholder", "testID"] {
            if let value = control[key] as? String, !value.isEmpty {
                candidate[key] = value
            }
        }
        if let bounds = control["bounds"] as? [String: Any] {
            candidate["bounds"] = bounds
        }
        return candidate
    }

    private static let mailMutationControlPhrases = [
        "reply all",
        "reply",
        "forward",
        "send mail",
        "send",
        "delete",
        "archive",
        "move to",
        "move",
        "mark as read",
        "mark read",
        "mark as unread",
        "mark unread",
        "report junk",
        "junk",
        "report phishing",
        "phishing",
        "discard",
        "sweep",
        "block sender",
        "ignore conversation"
    ]

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

    static func jsonObject(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    static func jsonString(_ object: [String: Any]) throws -> String {
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
                ? "For Google Docs, Sheets, or Slides, switch strategy: use google-drive-open, google-docs-read-document, google-docs-replace-document, google-find-replace, or stop for user input. Avoid repeated menu clicks or synthetic Cmd+A if the snapshot is unchanged."
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

    private static func boolQueryValue(_ value: String?) -> Bool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        if ["1", "true", "yes", "y"].contains(value) { return true }
        if ["0", "false", "no", "n"].contains(value) { return false }
        return nil
    }
    private struct EmbeddedPageReadRequest {
        var frames: [[String: Any]]
        var warnings: [String]
        let continuation: CheckedContinuation<EmbeddedPageReadResult, Never>
        var inactivityTask: Task<Void, Never>?
        let hardTimeoutTask: Task<Void, Never>?
    }

    private struct EmbeddedPageReadResult {
        let frames: [[String: Any]]
        let warnings: [String]
    }

    private final class WeakPageReadMessageHandler: NSObject, WKScriptMessageHandler {
        nonisolated(unsafe) weak var session: ShelfBrowserSession?

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor [weak session] in
                session?.handleEmbeddedPageReadMessage(message.body)
            }
        }
    }

}
