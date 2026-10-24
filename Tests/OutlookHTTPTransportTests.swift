import Foundation
import Testing
@testable import ASTRA

@Suite("Bounded Outlook HTTP transport", .serialized)
struct OutlookHTTPTransportTests {
    @Test("Real URLSession refuses a redirect without replaying the bearer token")
    func actualRedirectIsRefused() async throws {
        let server = try await RedirectingHTTPServer.start()
        defer { server.stop() }
        var request = URLRequest(url: server.url(path: RedirectingHTTPServer.writePath))
        request.setValue("Bearer synthetic-transport-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSessionOutlookHTTPTransport().data(for: request, maximumBytes: 100)
        #expect(response.statusCode == 307)
        #expect(data.isEmpty)
        #expect(server.requests.map(\.path) == [RedirectingHTTPServer.writePath])
    }

    @Test("The exact response limit is accepted, with or without a size header", arguments: [true, false])
    func exactLimitIsComplete(declared: Bool) async throws {
        let server = try await RedirectingHTTPServer.start(body: "1234", declaredLength: declared)
        defer { server.stop() }
        let (data, response) = try await URLSessionOutlookHTTPTransport().data(
            for: URLRequest(url: server.url(path: "/body")), maximumBytes: 4)
        #expect(response.statusCode == 200)
        #expect(data == Data("1234".utf8))
    }

    @Test("Oversized responses are refused instead of truncated, including unknown-length streams", arguments: [true, false])
    func oversizeIsNeverPartialSuccess(declared: Bool) async throws {
        let server = try await RedirectingHTTPServer.start(body: String(repeating: "x", count: 65_537), declaredLength: declared)
        defer { server.stop() }
        do {
            _ = try await URLSessionOutlookHTTPTransport().data(for: URLRequest(url: server.url(path: "/body")), maximumBytes: 65_536)
            Issue.record("Returned a truncated or oversized response")
        } catch OutlookHTTPFailure.responseTooLarge {}
    }
}
