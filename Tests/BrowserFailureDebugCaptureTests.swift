import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Failure Debug Capture", .serialized)
struct BrowserFailureDebugCaptureTests {
    @Test("Debug capture is failure-only and enabled by default")
    func debugCapturePolicyAndTrigger() {
        let suiteName = "astra-browser-debug-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultRequest = BrowserBridgeRequest(
            method: "POST",
            path: "/click",
            headers: [:],
            queryItems: [:],
            body: Data()
        )
        let optedInRequest = BrowserBridgeRequest(
            method: "POST",
            path: "/click",
            headers: ["x-astra-browser-debug-capture": "1"],
            queryItems: [:],
            body: Data()
        )

        #expect(BrowserFailureDebugCapture.policy(for: defaultRequest, environment: [:], defaults: defaults).isEnabled == true)

        defaults.set(false, forKey: AppStorageKeys.browserDebugCapture)
        #expect(BrowserFailureDebugCapture.policy(for: defaultRequest, environment: [:], defaults: defaults).isEnabled == false)
        #expect(BrowserFailureDebugCapture.policy(for: optedInRequest, environment: [:], defaults: defaults).isEnabled == true)
        #expect(BrowserFailureDebugCapture.policy(for: defaultRequest, environment: ["ASTRA_BROWSER_DEBUG_CAPTURE": "true"], defaults: defaults).isEnabled == true)
        #expect(BrowserFailureDebugCapture.policy(for: defaultRequest, environment: ["ASTRA_BROWSER_DEBUG_CAPTURE": "0"], defaults: defaults).isEnabled == false)
        #expect(BrowserFailureDebugCapture.shouldCapture(statusCode: 200, result: ["ok": true]) == false)
        #expect(BrowserFailureDebugCapture.shouldCapture(statusCode: 500, result: ["ok": true]) == true)
        #expect(BrowserFailureDebugCapture.shouldCapture(statusCode: 200, result: ["ok": false, "error": "target_obscured"]) == true)
        #expect(BrowserFailureDebugCapture.shouldCapture(statusCode: 200, result: ["ok": true, "loopWarning": "unchanged"]) == true)
    }

    @Test("Settings toggle injects debug capture environment for browser tasks")
    @MainActor
    func settingsToggleInjectsDebugCaptureEnvironment() throws {
        let key = AppStorageKeys.browserDebugCapture
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            ShelfBrowserBridgeRegistry.shared.reset()
        }

        let taskID = UUID()
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.com",
            currentTitle: "Example",
            taskID: taskID,
            isPresented: true,
            isEnabled: true
        )

        UserDefaults.standard.removeObject(forKey: key)
        #expect(ShelfBrowserBridgeRegistry.shared.environmentVariables(for: taskID)[BrowserFailureDebugCapture.environmentVariable] == "1")

        UserDefaults.standard.set(false, forKey: key)
        #expect(ShelfBrowserBridgeRegistry.shared.environmentVariables(for: taskID)[BrowserFailureDebugCapture.environmentVariable] == nil)

        UserDefaults.standard.set(true, forKey: key)
        #expect(ShelfBrowserBridgeRegistry.shared.environmentVariables(for: taskID)[BrowserFailureDebugCapture.environmentVariable] == "1")
    }

    @Test("Compact snapshot tree redacts URLs and hashes page text fields")
    func compactSnapshotTreeRedactsText() throws {
        let compact = BrowserFailureDebugCapture.compactSnapshotTree(from: [
            "url": "https://docs.google.com/document/d/abc/edit?token=secret#frag",
            "title": "Private Document",
            "controls": [[
                "tag": "button",
                "role": "button",
                "type": "button",
                "label": "Private Label",
                "selector": "button[aria-label='Private Label']",
                "href": "https://example.com/action?token=secret#frag",
                "disabled": false,
                "actionable": true,
                "bounds": ["x": 1, "y": 2, "width": 3, "height": 4]
            ]]
        ])

        #expect(compact["url"] as? String == "https://docs.google.com/document/d/abc/edit")
        let controls = try #require(compact["controls"] as? [[String: Any]])
        let control = try #require(controls.first)
        #expect(control["href"] as? String == "https://example.com/action")

        let label = try #require(control["label"] as? [String: Any])
        let selector = try #require(control["selector"] as? [String: Any])
        #expect(label["length"] as? Int == "Private Label".count)
        #expect(label["hash"] as? String != nil)
        #expect(label["preview"] == nil)
        #expect(selector["hash"] as? String != nil)
    }

    @Test("Console and network event summaries strip URL secrets")
    func compactDebugEventsRedactsURLSecrets() throws {
        let compact = BrowserFailureDebugCapture.compactDebugEvents(from: [
            "ok": true,
            "url": "https://example.com/page?token=secret#frag",
            "title": "Example",
            "consoleEvents": [[
                "level": "error",
                "message": "Failed loading https://example.com/api?token=secret#frag",
                "source": "https://example.com/app.js?build=secret#frag",
                "line": 12
            ]],
            "navigationEvents": [[
                "type": "load",
                "url": "https://example.com/page?token=secret#frag"
            ]],
            "networkEvents": [[
                "type": "fetch",
                "url": "https://example.com/api?token=secret#frag",
                "status": 500
            ]]
        ])

        #expect(compact["url"] as? String == "https://example.com/page")
        let consoleEvents = try #require(compact["consoleEvents"] as? [[String: Any]])
        let consoleEvent = try #require(consoleEvents.first)
        let message = try #require(consoleEvent["message"] as? [String: Any])
        #expect((message["preview"] as? String)?.contains("token=secret") == false)
        #expect(consoleEvent["source"] as? String == "https://example.com/app.js")

        let networkEvents = try #require(compact["networkEvents"] as? [[String: Any]])
        #expect(networkEvents.first?["url"] as? String == "https://example.com/api")
    }
}
