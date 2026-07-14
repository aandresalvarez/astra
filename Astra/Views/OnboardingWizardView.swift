import SwiftUI
import ASTRACore
import ASTRAPersistence
import ASTRAModels

struct OnboardingCapabilityOption: Identifiable, Equatable {
    let id: String
    let packageID: String?
    let title: String
    let subtitle: String
    let icon: String
}

struct OnboardingCapabilityInstallationInputs: Equatable {
    var credentialInputs: [String: String] = [:]
    var configInputs: [String: String] = [:]
    var baseURLOverrides: [String: String] = [:]
}

struct OnboardingCapabilityConfiguration: Equatable {
    static let defaultRedcapAPIURL = "https://redcap.stanford.edu/api/"
    static let defaultGCPRegion = "us-central1"

    var jiraBaseURL = ""
    var jiraEmail = ""
    var jiraAPIToken = ""
    var jiraProjects = ""
    var gcpProject = ""
    var gcpRegion = ""
    var redcapAPIURL = defaultRedcapAPIURL
    var redcapAPIToken = ""

    func missingRequirements(for packageID: String, githubCLIReady: Bool = true) -> [String] {
        switch packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            return [
                trimmed(jiraBaseURL).isEmpty ? "Jira base URL" : nil,
                trimmed(jiraEmail).isEmpty ? "Jira email" : nil,
                trimmed(jiraAPIToken).isEmpty ? "Jira API token" : nil
            ].compactMap { $0 }
        case OnboardingCapabilitySetup.githubPackageID:
            return githubCLIReady ? [] : ["Authenticated gh CLI"]
        case OnboardingCapabilitySetup.gcloudPackageID:
            return trimmed(gcpProject).isEmpty ? ["GCP project"] : []
        case OnboardingCapabilitySetup.redcapPackageID:
            return [
                trimmed(redcapAPIURL).isEmpty ? "REDCap API URL" : nil,
                trimmed(redcapAPIToken).isEmpty ? "REDCap API token" : nil
            ].compactMap { $0 }
        default:
            return []
        }
    }

    func installationInputs(for packageID: String) -> OnboardingCapabilityInstallationInputs {
        var inputs = OnboardingCapabilityInstallationInputs()
        switch packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            let baseURL = trimmed(jiraBaseURL)
            inputs.credentialInputs = nonEmptyValues([
                "JIRA_EMAIL": jiraEmail,
                "JIRA_API_TOKEN": jiraAPIToken
            ])
            inputs.configInputs = nonEmptyValues([
                "JIRA_BASE_URL": baseURL,
                "JIRA_PROJECTS": jiraProjects
            ])
            if !baseURL.isEmpty {
                inputs.baseURLOverrides["Jira"] = baseURL
            }
        case OnboardingCapabilitySetup.gcloudPackageID:
            inputs.configInputs = nonEmptyValues([
                "GCP_PROJECT": gcpProject,
                "GCP_REGION": gcpRegion
            ])
        case OnboardingCapabilitySetup.redcapPackageID:
            let apiURL = trimmed(redcapAPIURL)
            inputs.credentialInputs = nonEmptyValues([
                "REDCAP_API_TOKEN": redcapAPIToken
            ])
            inputs.configInputs = nonEmptyValues([
                "REDCAP_API_URL": apiURL
            ])
            if !apiURL.isEmpty {
                inputs.baseURLOverrides["REDCap"] = apiURL
            }
        default:
            break
        }
        return inputs
    }

    mutating func applyCopiedInputs(_ inputsByPackageID: [String: OnboardingCapabilityInstallationInputs]) {
        for packageID in OnboardingCapabilitySetup.orderedPackageIDs(Set(inputsByPackageID.keys)) {
            guard let inputs = inputsByPackageID[packageID] else { continue }
            applyCopiedInputs(inputs, for: packageID)
        }
    }

    mutating func clearSecrets() {
        jiraAPIToken = ""
        redcapAPIToken = ""
    }

    @discardableResult
    mutating func applyEnvironmentDefaults(gcpProject: String, gcpRegion: String) -> Bool {
        var changed = false
        let trimmedProject = trimmed(gcpProject)
        let trimmedRegion = trimmed(gcpRegion)
        if trimmed(self.gcpProject).isEmpty, !trimmedProject.isEmpty {
            self.gcpProject = trimmedProject
            changed = true
        }
        if trimmed(self.gcpRegion).isEmpty {
            self.gcpRegion = trimmedRegion.isEmpty ? Self.defaultGCPRegion : trimmedRegion
            changed = true
        }
        if trimmed(redcapAPIURL).isEmpty {
            redcapAPIURL = Self.defaultRedcapAPIURL
            changed = true
        }
        return changed
    }

    private func nonEmptyValues(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [:]) { result, entry in
            let value = trimmed(entry.value)
            if !value.isEmpty {
                result[entry.key] = value
            }
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func applyCopiedInputs(
        _ inputs: OnboardingCapabilityInstallationInputs,
        for packageID: String
    ) {
        switch packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            jiraBaseURL = firstNonEmpty(
                inputs.configInputs["JIRA_BASE_URL"],
                inputs.baseURLOverrides["Jira"],
                jiraBaseURL
            )
            jiraProjects = firstNonEmpty(inputs.configInputs["JIRA_PROJECTS"], jiraProjects)
            jiraEmail = firstNonEmpty(inputs.credentialInputs["JIRA_EMAIL"], jiraEmail)
            jiraAPIToken = firstNonEmpty(inputs.credentialInputs["JIRA_API_TOKEN"], jiraAPIToken)
        case OnboardingCapabilitySetup.gcloudPackageID:
            gcpProject = firstNonEmpty(inputs.configInputs["GCP_PROJECT"], gcpProject)
            gcpRegion = firstNonEmpty(inputs.configInputs["GCP_REGION"], gcpRegion)
        case OnboardingCapabilitySetup.redcapPackageID:
            redcapAPIURL = firstNonEmpty(
                inputs.configInputs["REDCAP_API_URL"],
                inputs.baseURLOverrides["REDCap"],
                redcapAPIURL
            )
            redcapAPIToken = firstNonEmpty(inputs.credentialInputs["REDCAP_API_TOKEN"], redcapAPIToken)
        default:
            break
        }
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmedValue = trimmed(value ?? "")
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }
        return ""
    }
}

