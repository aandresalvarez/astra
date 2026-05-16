import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Page Read Service")
struct BrowserPageReadServiceTests {
    @Test("response reports full coverage for readable untruncated frames")
    func responseReportsFullCoverage() throws {
        let response = BrowserPageReadService.response(
            url: "https://example.com",
            title: "Example",
            engine: "embedded",
            backend: "embedded WebKit",
            format: "markdown",
            limit: 10_000,
            chunkSize: 2_000,
            frames: [
                [
                    "frameID": "main",
                    "url": "https://example.com",
                    "title": "Example",
                    "text": "Readable page text",
                    "textLength": 18,
                    "accessible": true,
                    "source": "test"
                ]
            ]
        )

        #expect(response["coverage"] as? String == "full")
        #expect(response["truncated"] as? Bool == false)
        #expect((response["content"] as? String ?? "").contains("# Example"))
        #expect((response["chunks"] as? [[String: Any]])?.count == 1)
    }

    @Test("response reports partial coverage for inaccessible frames")
    func responseReportsPartialCoverage() throws {
        let response = BrowserPageReadService.response(
            url: "https://example.com",
            title: "Example",
            engine: "embedded",
            backend: "embedded WebKit",
            format: "text",
            limit: 10_000,
            chunkSize: 2_000,
            frames: [
                [
                    "frameID": "main",
                    "url": "https://example.com",
                    "title": "Example",
                    "text": "Readable page text",
                    "accessible": true,
                    "source": "test"
                ],
                [
                    "frameID": "main.0",
                    "url": "https://third-party.example/frame",
                    "title": "Third party",
                    "accessible": false,
                    "source": "test",
                    "error": "frame_report_unavailable"
                ]
            ]
        )

        #expect(response["coverage"] as? String == "partial")
        let frames = try #require(response["frames"] as? [[String: Any]])
        #expect(frames.count == 2)
        #expect((frames[1]["error"] as? String) == "frame_report_unavailable")
    }

    @Test("response chunks and marks combined truncation")
    func responseChunksAndTruncates() throws {
        let response = BrowserPageReadService.response(
            url: "https://example.com",
            title: "Example",
            engine: "controlled",
            backend: "controlled Chromium profile",
            format: "text",
            limit: 2_500,
            chunkSize: 1_000,
            frames: [
                [
                    "frameID": "main",
                    "url": "https://example.com",
                    "title": "Example",
                    "text": String(repeating: "a", count: 3_000),
                    "accessible": true,
                    "source": "test"
                ]
            ]
        )

        #expect(response["coverage"] as? String == "partial")
        #expect(response["truncated"] as? Bool == true)
        #expect((response["content"] as? String ?? "").count == 2_500)
        #expect((response["chunks"] as? [[String: Any]])?.count == 3)
    }

    @Test("response reports unknown coverage when no frames are readable")
    func responseReportsUnknownCoverageWithoutReadableFrames() {
        let response = BrowserPageReadService.response(
            url: "https://example.com",
            title: "Example",
            engine: "embedded",
            backend: "embedded WebKit",
            format: "text",
            limit: 10_000,
            chunkSize: 2_000,
            frames: []
        )

        #expect(response["coverage"] as? String == "unknown")
        #expect(response["readableFrameCount"] as? Int == 0)
        #expect((response["warnings"] as? [String] ?? []).contains("No readable frame reports were returned."))
    }

    @Test("responseFromSnapshot preserves compact snapshot content")
    func responseFromSnapshotPreservesContent() throws {
        let response = BrowserPageReadService.responseFromSnapshot(
            [
                "url": "https://example.com",
                "title": "Example",
                "text": "Compact snapshot text"
            ],
            engine: "controlled",
            backend: "controlled Chromium profile",
            format: "text",
            limit: 10_000,
            chunkSize: 2_000
        )

        #expect(response["coverage"] as? String == "full")
        #expect(response["frameCount"] as? Int == 1)
        #expect((response["diagnostics"] as? [String: Any])?["source"] as? String == "snapshot")
        #expect((response["content"] as? String ?? "").contains("Compact snapshot text"))
    }

    @Test("chunks split cleanly on exact boundaries")
    func chunksSplitOnExactBoundaries() throws {
        let frames: [[String: Any]] = [
            [
                "frameID": "main",
                "url": "https://example.com",
                "title": "Example",
                "text": String(repeating: "a", count: 1_200),
                "accessible": true,
                "source": "test"
            ]
        ]
        let baseline = BrowserPageReadService.response(
            url: "https://example.com",
            title: "Example",
            engine: "controlled",
            backend: "controlled Chromium profile",
            format: "text",
            limit: 10_000,
            chunkSize: 8_000,
            frames: frames
        )
        let exactChunkSize = try #require((baseline["content"] as? String)?.count)

        let response = BrowserPageReadService.response(
            url: "https://example.com",
            title: "Example",
            engine: "controlled",
            backend: "controlled Chromium profile",
            format: "text",
            limit: 10_000,
            chunkSize: exactChunkSize,
            frames: frames
        )

        let chunks = try #require(response["chunks"] as? [[String: Any]])
        #expect(chunks.count == 1)
        #expect((chunks[0]["text"] as? String ?? "").count == exactChunkSize)
    }

    @Test("scripts expose embedded reporter and controlled frame reader")
    func scriptsExposePageReadHooks() {
        let embedded = BrowserAutomationScripts.embeddedPageReadReporterScript()
        let dispatch = BrowserAutomationScripts.embeddedPageReadDispatchScript(requestID: "rid", limit: 50_000)
        let controlled = BrowserAutomationScripts.pageReadFrameScript(limit: 50_000)

        #expect(embedded.contains("window.webkit.messageHandlers.astraPageRead.postMessage"))
        #expect(embedded.contains("window.__astraPageReadHandleRequest"))
        #expect(embedded.contains("event.source !== window.parent"))
        #expect(dispatch.contains("__astraPageRead: true"))
        #expect(dispatch.contains("dispatched"))
        #expect(!dispatch.contains("window.postMessage(request"))
        #expect(controlled.contains("__astraCollectPageReadFrame"))
        #expect(controlled.contains("controlled_chromium"))
    }
}
