import Testing
import Foundation
@testable import ASTRA
import ASTRACore

/// Whether a `.permissionDenied` failure is one the user can actually approve.
/// Split out of the Copilot suite because the question is provider-agnostic:
/// the same category covers a CLI approval prompt ASTRA could not answer and a
/// provider refusing the call outright, and only the first can be granted here.
@Suite("Runtime Permission Denial Classification")
struct RuntimePermissionDenialClassificationTests {
    /// Reproduces the run that motivated `isApprovableRuntimePermission`: the
    /// stderr below is the sanitized text ASTRA logged five times for task
    /// 5FB5E95B, each time behind an approval card the user then approved.
    @Test("A Vertex 403 is permission denied but not something the user can approve")
    func vertexAuthorizationDenialIsNotApprovable() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .claudeCode,
            model: "claude-opus-4-6",
            exitCode: 1,
            rawError: """
            Failed to authenticate. API Error: 403 \
            {"error":{"code":403,"message":"Permission denied on resource project example-project.","status":"PERMISSION_DENIED"}}
            """,
            providerVersion: "claude 1.0.0",
            stream: nil
        )

        #expect(diagnostic.category == .permissionDenied)
        #expect(diagnostic.isApprovableRuntimePermission == false)
        #expect(diagnostic.userMessage.contains("not by ASTRA"))
        #expect(diagnostic.userMessage.contains("Approving more permissions here will not change the result"))
        let fields = diagnostic.auditFields(phase: "run", stream: nil)
        #expect(fields["approvable_runtime_permission"] == "false")
    }

    @Test("A local approval prompt stays approvable so the card is still offered")
    func localApprovalPromptRemainsApprovable() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: "gpt-5",
            exitCode: 15,
            rawError: "Copilot is waiting for a permission approval ASTRA cannot answer directly: Allow access to these paths? (y/n):",
            providerVersion: "GitHub Copilot CLI 0.0.342",
            stream: nil
        )

        #expect(diagnostic.category == .permissionDenied)
        #expect(diagnostic.isApprovableRuntimePermission)
        #expect(diagnostic.userMessage.contains("approval prompt"))
    }

    /// An org-policy denial names a local-sounding path grant, so the two
    /// needle lists overlap here. The provider marker has to win, otherwise the
    /// narrow fix leaks the loop back in through a wider error message.
    @Test("A provider marker outranks a local one in the same message")
    func providerMarkerOutranksLocalMarker() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .claudeCode,
            model: "claude-opus-4-6",
            exitCode: 1,
            rawError: "HTTP 403: organization policy blocks this request. Allow access to these paths? is not the problem.",
            providerVersion: "claude 1.0.0",
            stream: nil
        )

        #expect(diagnostic.category == .permissionDenied)
        #expect(diagnostic.isApprovableRuntimePermission == false)
    }

    /// The default matters more than the list. Withholding the card is the
    /// destructive direction — it leaves a dead run the user cannot act on —
    /// so an unrecognised denial keeps the card. Only a provable provider
    /// refusal loses it.
    @Test("An unrecognised denial stays approvable")
    func unrecognizedDenialStaysApprovable() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .cursorCLI,
            model: "grok-4.5-medium",
            exitCode: 1,
            rawError: "Error: access denied.",
            providerVersion: "2026.07.01-41b2de7",
            stream: nil
        )

        #expect(diagnostic.category == .permissionDenied)
        #expect(diagnostic.isApprovableRuntimePermission)
    }

    /// The two phrasings the end-to-end permission scenarios actually emit. An
    /// allowlist of local prompts missed both, which is why there isn't one.
    @Test("The local prompts the runtimes really emit stay approvable", arguments: [
        "Permission denied and could not request permission from user",
        "Permission denied for tool: Agent. approval required"
    ])
    func realWorldLocalPromptsRemainApprovable(rawError: String) {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: "gpt-5",
            exitCode: 15,
            rawError: rawError,
            providerVersion: "GitHub Copilot CLI 0.0.342",
            stream: nil
        )

        #expect(diagnostic.category == .permissionDenied)
        #expect(diagnostic.isApprovableRuntimePermission)
    }

    @Test("The approvable flag is only reported on the category it discriminates")
    func approvableFieldIsAbsentOnOtherCategories() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .claudeCode,
            model: "claude-opus-4-6",
            exitCode: 1,
            rawError: "Error: not authenticated. Run claude /login.",
            providerVersion: "claude 1.0.0",
            stream: nil
        )

        #expect(diagnostic.category == .authenticationFailed)
        #expect(diagnostic.auditFields(phase: "run", stream: nil)["approvable_runtime_permission"] == nil)
    }
}
