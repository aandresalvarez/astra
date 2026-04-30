import Testing
import Foundation
@testable import ASTRA
import ASTRACore

/// Lightweight contract tests for the onboarding wizard's step machine.
/// The view itself is mostly SwiftUI glue that's easier to verify by
/// running the app; what needs protection is the step ordering and the
/// `rawValue` stability that the progress bar and tests depend on.
@Suite("OnboardingWizard")
struct OnboardingWizardTests {

    @Test("Steps are in the documented order")
    func stepOrdering() {
        let ordered = OnboardingWizardView.Step.allCases
        #expect(ordered == [
            .welcome,
            .requiredCLIs,
            .workspaceRoot,
            .catalogPreview,
            .ready
        ])
    }

    @Test("Step rawValues are stable for progress-bar math")
    func stepRawValuesStable() {
        // The progress bar fills steps where rawValue < currentStep's
        // rawValue. If the raw order ever changes, the bar silently
        // breaks — this test locks the assignment in.
        #expect(OnboardingWizardView.Step.welcome.rawValue == 0)
        #expect(OnboardingWizardView.Step.requiredCLIs.rawValue == 1)
        #expect(OnboardingWizardView.Step.workspaceRoot.rawValue == 2)
        #expect(OnboardingWizardView.Step.catalogPreview.rawValue == 3)
        #expect(OnboardingWizardView.Step.ready.rawValue == 4)
    }

    @Test("Progress labels are short enough for the bar")
    func progressLabelsAreShort() {
        // Keep labels ≤ 8 chars so the 5 labels + connecting lines all fit
        // in the 760pt-minimum progress strip without wrapping. We hit
        // this once with "Workspace" wrapping to "Work-space" on-screen;
        // the ceiling is deliberately tight to catch regressions early.
        for step in OnboardingWizardView.Step.allCases {
            #expect(step.progressLabel.count <= 8,
                    "Step \(step) progressLabel '\(step.progressLabel)' is too long (max 8 chars)")
        }
    }

    @Test("Each step has non-empty title and label")
    func noEmptyStrings() {
        for step in OnboardingWizardView.Step.allCases {
            #expect(!step.title.isEmpty)
            #expect(!step.progressLabel.isEmpty)
        }
    }

    @Test("Required CLI checks include Claude and GitHub")
    func requiredCLIChecksIncludeClaudeAndGitHub() {
        let prerequisites = OnboardingWizardView.requiredCLIPrerequisites
        #expect(prerequisites.map(\.binary) == ["claude", "gh", "gh"])
        #expect(prerequisites.map(\.livenessArgs) == [
            ["--version"],
            ["--version"],
            ["auth", "status"]
        ])
        #expect(prerequisites[1] == CommonCLIPrerequisites.githubCLI)
        #expect(prerequisites[2] == CommonCLIPrerequisites.githubAuth)
    }

    @Test("Onboarding completion uses the Astra-specific storage key")
    func completionStorageKeyIsNamespaced() {
        #expect(AppStorageKeys.hasCompletedOnboarding == "astra.hasCompletedOnboarding")
        #expect(AppStorageKeys.hasPresentedOnboarding == "astra.hasPresentedOnboarding")
        #expect(AppStorageKeys.skipPermissions == "skipPermissions")
        #expect(AppStorageKeys.securityGateDefaultedToReview == "astra.securityGateDefaultedToReview.v1")
    }
}
