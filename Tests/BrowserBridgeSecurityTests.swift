import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Bridge Security")
struct BrowserBridgeSecurityTests {
    @Test("Bridge requires per-session access token")
    func bridgeRequiresAccessToken() async throws {
        let endpoint = LockedEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "session-token", route: { request in
            .json(["ok": true, "path": request.path])
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }

        let baseURL = try await endpoint.waitForURL()
        let rejected = try await httpGet(baseURL.appendingPathComponent("health"), token: nil)
        #expect(rejected.statusCode == 403)
        #expect(rejected.body.contains("unauthorized_browser_bridge_request"))

        let accepted = try await httpGet(baseURL.appendingPathComponent("health"), token: "session-token")
        #expect(accepted.statusCode == 200)
        #expect(accepted.body.contains(#""ok" : true"#) || accepted.body.contains(#""ok":true"#))
    }

    @Test("Bridge accepts explicit token header")
    func bridgeAcceptsExplicitTokenHeader() async throws {
        let endpoint = LockedEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "session-token", route: { request in
            .json(["ok": request.headerValue("x-astra-browser-token") == "session-token"])
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }

        let baseURL = try await endpoint.waitForURL()
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.setValue("session-token", forHTTPHeaderField: "X-ASTRA-Browser-Token")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        let body = String(data: data, encoding: .utf8) ?? ""

        #expect(statusCode == 200)
        #expect(body.contains(#""ok" : true"#) || body.contains(#""ok":true"#))
    }

    @Test("Bridge command contracts normalize decoded targeting fields")
    func bridgeCommandContractsNormalizeDecodedTargetingFields() throws {
        let clickJSON = Data("""
        {
          "analysisID": " analysis-1 ",
          "controlID": " control-2 ",
          "selector": " button[data-id='submit'] ",
          "label": " Submit ",
          "role": " button ",
          "placeholder": " ",
          "testID": "",
          "allowDangerous": true
        }
        """.utf8)
        let click = try JSONDecoder().decode(ClickCommand.self, from: clickJSON)

        #expect(click.normalizedSelector == "button[data-id='submit']")
        #expect(click.normalizedLabel == "Submit")
        #expect(click.normalizedRole == "button")
        #expect(click.normalizedPlaceholder == nil)
        #expect(click.normalizedTestID == nil)
        #expect(click.hasAnalysisControl)
        #expect(click.allowDangerous == true)

        let batchJSON = Data("""
        {
          "actions": [
            {
              "action": " CLICK ",
              "analysisID": "analysis-1",
              "controlID": " ",
              "selector": " button.primary "
            }
          ],
          "snapshotMode": "summary",
          "snapshotLimit": 12
        }
        """.utf8)
        let batch = try JSONDecoder().decode(BatchCommand.self, from: batchJSON)
        let action = try #require(batch.actions.first)

        #expect(action.normalizedAction == "click")
        #expect(action.normalizedSelector == "button.primary")
        #expect(!action.hasAnalysisControl)
        #expect(batch.snapshotMode == "summary")
        #expect(batch.snapshotLimit == 12)
    }

    @Test("Bridge command router recognizes every published action")
    func bridgeCommandRouterRecognizesEveryPublishedAction() throws {
        let actions = ShelfBrowserBridgeCommandRouter.actionMetadata(
            canUseGoogleDriveOpen: false,
            googleDriveOpenDefaultTimeoutSeconds: 24
        )

        for action in actions {
            let method = try #require(action["method"] as? String)
            let path = try #require(action["path"] as? String)
            #expect(
                ShelfBrowserBridgeCommandRouter.route(method: method, path: path) != nil,
                "Missing route for \(method) \(path)"
            )
        }

        #expect(ShelfBrowserBridgeCommandRouter.route(method: "get", path: "/actions") == .actions)
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "POST", path: "/missing") == nil)
    }

    @Test("Bridge actions response preserves metadata contract")
    func bridgeActionsResponsePreservesMetadataContract() throws {
        let response = ShelfBrowserBridgeCommandRouter.actionsResponse(
            backend: "controlled Chromium profile",
            capabilities: ["actions", "google.drive.open"],
            canUseGoogleDriveOpen: true,
            googleDriveOpenDefaultTimeoutSeconds: 24
        )

        #expect(response["ok"] as? Bool == true)
        #expect(response["backend"] as? String == "controlled Chromium profile")
        #expect(response["actionMetadataVersion"] as? Int == 1)
        #expect(response["capabilities"] as? [String] == ["actions", "google.drive.open"])

        let actions = try #require(response["actions"] as? [[String: Any]])
        let paths = Set(actions.compactMap { $0["path"] as? String })
        #expect(paths.contains("/actions"))
        #expect(paths.contains("/googleDriveOpen"))

        let driveOpen = try #require(actions.first { ($0["path"] as? String) == "/googleDriveOpen" })
        #expect(driveOpen["enabled"] as? Bool == true)
        #expect(driveOpen["adapterID"] as? String == BrowserSiteAdapterID.googleDrive)

        let body = try #require(driveOpen["body"] as? [String: Any])
        #expect(body["name"] as? String == "Untitled document")
        #expect(body["timeoutSeconds"] as? Double == 24)
    }

    private func httpGet(_ url: URL, token: String?) async throws -> (statusCode: Int, body: String) {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        return (statusCode, String(data: data, encoding: .utf8) ?? "")
    }
}

private actor LockedEndpoint {
    private var value: String?

    func set(_ nextValue: String?) {
        value = nextValue
    }

    func waitForURL() async throws -> URL {
        for _ in 0..<100 {
            let snapshot = value
            if let snapshot, let url = URL(string: snapshot) {
                return url
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw BrowserBridgeSecurityTestError.endpointUnavailable
    }
}

private enum BrowserBridgeSecurityTestError: Error {
    case endpointUnavailable
}