enum OnboardingCapabilitySetup {
    static let requiredRuntimeID = "agent-runtime"
    static let jiraPackageID = "jira-workflow"
    static let githubPackageID = "github-workflow"
    static let gcloudPackageID = "gcloud-workflow"
    static let redcapPackageID = "redcap-workflow"

    static let requiredRuntime = OnboardingCapabilityOption(
        id: requiredRuntimeID,
        packageID: nil,
        title: "Agent runtime",
        subtitle: "Selected AI runtime",
        icon: "sparkles"
    )

    static let configurableOptions: [OnboardingCapabilityOption] = [
        OnboardingCapabilityOption(
            id: jiraPackageID,
            packageID: jiraPackageID,
            title: "Jira",
            subtitle: "Search and read Jira tickets",
            icon: "list.bullet.clipboard"
        ),
        OnboardingCapabilityOption(
            id: githubPackageID,
            packageID: githubPackageID,
            title: "GitHub",
            subtitle: "Manage issues, PRs, and CI with gh",
            icon: "chevron.left.forwardslash.chevron.right"
        ),
        OnboardingCapabilityOption(
            id: gcloudPackageID,
            packageID: gcloudPackageID,
            title: "Google Cloud",
            subtitle: "Manage GCP resources, BigQuery, and deploys",
            icon: "cloud.fill"
        ),
        OnboardingCapabilityOption(
            id: redcapPackageID,
            packageID: redcapPackageID,
            title: "REDCap",
            subtitle: "Query and manage Stanford REDCap projects",
            icon: "tablecells"
        )
    ]

    static func outcomeSubtitle(for option: OnboardingCapabilityOption) -> String {
        switch option.packageID {
        case jiraPackageID:
            return "Search, read, and summarize Jira tickets"
        case githubPackageID:
            return "Review PRs, issues, and CI"
        case gcloudPackageID:
            return "Query BigQuery and work with GCP resources"
        case redcapPackageID:
            return "Talk to REDCap projects and metadata"
        default:
            return option.subtitle
        }
    }

    static var installablePackageIDs: Set<String> {
        Set(configurableOptions.compactMap(\.packageID))
    }

