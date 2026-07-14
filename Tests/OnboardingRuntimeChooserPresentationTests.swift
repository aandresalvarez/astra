import Testing
@testable import ASTRA
import ASTRACore

@Suite("Onboarding runtime chooser presentation")
struct OnboardingRuntimeChooserPresentationTests {
    @Test("Selected runtime exposes the exact readiness blocker")
    func selectedRuntimeExposesReadinessBlocker() throws {
        let row = runtimeRow(state: .selectedReady, isSelected: true)
        let blocker = RuntimeReadinessCheck(
            id: "claude-vertex-project",
            title: "Vertex project",
            detail: "No Google Cloud project is configured.",
            state: .blocked,
            remediation: "Set a project in Settings → Runtimes."
        )

        let selected = try #require(OnboardingRuntimeChooserPresentation.selectedBlocker(
            for: row,
            blockers: [blocker]
        ))

        #expect(selected == blocker)
        #expect(OnboardingRuntimeChooserPresentation.subtitle(
            for: row,
            authSessionStatus: nil,
            selectedBlocker: selected
        ) == "Needs setup — Vertex project")
    }

    @Test("Manual sign-in fallback replaces generic awaiting copy")
    func manualSignInFallbackIsVisible() {
        let row = runtimeRow(state: .awaitingSignIn, isSelected: true)

        let subtitle = OnboardingRuntimeChooserPresentation.subtitle(
            for: row,
            authSessionStatus: "Command copied — paste it into Terminal to sign in.",
            selectedBlocker: nil
        )

        #expect(subtitle == "Command copied — paste it into Terminal to sign in.")
    }

    @Test("Install failure retains actionable detail and output")
    func installFailureRetainsDiagnostics() throws {
        let result = RuntimeCLIInstallResult(
            runtime: .codexCLI,
            plan: nil,
            succeeded: false,
            summary: "Codex CLI install failed.",
            detail: "npm could not write to the global package directory.",
            fullLog: "npm ERR! code EACCES"
        )

        let failure = try #require(OnboardingRuntimeChooserPresentation.installFailure(
            for: .codexCLI,
            result: result
        ))

        #expect(failure.summary == "Codex CLI install failed.")
        #expect(failure.detail == "npm could not write to the global package directory.")
        #expect(failure.output == "npm ERR! code EACCES")
    }

    @Test("Chooser exposes a global re-check action for link-only installs")
    func linkOnlyInstallHasRecheckAction() {
        #expect(OnboardingRuntimeChooserPresentation.recheckActionTitle == "Re-check runtimes")
    }

    private func runtimeRow(
        state: RuntimeProviderRowState,
        isSelected: Bool
    ) -> RuntimeProviderRowPresentation {
        RuntimeProviderRowPresentation(
            id: .claudeCode,
            title: "Claude Code",
            subtitle: "Selected and ready",
            state: state,
            isSelected: isSelected,
            isInstalled: true,
            installCommand: nil
        )
    }
}
