import Foundation
import Darwin
import Testing
import WebKit
@testable import ASTRA

@Suite("Browser Bridge Security")
struct BrowserBridgeSecurityTests {
    @Test("Embedded preview blocks WebKit file and media pickers")
    func embeddedPreviewBlocksWebKitFileAndMediaPickers() {
        #expect(ShelfBrowserPrivacyBoundary.blocksEmbeddedPreviewFilePickers)
        #expect(ShelfBrowserPrivacyBoundary.blocksEmbeddedPreviewMediaCapture)
    }

    @Test("Embedded preview uses an ephemeral WebKit data store")
    @MainActor
    func embeddedPreviewUsesEphemeralWebKitDataStore() {
        let configuration = ShelfBrowserWebViewConfigurationFactory.makeEmbeddedConfiguration(
            pageReadMessageHandler: NoopScriptMessageHandler()
        )

        #expect(ShelfBrowserPrivacyBoundary.usesEphemeralEmbeddedPreviewDataStore)
        #expect(!configuration.websiteDataStore.isPersistent)
    }

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

    @Test("Bridge rate limiter blocks bursts and refills after the window")
    func bridgeRateLimiterBlocksBurstsAndRefills() {
        let clock = RateLimitClock(now: Date(timeIntervalSince1970: 100))
        let limiter = BrowserBridgeRateLimiter(
            maxRequests: 2,
            window: 1,
            now: { clock.now }
        )

        #expect(limiter.allowsRequest())
        #expect(limiter.allowsRequest())
        #expect(!limiter.allowsRequest())

        clock.now = Date(timeIntervalSince1970: 101.1)
        #expect(limiter.allowsRequest())
    }

