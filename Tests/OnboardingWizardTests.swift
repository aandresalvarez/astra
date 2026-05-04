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
            .capabilitySetup,
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
        #expect(OnboardingWizardView.Step.capabilitySetup.rawValue == 3)
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
        #expect(AppStorageKeys.onboardingEnabledCapabilityIDs == "astra.onboardingEnabledCapabilityIDs")
        #expect(AppStorageKeys.skipPermissions == "skipPermissions")
        #expect(AppStorageKeys.securityGateDefaultedToReview == "astra.securityGateDefaultedToReview.v1")
        #expect(AppStorageKeys.hasSeenNewTaskNudge == "astra.hasSeenNewTaskNudge.v1")
    }

    @Test("Capability setup exposes the requested first-workspace choices")
    @MainActor
    func capabilitySetupIncludesRequestedChoices() {
        #expect(OnboardingCapabilitySetup.requiredRuntime.id == "claude-cli")
        #expect(OnboardingCapabilitySetup.requiredRuntime.packageID == nil)

        #expect(OnboardingCapabilitySetup.configurableOptions.compactMap(\.packageID) == [
            "jira-workflow",
            "github-workflow",
            "gcloud-workflow",
            "redcap-workflow"
        ])

        let builtInIDs = Set(PluginCatalog.builtInPackages.map(\.id))
        #expect(OnboardingCapabilitySetup.installablePackageIDs.isSubset(of: builtInIDs))
    }

    @Test("Capability setup persists only known package IDs in display order")
    func capabilitySetupStorageRoundTripsKnownPackages() {
        let rawValue = "redcap-workflow,unknown,gcloud-workflow,jira-workflow"
        let selected = OnboardingCapabilitySetup.selectedPackageIDs(from: rawValue)

        #expect(selected == ["jira-workflow", "gcloud-workflow", "redcap-workflow"])
        #expect(OnboardingCapabilitySetup.encode(selected) == "jira-workflow,gcloud-workflow,redcap-workflow")
        #expect(OnboardingCapabilitySetup.selectedDisplayNames(from: selected) == [
            "Jira Workflow",
            "Google Cloud",
            "REDCap Workflow"
        ])
    }

    @Test("Capability setup resolves selected built-in packages")
    @MainActor
    func capabilitySetupResolvesSelectedPackages() {
        let packages = OnboardingCapabilitySetup.selectedPackages(
            from: PluginCatalog.builtInPackages,
            rawValue: "github-workflow,redcap-workflow"
        )

        #expect(packages.map(\.id) == ["github-workflow", "redcap-workflow"])
    }

    @Test("Capability setup validates required configuration values")
    func capabilitySetupValidatesRequiredConfigurationValues() {
        var configuration = OnboardingCapabilityConfiguration()

        #expect(configuration.missingRequirements(for: "jira-workflow") == [
            "Jira base URL",
            "Jira email",
            "Jira API token"
        ])
        #expect(configuration.missingRequirements(for: "gcloud-workflow") == ["GCP project"])
        #expect(configuration.missingRequirements(for: "redcap-workflow") == ["REDCap API token"])
        #expect(configuration.missingRequirements(for: "github-workflow", githubCLIReady: false) == ["Authenticated gh CLI"])

        configuration.jiraBaseURL = "https://example.atlassian.net"
        configuration.jiraEmail = "user@example.com"
        configuration.jiraAPIToken = "token"
        configuration.gcpProject = "gcp-project"
        configuration.redcapAPIToken = "redcap-token"

        #expect(configuration.missingRequirements(for: "jira-workflow").isEmpty)
        #expect(configuration.missingRequirements(for: "gcloud-workflow").isEmpty)
        #expect(configuration.missingRequirements(for: "redcap-workflow").isEmpty)
        #expect(configuration.missingRequirements(for: "github-workflow", githubCLIReady: true).isEmpty)
    }

    @Test("Capability setup maps configuration to installer inputs")
    func capabilitySetupMapsConfigurationToInstallerInputs() {
        let configuration = OnboardingCapabilityConfiguration(
            jiraBaseURL: " https://example.atlassian.net ",
            jiraEmail: " user@example.com ",
            jiraAPIToken: " jira-token ",
            jiraProjects: " ENG, OPS ",
            gcpProject: " gcp-project ",
            gcpRegion: " us-central1 ",
            redcapAPIURL: " https://redcap.example.edu/api/ ",
            redcapAPIToken: " redcap-token "
        )

        let jira = configuration.installationInputs(for: "jira-workflow")
        #expect(jira.credentialInputs == [
            "JIRA_EMAIL": "user@example.com",
            "JIRA_API_TOKEN": "jira-token"
        ])
        #expect(jira.configInputs == [
            "JIRA_BASE_URL": "https://example.atlassian.net",
            "JIRA_PROJECTS": "ENG, OPS"
        ])
        #expect(jira.baseURLOverrides == ["Jira": "https://example.atlassian.net"])

        let gcp = configuration.installationInputs(for: "gcloud-workflow")
        #expect(gcp.configInputs == [
            "GCP_PROJECT": "gcp-project",
            "GCP_REGION": "us-central1"
        ])

        let redcap = configuration.installationInputs(for: "redcap-workflow")
        #expect(redcap.credentialInputs == ["REDCAP_API_TOKEN": "redcap-token"])
        #expect(redcap.configInputs == ["REDCAP_API_URL": "https://redcap.example.edu/api/"])
        #expect(redcap.baseURLOverrides == ["REDCap": "https://redcap.example.edu/api/"])
    }
}
