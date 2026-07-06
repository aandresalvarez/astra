import Testing
import Foundation
import SwiftData
import ASTRAModels
@testable import ASTRA
import ASTRACore

private func makeCapabilitySetupCopyContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

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
            .permissions,
            .workspaceRoot,
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
        #expect(OnboardingWizardView.Step.permissions.rawValue == 2)
        #expect(OnboardingWizardView.Step.workspaceRoot.rawValue == 3)
        #expect(OnboardingWizardView.Step.ready.rawValue == 4)
    }

    @Test("Progress labels are short enough for the bar")
    func progressLabelsAreShort() {
        // Keep labels ≤ 8 chars so the labels + connecting lines all fit
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

    @Test("Required CLI checks only require the selected AI runtime")
    func requiredCLIChecksOnlyRequireSelectedAIRuntime() {
        let claudePrerequisites = OnboardingWizardView.requiredCLIPrerequisites(for: .claudeCode)
        #expect(claudePrerequisites.map(\.binary) == ["claude"])
        #expect(claudePrerequisites.map(\.livenessArgs) == [["--version"]])

        let copilotPrerequisites = OnboardingWizardView.requiredCLIPrerequisites(for: .copilotCLI)
        #expect(copilotPrerequisites.map(\.binary) == ["copilot"])
        #expect(copilotPrerequisites.map(\.livenessArgs) == [["--version"]])

        let antigravityPrerequisites = OnboardingWizardView.requiredCLIPrerequisites(for: .antigravityCLI)
        #expect(antigravityPrerequisites.map(\.binary) == ["agy"])
        #expect(antigravityPrerequisites.map(\.livenessArgs) == [["--version"]])

        let cursorPrerequisites = OnboardingWizardView.requiredCLIPrerequisites(for: .cursorCLI)
        #expect(cursorPrerequisites.map(\.binary) == ["cursor-agent"])
        #expect(cursorPrerequisites.map(\.livenessArgs) == [["--version"]])

        let openCodePrerequisites = OnboardingWizardView.requiredCLIPrerequisites(for: .openCodeCLI)
        #expect(openCodePrerequisites.map(\.binary) == ["opencode"])
        #expect(openCodePrerequisites.map(\.livenessArgs) == [["--version"]])
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

    @Test("Workspace capability setup exposes the requested choices")
    @MainActor
    func capabilitySetupIncludesRequestedChoices() {
        #expect(OnboardingCapabilitySetup.requiredRuntime.id == "agent-runtime")
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

    @Test("Workspace capability setup outcome copy matches Jira read-only support")
    func capabilitySetupOutcomeCopyMatchesJiraReadOnlySupport() {
        let jira = try! #require(OnboardingCapabilitySetup.configurableOptions.first {
            $0.packageID == OnboardingCapabilitySetup.jiraPackageID
        })

        #expect(OnboardingCapabilitySetup.outcomeSubtitle(for: jira) == "Search, read, and summarize Jira tickets")
        #expect(!OnboardingCapabilitySetup.outcomeSubtitle(for: jira).contains("Create"))
        #expect(!OnboardingCapabilitySetup.outcomeSubtitle(for: jira).contains("update"))
    }

    @Test("Workspace capability setup persists only known package IDs in display order")
    func capabilitySetupStorageRoundTripsKnownPackages() {
        let rawValue = "redcap-workflow,unknown,gcloud-workflow,jira-workflow"
        let selected = OnboardingCapabilitySetup.selectedPackageIDs(from: rawValue)

        #expect(selected == ["jira-workflow", "gcloud-workflow", "redcap-workflow"])
        #expect(OnboardingCapabilitySetup.encode(selected) == "jira-workflow,gcloud-workflow,redcap-workflow")
        #expect(OnboardingCapabilitySetup.selectedDisplayNames(from: selected) == [
            "Jira",
            "Google Cloud",
            "REDCap"
        ])
    }

    @Test("Workspace capability setup resolves selected built-in packages")
    @MainActor
    func capabilitySetupResolvesSelectedPackages() {
        let packages = OnboardingCapabilitySetup.selectedPackages(
            from: PluginCatalog.builtInPackages,
            rawValue: "github-workflow,redcap-workflow"
        )

        #expect(packages.map(\.id) == ["github-workflow", "redcap-workflow"])
    }

    @Test("Workspace capability setup validates required configuration values")
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

    @Test("Workspace capability setup applies environment defaults without overwriting user values")
    func capabilitySetupAppliesEnvironmentDefaults() {
        var configuration = OnboardingCapabilityConfiguration(redcapAPIURL: "")

        let changed = configuration.applyEnvironmentDefaults(
            gcpProject: " vertex-project ",
            gcpRegion: " global "
        )

        #expect(changed)
        #expect(configuration.gcpProject == "vertex-project")
        #expect(configuration.gcpRegion == "global")
        #expect(configuration.redcapAPIURL == OnboardingCapabilityConfiguration.defaultRedcapAPIURL)

        let changedAgain = configuration.applyEnvironmentDefaults(
            gcpProject: "other-project",
            gcpRegion: "us-east5"
        )

        #expect(!changedAgain)
        #expect(configuration.gcpProject == "vertex-project")
        #expect(configuration.gcpRegion == "global")
    }

    @Test("Workspace capability setup maps configuration to installer inputs")
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

    @Test("Workspace capability setup copies local configuration from another workspace")
    @MainActor
    func workspaceCapabilitySetupCopiesLocalConfiguration() throws {
        let container = try makeCapabilitySetupCopyContainer()
        let context = container.mainContext
        let source = Workspace(name: "Clinical Ops", primaryPath: "/tmp/clinical-ops")
        source.enabledCapabilityIDs = [
            "jira-workflow",
            "github-workflow",
            "gcloud-workflow",
            "redcap-workflow",
            "security-auditor"
        ]
        context.insert(source)

        let jira = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://clinical.atlassian.net",
            authMethod: "basic"
        )
        jira.workspace = source
        jira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jira.credentialValues = ["", ""]
        jira.configKeys = ["JIRA_PROJECTS"]
        jira.configValues = ["CLIN, OPS"]
        context.insert(jira)

        let gcloud = Connector(
            name: "Google Cloud",
            serviceType: "gcloud",
            connectorDescription: "GCP via gcloud",
            authMethod: "none"
        )
        gcloud.workspace = source
        gcloud.configKeys = ["GCP_PROJECT", "GCP_REGION"]
        gcloud.configValues = ["astra-clinical", "us-west1"]
        context.insert(gcloud)

        let redcap = Connector(
            name: "REDCap",
            serviceType: "redcap",
            connectorDescription: "REDCap API",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        redcap.workspace = source
        redcap.credentialKeys = ["REDCAP_API_TOKEN"]
        redcap.credentialValues = [""]
        context.insert(redcap)

        let store = MockSecretStore()
        store.save(
            key: "JIRA_EMAIL",
            value: "user@example.edu",
            entityID: KeychainSecretStore.connectorEntityID(for: jira.id),
            label: nil
        )
        store.save(
            key: "JIRA_API_TOKEN",
            value: "jira-token",
            entityID: KeychainSecretStore.connectorEntityID(for: jira.id),
            label: nil
        )
        store.save(
            key: "REDCAP_API_TOKEN",
            value: "redcap-token",
            entityID: KeychainSecretStore.connectorEntityID(for: redcap.id),
            label: nil
        )

        let summary = CapabilitySetupCopier(secretStore: store).copySetup(from: source)

        #expect(summary.sourceWorkspaceName == "Clinical Ops")
        #expect(summary.selectedPackageIDs == [
            "jira-workflow",
            "github-workflow",
            "gcloud-workflow",
            "redcap-workflow"
        ])
        #expect(summary.copiedCredentialCount == 3)
        #expect(summary.inputsByPackageID["jira-workflow"]?.configInputs["JIRA_BASE_URL"] == "https://clinical.atlassian.net")
        #expect(summary.inputsByPackageID["jira-workflow"]?.configInputs["JIRA_PROJECTS"] == "CLIN, OPS")
        #expect(summary.inputsByPackageID["gcloud-workflow"]?.configInputs["GCP_PROJECT"] == "astra-clinical")
        #expect(summary.inputsByPackageID["redcap-workflow"]?.configInputs["REDCAP_API_URL"] == "https://redcap.example.edu/api/")

        var copiedConfiguration = OnboardingCapabilityConfiguration(redcapAPIURL: "")
        copiedConfiguration.applyCopiedInputs(summary.inputsByPackageID)

        #expect(copiedConfiguration.jiraBaseURL == "https://clinical.atlassian.net")
        #expect(copiedConfiguration.jiraEmail == "user@example.edu")
        #expect(copiedConfiguration.jiraAPIToken == "jira-token")
        #expect(copiedConfiguration.jiraProjects == "CLIN, OPS")
        #expect(copiedConfiguration.gcpProject == "astra-clinical")
        #expect(copiedConfiguration.gcpRegion == "us-west1")
        #expect(copiedConfiguration.redcapAPIURL == "https://redcap.example.edu/api/")
        #expect(copiedConfiguration.redcapAPIToken == "redcap-token")
    }

    @Test("Workspace capability setup copies legacy REDCap connector keys")
    @MainActor
    func workspaceCapabilitySetupCopiesLegacyREDCapConnectorKeys() throws {
        let container = try makeCapabilitySetupCopyContainer()
        let context = container.mainContext
        let source = Workspace(name: "Legacy REDCap", primaryPath: "/tmp/legacy-redcap")
        source.enabledCapabilityIDs = ["redcap-workflow"]
        context.insert(source)

        let redcap = Connector(
            name: "Study REDCap",
            serviceType: "redcap",
            connectorDescription: "Legacy REDCap API",
            authMethod: "api_key"
        )
        redcap.workspace = source
        redcap.credentialKeys = ["API_TOKEN"]
        redcap.credentialValues = ["legacy-token"]
        redcap.configKeys = ["API_URL"]
        redcap.configValues = ["https://redcap.legacy.edu/api/"]
        context.insert(redcap)

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "redcap-workflow" })
        let inputs = CapabilitySetupCopier(secretStore: MockSecretStore()).installationInputs(
            for: package,
            from: source
        )

        #expect(inputs.credentialInputs["REDCAP_API_TOKEN"] == "legacy-token")
        #expect(inputs.configInputs["REDCAP_API_URL"] == "https://redcap.legacy.edu/api/")
    }

    @Test("Workspace capability setup copies credentials from legacy AgentFlow Keychain namespace")
    @MainActor
    func workspaceCapabilitySetupCopiesLegacyAgentFlowKeychainCredentials() throws {
        let container = try makeCapabilitySetupCopyContainer()
        let context = container.mainContext
        let source = Workspace(name: "Legacy Jira", primaryPath: "/tmp/legacy-jira")
        context.insert(source)

        let jira = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://legacy.atlassian.net",
            authMethod: "basic"
        )
        jira.isGlobal = true
        jira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jira.credentialValues = ["", ""]
        context.insert(jira)
        source.enabledGlobalConnectorIDs = [jira.id.uuidString]

        let store = MockSecretStore()
        let legacyEntityID = "agentflow-\(jira.id.uuidString)"
        store.save(
            key: "JIRA_EMAIL",
            value: "legacy@example.edu",
            entityID: legacyEntityID,
            label: nil
        )
        store.save(
            key: "JIRA_API_TOKEN",
            value: "legacy-token",
            entityID: legacyEntityID,
            label: nil
        )

        let summary = CapabilitySetupCopier(secretStore: store).copySetup(
            from: source,
            globalConnectors: [jira]
        )

        #expect(summary.selectedPackageIDs == ["jira-workflow"])
        #expect(summary.inputsByPackageID["jira-workflow"]?.configInputs["JIRA_BASE_URL"] == "https://legacy.atlassian.net")
        #expect(summary.inputsByPackageID["jira-workflow"]?.credentialInputs["JIRA_EMAIL"] == "legacy@example.edu")
        #expect(summary.inputsByPackageID["jira-workflow"]?.credentialInputs["JIRA_API_TOKEN"] == "legacy-token")
    }

    @Test("Workspace capability setup copies stale global connector credentials")
    @MainActor
    func workspaceCapabilitySetupCopiesStaleGlobalConnectorCredentials() throws {
        let container = try makeCapabilitySetupCopyContainer()
        let context = container.mainContext
        let source = Workspace(name: "Jira Coral Sprints", primaryPath: "/tmp/jira-coral")
        context.insert(source)

        let staleCredentialConnectorID = UUID()
        let jiraWithURL = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        jiraWithURL.isGlobal = true
        jiraWithURL.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jiraWithURL.credentialValues = ["", ""]
        context.insert(jiraWithURL)
        source.enabledGlobalConnectorIDs = [
            staleCredentialConnectorID.uuidString,
            jiraWithURL.id.uuidString
        ]

        let store = MockSecretStore()
        let staleEntityID = "agentflow-\(staleCredentialConnectorID.uuidString)"
        store.save(
            key: "JIRA_EMAIL",
            value: "coral@example.edu",
            entityID: staleEntityID,
            label: nil
        )
        store.save(
            key: "JIRA_API_TOKEN",
            value: "coral-token",
            entityID: staleEntityID,
            label: nil
        )

        let summary = CapabilitySetupCopier(secretStore: store).copySetup(
            from: source,
            globalConnectors: [jiraWithURL]
        )

        #expect(summary.selectedPackageIDs == ["jira-workflow"])
        #expect(summary.inputsByPackageID["jira-workflow"]?.configInputs["JIRA_BASE_URL"] == "https://stanfordmed.atlassian.net")
        #expect(summary.inputsByPackageID["jira-workflow"]?.credentialInputs["JIRA_EMAIL"] == "coral@example.edu")
        #expect(summary.inputsByPackageID["jira-workflow"]?.credentialInputs["JIRA_API_TOKEN"] == "coral-token")
    }

    @Test("Workspace capability setup ignores unchanged default base URLs")
    @MainActor
    func workspaceCapabilitySetupIgnoresUnchangedDefaultBaseURLs() throws {
        let container = try makeCapabilitySetupCopyContainer()
        let context = container.mainContext
        let source = Workspace(name: "Empty REDCap", primaryPath: "/tmp/empty-redcap")
        source.enabledCapabilityIDs = ["redcap-workflow"]
        context.insert(source)

        let redcap = Connector(
            name: "REDCap",
            serviceType: "redcap",
            connectorDescription: "Default REDCap API",
            baseURL: OnboardingCapabilityConfiguration.defaultRedcapAPIURL,
            authMethod: "api_key"
        )
        redcap.workspace = source
        redcap.credentialKeys = ["REDCAP_API_TOKEN"]
        redcap.credentialValues = [""]
        context.insert(redcap)

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "redcap-workflow" })
        let inputs = CapabilitySetupCopier(secretStore: MockSecretStore()).installationInputs(
            for: package,
            from: source
        )
        let summary = CapabilitySetupCopier(secretStore: MockSecretStore()).copySetup(from: source)

        #expect(inputs == OnboardingCapabilityInstallationInputs())
        #expect(summary.selectedPackageIDs == ["redcap-workflow"])
        #expect(summary.inputsByPackageID["redcap-workflow"] == nil)
    }

    @Test("Workspace capability setup infers legacy global connector configuration")
    @MainActor
    func workspaceCapabilitySetupInfersLegacyGlobalConnectorConfiguration() throws {
        let container = try makeCapabilitySetupCopyContainer()
        let context = container.mainContext
        let source = Workspace(name: "Shared Jira", primaryPath: "/tmp/shared-jira")
        context.insert(source)

        let jira = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://shared.atlassian.net",
            authMethod: "basic"
        )
        jira.isGlobal = true
        jira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jira.credentialValues = ["", ""]
        jira.configKeys = ["JIRA_PROJECTS"]
        jira.configValues = ["SHARED"]
        context.insert(jira)
        source.enabledGlobalConnectorIDs = [jira.id.uuidString]

        let store = MockSecretStore()
        store.save(
            key: "JIRA_EMAIL",
            value: "shared@example.edu",
            entityID: KeychainSecretStore.connectorEntityID(for: jira.id),
            label: nil
        )
        store.save(
            key: "JIRA_API_TOKEN",
            value: "shared-token",
            entityID: KeychainSecretStore.connectorEntityID(for: jira.id),
            label: nil
        )

        let summary = CapabilitySetupCopier(secretStore: store).copySetup(
            from: source,
            globalConnectors: [jira]
        )
        #expect(summary.selectedPackageIDs == ["jira-workflow"])

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let inputs = CapabilitySetupCopier(secretStore: store).installationInputs(
            for: package,
            from: source,
            globalConnectors: [jira]
        )

        #expect(inputs.baseURLOverrides["Jira"] == "https://shared.atlassian.net")
        #expect(inputs.configInputs["JIRA_BASE_URL"] == "https://shared.atlassian.net")
        #expect(inputs.configInputs["JIRA_PROJECTS"] == "SHARED")
        #expect(inputs.credentialInputs["JIRA_EMAIL"] == "shared@example.edu")
        #expect(inputs.credentialInputs["JIRA_API_TOKEN"] == "shared-token")
    }
}
