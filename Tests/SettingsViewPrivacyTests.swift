import Foundation
import Testing

@Suite("Settings Privacy Copy")
struct SettingsViewPrivacyTests {
    @Test("Browser debug capture disclosure warns about visible screenshot content")
    func browserDebugCaptureDisclosureWarnsAboutVisibleScreenshotContent() throws {
        let source = try settingsViewSource()

        #expect(source.contains("Browser Debug Capture"))
        #expect(source.contains("screenshot thumbnail that may contain visible page content"))
        #expect(source.contains("Controlled Chromium uses probed CDP event streams"))
        #expect(source.contains("embedded WebKit uses page instrumentation"))
    }

    @Test("Readiness section copy scopes checks to default provider")
    func readinessSectionCopyScopesChecksToDefaultProvider() throws {
        let source = try settingsViewSource()

        #expect(source.contains(#"Section("Default Provider Readiness")"#))
        #expect(source.contains("Run a readiness check to verify the default provider"))
        #expect(!source.contains(#"Section("Technical Readiness")"#))
    }

    private func settingsViewSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Astra/Views/SettingsView.swift"),
            encoding: .utf8
        )
    }
}
