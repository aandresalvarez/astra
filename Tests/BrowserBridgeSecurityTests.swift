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
