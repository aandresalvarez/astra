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

    static let defaultCandidates: [ControlledBrowserCandidate] = [
        .init(name: "Google Chrome", executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        .init(name: "Microsoft Edge", executablePath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        .init(name: "Brave Browser", executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
        .init(name: "Chromium", executablePath: "/Applications/Chromium.app/Contents/MacOS/Chromium"),
        .init(name: "Google Chrome", executablePath: "\(NSHomeDirectory())/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        .init(name: "Microsoft Edge", executablePath: "\(NSHomeDirectory())/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
    ]

    static func firstAvailable(fileManager: FileManager = .default) -> ControlledBrowserCandidate? {
        defaultCandidates.first { fileManager.isExecutableFile(atPath: $0.executablePath) }
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

    var isLaunching: Bool {
        runState == .launching
    }

    deinit {
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
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        _ = try await evaluate(script: BrowserAutomationScripts.debugInstrumentationScript)
    }

    func debugEvents() async throws -> String {
        try await ensureLaunched(initialURL: URL(string: "about:blank"))
        let value = try await evaluate(script: BrowserAutomationScripts.debugReadScript)
        try await refreshPageMetadata()
        return value
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
}