    @Test("Unauthorized bridge requests do not consume the authorized request limiter")
    func unauthorizedBridgeRequestsDoNotConsumeAuthorizedLimiter() async throws {
        let endpoint = LockedEndpoint()
        let limiter = BrowserBridgeRateLimiter(maxRequests: 1, window: 60)
        let server = BrowserBridgeServer(
            requiredAccessToken: "session-token",
            rateLimiter: limiter,
            route: { _ in .json(["ok": true]) },
            onEndpointChanged: { value in
                Task { await endpoint.set(value) }
            }
        )
        server.start()
        defer { server.stop() }

        let baseURL = try await endpoint.waitForURL()
        let unauthorized = try await httpGet(baseURL.appendingPathComponent("health"), token: "wrong-token")
        #expect(unauthorized.statusCode == 403)

        let authorized = try await httpGet(baseURL.appendingPathComponent("health"), token: "session-token")
        #expect(authorized.statusCode == 200)
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
        #expect(BrowserDangerousActionApproval.trustedProviderApproval(click.allowDangerous) == false)

        let batchJSON = Data("""
        {
          "actions": [
            {
              "action": " CLICK ",
              "analysisID": "analysis-1",
              "controlID": " ",
              "selector": " button.primary ",
              "allowDangerous": true
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
        #expect(action.allowDangerous == true)
        #expect(BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous) == false)
        #expect(batch.snapshotMode == "summary")
        #expect(batch.snapshotLimit == 12)
    }

    @Test("Bridge navigation policy rejects local file targets")
    func bridgeNavigationPolicyRejectsLocalFileTargets() {
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "file:///etc/passwd") == nil)
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "/etc/passwd") == nil)
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "~/Library/Keychains/login.keychain-db") == nil)
    }

    @Test("Bridge navigation policy rejects malformed web targets without hosts")
    func bridgeNavigationPolicyRejectsMalformedWebTargets() {
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "https:") == nil)
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "https:///missing-host") == nil)
    }

    @Test("Bridge navigation policy allows web targets")
    func bridgeNavigationPolicyAllowsWebTargets() throws {
        let explicit = try #require(BrowserBridgeNavigationPolicy.normalizedProviderURL(
            from: "https://docs.google.com/document/d/example/edit"
        ))
        let hostname = try #require(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "outlook.office.com"))

        #expect(explicit.absoluteString == "https://docs.google.com/document/d/example/edit")
        #expect(hostname.absoluteString == "https://outlook.office.com")
    }

    @Test("Bridge open control navigation rejects unsafe hrefs before activation fallback")
    func bridgeOpenControlNavigationRejectsUnsafeHrefsBeforeFallback() throws {
        #expect(BrowserBridgeNavigationPolicy.openControlNavigation(forHref: "") == .fallbackToActivation)
        #expect(BrowserBridgeNavigationPolicy.openControlNavigation(forHref: "file:///etc/passwd") == .reject)

        let decision = BrowserBridgeNavigationPolicy.openControlNavigation(forHref: "https://docs.google.com/document/d/example/edit")
        guard case let .navigate(url) = decision else {
            Issue.record("Expected web href to navigate, got \(decision)")
            return
        }
        #expect(url.absoluteString == "https://docs.google.com/document/d/example/edit")
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

    @Test("Bridge command router centralizes request accounting policy")
    func bridgeCommandRouterCentralizesRequestAccountingPolicy() throws {
        let unaccountedRoutes: Set<ShelfBrowserBridgeRoute> = [
            .health,
            .actions,
            .trace,
            .benchmark
        ]

        for route in ShelfBrowserBridgeRoute.allCases {
            #expect(route.isFlightRecorded == !unaccountedRoutes.contains(route))
            #expect(route.isRunGuarded == !unaccountedRoutes.contains(route))
            #expect(route.isAvailableWhenBridgeDisabled == (route == .health || route == .actions))
        }
    }

    @Test("Bridge command router enforces route methods")
    func bridgeCommandRouterEnforcesRouteMethods() throws {
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "POST", path: "/health") == nil)
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "GET", path: "/navigate") == nil)
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "GET", path: "/click") == nil)
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "POST", path: "/snapshot") == nil)
    }

    @Test("Bridge actions response preserves metadata contract")
    func bridgeActionsResponsePreservesMetadataContract() throws {
        let response = ShelfBrowserBridgeCommandRouter.actionsResponse(
            backend: "controlled Chromium profile",
            automationEngine: BrowserAutomationEngineDescriptor(kind: .controlledCDP),
            capabilities: ["actions", "google.drive.open"],
            canUseGoogleDriveOpen: true,
            googleDriveOpenDefaultTimeoutSeconds: 24
        )

        #expect(response["ok"] as? Bool == true)
        #expect(response["backend"] as? String == "controlled Chromium profile")
        let engine = try #require(response["automationEngine"] as? [String: Any])
        #expect(engine["kind"] as? String == "controlled-cdp")
        #expect(engine["providerToolName"] as? String == "astra-browser")
        #expect(engine["exposesRawDebugEndpoint"] as? Bool == false)
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

    @Test("Malformed negative Content-Length receives 400 instead of crashing parser")
    func malformedNegativeContentLengthReceivesBadRequest() async throws {
        let endpoint = LockedEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: nil, route: { _ in
            .json(["ok": true])
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }

        let baseURL = try await endpoint.waitForURL()
        let response = try rawHTTP(
            to: baseURL,
            request: "POST /health HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        )

        #expect(response.contains("HTTP/1.1 400 Bad Request"))
        #expect(response.contains("invalid_content_length"))
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

    private func rawHTTP(to baseURL: URL, request: String) throws -> String {
        let port = try #require(baseURL.port)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowserBridgeSecurityTestError.socketFailed }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw BrowserBridgeSecurityTestError.socketFailed
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw BrowserBridgeSecurityTestError.socketFailed }

        let bytes = Array(request.utf8)
        try bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let written = Darwin.write(fd, baseAddress, bytes.count)
            guard written == bytes.count else { throw BrowserBridgeSecurityTestError.socketFailed }
        }
        shutdown(fd, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = Darwin.read(fd, &buffer, buffer.count)
            if readCount > 0 {
                data.append(buffer, count: readCount)
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class NoopScriptMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
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
    case socketFailed
}

private final class RateLimitClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
