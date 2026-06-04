import AppKit
import Darwin
import Foundation

enum ControlledBrowserError: LocalizedError {
    case browserNotFound
    case missingDebugPort
    case noInspectablePage
    case invalidDevToolsResponse
    case timedOut(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            return "No supported Chromium browser was found. Install Google Chrome, Microsoft Edge, Brave, or Chromium."
        case .missingDebugPort:
            return "Could not allocate a local debugging port for the controlled browser."
        case .noInspectablePage:
            return "The controlled browser did not expose an inspectable page yet."
        case .invalidDevToolsResponse:
            return "The controlled browser returned an invalid DevTools response."
        case .timedOut(let operation):
            return "The controlled browser timed out while \(operation)."
        case .commandFailed(let message):
            return message
        }
    }
}

struct ControlledBrowserCandidate: Equatable {
    let name: String
    let executablePath: String

    static let executablePathEnvironmentKey = "ASTRA_CONTROLLED_BROWSER_EXECUTABLE"
    static let browserNameEnvironmentKey = "ASTRA_CONTROLLED_BROWSER_NAME"

    static let defaultCandidates: [ControlledBrowserCandidate] = [
        .init(name: "Google Chrome for Testing", executablePath: "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
        .init(name: "Google Chrome", executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        .init(name: "Microsoft Edge", executablePath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        .init(name: "Brave Browser", executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
        .init(name: "Chromium", executablePath: "/Applications/Chromium.app/Contents/MacOS/Chromium"),
        .init(name: "Google Chrome for Testing", executablePath: "\(NSHomeDirectory())/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
        .init(name: "Google Chrome", executablePath: "\(NSHomeDirectory())/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        .init(name: "Microsoft Edge", executablePath: "\(NSHomeDirectory())/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
    ]

    static func firstAvailable(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ControlledBrowserCandidate? {
        if let override = environment[executablePathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                let name = environment[browserNameEnvironmentKey]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedName: String
                if let name, !name.isEmpty {
                    resolvedName = name
                } else {
                    resolvedName = URL(fileURLWithPath: expanded).lastPathComponent
                }
                return ControlledBrowserCandidate(
                    name: resolvedName,
                    executablePath: expanded
                )
            }
        }
        return defaultCandidates.first { fileManager.isExecutableFile(atPath: $0.executablePath) }
    }

    func launchArguments(profilePath: String, debugPort: UInt16, initialURL: URL?) -> [String] {
        var arguments = [
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(debugPort)",
            "--user-data-dir=\(profilePath)",
            "--no-first-run",
            "--no-default-browser-check",
            "--new-window"
        ]
        if let initialURL {
            arguments.append(initialURL.absoluteString)
        }
        return arguments
    }
}

struct ControlledBrowserDebugTarget: Equatable {
    let processID: pid_t
    let debugPort: UInt16
}

struct ControlledBrowserCDPCapabilityReport: Equatable {
    let browser: String
    let protocolVersion: String
    let domains: [String: Bool]
    let errors: [String: String]

    var jsonObject: [String: Any] {
        [
            "browser": browser,
            "protocolVersion": protocolVersion,
            "domains": domains,
            "errors": errors
        ]
    }
}

enum ControlledBrowserCDPDiagnosticsFormatter {
    static func diagnosticsObject(
        url: String,
        title: String,
        events: [[String: Any]],
        capabilities: ControlledBrowserCDPCapabilityReport
    ) -> [String: Any] {
        [
            "ok": true,
            "captureMode": "cdp_event_stream",
            "url": url,
            "title": title,
            "capabilities": capabilities.jsonObject,
            "consoleEvents": consoleEvents(from: events),
            "navigationEvents": navigationEvents(from: events),
            "networkEvents": networkEvents(from: events)
        ]
    }

    private static func consoleEvents(from events: [[String: Any]]) -> [[String: Any]] {
        events.compactMap { event in
            let method = stringValue(event["method"])
            let params = event["params"] as? [String: Any] ?? [:]
            switch method {
            case "Runtime.consoleAPICalled":
                let args = params["args"] as? [[String: Any]] ?? []
                let message = args.map { arg in
                    stringValue(arg["value"]).isEmpty ? stringValue(arg["description"]) : stringValue(arg["value"])
                }.joined(separator: " ")
                return [
                    "source": "cdp.Runtime.consoleAPICalled",
                    "level": stringValue(params["type"]),
                    "message": message
                ]
            case "Runtime.exceptionThrown":
                let details = params["exceptionDetails"] as? [String: Any] ?? [:]
                let exception = details["exception"] as? [String: Any] ?? [:]
                return [
                    "source": stringValue(details["url"]).isEmpty ? "cdp.Runtime.exceptionThrown" : stringValue(details["url"]),
                    "level": "exception",
                    "message": stringValue(details["text"]).isEmpty ? stringValue(exception["description"]) : stringValue(details["text"]),
                    "line": intValue(details["lineNumber"]) ?? 0,
                    "column": intValue(details["columnNumber"]) ?? 0
                ]
            case "Log.entryAdded":
                let entry = params["entry"] as? [String: Any] ?? [:]
                return [
                    "source": stringValue(entry["url"]).isEmpty ? "cdp.Log.entryAdded" : stringValue(entry["url"]),
                    "level": stringValue(entry["level"]),
                    "message": stringValue(entry["text"]),
                    "line": intValue(entry["lineNumber"]) ?? 0
                ]
            default:
                return nil
            }
        }
    }

    private static func navigationEvents(from events: [[String: Any]]) -> [[String: Any]] {
        events.compactMap { event in
            let method = stringValue(event["method"])
            let params = event["params"] as? [String: Any] ?? [:]
            switch method {
            case "Page.frameNavigated":
                let frame = params["frame"] as? [String: Any] ?? [:]
                return [
                    "source": "cdp.Page.frameNavigated",
                    "type": "frameNavigated",
                    "url": stringValue(frame["url"])
                ]
            case "Page.domContentEventFired":
                return ["source": "cdp.Page.domContentEventFired", "type": "DOMContentLoaded"]
            case "Page.loadEventFired":
                return ["source": "cdp.Page.loadEventFired", "type": "load"]
            case "Page.lifecycleEvent":
                return [
                    "source": "cdp.Page.lifecycleEvent",
                    "type": stringValue(params["name"]),
                    "frameId": stringValue(params["frameId"])
                ]
            default:
                return nil
            }
        }
    }

    private static func networkEvents(from events: [[String: Any]]) -> [[String: Any]] {
        events.compactMap { event in
            let method = stringValue(event["method"])
            let params = event["params"] as? [String: Any] ?? [:]
            switch method {
            case "Network.responseReceived":
                let response = params["response"] as? [String: Any] ?? [:]
                let status = intValue(response["status"]) ?? 0
                guard status >= 400 else { return nil }
                return [
                    "source": "cdp.Network.responseReceived",
                    "type": stringValue(params["type"]).isEmpty ? "response" : stringValue(params["type"]),
                    "method": "",
                    "url": stringValue(response["url"]),
                    "status": status
                ]
            case "Network.loadingFailed":
                return [
                    "source": "cdp.Network.loadingFailed",
                    "type": stringValue(params["type"]).isEmpty ? "request" : stringValue(params["type"]),
                    "method": "",
                    "url": "",
                    "error": stringValue(params["errorText"])
                ]
            default:
                return nil
            }
        }
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

enum ControlledBrowserRunState: String, CaseIterable {
    case idle
    case launching
    case running
    case attached
    case stopped
    case failed

    var label: String {
        switch self {
        case .idle: "Not launched"
        case .launching: "Opening"
        case .running: "Connected"
        case .attached: "Connected"
        case .stopped: "Stopped"
        case .failed: "Needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .launching: "arrow.triangle.2.circlepath"
        case .running: "checkmark.circle.fill"
        case .attached: "link.circle.fill"
        case .stopped: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class ControlledBrowserController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var runState: ControlledBrowserRunState = .idle
    @Published private(set) var browserName: String?
    @Published private(set) var currentURL = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var statusMessage = "Controlled browser not launched"
    @Published private(set) var profilePath = ControlledBrowserController.defaultProfilePath
    @Published private(set) var debugPort: UInt16?
    @Published private(set) var processID: pid_t?
    @Published private(set) var lastErrorMessage: String?

    private var process: Process?
    private var attachedProcessID: pid_t?
    private var diagnosticsClient: PersistentCDPDiagnosticsClient?
    private var diagnosticsPageID: String?

    var isLaunching: Bool {
        runState == .launching
    }

    deinit {
        diagnosticsClient?.close()
        process?.terminate()
    }

    func launch(initialAddress: String? = nil) async {
        guard !isLaunching else {
            statusMessage = "Controlled browser is already opening"
            return
        }
        runState = .launching
        statusMessage = "Preparing controlled browser profile"
        lastErrorMessage = nil

        do {
            let url = initialAddress.flatMap(ShelfBrowserAddress.normalizedURL(from:))
            try await ensureLaunched(initialURL: url)
            if let url {
                try await navigate(to: url)
            }
            try await refreshPageMetadata()
            if runState == .launching {
                runState = attachedProcessID == nil ? .running : .attached
            }
            statusMessage = "\(browserName ?? "Controlled browser") ready"
        } catch {
            process = nil
            attachedProcessID = nil
            debugPort = nil
            processID = nil
            isRunning = false
            runState = .failed
            lastErrorMessage = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    func refreshStatus() async {
        guard !isLaunching else { return }

        if isRunning {
            do {
                try await refreshPageMetadata()
                runState = attachedProcessID == nil ? .running : .attached
                statusMessage = "\(browserName ?? "Controlled browser") ready"
                lastErrorMessage = nil
                return
            } catch {
                process = nil
                attachedProcessID = nil
                debugPort = nil
                processID = nil
                isRunning = false
                currentURL = ""
                pageTitle = ""
                runState = .stopped
                statusMessage = "Controlled browser is not reachable"
                lastErrorMessage = error.localizedDescription
            }
        }

        if await attachToExistingControlledBrowser() {
            return
        }

        debugPort = nil
        processID = nil
        runState = .idle
        statusMessage = "Controlled browser not launched"
    }

    func stop() {
        diagnosticsClient?.close()
        diagnosticsClient = nil
        diagnosticsPageID = nil
        if let process, process.isRunning {
            process.terminate()
        } else if let attachedProcessID {
            Darwin.kill(attachedProcessID, SIGTERM)
        }
        process = nil
        attachedProcessID = nil
        debugPort = nil
        processID = nil
        isRunning = false
        currentURL = ""
        pageTitle = ""
        runState = .stopped
        lastErrorMessage = nil
        statusMessage = "Controlled browser stopped"
    }

    func navigate(to address: String) async throws {
        guard let url = ShelfBrowserAddress.normalizedURL(from: address) else {
            throw ControlledBrowserError.commandFailed("Invalid URL.")
        }
        try await ensureLaunched(initialURL: url)
        try await navigate(to: url)
    }

    func reload() async throws {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        try await sendCDPCommand(method: "Page.reload", params: [:])
        try await refreshPageMetadata()
    }

    func snapshot() async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let value = try await evaluate(script: BrowserAutomationScripts.snapshotScript)
        try await refreshPageMetadata()
        return value
    }

    func readPage(
        format: String = "text",
        limit: Int = BrowserPageReadService.defaultLimit,
        chunkSize: Int = BrowserPageReadService.defaultChunkSize
    ) async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let page = try await currentPage()
        let normalizedLimit = BrowserPageReadService.normalizedLimit(limit)
        let normalizedChunkSize = BrowserPageReadService.normalizedChunkSize(chunkSize)
        let normalizedFormat = BrowserPageReadService.normalizedFormat(format)

        do {
            let response = try await readPageWithScopedCDP(
                page: page,
                format: normalizedFormat,
                limit: normalizedLimit,
                chunkSize: normalizedChunkSize
            )
            try await refreshPageMetadata()
            return try Self.jsonString(response)
        } catch {
            let snapshotJSON = try await snapshot()
            let snapshotObject = try Self.jsonObject(from: snapshotJSON)
            let response = BrowserPageReadService.responseFromSnapshot(
                snapshotObject,
                engine: ShelfBrowserEngine.controlled.rawValue,
                backend: ShelfBrowserEngine.controlled.bridgeBackendLabel,
                format: normalizedFormat,
                limit: normalizedLimit,
                chunkSize: normalizedChunkSize,
                warnings: [
                    "Controlled frame-aware read failed and fell back to the compact snapshot path.",
                    error.localizedDescription
                ]
            )
            try await refreshPageMetadata()
            return try Self.jsonString(response)
        }
    }

    func accessibilitySnapshot(limit: Int = 300) async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let response = try await sendCDPCommand(
            method: "Accessibility.getFullAXTree",
            params: ["interestingOnly": true]
        )
        try await refreshPageMetadata()
        guard let result = response["result"] as? [String: Any] else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        let rawNodes = result["nodes"] as? [[String: Any]] ?? []
        let compactNodes = rawNodes.prefix(max(0, limit)).map(Self.compactAccessibilityNode)
        return try Self.jsonString([
            "ok": true,
            "url": currentURL,
            "title": pageTitle,
            "nodeCount": rawNodes.count,
            "returnedNodeCount": compactNodes.count,
            "nodes": Array(compactNodes)
        ])
    }

    func installDebugInstrumentation() async throws {
        try await startCDPDiagnostics()
    }

    func startCDPDiagnostics() async throws {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let page = try await currentPage()
        if diagnosticsClient != nil, diagnosticsPageID == page.id {
            return
        }
        diagnosticsClient?.close()
        diagnosticsClient = nil
        diagnosticsPageID = nil

        guard let webSocketURL = URL(string: page.webSocketDebuggerURL),
              let debugPort else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        let version = try await devToolsVersion(debugPort: debugPort)
        let client = PersistentCDPDiagnosticsClient(webSocketURL: webSocketURL)
        try await client.connect()
        try await client.probeAndEnable(version: version)
        diagnosticsClient = client
        diagnosticsPageID = page.id
    }

    func debugEvents() async throws -> String {
        try await startCDPDiagnostics()
        try await refreshPageMetadata()
        guard let diagnosticsClient else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        return try Self.jsonString(diagnosticsClient.snapshot(url: currentURL, title: pageTitle))
    }

    func screenshotJPEGBase64(quality: Int = 45) async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        _ = try? await sendCDPCommand(method: "Page.enable", params: [:])
        let response = try await sendCDPCommand(
            method: "Page.captureScreenshot",
            params: [
                "format": "jpeg",
                "quality": max(1, min(100, quality)),
                "fromSurface": true,
                "captureBeyondViewport": false
            ]
        )
        try await refreshPageMetadata()
        guard let result = response["result"] as? [String: Any],
              let base64 = result["data"] as? String,
              !base64.isEmpty else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        return base64
    }

    func click(
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
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let targetJSON = try await evaluate(script: BrowserAutomationScripts.clickTargetScript(
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
        var target = try Self.jsonObject(from: targetJSON)
        guard Self.boolValue(target["ok"]) else {
            return targetJSON
        }
        guard let targetX = Self.doubleValue(target["x"]),
              let targetY = Self.doubleValue(target["y"]) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        try await dispatchMouseClick(x: targetX, y: targetY)
        try await refreshPageMetadata()
        target["clicked"] = true
        target["url"] = currentURL
        return try Self.jsonString(target)
    }

    func doubleClick(
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
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let targetJSON = try await evaluate(script: BrowserAutomationScripts.clickTargetScript(
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
        var target = try Self.jsonObject(from: targetJSON)
        guard Self.boolValue(target["ok"]) else {
            return targetJSON
        }
        guard let targetX = Self.doubleValue(target["x"]),
              let targetY = Self.doubleValue(target["y"]) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        try await dispatchMouseClick(x: targetX, y: targetY, clickCount: 2)
        try await refreshPageMetadata()
        target["clicked"] = true
        target["doubleClicked"] = true
        target["url"] = currentURL
        return try Self.jsonString(target)
    }


    func targetInfo(
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
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let value = try await evaluate(script: BrowserAutomationScripts.targetInfoScript(
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
        try await refreshPageMetadata()
        return value
    }

    func type(
        selector: String?,
        text: String,
        clear: Bool,
        label: String? = nil,
        role: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil
    ) async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let value = try await evaluate(script: BrowserAutomationScripts.typeScript(
            selector: selector,
            text: text,
            clear: clear,
            label: label,
            role: role,
            placeholder: placeholder,
            testID: testID
        ))
        try await refreshPageMetadata()
        return value
    }

    func replaceText(find: String, replacement: String, selector: String?, all: Bool) async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let value = try await evaluate(script: BrowserAutomationScripts.replaceTextScript(
            find: find,
            replacement: replacement,
            selector: selector,
            all: all
        ))
        try await refreshPageMetadata()
        return value
    }

    func keypress(key: String, modifiers: [String]) async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let definition = Self.keyDefinition(for: key, modifiers: modifiers)
        let modifierMask = Self.cdpModifierMask(for: modifiers)

        var downParams: [String: Any] = [
            "type": "rawKeyDown",
            "key": definition.key,
            "code": definition.code,
            "windowsVirtualKeyCode": definition.virtualKeyCode,
            "nativeVirtualKeyCode": definition.virtualKeyCode,
            "modifiers": modifierMask
        ]
        if modifierMask == 0, let text = definition.text {
            downParams["text"] = text
            downParams["unmodifiedText"] = text
        }

        try await sendCDPCommand(method: "Input.dispatchKeyEvent", params: downParams)
        try await sendCDPCommand(method: "Input.dispatchKeyEvent", params: [
            "type": "keyUp",
            "key": definition.key,
            "code": definition.code,
            "windowsVirtualKeyCode": definition.virtualKeyCode,
            "nativeVirtualKeyCode": definition.virtualKeyCode,
            "modifiers": modifierMask
        ])
        try await refreshPageMetadata()
        return try Self.jsonString([
            "ok": true,
            "key": definition.key,
            "code": definition.code,
            "modifiers": modifiers
        ])
    }

    func insertText(_ text: String) async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        try await sendCDPCommand(method: "Input.insertText", params: ["text": text])
        try await refreshPageMetadata()
        return try Self.jsonString(["ok": true, "textLength": text.count])
    }

    func showWindow() async {
        do {
            let initialURL = ShelfBrowserAddress.normalizedURL(from: currentURL) ?? URL(string: "about:blank")
            try await ensureLaunched(initialURL: initialURL)
            try await restoreCurrentPageWindow()
            try await sendCDPCommand(method: "Page.bringToFront", params: [:])
            activateRunningBrowser()
            try await refreshPageMetadata()
            statusMessage = "\(browserName ?? "Controlled browser") shown"
            lastErrorMessage = nil
        } catch {
            openWindow()
            statusMessage = "Opened \(browserName ?? "controlled browser")"
            lastErrorMessage = error.localizedDescription
        }
    }

    func openWindow() {
        let executablePath = process?.executableURL?.path
            ?? ControlledBrowserCandidate.firstAvailable()?.executablePath
        guard let executablePath else { return }
        let appURL = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        NSWorkspace.shared.open(appURL)
    }

    private func activateRunningBrowser() {
        let targetProcessID = processID ?? attachedProcessID ?? process?.processIdentifier
        guard let targetProcessID,
              let app = NSRunningApplication(processIdentifier: targetProcessID) else {
            openWindow()
            return
        }
        app.activate(options: [.activateAllWindows])
    }

    private func restoreCurrentPageWindow() async throws {
        let page = try await currentPage()
        var params: [String: Any] = [:]
        if let id = page.id {
            params["targetId"] = id
        }

        let response = try await sendCDPCommand(method: "Browser.getWindowForTarget", params: params)
        guard let result = response["result"] as? [String: Any],
              let windowID = Self.intValue(result["windowId"]) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }

        try await sendCDPCommand(
            method: "Browser.setWindowBounds",
            params: [
                "windowId": windowID,
                "bounds": ["windowState": "normal"]
            ]
        )
    }

    private func ensureLaunched(initialURL: URL?) async throws {
        if process?.isRunning == true, debugPort != nil {
            do {
                _ = try await currentPage()
                isRunning = true
                processID = process?.processIdentifier
                runState = .running
                return
            } catch {
                process?.terminate()
                process = nil
                debugPort = nil
                processID = nil
                isRunning = false
            }
        }

        runState = .launching
        statusMessage = "Looking for an existing controlled browser"
        lastErrorMessage = nil

        if await attachToExistingControlledBrowser() {
            return
        }

        guard let candidate = ControlledBrowserCandidate.firstAvailable() else {
            throw ControlledBrowserError.browserNotFound
        }
        guard let port = Self.randomDebugPort() else {
            throw ControlledBrowserError.missingDebugPort
        }

        try FileManager.default.createDirectory(atPath: profilePath, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: candidate.executablePath)
        process.arguments = candidate.launchArguments(profilePath: profilePath, debugPort: port, initialURL: initialURL)
        do {
            try process.run()
        } catch {
            let detail = "\(error.localizedDescription) \(candidate.executablePath)"
            if MacOSPermissionDiagnostics.isLikelyAppManagementDenial(detail) {
                throw ControlledBrowserError.commandFailed(
                    MacOSPermissionDiagnostics.appManagementIssue(
                        appDisplayName: AppChannel.current.displayName,
                        targetAppName: candidate.name
                    ).message
                )
            }
            throw error
        }

        self.process = process
        attachedProcessID = nil
        debugPort = port
        processID = process.processIdentifier
        browserName = candidate.name
        isRunning = true
        runState = .launching
        statusMessage = "Opening \(candidate.name) and waiting for DevTools"

        do {
            try await waitForDevTools()
            runState = .running
            statusMessage = "\(candidate.name) controlled profile connected"
        } catch {
            if await attachToExistingControlledBrowser() {
                return
            }
            process.terminate()
            self.process = nil
            debugPort = nil
            processID = nil
            isRunning = false
            throw error
        }
    }

    private func navigate(to url: URL) async throws {
        _ = try await sendCDPCommand(method: "Page.navigate", params: ["url": url.absoluteString])
        currentURL = url.absoluteString
        statusMessage = "Navigated controlled browser"
        try await refreshPageMetadata()
    }

    private func dispatchMouseClick(x: Double, y: Double, clickCount: Int = 1) async throws {
        try await sendCDPCommand(method: "Input.dispatchMouseEvent", params: [
            "type": "mouseMoved",
            "x": x,
            "y": y,
            "button": "none"
        ])
        for count in 1...max(1, clickCount) {
            try await sendCDPCommand(method: "Input.dispatchMouseEvent", params: [
                "type": "mousePressed",
                "x": x,
                "y": y,
                "button": "left",
                "clickCount": count
            ])
            try await sendCDPCommand(method: "Input.dispatchMouseEvent", params: [
                "type": "mouseReleased",
                "x": x,
                "y": y,
                "button": "left",
                "clickCount": count
            ])
            if count < clickCount {
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
    }

    private func readPageWithScopedCDP(
        page: DevToolsPage,
        format: String,
        limit: Int,
        chunkSize: Int
    ) async throws -> [String: Any] {
        guard let debugPort else {
            throw ControlledBrowserError.missingDebugPort
        }

        let browserSocket = try await browserWebSocketDebuggerURL(debugPort: debugPort)
        let webSocketURL = URL(string: browserSocket) ?? URL(string: page.webSocketDebuggerURL)
        guard let webSocketURL else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }

        let client = OperationCDPClient(webSocketURL: webSocketURL)
        try await client.connect()
        defer { client.close() }

        var warnings: [String] = []
        var diagnostics: [String: Any] = [:]
        var frames: [[String: Any]] = []
        var observedEvents: [[String: Any]] = []
        var attachedSessionIDs: [String] = []
        var readOOPIFTargetIDs = Set<String>()
        var pageSessionID: String?

        if let targetID = page.id, browserSocket != page.webSocketDebuggerURL {
            do {
                let attached = try await client.send(
                    method: "Target.attachToTarget",
                    params: ["targetId": targetID, "flatten": true]
                )
                pageSessionID = (attached["result"] as? [String: Any])?["sessionId"] as? String
                if let pageSessionID {
                    attachedSessionIDs.append(pageSessionID)
                }
                _ = try? await client.send(method: "Page.enable", params: [:], sessionID: pageSessionID)
                _ = try? await client.send(method: "Runtime.enable", params: [:], sessionID: pageSessionID)
                _ = try? await client.send(
                    method: "Target.setAutoAttach",
                    params: [
                        "autoAttach": true,
                        "waitForDebuggerOnStart": false,
                        "flatten": true
                    ]
                )
                observedEvents.append(contentsOf: client.drainEvents())
            } catch {
                warnings.append("Could not attach to the page target through the browser CDP endpoint: \(error.localizedDescription)")
            }
        }

        let primarySessionID = pageSessionID
        frames.append(contentsOf: try await readPageFrames(
            client: client,
            sessionID: primarySessionID,
            source: "controlled_chromium",
            limit: limit,
            observedEvents: &observedEvents,
            warnings: &warnings
        ))
        let pageFrameIDs = Set(frames.compactMap { Self.stringValue($0["frameID"]) }.filter { !$0.isEmpty })

        let autoAttachedOOPIFs = Self.autoAttachedIframeTargets(
            from: observedEvents,
            pageTargetID: page.id,
            pageFrameIDs: pageFrameIDs
        )
        diagnostics["autoAttachedOOPIFTargetCount"] = autoAttachedOOPIFs.count
        let oopifTargetReadLimit = 20
        if autoAttachedOOPIFs.count > oopifTargetReadLimit {
            warnings.append("Controlled read inspected first \(oopifTargetReadLimit) of \(autoAttachedOOPIFs.count) auto-attached iframe targets; remaining targets were not read.")
        }
        for target in autoAttachedOOPIFs.prefix(oopifTargetReadLimit) {
            guard !readOOPIFTargetIDs.contains(target.targetID) else { continue }
            readOOPIFTargetIDs.insert(target.targetID)
            attachedSessionIDs.append(target.sessionID)
            do {
                let iframeFrames = try await readPageFrames(
                    client: client,
                    sessionID: target.sessionID,
                    source: "controlled_chromium_oopif",
                    limit: limit,
                    observedEvents: &observedEvents,
                    warnings: &warnings
                )
                Self.mergePageReadFrames(iframeFrames, into: &frames)
            } catch {
                Self.mergePageReadFrames([
                    [
                        "frameID": target.targetID,
                        "url": target.url,
                        "title": target.title,
                        "accessible": false,
                        "source": "controlled_chromium_oopif",
                        "error": error.localizedDescription
                    ]
                ], into: &frames)
            }
        }

        do {
            let targetResponse = try await client.send(method: "Target.getTargets")
            observedEvents.append(contentsOf: client.drainEvents())
            let allIframeTargetInfos = ((targetResponse["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? String) == "iframe" }
            let targetInfos = allIframeTargetInfos.filter {
                Self.isIframeTargetInfoScopedToPage($0, pageTargetID: page.id, pageFrameIDs: pageFrameIDs)
            }
            diagnostics["oopifTargetCount"] = allIframeTargetInfos.count
            diagnostics["scopedOOPIFTargetCount"] = targetInfos.count

            let fallbackTargetInfos = targetInfos.filter {
                guard let targetID = $0["targetId"] as? String else { return false }
                return !readOOPIFTargetIDs.contains(targetID)
            }
            if fallbackTargetInfos.count > oopifTargetReadLimit {
                warnings.append("Controlled read inspected first \(oopifTargetReadLimit) of \(fallbackTargetInfos.count) fallback iframe targets; remaining targets were not read.")
            }
            for targetInfo in fallbackTargetInfos.prefix(oopifTargetReadLimit) {
                guard let targetID = targetInfo["targetId"] as? String else { continue }
                readOOPIFTargetIDs.insert(targetID)
                do {
                    let attached = try await client.send(
                        method: "Target.attachToTarget",
                        params: ["targetId": targetID, "flatten": true]
                    )
                    guard let sessionID = (attached["result"] as? [String: Any])?["sessionId"] as? String else { continue }
                    attachedSessionIDs.append(sessionID)
                    let iframeFrames = try await readPageFrames(
                        client: client,
                        sessionID: sessionID,
                        source: "controlled_chromium_oopif",
                        limit: limit,
                        observedEvents: &observedEvents,
                        warnings: &warnings
                    )
                    Self.mergePageReadFrames(iframeFrames, into: &frames)
                } catch {
                    Self.mergePageReadFrames([[
                        "frameID": targetID,
                        "url": targetInfo["url"] as? String ?? "",
                        "title": targetInfo["title"] as? String ?? "",
                        "accessible": false,
                        "source": "controlled_chromium_oopif",
                        "error": error.localizedDescription
                    ]], into: &frames)
                }
            }
        } catch {
            warnings.append("Could not enumerate out-of-process iframe targets: \(error.localizedDescription)")
        }

        let resolvedURL = self.currentURL.isEmpty ? page.url : self.currentURL
        let resolvedTitle = self.pageTitle.isEmpty ? page.title : self.pageTitle

        do {
            let axResponse = try await client.send(
                method: "Accessibility.getFullAXTree",
                params: ["interestingOnly": true],
                sessionID: primarySessionID
            )
            observedEvents.append(contentsOf: client.drainEvents())
            let nodes = ((axResponse["result"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            diagnostics["accessibilityNodeCount"] = nodes.count
            let axText = Self.accessibilityText(from: nodes, limit: limit)
            diagnostics["accessibilityTextLength"] = axText.textLength
            diagnostics["accessibilityTextTruncated"] = axText.truncated
            if Self.mergeAccessibilityText(
                axText,
                into: &frames,
                pageURL: resolvedURL,
                pageTitle: resolvedTitle
            ) {
                warnings.append("Accessibility tree text was merged because DOM frame text was empty, sparse, or likely canvas-rendered.")
            }
        } catch {
            warnings.append("Accessibility tree read failed: \(error.localizedDescription)")
        }

        do {
            let domResponse = try await client.send(
                method: "DOMSnapshot.captureSnapshot",
                params: [
                    "computedStyles": [],
                    "includeDOMRects": true,
                    "includePaintOrder": false
                ],
                sessionID: primarySessionID
            )
            observedEvents.append(contentsOf: client.drainEvents())
            let documents = ((domResponse["result"] as? [String: Any])?["documents"] as? [[String: Any]]) ?? []
            diagnostics["domSnapshotDocumentCount"] = documents.count
        } catch {
            warnings.append("DOM snapshot read failed: \(error.localizedDescription)")
        }

        diagnostics["cdpEventCount"] = observedEvents.count
        diagnostics["runtimeExecutionContextEventCount"] = observedEvents.filter {
            Self.stringValue($0["method"]) == "Runtime.executionContextCreated"
        }.count
        for sessionID in attachedSessionIDs.reversed() {
            _ = try? await client.send(
                method: "Target.detachFromTarget",
                params: ["sessionId": sessionID]
            )
        }

        return BrowserPageReadService.response(
            url: resolvedURL,
            title: resolvedTitle,
            engine: ShelfBrowserEngine.controlled.rawValue,
            backend: ShelfBrowserEngine.controlled.bridgeBackendLabel,
            format: format,
            limit: limit,
            chunkSize: chunkSize,
            frames: Self.deduplicatedPageReadFrames(frames),
            warnings: warnings,
            diagnostics: diagnostics
        )
    }

    private func readPageFrames(
        client: OperationCDPClient,
        sessionID: String?,
        source: String,
        limit: Int,
        observedEvents: inout [[String: Any]],
        warnings: inout [String]
    ) async throws -> [[String: Any]] {
        _ = try? await client.send(method: "Page.enable", params: [:], sessionID: sessionID)
        _ = try? await client.send(method: "Runtime.enable", params: [:], sessionID: sessionID)
        observedEvents.append(contentsOf: client.drainEvents())

        let frameTreeResponse = try await client.send(
            method: "Page.getFrameTree",
            params: [:],
            sessionID: sessionID
        )
        observedEvents.append(contentsOf: client.drainEvents())
        guard let result = frameTreeResponse["result"] as? [String: Any],
              let frameTree = result["frameTree"] as? [String: Any] else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }

        let frameInfos = Self.flattenFrameTree(frameTree)
        let frameReadLimit = 80
        if frameInfos.count > frameReadLimit {
            warnings.append("Controlled read inspected first \(frameReadLimit) of \(frameInfos.count) frames for \(source); remaining frames were not read.")
        }
        var frames: [[String: Any]] = []
        for frameInfo in frameInfos.prefix(frameReadLimit) {
            let frameID = Self.stringValue(frameInfo["id"])
            guard !frameID.isEmpty else { continue }
            do {
                let contextID = try await pageReadExecutionContextID(
                    client: client,
                    sessionID: sessionID,
                    frameID: frameID,
                    observedEvents: &observedEvents
                )
                let frame = try await evaluatePageReadFrame(
                    client: client,
                    sessionID: sessionID,
                    contextID: contextID,
                    frameID: frameID,
                    parentFrameID: Self.stringValue(frameInfo["parentId"]),
                    source: source,
                    limit: limit
                )
                observedEvents.append(contentsOf: client.drainEvents())
                frames.append(frame)
            } catch {
                frames.append([
                    "frameID": frameID,
                    "parentFrameID": Self.stringValue(frameInfo["parentId"]),
                    "url": Self.stringValue(frameInfo["url"]),
                    "title": Self.stringValue(frameInfo["name"]),
                    "accessible": false,
                    "source": source,
                    "error": error.localizedDescription
                ])
            }
        }
        return frames
    }

    private func pageReadExecutionContextID(
        client: OperationCDPClient,
        sessionID: String?,
        frameID: String,
        observedEvents: inout [[String: Any]]
    ) async throws -> Int? {
        do {
            let world = try await client.send(
                method: "Page.createIsolatedWorld",
                params: [
                    "frameId": frameID,
                    "worldName": "ASTRAReadPage",
                    "grantUniveralAccess": false
                ],
                sessionID: sessionID
            )
            observedEvents.append(contentsOf: client.drainEvents())
            return Self.intValue((world["result"] as? [String: Any])?["executionContextId"])
        } catch {
            observedEvents.append(contentsOf: client.drainEvents())
            if let eventContextID = Self.executionContextID(
                from: observedEvents,
                sessionID: sessionID,
                frameID: frameID,
                worldName: nil
            ) {
                return eventContextID
            }
            throw error
        }
    }

    private func evaluatePageReadFrame(
        client: OperationCDPClient,
        sessionID: String?,
        contextID: Int?,
        frameID: String,
        parentFrameID: String,
        source: String,
        limit: Int
    ) async throws -> [String: Any] {
        var params: [String: Any] = [
            "expression": BrowserAutomationScripts.pageReadFrameScript(limit: limit),
            "awaitPromise": true,
            "returnByValue": true,
            "timeout": 8_000
        ]
        if let contextID {
            params["contextId"] = contextID
        }
        let response = try await client.send(
            method: "Runtime.evaluate",
            params: params,
            sessionID: sessionID
        )
        guard let result = response["result"] as? [String: Any],
              result["exceptionDetails"] == nil,
              let remoteObject = result["result"] as? [String: Any],
              let value = remoteObject["value"] as? String else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        var object = try Self.jsonObject(from: value)
        object["frameID"] = frameID
        if !parentFrameID.isEmpty {
            object["parentFrameID"] = parentFrameID
        }
        object["source"] = source
        return object
    }

    private func refreshPageMetadata() async throws {
        let page = try await currentPage()
        currentURL = page.url
        pageTitle = page.title
    }

    private func evaluate(script: String) async throws -> String {
        let response = try await sendCDPCommand(
            method: "Runtime.evaluate",
            params: [
                "expression": script,
                "awaitPromise": true,
                "returnByValue": true,
                "timeout": 5000
            ]
        )
        guard let result = response["result"] as? [String: Any],
              let remoteObject = result["result"] as? [String: Any] else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw ControlledBrowserError.commandFailed(String(describing: exception))
        }
        if let value = remoteObject["value"] as? String {
            return value
        }
        if let value = remoteObject["value"] {
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "value": value])
            return String(data: data, encoding: .utf8) ?? #"{"ok":true}"#
        }
        return #"{"ok":true}"#
    }

    @discardableResult
    private func sendCDPCommand(method: String, params: [String: Any]) async throws -> [String: Any] {
        let page = try await currentPage()
        guard let webSocketURL = URL(string: page.webSocketDebuggerURL) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }

        let id = Int.random(in: 1...1_000_000)
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        let deadline = Date().addingTimeInterval(8)
        try await Self.sendWebSocketMessage(.string(json), on: task, timeout: 4, operationName: "sending a browser command")

        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ControlledBrowserError.timedOut("waiting for a browser command response")
            }
            let message = try await Self.receiveWebSocketMessage(
                from: task,
                timeout: remaining,
                operationName: "waiting for a browser command response"
            )
            let data: Data
            switch message {
            case .data(let messageData):
                data = messageData
            case .string(let text):
                data = Data(text.utf8)
            @unknown default:
                continue
            }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard Self.responseID(from: object) == id else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                throw ControlledBrowserError.commandFailed(String(describing: error))
            }
            return object
        }
    }

    private func waitForDevTools() async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            do {
                _ = try await currentPage()
                return
            } catch {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw ControlledBrowserError.noInspectablePage
    }

    private func currentPage() async throws -> DevToolsPage {
        guard let debugPort else {
            throw ControlledBrowserError.missingDebugPort
        }
        var pages = try await devToolsPages(debugPort: debugPort)
        if pages.isEmpty {
            try await createInspectablePage(debugPort: debugPort)
            pages = try await devToolsPages(debugPort: debugPort)
        }

        let inspectablePages = pages.filter { $0.type == "page" && !$0.webSocketDebuggerURL.isEmpty }
        if inspectablePages.isEmpty {
            try await createInspectablePage(debugPort: debugPort)
            pages = try await devToolsPages(debugPort: debugPort)
        }

        let refreshedInspectablePages = pages.filter { $0.type == "page" && !$0.webSocketDebuggerURL.isEmpty }
        let page = refreshedInspectablePages.first { !currentURL.isEmpty && $0.url == currentURL }
            ?? refreshedInspectablePages.first { $0.url.hasPrefix("http://") || $0.url.hasPrefix("https://") }
            ?? refreshedInspectablePages.first { !$0.url.hasPrefix("chrome://") && !$0.url.hasPrefix("edge://") && !$0.url.hasPrefix("about:") }
            ?? refreshedInspectablePages.first
        guard let page else {
            throw ControlledBrowserError.noInspectablePage
        }
        return page
    }

    private func devToolsPages(debugPort: UInt16) async throws -> [DevToolsPage] {
        let url = URL(string: "http://127.0.0.1:\(debugPort)/json")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([DevToolsPage].self, from: data)
    }

    private func createInspectablePage(debugPort: UInt16) async throws {
        var components = URLComponents(string: "http://127.0.0.1:\(debugPort)/json/new")
        components?.percentEncodedQuery = "about%3Ablank"
        guard let url = components?.url else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 4
        _ = try await URLSession.shared.data(for: request)
    }

    private func browserWebSocketDebuggerURL(debugPort: UInt16) async throws -> String {
        try await devToolsVersion(debugPort: debugPort).webSocketDebuggerURL
    }

    private func devToolsVersion(debugPort: UInt16) async throws -> DevToolsVersion {
        let url = URL(string: "http://127.0.0.1:\(debugPort)/json/version")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(DevToolsVersion.self, from: data)
    }

    private func attachToExistingControlledBrowser() async -> Bool {
        guard let target = await Self.runningDebugTarget(profilePath: profilePath) else { return false }

        debugPort = target.debugPort
        attachedProcessID = target.processID
        process = nil
        processID = target.processID
        browserName = browserName ?? "Google Chrome"
        isRunning = true
        runState = .attached
        lastErrorMessage = nil
        statusMessage = "Attached to existing controlled browser"

        do {
            try await refreshPageMetadata()
            return true
        } catch {
            debugPort = nil
            attachedProcessID = nil
            processID = nil
            isRunning = false
            return false
        }
    }

    private static var defaultProfilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(AppChannel.current.appSupportDirectoryName)
            .appendingPathComponent("ControlledBrowser")
            .appendingPathComponent("Default")
            .path
    }

    private static func randomDebugPort() -> UInt16? {
        UInt16.random(in: 42_000...62_000)
    }

    nonisolated static func runningDebugTarget(profilePath: String) async -> ControlledBrowserDebugTarget? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runningDebugTargetSync(profilePath: profilePath))
            }
        }
    }

    private nonisolated static func runningDebugTargetSync(profilePath: String) -> ControlledBrowserDebugTarget? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return runningDebugTarget(profilePath: profilePath, processList: output)
    }

    nonisolated static func runningDebugTarget(profilePath: String, processList: String) -> ControlledBrowserDebugTarget? {
        let profileArgument = "--user-data-dir=\(profilePath)"
        let portArgument = "--remote-debugging-port="
        var matches: [(target: ControlledBrowserDebugTarget, isPrimaryBrowserProcess: Bool)] = []

        for rawLine in processList.split(separator: "\n") {
            let line = String(rawLine)
            guard line.contains(profileArgument),
                  let portRange = line.range(of: portArgument) else {
                continue
            }

            let pidText = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
            let portText = line[portRange.upperBound...].prefix(while: { $0.isNumber })
            guard let pidText,
                  let processID = pid_t(String(pidText)),
                  let debugPort = UInt16(portText) else {
                continue
            }

            let isPrimaryBrowserProcess = !line.contains(" --type=")
                && ControlledBrowserCandidate.defaultCandidates.contains { candidate in
                    line.contains(candidate.executablePath)
                }
            matches.append((
                target: ControlledBrowserDebugTarget(processID: processID, debugPort: debugPort),
                isPrimaryBrowserProcess: isPrimaryBrowserProcess
            ))
        }

        return matches.first(where: \.isPrimaryBrowserProcess)?.target ?? matches.first?.target
    }

    private nonisolated static func sendWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask,
        timeout: TimeInterval,
        operationName: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let box = CallbackBox<Void>()
            let timeoutItem = DispatchWorkItem {
                task.cancel(with: .goingAway, reason: nil)
                box.finish(.failure(ControlledBrowserError.timedOut(operationName)), continuation: continuation)
            }
            box.timeoutItem = timeoutItem
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            task.send(message) { error in
                if let error {
                    box.finish(.failure(error), continuation: continuation)
                } else {
                    box.finish(.success(()), continuation: continuation)
                }
            }
        }
    }