    static func selectedPackageIDs(from rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        })
            .intersection(installablePackageIDs)
    }

    static func encode(_ packageIDs: Set<String>) -> String {
        orderedPackageIDs(packageIDs).joined(separator: ",")
    }

    static func selectedPackages(
        from catalogPackages: [PluginPackage],
        rawValue: String
    ) -> [PluginPackage] {
        var packagesByID: [String: PluginPackage] = [:]
        for package in catalogPackages {
            packagesByID[package.id] = package
        }
        return orderedPackageIDs(selectedPackageIDs(from: rawValue)).compactMap { packagesByID[$0] }
    }

    static func selectedDisplayNames(from packageIDs: Set<String>) -> [String] {
        orderedPackageIDs(packageIDs).compactMap { packageID in
            configurableOptions.first { $0.packageID == packageID }?.title
        }
    }

    static func orderedPackageIDs(_ packageIDs: Set<String>) -> [String] {
        configurableOptions.compactMap { option in
            guard let packageID = option.packageID, packageIDs.contains(packageID) else { return nil }
            return packageID
        }
    }
}

/// Multi-step first-run wizard. Owns its own step state and the
/// completion flag in `@AppStorage`. Drives AI runtime probes up
/// front so the user knows whether their machine can run tasks, then walks
/// them through global access and first workspace setup.
///
/// Visuals follow the Stanford design system (`StanfordTheme.swift`) so
/// the wizard matches the rest of the app — cardinal red for the brand tile,
/// interactive teal for controls, and semantic success/warning tokens for
/// readiness. All font sizes come from the approved Stanford scale; no ad hoc
/// `.title2` / `.callout` shortcuts.
///
/// Steps:
///   0. AI runtime — pick and ready one coding-agent CLI
///   1. Permissions — review local Keychain and workspace storage access
///   2. Workspace — create the first workspace and quick-start capabilities
///   3. Ready — open the configured workspace
enum WorkspaceCreationOutcome: Equatable {
    case notCreated
    case created
    /// The workspace itself was created, but at least one quick-start
    /// capability's credential could not be saved (e.g. a denied Keychain
    /// prompt) — surfaced so the wizard doesn't silently report success.
    case createdWithCapabilityIssues
}

struct OnboardingWizardView: View {
    /// Bound to the enclosing gate (see `AppStorageKeys.hasCompletedOnboarding`).
    /// Toggling true dismisses the wizard.
    @Binding var hasCompletedOnboarding: Bool

    /// Called when the user finishes the workspace setup step.
    /// The wrapping ContentView persists the workspace and selects it.
    var onCreateWorkspace: (NewWorkspaceDraft) -> WorkspaceCreationOutcome
    var allowsDismiss: Bool
    var onDismiss: () -> Void
    @Binding var capabilityConfiguration: OnboardingCapabilityConfiguration

    static func requiredCLIPrerequisites(for runtime: AgentRuntimeID) -> [CLIPrerequisite] {
        [runtimePrerequisite(for: runtime)]
    }

    static func runtimePrerequisite(for runtime: AgentRuntimeID) -> CLIPrerequisite {
        AgentRuntimeAdapterRegistry.descriptor(for: runtime).prerequisite
    }

    /// Optional hook for testing — force a step on init.
    init(
        hasCompletedOnboarding: Binding<Bool>,
        initialStep: Step = .requiredCLIs,
        allowsDismiss: Bool = false,
        onDismiss: @escaping () -> Void = {},
        capabilityConfiguration: Binding<OnboardingCapabilityConfiguration> = .constant(OnboardingCapabilityConfiguration()),
        onCreateWorkspace: @escaping (NewWorkspaceDraft) -> WorkspaceCreationOutcome
    ) {
        self._hasCompletedOnboarding = hasCompletedOnboarding
        self._currentStep = State(initialValue: initialStep)
        self._capabilityConfiguration = capabilityConfiguration
        self.allowsDismiss = allowsDismiss
        self.onDismiss = onDismiss
        self.onCreateWorkspace = onCreateWorkspace
    }

    enum Step: Int, CaseIterable, Identifiable {
        case requiredCLIs = 0
        case permissions
        case workspaceRoot
        case ready
        var id: Int { rawValue }
    }

