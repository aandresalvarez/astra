import Foundation
import Testing

@Suite("Settings Privacy Copy")
struct SettingsViewPrivacyTests {
    @Test("Browser debug capture disclosure warns about visible screenshot content")
    func browserDebugCaptureDisclosureWarnsAboutVisibleScreenshotContent() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Astra/Views/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("Browser Debug Capture"))
        #expect(source.contains("screenshot thumbnail that may contain visible page content"))
        #expect(source.contains("Controlled Chromium uses probed CDP event streams"))
        #expect(source.contains("embedded WebKit uses page instrumentation"))
    }
}