    private nonisolated static func receiveWebSocketMessage(
        from task: URLSessionWebSocketTask,
        timeout: TimeInterval,
        operationName: String
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let box = CallbackBox<URLSessionWebSocketTask.Message>()
            let timeoutItem = DispatchWorkItem {
                task.cancel(with: .goingAway, reason: nil)
                box.finish(.failure(ControlledBrowserError.timedOut(operationName)), continuation: continuation)
            }
            box.timeoutItem = timeoutItem
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            task.receive { result in
                box.finish(result, continuation: continuation)
            }
        }
    }

    private nonisolated static func responseID(from object: [String: Any]) -> Int? {
        if let id = object["id"] as? Int {
            return id
        }
        if let id = object["id"] as? NSNumber {
            return id.intValue
        }
        if let id = object["id"] as? String {
            return Int(id)
        }
        return nil
    }

    private nonisolated static func jsonObject(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        return object
    }

    private nonisolated static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ControlledBrowserError.invalidDevToolsResponse
        }
        return string
    }

    private nonisolated static func compactAccessibilityNode(_ node: [String: Any]) -> [String: Any] {
        var object: [String: Any] = [
            "nodeId": stringValue(node["nodeId"]),
            "backendDOMNodeId": stringValue(node["backendDOMNodeId"]),
            "ignored": boolValue(node["ignored"]),
            "role": compactAXValue(node["role"]),
            "name": compactAXValue(node["name"]),
            "value": compactAXValue(node["value"]),
            "description": compactAXValue(node["description"])
        ]
        if let properties = node["properties"] as? [[String: Any]] {
            object["properties"] = properties.prefix(20).map { property in
                [
                    "name": stringValue(property["name"]),
                    "value": compactAXValue(property["value"])
                ]
            }
        }
        return object
    }

    private nonisolated static func compactAXValue(_ value: Any?) -> [String: Any] {
        guard let object = value as? [String: Any] else {
            return ["value": stringValue(value)]
        }
        return [
            "type": stringValue(object["type"]),
            "value": stringValue(object["value"])
        ]
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private nonisolated static func stringValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        return ""
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private nonisolated static func flattenFrameTree(_ frameTree: [String: Any]) -> [[String: Any]] {
        var frames: [[String: Any]] = []
        if let frame = frameTree["frame"] as? [String: Any] {
            frames.append(frame)
        }
        let children = frameTree["childFrames"] as? [[String: Any]] ?? []
        for child in children {
            frames.append(contentsOf: flattenFrameTree(child))
        }
        return frames
    }

    private nonisolated static func cdpModifierMask(for modifiers: [String]) -> Int {
        let normalized = Set(modifiers.map { $0.lowercased() })
        var mask = 0
        if normalized.contains("option") || normalized.contains("alt") {
            mask |= 1
        }
        if normalized.contains("control") || normalized.contains("ctrl") {
            mask |= 2
        }
        if normalized.contains("command") || normalized.contains("cmd") || normalized.contains("meta") {
            mask |= 4
        }
        if normalized.contains("shift") {
            mask |= 8
        }
        return mask
    }

    private nonisolated static func keyDefinition(for key: String, modifiers: [String]) -> CDPKeyDefinition {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        switch lower {
        case "enter", "return":
            return CDPKeyDefinition(key: "Enter", code: "Enter", virtualKeyCode: 13, text: "\n")
        case "escape", "esc":
            return CDPKeyDefinition(key: "Escape", code: "Escape", virtualKeyCode: 27, text: nil)
        case "tab":
            return CDPKeyDefinition(key: "Tab", code: "Tab", virtualKeyCode: 9, text: "\t")
        case "backspace":
            return CDPKeyDefinition(key: "Backspace", code: "Backspace", virtualKeyCode: 8, text: nil)
        case "delete":
            return CDPKeyDefinition(key: "Delete", code: "Delete", virtualKeyCode: 46, text: nil)
        case "arrowleft", "left":
            return CDPKeyDefinition(key: "ArrowLeft", code: "ArrowLeft", virtualKeyCode: 37, text: nil)
        case "arrowup", "up":
            return CDPKeyDefinition(key: "ArrowUp", code: "ArrowUp", virtualKeyCode: 38, text: nil)
        case "arrowright", "right":
            return CDPKeyDefinition(key: "ArrowRight", code: "ArrowRight", virtualKeyCode: 39, text: nil)
        case "arrowdown", "down":
            return CDPKeyDefinition(key: "ArrowDown", code: "ArrowDown", virtualKeyCode: 40, text: nil)
        default:
            break
        }

        let scalar = trimmed.unicodeScalars.first
        let character = scalar.map(String.init) ?? trimmed
        let uppercase = character.uppercased()
        let shifted = modifiers.contains { $0.caseInsensitiveCompare("shift") == .orderedSame }
        let keyValue = shifted ? uppercase : character.lowercased()
        let code: String
        if let scalar, CharacterSet.letters.contains(scalar) {
            code = "Key\(uppercase)"
        } else if let scalar, CharacterSet.decimalDigits.contains(scalar) {
            code = "Digit\(character)"
        } else {
            code = trimmed.isEmpty ? "Unidentified" : trimmed
        }
        let virtualKeyCode = Int(uppercase.unicodeScalars.first?.value ?? 0)
        return CDPKeyDefinition(key: keyValue, code: code, virtualKeyCode: virtualKeyCode, text: keyValue)
    }

    private struct CDPKeyDefinition {
        let key: String
        let code: String
        let virtualKeyCode: Int
        let text: String?
    }

    private final class CallbackBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false
        var timeoutItem: DispatchWorkItem?

        func finish(_ result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            didFinish = true
            let item = timeoutItem
            timeoutItem = nil
            lock.unlock()

            item?.cancel()
            continuation.resume(with: result)
        }
    }

    private nonisolated static func isIframeTargetInfoScopedToPage(
        _ targetInfo: [String: Any],
        pageTargetID: String?,
        pageFrameIDs: Set<String>
    ) -> Bool {
        let pageTargetID = pageTargetID ?? ""
        if !pageTargetID.isEmpty, stringValue(targetInfo["openerId"]) == pageTargetID {
            return true
        }
        for key in ["openerFrameId", "parentFrameId"] {
            let frameID = stringValue(targetInfo[key])
            if !frameID.isEmpty, pageFrameIDs.contains(frameID) {
                return true
            }
        }
        return false
    }

    private nonisolated static func autoAttachedIframeTargets(
        from events: [[String: Any]],
        pageTargetID: String?,
        pageFrameIDs: Set<String>
    ) -> [AutoAttachedTarget] {
        events.compactMap { event in
            guard stringValue(event["method"]) == "Target.attachedToTarget",
                  let params = event["params"] as? [String: Any],
                  let targetInfo = params["targetInfo"] as? [String: Any],
                  stringValue(targetInfo["type"]) == "iframe",
                  isIframeTargetInfoScopedToPage(targetInfo, pageTargetID: pageTargetID, pageFrameIDs: pageFrameIDs) else {
                return nil
            }
            let sessionID = stringValue(params["sessionId"])
            let targetID = stringValue(targetInfo["targetId"])
            guard !sessionID.isEmpty, !targetID.isEmpty else { return nil }
            return AutoAttachedTarget(
                targetID: targetID,
                sessionID: sessionID,
                url: stringValue(targetInfo["url"]),
                title: stringValue(targetInfo["title"])
            )
        }
    }

    private nonisolated static func executionContextID(
        from events: [[String: Any]],
        sessionID: String?,
        frameID: String,
        worldName: String?
    ) -> Int? {
        for event in events.reversed() {
            guard stringValue(event["method"]) == "Runtime.executionContextCreated" else { continue }
            let eventSessionID = stringValue(event["sessionId"])
            if eventSessionID != (sessionID ?? "") {
                continue
            }
            guard let params = event["params"] as? [String: Any],
                  let context = params["context"] as? [String: Any],
                  let auxData = context["auxData"] as? [String: Any],
                  stringValue(auxData["frameId"]) == frameID else {
                continue
            }
            if let worldName, !worldName.isEmpty, stringValue(context["name"]) != worldName {
                continue
            }
            if worldName == nil {
                let isDefault = boolValue(auxData["isDefault"])
                if !isDefault, stringValue(context["name"]) == "ASTRAReadPage" {
                    return intValue(context["id"])
                }
                if !isDefault {
                    continue
                }
            }
            return intValue(context["id"])
        }
        return nil
    }

    private nonisolated static func mergePageReadFrames(
        _ incomingFrames: [[String: Any]],
        into frames: inout [[String: Any]]
    ) {
        for incoming in incomingFrames {
            let frameID = stringValue(incoming["frameID"])
            guard !frameID.isEmpty else {
                frames.append(incoming)
                continue
            }
            if let existingIndex = frames.firstIndex(where: { stringValue($0["frameID"]) == frameID }) {
                // Equal scores favor later reads because they usually come from a more specific
                // target/session pass after auto-attach or fallback routing has resolved.
                if pageReadFrameScore(incoming) >= pageReadFrameScore(frames[existingIndex]) {
                    frames[existingIndex] = incoming
                }
            } else {
                frames.append(incoming)
            }
        }
    }

    private nonisolated static func deduplicatedPageReadFrames(_ frames: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        mergePageReadFrames(frames, into: &result)
        return result
    }

    private nonisolated static func pageReadFrameScore(_ frame: [String: Any]) -> Int {
        let textLength = stringValue(frame["text"]).count
        let truncated = boolValue(frame["truncated"])
        let textScore = truncated ? min(textLength, 1_000) : textLength
        let accessibilityBonus = boolValue(frame["accessible"]) ? 10_000 : 0
        let completenessBonus = truncated ? 0 : 2_000
        let sourceBonus = stringValue(frame["source"]).contains("oopif") ? 100 : 0
        return accessibilityBonus + completenessBonus + sourceBonus + textScore
    }

    private nonisolated static func accessibilityText(
        from nodes: [[String: Any]],
        limit: Int
    ) -> AXTextExtraction {
        let boundedLimit = max(1_000, min(limit, 250_000))
        var pieces: [String] = []
        var textLength = 0
        var returnedLength = 0
        var truncated = false

        for node in nodes where !boolValue(node["ignored"]) {
            var valuesSeenInNode = Set<String>()
            let values = [
                axValueText(node["name"]),
                axValueText(node["value"]),
                axValueText(node["description"])
            ]
            for rawValue in values {
                let text = rawValue.replacingOccurrences(
                    of: "\\s+",
                    with: " ",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, valuesSeenInNode.insert(text).inserted else { continue }
                textLength += text.count + 1
                let separatorLength = pieces.isEmpty ? 0 : 1
                if returnedLength + separatorLength >= boundedLimit {
                    truncated = true
                    continue
                }
                let remaining = boundedLimit - returnedLength - separatorLength
                let next = text.count > remaining ? String(text.prefix(remaining)) : text
                pieces.append(next)
                returnedLength += separatorLength + next.count
                if text.count > remaining {
                    truncated = true
                }
            }
        }

        return AXTextExtraction(
            text: pieces.joined(separator: "\n"),
            textLength: textLength,
            truncated: truncated
        )
    }

    private nonisolated static func mergeAccessibilityText(
        _ extraction: AXTextExtraction,
        into frames: inout [[String: Any]],
        pageURL: String,
        pageTitle: String
    ) -> Bool {
        guard !extraction.text.isEmpty else { return false }
        let preferredIndex = frames.firstIndex {
            stringValue($0["parentFrameID"]).isEmpty && !stringValue($0["source"]).contains("oopif")
        }

        guard let index = preferredIndex else {
            frames.append([
                "frameID": "main",
                "url": pageURL,
                "title": pageTitle,
                "text": extraction.text,
                "textLength": extraction.textLength,
                "returnedTextLength": extraction.text.count,
                "truncated": extraction.truncated,
                "accessible": true,
                "source": "controlled_chromium_accessibility",
                "warnings": ["Accessibility tree text was used because DOM text was unavailable."]
            ])
            return true
        }

        let existingText = stringValue(frames[index]["text"])
        let existingTrimmedText = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentKind = stringValue(frames[index]["contentKind"])
        let accessibilityTextIsRicher = extraction.text.count > Int(Double(max(existingTrimmedText.count, 1)) * 1.5)
        let shouldMerge = existingTrimmedText.isEmpty
            || (contentKind == "canvas" && extraction.text.count > existingText.count)
            || accessibilityTextIsRicher
        guard shouldMerge else { return false }

        var frame = frames[index]
        var frameWarnings = frame["warnings"] as? [String] ?? []
        frameWarnings.append("Accessibility tree text was used because DOM text was empty, sparse, or canvas-rendered.")
        frame["text"] = extraction.text
        frame["textLength"] = extraction.textLength
        frame["returnedTextLength"] = extraction.text.count
        frame["truncated"] = extraction.truncated
        frame["accessible"] = true
        frame["source"] = stringValue(frame["source"]).isEmpty
            ? "controlled_chromium_accessibility"
            : "\(stringValue(frame["source"]))+accessibility"
        frame["warnings"] = Array(Set(frameWarnings)).sorted()
        frame.removeValue(forKey: "error")
        frames[index] = frame
        return true
    }

    private nonisolated static func axValueText(_ value: Any?) -> String {
        guard let object = value as? [String: Any] else {
            return stringValue(value)
        }
        return stringValue(object["value"])
    }

    private struct AutoAttachedTarget {
        let targetID: String
        let sessionID: String
        let url: String
        let title: String
    }

    private struct AXTextExtraction {
        let text: String
        let textLength: Int
        let truncated: Bool
    }

    private final class PersistentCDPDiagnosticsClient: @unchecked Sendable {
        private let configuration: URLSessionConfiguration
        private let session: URLSession
        private let task: URLSessionWebSocketTask
        private let queue = DispatchQueue(label: "com.coral.astra.controlled-browser.cdp-diagnostics")
        private var nextID = 1
        private var responses: [Int: [String: Any]] = [:]
        private var events: [[String: Any]] = []
        private var receiveTask: Task<Void, Never>?
        private var isClosed = false
        private var capabilities = ControlledBrowserCDPCapabilityReport(
            browser: "",
            protocolVersion: "",
            domains: [:],
            errors: [:]
        )

        init(webSocketURL: URL) {
            configuration = .ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 0
            session = URLSession(configuration: configuration)
            task = session.webSocketTask(with: webSocketURL)
        }

        func connect() async throws {
            task.resume()
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        }

        func close() {
            queue.sync {
                isClosed = true
            }
            receiveTask?.cancel()
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        func probeAndEnable(version: DevToolsVersion) async throws {
            var domains = try await schemaDomains()
            var errors: [String: String] = [:]
            let activeProbes: [(domain: String, method: String)] = [
                ("Runtime", "Runtime.enable"),
                ("Log", "Log.enable"),
                ("Network", "Network.enable"),
                ("Page", "Page.enable"),
                ("DOM", "DOM.enable")
            ]

            for probe in activeProbes {
                do {
                    _ = try await send(method: probe.method)
                    domains[probe.domain] = true
                } catch {
                    domains[probe.domain] = false
                    errors[probe.domain] = error.localizedDescription
                }
            }

            if domains["Accessibility"] == true {
                do {
                    _ = try await send(method: "Accessibility.getFullAXTree", params: ["interestingOnly": true])
                } catch {
                    domains["Accessibility"] = false
                    errors["Accessibility"] = error.localizedDescription
                }
            }

            queue.sync {
                capabilities = ControlledBrowserCDPCapabilityReport(
                    browser: version.browser,
                    protocolVersion: version.protocolVersion,
                    domains: domains,
                    errors: errors
                )
            }
        }

        func snapshot(url: String, title: String) -> [String: Any] {
            let state = queue.sync {
                (events, capabilities)
            }
            return ControlledBrowserCDPDiagnosticsFormatter.diagnosticsObject(
                url: url,
                title: title,
                events: state.0,
                capabilities: state.1
            )
        }

        private func schemaDomains() async throws -> [String: Bool] {
            do {
                let response = try await send(method: "Schema.getDomains")
                let rawDomains = ((response["result"] as? [String: Any])?["domains"] as? [[String: Any]]) ?? []
                var domains: [String: Bool] = [:]
                for domain in rawDomains {
                    let name = ControlledBrowserController.stringValue(domain["name"])
                    if !name.isEmpty {
                        domains[name] = true
                    }
                }
                return domains
            } catch {
                return [
                    "Runtime": false,
                    "Log": false,
                    "Network": false,
                    "Page": false,
                    "DOM": false,
                    "Accessibility": false,
                    "Input": false
                ]
            }
        }

        private func send(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
            let id = queue.sync {
                let value = nextID
                nextID += 1
                return value
            }

            let payload: [String: Any] = [
                "id": id,
                "method": method,
                "params": params
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let json = String(data: data, encoding: .utf8) else {
                throw ControlledBrowserError.invalidDevToolsResponse
            }
            try await ControlledBrowserController.sendWebSocketMessage(
                .string(json),
                on: task,
                timeout: 4,
                operationName: "sending a browser diagnostics command"
            )

            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                let response = queue.sync {
                    responses.removeValue(forKey: id)
                }
                if let response {
                    if let error = response["error"] as? [String: Any] {
                        throw ControlledBrowserError.commandFailed(String(describing: error))
                    }
                    return response
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw ControlledBrowserError.timedOut("waiting for a browser diagnostics command response")
        }

        private func receiveLoop() async {
            while !Task.isCancelled {
                let closed = queue.sync { isClosed }
                if closed { return }

                do {
                    let message = try await receiveWebSocketMessage()
                    let messageData: Data
                    switch message {
                    case .data(let data):
                        messageData = data
                    case .string(let text):
                        messageData = Data(text.utf8)
                    @unknown default:
                        continue
                    }
                    guard let object = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                        continue
                    }
                    record(object)
                } catch {
                    return
                }
            }
        }

        private func record(_ object: [String: Any]) {
            queue.sync {
                if let id = ControlledBrowserController.responseID(from: object) {
                    responses[id] = object
                    return
                }
                events.append(object)
                if events.count > 240 {
                    events.removeFirst(events.count - 240)
                }
            }
        }

        private func receiveWebSocketMessage() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                task.receive { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    // Operation-scoped and serial-only. Callers must not invoke send concurrently;
    // nextID and the event buffer intentionally avoid locking for this short-lived read path.
    private final class OperationCDPClient: @unchecked Sendable {
        private let configuration: URLSessionConfiguration
        private let session: URLSession
        private let task: URLSessionWebSocketTask
        private var nextID = 1
        private(set) var events: [[String: Any]] = []

        init(webSocketURL: URL) {
            configuration = .ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 20
            session = URLSession(configuration: configuration)
            task = session.webSocketTask(with: webSocketURL)
        }

        func connect() async throws {
            task.resume()
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        func drainEvents() -> [[String: Any]] {
            let drained = events
            events.removeAll()
            return drained
        }

        func send(
            method: String,
            params: [String: Any] = [:],
            sessionID: String? = nil
        ) async throws -> [String: Any] {
            let id = nextID
            nextID += 1
            var payload: [String: Any] = [
                "id": id,
                "method": method,
                "params": params
            ]
            if let sessionID, !sessionID.isEmpty {
                payload["sessionId"] = sessionID
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let json = String(data: data, encoding: .utf8) else {
                throw ControlledBrowserError.invalidDevToolsResponse
            }

            try await ControlledBrowserController.sendWebSocketMessage(
                .string(json),
                on: task,
                timeout: 4,
                operationName: "sending a browser command"
            )

            let deadline = Date().addingTimeInterval(10)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    throw ControlledBrowserError.timedOut("waiting for a browser command response")
                }
                let message = try await ControlledBrowserController.receiveWebSocketMessage(
                    from: task,
                    timeout: remaining,
                    operationName: "waiting for a browser command response"
                )
                let messageData: Data
                switch message {
                case .data(let data):
                    messageData = data
                case .string(let text):
                    messageData = Data(text.utf8)
                @unknown default:
                    continue
                }
                guard let object = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    continue
                }
                if ControlledBrowserController.responseID(from: object) == id {
                    if let error = object["error"] as? [String: Any] {
                        throw ControlledBrowserError.commandFailed(String(describing: error))
                    }
                    return object
                }
                events.append(object)
            }
        }
    }

    private struct DevToolsPage: Decodable {
        let id: String?
        let type: String
        let title: String
        let url: String
        let webSocketDebuggerURL: String

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case title
            case url
            case webSocketDebuggerURL = "webSocketDebuggerUrl"
        }
    }

    private struct DevToolsVersion: Decodable {
        let webSocketDebuggerURL: String
        let browser: String
        let protocolVersion: String

        enum CodingKeys: String, CodingKey {
            case webSocketDebuggerURL = "webSocketDebuggerUrl"
            case browser = "Browser"
            case protocolVersion = "Protocol-Version"
        }
    }
}