    @Environment(\.preflightCache) private var preflightCache
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.workspacesRoot) private var workspacesRoot = ""
    @State private var currentStep: Step
    @StateObject private var runtimeSetup = RuntimeSetupModel()
    @State private var workspaceDraft = NewWorkspaceDraft()
    @State private var workspaceValidationIssues: [String] = []
    @State private var workspaceValidationWarnings: [String] = []
    @State private var isShowingWorkspaceValidationWarning = false
    @State private var isShowingCapabilityEnableFailure = false
    @State private var createdWorkspaceName: String?
    @StateObject private var macOSPermissions = MacOSPermissionsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressHeader(
                currentStepIndex: currentStep.rawValue,
                stepCount: Step.allCases.count,
                allowsDismiss: allowsDismiss,
                onDismiss: onDismiss
            )
            Divider()

            ScrollView {
                stepContent
                    .padding(.horizontal, 36)
                    .padding(.vertical, 38)
                    .frame(maxWidth: 940)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(Stanford.panelBackground)
        .alert("Continue with unvalidated capabilities?", isPresented: $isShowingWorkspaceValidationWarning) {
            Button("Continue Anyway") {
                createFirstWorkspaceAndAdvance()
            }
            Button("Back", role: .cancel) {}
        } message: {
            Text(workspaceValidationWarnings.prefix(3).joined(separator: "\n"))
        }
        .alert("Some credentials couldn't be saved", isPresented: $isShowingCapabilityEnableFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your workspace was created, but one or more capability credentials could not be saved to Keychain. Add them later in Configure > Connectors.")
        }
    }

    // MARK: - Step Content Router

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .requiredCLIs:   cliStep
        case .permissions:    permissionsStep
        case .workspaceRoot:  workspaceStep
        case .ready:          readyStep
        }
    }

    // MARK: - Steps

    private var cliStep: some View {
        let presentation = Step.requiredCLIs.presentation()

        return VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 22) {
                AstraAppIconTile(size: 64, showsChannelBadge: false)

                VStack(alignment: .leading, spacing: 10) {
                    Text(presentation.heading)
                        .font(Stanford.heading(28))
                        .foregroundStyle(Stanford.readingText)
                    Text(presentation.subtitle)
                        .font(Stanford.body(15))
                        .foregroundStyle(Stanford.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let supportingText = presentation.supportingText {
                        Text(supportingText)
                            .font(Stanford.body(13))
                            .foregroundStyle(Stanford.textSecondary)
                            .padding(.top, 4)
                    }
                }
            }

            OnboardingRuntimeChooserView(model: runtimeSetup)
        }
        .task {
            runtimeSetup.attach(preflightCache: preflightCache)
            await runtimeSetup.refreshAndWait(force: false)
        }
    }

    private var permissionsStep: some View {
        let presentation = Step.permissions.presentation()

        return VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "checkmark.shield.fill",
                title: presentation.heading,
                subtitle: presentation.subtitle,
                tint: Stanford.lagunita
            )

            MacOSPermissionsSectionView(
                context: .onboarding,
                workspaceRoot: resolvedWorkspaceRoot,
                model: macOSPermissions,
                showsHeader: false
            )
        }
    }

    private var workspaceStep: some View {
        let presentation = Step.workspaceRoot.presentation()

        return VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "folder.badge.plus",
                title: presentation.heading,
                subtitle: presentation.subtitle,
                tint: Stanford.lagunita
            )

            WorkspaceSetupForm(
                draft: $workspaceDraft,
                rootPath: resolvedWorkspaceRoot,
                mode: .onboarding,
                validationIssues: $workspaceValidationIssues,
                validationWarnings: $workspaceValidationWarnings
            )
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var readyStep: some View {
        let presentation = Step.ready.presentation(workspaceName: createdWorkspaceName)

        return VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "checkmark.seal.fill",
                title: presentation.heading,
                subtitle: presentation.subtitle,
                tint: Stanford.paloAltoGreen
            )

            VStack(alignment: .leading, spacing: 10) {
                readinessRow(
                    title: "Workspace",
                    status: createdWorkspaceName ?? workspaceDraft.trimmedName,
                    ready: createdWorkspaceName != nil
                )
                readinessRow(
                    title: "AI runtime",
                    status: selectedRuntimeStatusSummary,
                    ready: isSelectedRuntimeHealthy
                )
                readinessRow(
                    title: "Capabilities",
                    status: firstWorkspaceCapabilitySummary,
                    ready: true
                )
            }
            .padding(14)
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.illuminating)
                Text("Tip: add or remove capabilities any time from Workspace Context.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
            }
        }
    }

    // MARK: - Reusable Blocks

    private func stepHeader(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(Stanford.ui(22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Stanford.heading(22))
                    .foregroundStyle(Stanford.black)
                Text(subtitle)
                    .font(Stanford.body(14))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func readinessRow(title: String, status: String, ready: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(Stanford.ui(14))
                .foregroundStyle(ready ? Stanford.paloAltoGreen : Stanford.poppy)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.body(13).weight(.medium))
                    .foregroundStyle(Stanford.black)
                Text(status)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var selectedRuntimeStatusSummary: String {
        switch runtimeSetup.status(for: runtimeSetup.selectedRuntime) {
        case .healthy(_, let version): "Ready — \(version)"
        case .unauthenticated(let detail): detail
        case .unresponsive(let detail): detail
        case .missingBinary: "Not installed on this Mac"
        case .none: "Not yet checked"
        }
    }

    private var isSelectedRuntimeHealthy: Bool {
        runtimeSetup.isInstalled(runtimeSetup.selectedRuntime)
    }

    private var firstWorkspaceCapabilitySummary: String {
        let names = OnboardingCapabilitySetup.selectedDisplayNames(from: workspaceDraft.selectedCapabilityIDs)
        if names.isEmpty {
            return "None selected. Add capabilities later from Workspace Context."
        }
        return names.joined(separator: ", ")
    }

    private var canCreateFirstWorkspace: Bool {
        !workspaceDraft.trimmedName.isEmpty && workspaceValidationIssues.isEmpty
    }

    // MARK: - Footer

    private var footerBar: some View {
        let presentation = currentStep.presentation(workspaceName: createdWorkspaceName)
        return OnboardingActionFooter(
            showsBack: currentStep != Step.allCases.first && !(currentStep == .ready && createdWorkspaceName != nil),
            blocker: continueBlocker,
            warning: continueWarning,
            requirement: continueRequirement,
            primaryActionTitle: presentation.primaryActionTitle,
            guidance: presentation.actionGuidance,
            isPrimaryActionEnabled: canContinueFromCurrentStep,
            reduceMotion: reduceMotion,
            onBack: goBack,
            onPrimaryAction: performPrimaryAction
        )
    }

    private func performPrimaryAction() {
        if currentStep == .ready {
            hasCompletedOnboarding = true
        } else {
            goNext()
        }
    }

    // MARK: - Actions

    private func goNext() {
        if currentStep == .workspaceRoot, createdWorkspaceName == nil {
            guard canCreateFirstWorkspace else { return }
            if !workspaceValidationWarnings.isEmpty {
                isShowingWorkspaceValidationWarning = true
                return
            }
            createFirstWorkspaceAndAdvance()
            return
        }
        if let next = Step(rawValue: currentStep.rawValue + 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { currentStep = next }
        }
    }

    private func createFirstWorkspaceAndAdvance() {
        let workspaceName = workspaceDraft.trimmedName
        let outcome = onCreateWorkspace(workspaceDraft)
        guard outcome != .notCreated else { return }
        createdWorkspaceName = workspaceName
        if outcome == .createdWithCapabilityIssues {
            isShowingCapabilityEnableFailure = true
        }
        if let next = Step(rawValue: currentStep.rawValue + 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { currentStep = next }
        }
    }

    private func goBack() {
        if let prev = Step(rawValue: currentStep.rawValue - 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { currentStep = prev }
        }
    }

    private var resolvedWorkspaceRoot: String {
        if !workspacesRoot.isEmpty { return workspacesRoot }
        return AppChannel.current.defaultWorkspacesRoot
    }

    private var canContinueFromCurrentStep: Bool {
        switch currentStep {
        case .requiredCLIs:
            return runtimeSetup.isCoreRuntimeReady
        case .workspaceRoot:
            return canCreateFirstWorkspace || createdWorkspaceName != nil
        default:
            return true
        }
    }

    private var continueBlocker: String? {
        switch currentStep {
        case .requiredCLIs:
            return runtimeSetup.continueBlockerText
        case .workspaceRoot:
            return workspaceValidationIssues.first
        default:
            return nil
        }
    }

    private var continueWarning: String? {
        switch currentStep {
        case .workspaceRoot:
            return workspaceValidationWarnings.first
        default:
            return nil
        }
    }

    private var continueRequirement: String? {
        guard currentStep == .workspaceRoot,
              workspaceDraft.trimmedName.isEmpty else {
            return nil
        }
        return WorkspaceCreationPresentation.emptyNameRequirement
    }
}
