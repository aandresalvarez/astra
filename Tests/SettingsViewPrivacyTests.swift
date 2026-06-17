import Foundation
import Testing
@testable import ASTRA

@Suite("Settings Privacy Copy")
struct SettingsViewPrivacyTests {
    @Test("Runtime guardrails disclose the always-on ASTRA host privacy boundary")
    func runtimeGuardrailsDiscloseHostPrivacyBoundary() throws {
        let source = try runtimeSettingsSource()

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
        let source = try runtimeSettingsSource()

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

    @Test("Runtime setup copy scopes checks to the selected provider")
    func runtimeSetupCopyScopesChecksToSelectedProvider() throws {
        let source = try settingsViewSource()

        #expect(source.contains("SettingsRuntimeTab("))
        #expect(!source.contains(#"Section("Technical Readiness")"#))
    }

    @Test("Runtime settings reuse the shared runtime setup section")
    func runtimeSettingsReuseSharedRuntimeSetupSection() throws {
        let source = try settingsViewSource()
        let runtimeTabSource = try runtimeTabSource()

        #expect(source.contains("SettingsRuntimeTab("))
        #expect(runtimeTabSource.contains("RuntimeSetupSection(model: settingsRuntimeSetup"))
        #expect(!source.contains(#"Section("Provider Selection")"#))
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

    private func runtimeTabSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Astra/Views/SettingsRuntimeTab.swift"),
            encoding: .utf8
        )
    }

    private func runtimeSettingsSource() throws -> String {
        try [settingsViewSource(), runtimeTabSource()].joined(separator: "\n")
    }
}
