import SwiftUI
import ASTRACore

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
/// the wizard matches the rest of the app — cardinal red for primary
/// actions, lagunita teal for accents, paloAltoGreen / poppy for
/// success/warn states. All font sizes come from the approved Stanford
/// scale; no ad hoc `.title2` / `.callout` shortcuts.
///
/// Steps:
///   0. Welcome — what ASTRA is + what it needs
///   1. AI runtime — pick and ready one coding-agent CLI
///   2. Permissions — macOS access needed for browser control
///   3. Workspace — create the first workspace and quick-start capabilities
///   4. Ready — open the configured workspace
struct OnboardingWizardView: View {
    /// Bound to the enclosing gate (see `AppStorageKeys.hasCompletedOnboarding`).
    /// Toggling true dismisses the wizard.
    @Binding var hasCompletedOnboarding: Bool

    /// Called when the user finishes the workspace setup step.
    /// The wrapping ContentView persists the workspace and selects it.
    var onCreateWorkspace: (NewWorkspaceDraft) -> Bool
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
        initialStep: Step = .welcome,
        allowsDismiss: Bool = false,
        onDismiss: @escaping () -> Void = {},
        capabilityConfiguration: Binding<OnboardingCapabilityConfiguration> = .constant(OnboardingCapabilityConfiguration()),
        onCreateWorkspace: @escaping (NewWorkspaceDraft) -> Bool
    ) {
        self._hasCompletedOnboarding = hasCompletedOnboarding
        self._currentStep = State(initialValue: initialStep)
        self._capabilityConfiguration = capabilityConfiguration
        self.allowsDismiss = allowsDismiss
        self.onDismiss = onDismiss
        self.onCreateWorkspace = onCreateWorkspace
    }

    enum Step: Int, CaseIterable, Identifiable {
        case welcome = 0
        case requiredCLIs
        case permissions
        case workspaceRoot
        case ready
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome:        "Welcome to ASTRA"
            case .requiredCLIs:   "AI Runtime"
            case .permissions:    "macOS Access"
            case .workspaceRoot:  "First Workspace"
            case .ready:          "You're Ready"
            }
        }

        /// Short label shown under each dot in the progress bar. Keep
        /// under ~8 characters so the labels fit without wrapping at
        /// the wizard's 720pt minimum width.
        var progressLabel: String {
            switch self {
            case .welcome:        "Welcome"
            case .requiredCLIs:   "Runtime"
            case .permissions:    "Access"
            case .workspaceRoot:  "Folder"
            case .ready:          "Done"
            }
        }
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
    @State private var createdWorkspaceName: String?
    @StateObject private var macOSPermissions = MacOSPermissionsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                progressBar
                    .frame(maxWidth: .infinity)
                if allowsDismiss {
                    Button("Close") { onDismiss() }
                        .font(Stanford.body(13))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close onboarding")
                }
            }
            .padding(.trailing, allowsDismiss ? 20 : 0)
            Divider()

            ScrollView {
                stepContent
                    .padding(28)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Stanford.panelBackground)
        .alert("Continue with unvalidated capabilities?", isPresented: $isShowingWorkspaceValidationWarning) {
            Button("Continue Anyway") {
                createFirstWorkspaceAndAdvance()
            }
            Button("Back", role: .cancel) {}
        } message: {
            Text(workspaceValidationWarnings.prefix(3).joined(separator: "\n"))
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 0) {
            ForEach(Step.allCases) { step in
                stepIndicator(step)
                if step != Step.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue
                              ? Stanford.lagunita
                              : Stanford.sandstone.opacity(0.35))
                        .frame(height: 2)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func stepIndicator(_ step: Step) -> some View {
        let active = step == currentStep
        let done = step.rawValue < currentStep.rawValue
        let dotColor: Color = {
            if done { return Stanford.lagunita }
            if active { return Stanford.lagunita.opacity(0.18) }
            return Stanford.sandstone.opacity(0.25)
        }()
        let textColor: Color = {
            if active { return Stanford.lagunita }
            if done { return Stanford.lagunita.opacity(0.85) }
            return Stanford.coolGrey
        }()

        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(Stanford.ui(11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(active ? Stanford.lagunita : Stanford.coolGrey)
                }
            }
            Text(step.progressLabel)
                .font(Stanford.caption(12).weight(active ? .semibold : .regular))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: true, vertical: false)
                .lineLimit(1)
        }
    }

    // MARK: - Step Content Router

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:        welcomeStep
        case .requiredCLIs:   cliStep
        case .permissions:    permissionsStep
        case .workspaceRoot:  workspaceStep
        case .ready:          readyStep
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "hand.wave.fill",
                title: "Welcome to ASTRA",
                subtitle: "Workspaces, tasks, capabilities, and automation",
                tint: Stanford.cardinalRed
            )

            bulletList([
                ("square.stack.3d.up.fill", "Organize agent work into separate workspaces"),
                ("puzzlepiece.extension.fill", "Enable capability packages per workspace"),
                ("sidebar.right", "Use task shelves for plans, text, query, and browser work when relevant")
            ])

            calloutBox(
                icon: "info.circle.fill",
                title: "What ASTRA checks first",
                body: "ASTRA needs one AI runtime, such as Claude Code or GitHub Copilot. GitHub CLI is only needed when you enable GitHub repository capabilities.",
                tint: Stanford.sky
            )
        }
    }

    private var cliStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "terminal.fill",
                title: "Choose an AI Runtime",
                subtitle: "ASTRA drives a coding-agent CLI on your Mac. Pick one to start — you can add or switch later in Settings.",
                tint: Stanford.lagunita
            )

            RuntimeSetupSection(model: runtimeSetup)
        }
        .task {
            runtimeSetup.attach(preflightCache: preflightCache)
            await runtimeSetup.refreshAndWait(force: false)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "checkmark.shield.fill",
                title: "macOS Access",
                subtitle: "Check the local permissions ASTRA needs now. Browser control is verified later, when you use it.",
                tint: Stanford.lagunita
            )

            MacOSPermissionsSectionView(
                context: .onboarding,
                workspaceRoot: resolvedWorkspaceRoot,
                model: macOSPermissions
            )

            calloutBox(
                icon: "info.circle.fill",
                title: "Why this matters",
                body: "ASTRA checks credentials and workspace storage here. Browser control and capability-specific access are checked when you choose to use those features.",
                tint: Stanford.sky
            )
        }
    }

    private var workspaceStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "folder.badge.plus",
                title: "Create Your First Workspace",
                subtitle: "Name the workspace, add guidance, and connect the systems this work can use immediately.",
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
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "checkmark.seal.fill",
                title: "You're Ready",
                subtitle: "Your workspace is ready. Open it and start asking tasks that use its enabled capabilities.",
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

    private func bulletList(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.1) { icon, text in
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(Stanford.ui(14))
                        .foregroundStyle(Stanford.lagunita)
                        .frame(width: 22)
                    Text(text)
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.black)
                }
            }
        }
    }

    private func calloutBox(icon: String, title: String, body: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(Stanford.ui(13))
                .foregroundStyle(tint)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(body)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.black)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
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
        HStack(spacing: 10) {
            if currentStep != .welcome && !(currentStep == .ready && createdWorkspaceName != nil) {
                Button("Back") { goBack() }
                    .font(Stanford.body(13))
            }

            if let continueBlocker {
                Label(continueBlocker, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.poppy)
                    .lineLimit(2)
            } else if let continueWarning {
                Label(continueWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.poppy)
                    .lineLimit(2)
            }

            Spacer()

            if currentStep == .ready {
                Button {
                    hasCompletedOnboarding = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Open Workspace")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(StanfordButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    goNext()
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(StanfordButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinueFromCurrentStep)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
        guard onCreateWorkspace(workspaceDraft) else { return }
        createdWorkspaceName = workspaceName
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
            if workspaceDraft.trimmedName.isEmpty {
                return "Name your first workspace before continuing."
            }
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
}
