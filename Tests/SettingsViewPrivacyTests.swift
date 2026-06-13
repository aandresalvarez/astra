import Foundation
import Testing
@testable import ASTRA

@Suite("Settings Privacy Copy")
struct SettingsViewPrivacyTests {
    @Test("Runtime guardrails disclose the always-on ASTRA host privacy boundary")
    func runtimeGuardrailsDiscloseHostPrivacyBoundary() throws {
        let source = try settingsViewSource()

        #expect(RuntimeGuardrailsPresentation.hostPrivacyTitle == "ASTRA App Privacy Boundary")
        #expect(RuntimeGuardrailsPresentation.hostPrivacyStatus == "Always On")
        #expect(RuntimeGuardrailsPresentation.hostPrivacyDetail.contains("Photos"))
        #expect(RuntimeGuardrailsPresentation.hostPrivacyDetail.contains("Music"))
        #expect(RuntimeGuardrailsPresentation.hostPrivacyDetail.contains("app bundles"))
        #expect(RuntimeGuardrailsPresentation.hostPrivacyDetail.contains("external volumes"))
        #expect(RuntimeGuardrailsPresentation.hostPrivacyDetail.contains("agent subprocesses"))
        #expect(RuntimeGuardrailsPresentation.hostPrivacyDetail.contains("explicitly selects"))
        #expect(source.contains("RuntimeGuardrailsPresentation.hostPrivacyTitle"))
        #expect(source.contains("RuntimeGuardrailsPresentation.hostPrivacyDetail"))
    }

    @Test("Runtime guardrails expose read-scope audit controls")
    func runtimeGuardrailsExposeReadScopeAuditControls() throws {
        let source = try settingsViewSource()

        #expect(source.contains(#"@AppStorage(AppStorageKeys.sandboxReadScope)"#))
        #expect(source.contains(#"Picker("Read Scope""#))
        #expect(source.contains("selectedSandboxReadScope.helpText"))
        #expect(ExecutionSandboxReadScope.open.helpText.contains("privacy-sensitive"))
        #expect(ExecutionSandboxReadScope.audit.helpText.contains("hard-blocking"))
        #expect(ExecutionSandboxReadScope.audit.helpText.contains("strict-scope misses"))
        #expect(ExecutionSandboxReadScope.enforce.helpText.contains("can read only"))
    }

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
