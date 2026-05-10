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
}

enum OnboardingCapabilitySetup {
    static let claudeRuntimeID = "claude-cli"
    static let jiraPackageID = "jira-workflow"
    static let githubPackageID = "github-workflow"
    static let gcloudPackageID = "gcloud-workflow"
    static let redcapPackageID = "redcap-workflow"

    static let requiredRuntime = OnboardingCapabilityOption(
        id: claudeRuntimeID,
        packageID: nil,
        title: "Claude CLI",
        subtitle: "Required agent runtime",
        icon: "sparkles"
    )

    static let configurableOptions: [OnboardingCapabilityOption] = [
        OnboardingCapabilityOption(
            id: jiraPackageID,
            packageID: jiraPackageID,
            title: "Jira",
            subtitle: "Query, create, and update Jira tickets",
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

    private static func orderedPackageIDs(_ packageIDs: Set<String>) -> [String] {
        configurableOptions.compactMap { option in
            guard let packageID = option.packageID, packageIDs.contains(packageID) else { return nil }
            return packageID
        }
    }
}

/// Multi-step first-run wizard. Owns its own step state and the
/// completion flag in `@AppStorage`. Drives required CLI probes up
/// front so the user knows whether their machine can run core agent and
/// GitHub capabilities, then walks them through workspace setup.
///
/// Visuals follow the Stanford design system (`StanfordTheme.swift`) so
/// the wizard matches the rest of the app — cardinal red for primary
/// actions, lagunita teal for accents, paloAltoGreen / poppy for
/// success/warn states. All font sizes come from the approved Stanford
/// scale; no ad hoc `.title2` / `.callout` shortcuts.
///
/// Steps:
///   0. Welcome — what ASTRA is + what it needs
///   1. Required CLIs — Claude + GitHub CLI probes and install help
///   2. Workspace root — pick where projects live
///   3. Ready — "start your first workspace"
struct OnboardingWizardView: View {
    /// Bound to the enclosing gate (see `AppStorageKeys.hasCompletedOnboarding`).
    /// Toggling true dismisses the wizard.
    @Binding var hasCompletedOnboarding: Bool

    /// Called when the user hits "Create First Workspace" on the final step.
    /// The wrapping ContentView opens the actual workspace-creation sheet.
    var onCreateWorkspace: () -> Void
    var allowsDismiss: Bool
    var onDismiss: () -> Void
    @Binding var capabilityConfiguration: OnboardingCapabilityConfiguration

    static let requiredCLIPrerequisites: [CLIPrerequisite] = [
        CommonCLIPrerequisites.claude,
        CommonCLIPrerequisites.githubCLI,
        CommonCLIPrerequisites.githubAuth
    ]

    /// Optional hook for testing — force a step on init.
    init(
        hasCompletedOnboarding: Binding<Bool>,
        initialStep: Step = .welcome,
        allowsDismiss: Bool = false,
        onDismiss: @escaping () -> Void = {},
        capabilityConfiguration: Binding<OnboardingCapabilityConfiguration> = .constant(OnboardingCapabilityConfiguration()),
        onCreateWorkspace: @escaping () -> Void
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
        case workspaceRoot
        case ready
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome:        "Welcome to ASTRA"
            case .requiredCLIs:   "Required CLIs"
            case .workspaceRoot:  "Workspace Root"
            case .ready:          "You're Ready"
            }
        }

        /// Short label shown under each dot in the progress bar. Keep
        /// under ~8 characters so the 5 labels fit without wrapping at
        /// the wizard's 720pt minimum width.
        var progressLabel: String {
            switch self {
            case .welcome:        "Welcome"
            case .requiredCLIs:   "CLIs"
            case .workspaceRoot:  "Setup"
            case .ready:          "Done"
            }
        }
    }

    @Environment(\.preflightCache) private var preflightCache
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("workspacesRoot") private var workspacesRoot = ""
    @AppStorage(AppStorageKeys.onboardingEnabledCapabilityIDs) private var onboardingEnabledCapabilityIDsRaw = ""
    @AppStorage(AppStorageKeys.claudeProvider) private var claudeProviderRaw = ClaudeProvider.anthropic.rawValue
    @AppStorage(AppStorageKeys.claudeVertexProjectID) private var claudeVertexProjectID = ""
    @AppStorage(AppStorageKeys.claudeVertexRegion) private var claudeVertexRegion = ""
    @AppStorage(AppStorageKeys.claudeVertexOpusModel) private var claudeVertexOpusModel = ""
    @AppStorage(AppStorageKeys.claudeVertexSonnetModel) private var claudeVertexSonnetModel = ""
    @AppStorage(AppStorageKeys.claudeVertexHaikuModel) private var claudeVertexHaikuModel = ""
    @State private var currentStep: Step
    @State private var claudeStatus: HealthStatus?
    @State private var isProbingClaude = false
    @State private var githubStatus: HealthStatus?
    @State private var githubAuthStatus: HealthStatus?
    @State private var isProbingGitHub = false
    @State private var runtimeReadinessReport: RuntimeReadinessReport?
    @State private var isCheckingRuntimeReadiness = false
    @State private var showCLITechnicalDetails = false

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
                subtitle: "Agent Routines for Tasks, Runs, and Automation",
                tint: Stanford.cardinalRed
            )

            bulletList([
                ("square.stack.3d.up.fill", "Queue AI tasks across multiple workspaces"),
                ("puzzlepiece.extension.fill", "Pick skills, connectors, and tools from a catalog"),
                ("checkmark.shield.fill", "We'll verify Claude and GitHub CLI before anything runs")
            ])

            calloutBox(
                icon: "info.circle.fill",
                title: "What we'll check",
                body: "This wizard checks Claude CLI, GitHub CLI, and GitHub login, then picks a home folder for your workspaces.",
                tint: Stanford.sky
            )
        }
    }

    private var cliStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "terminal.fill",
                title: "Environment Check",
                subtitle: "ASTRA checks the local tools it needs and shows fixes only when something is missing.",
                tint: Stanford.lagunita
            )

            cliSummaryCard

            if !runtimeBlockers.isEmpty {
                calloutBox(
                    icon: "wrench.and.screwdriver.fill",
                    title: "Action needed",
                    body: runtimeFixHint,
                    tint: Stanford.poppy
                )
            }
        }
        .task {
            await refreshCLIEnvironment(forceRefresh: false)
        }
    }

    private var workspaceStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "folder.fill",
                title: "Workspace Root",
                subtitle: "Where ASTRA stores task history, logs, and per-workspace config.",
                tint: Stanford.lagunita
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Current location")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(Stanford.coolGrey)
                    .textCase(.uppercase)
                HStack(spacing: 10) {
                    Text(resolvedWorkspaceRoot)
                        .font(Stanford.mono(12))
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Stanford.fog)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1)
                        )
                    Button("Change…") { pickWorkspaceRoot() }
                        .font(Stanford.body(13))
                }
            }

            calloutBox(
                icon: "lightbulb.fill",
                title: "Good defaults",
                body: "\(AppChannel.current.defaultWorkspacesRoot) keeps things tidy and iCloud-backup-friendly. You can change this later in Settings.",
                tint: Stanford.illuminating
            )
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "checkmark.seal.fill",
                title: "You're Ready",
                subtitle: "Create your first workspace and queue up a task.",
                tint: Stanford.paloAltoGreen
            )

            VStack(alignment: .leading, spacing: 10) {
                readinessRow(
                    title: "Claude CLI",
                    status: claudeStatusSummary,
                    ready: isClaudeHealthy
                )
                readinessRow(
                    title: "GitHub CLI",
                    status: githubStatusSummary,
                    ready: isGitHubHealthy
                )
                readinessRow(
                    title: "Workspace root",
                    status: resolvedWorkspaceRoot,
                    ready: !resolvedWorkspaceRoot.isEmpty
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
                Text("Tip: reopen this wizard any time from Settings → Show Onboarding Again.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
            }
        }
    }

    // MARK: - Claude Probe Card

    private var cliSummaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if isCheckingRuntimeReadiness || isProbingClaude || isProbingGitHub {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: cliSummarySymbol)
                        .font(Stanford.ui(24, weight: .semibold))
                        .foregroundStyle(cliSummaryColor)
                        .frame(width: 30, height: 30)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(cliSummaryTitle)
                        .font(Stanford.heading(18))
                        .foregroundStyle(Stanford.black)
                    Text(cliSummarySubtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.coolGrey)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    Task { await refreshCLIEnvironment(forceRefresh: true) }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                        .font(Stanford.caption(12))
                }
                .disabled(isCheckingRuntimeReadiness || isProbingClaude || isProbingGitHub)
            }

            Divider().opacity(0.45)

            VStack(spacing: 8) {
                cliStatusRow(
                    title: "Claude runtime",
                    subtitle: claudeRuntimeSummary,
                    symbol: cliClaudeSymbol,
                    tint: cliClaudeColor
                )
                cliStatusRow(
                    title: "GitHub capability",
                    subtitle: githubCapabilitySummary,
                    symbol: cliGitHubSymbol,
                    tint: cliGitHubColor
                )
            }

            DisclosureGroup(isExpanded: $showCLITechnicalDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    if let runtimeReadinessReport {
                        LazyVGrid(columns: runtimeReadinessColumns, alignment: .leading, spacing: 8) {
                            ForEach(runtimeReadinessReport.checks) { check in
                                runtimeReadinessTile(check)
                            }
                        }
                    }

                    technicalPathRow("Claude path", status: claudeStatus)
                    technicalPathRow("GitHub path", status: githubStatus)
                }
                .padding(.top, 8)
            } label: {
                Label("Technical details", systemImage: "chevron.right.circle")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.coolGrey)
            }
        }
        .padding(16)
        .background(cliSummaryColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(cliSummaryColor.opacity(0.24), lineWidth: 1)
        )
    }

    private func cliStatusRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(Stanford.ui(15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(subtitle)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Stanford.fog.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func technicalPathRow(_ title: String, status: HealthStatus?) -> some View {
        if case .healthy(let path, _) = status {
            return AnyView(
                HStack(spacing: 8) {
                    Text(title)
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                        .frame(width: 78, alignment: .leading)
                    Text(path)
                        .font(Stanford.mono(10))
                        .foregroundStyle(Stanford.coolGrey)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            )
        }
        return AnyView(EmptyView())
    }

    private var cliSummaryTitle: String {
        if isCheckingRuntimeReadiness || isProbingClaude || isProbingGitHub {
            return "Checking this Mac"
        }
        if isCoreRuntimeReady {
            return "Ready to run tasks"
        }
        return "Setup needed"
    }

    private var cliSummarySubtitle: String {
        if isCoreRuntimeReady {
            if isGitHubHealthy {
                return "Claude is ready, and GitHub capabilities are available."
            }
            return "Claude is ready. GitHub can be connected later if you need repository capabilities."
        }
        return "Complete the suggested fix, then check again."
    }

    private var cliSummarySymbol: String {
        isCoreRuntimeReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var cliSummaryColor: Color {
        isCoreRuntimeReady ? Stanford.paloAltoGreen : Stanford.poppy
    }

    private var claudeRuntimeSummary: String {
        if isCoreRuntimeReady { return "Ready" }
        if let first = runtimeBlockers.first {
            return first.remediation ?? first.detail
        }
        return claudeStatusSummary
    }

    private var githubCapabilitySummary: String {
        if isGitHubHealthy { return "Ready" }
        if case .missingBinary = githubStatus {
            return "Optional unless you enable the GitHub capability."
        }
        return githubStatusSummary
    }

    private var cliClaudeSymbol: String {
        isCoreRuntimeReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var cliClaudeColor: Color {
        isCoreRuntimeReady ? Stanford.paloAltoGreen : Stanford.poppy
    }

    private var cliGitHubSymbol: String {
        isGitHubHealthy ? "checkmark.circle.fill" : "circle.dashed"
    }

    private var cliGitHubColor: Color {
        isGitHubHealthy ? Stanford.paloAltoGreen : Stanford.coolGrey
    }

    private var runtimeReadinessPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if isCheckingRuntimeReadiness {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: runtimeReadinessSymbol)
                        .font(Stanford.ui(18, weight: .semibold))
                        .foregroundStyle(runtimeReadinessColor)
                        .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtimeReadinessTitle)
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text(runtimeReadinessSubtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.coolGrey)
                }
                Spacer()
                Button {
                    Task { await refreshRuntimeReadiness() }
                } label: {
                    Label("Full Check", systemImage: "checkmark.seal")
                        .font(Stanford.caption(12))
                }
                .disabled(isCheckingRuntimeReadiness)
            }

            if let runtimeReadinessReport {
                LazyVGrid(columns: runtimeReadinessColumns, alignment: .leading, spacing: 8) {
                    ForEach(runtimeReadinessReport.checks) { check in
                        runtimeReadinessTile(check)
                    }
                }
            } else {
                Text("Checking runtime readiness...")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
            }
        }
        .padding(14)
        .background(runtimeReadinessColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(runtimeReadinessColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var runtimeReadinessColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 230), spacing: 8),
            GridItem(.flexible(minimum: 230), spacing: 8)
        ]
    }

    private func runtimeReadinessTile(_ check: RuntimeReadinessCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: readinessSymbol(for: check.state))
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(readinessColor(for: check.state))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                    .lineLimit(1)
                Text(check.detail)
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineLimit(2)
                if let remediation = check.remediation, !remediation.isEmpty {
                    Text(remediation)
                        .font(Stanford.caption(10))
                        .foregroundStyle(readinessColor(for: check.state))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(readinessColor(for: check.state).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var runtimeReadinessTitle: String {
        if isCheckingRuntimeReadiness { return "Checking environment" }
        return runtimeReadinessReport?.summary ?? "Environment not checked"
    }

    private var runtimeReadinessSubtitle: String {
        switch runtimeReadinessReport?.state {
        case .ready:
            return "Claude can run with the selected provider."
        case .warning:
            return "Core runtime is usable, but one item needs follow-up."
        case .blocked:
            return "Resolve the blocking item before creating workspaces."
        case .none:
            return "ASTRA verifies more than CLI version: auth and provider setup are included."
        }
    }

    private var runtimeReadinessSymbol: String {
        switch runtimeReadinessReport?.state {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .none: "circle.dotted"
        }
    }

    private var runtimeReadinessColor: Color {
        switch runtimeReadinessReport?.state {
        case .ready: Stanford.paloAltoGreen
        case .warning: Stanford.poppy
        case .blocked: Stanford.cardinalRed
        case .none: Stanford.coolGrey
        }
    }

    private var runtimeFixHint: String {
        guard runtimeReadinessReport != nil else {
            return "ASTRA is running the full check now. If it stalls, use Re-check after installing or logging in."
        }
        if runtimeBlockers.isEmpty {
            return "Core runtime is ready. GitHub is only required if you enable the GitHub capability."
        }
        return runtimeBlockers
            .prefix(2)
            .map { check in
                if let remediation = check.remediation, !remediation.isEmpty {
                    return "\(check.title): \(remediation)"
                }
                return "\(check.title): \(check.detail)"
            }
            .joined(separator: "\n")
    }

    private var runtimeBlockers: [RuntimeReadinessCheck] {
        runtimeReadinessReport?.checks.filter { $0.state == .blocked } ?? []
    }

    private var claudeProbeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                claudeStatusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text("claude CLI")
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text(claudeStatusSummary)
                        .font(Stanford.caption(12))
                        .foregroundStyle(claudeStatusColor)
                }
                Spacer()
                Button {
                    Task { await probeClaude(forceRefresh: true) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(Stanford.ui(11))
                        Text("Re-check")
                            .font(Stanford.caption(12))
                    }
                }
                .disabled(isProbingClaude)
            }

            if case .healthy(let path, _) = claudeStatus {
                Text("Path: \(path)")
                    .font(Stanford.mono(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .textSelection(.enabled)
            }

            providerRow
        }
        .padding(14)
        .background(claudeStatusColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(claudeStatusColor.opacity(0.25), lineWidth: 1)
        )
        .task {
            await probeClaude(forceRefresh: false)
        }
    }

    // Surfaces the configured Claude provider inline so a green "Ready" on the
    // version probe doesn't masquerade as a green provider configuration. The
    // wizard's `--version` probe alone can't catch the auth-fails-at-runtime
    // case (Anthropic not logged in, or Vertex env missing project/region), so
    // we display the provider state explicitly.
    @ViewBuilder
    private var providerRow: some View {
        let provider = ClaudeProvider(rawValue: claudeProviderRaw) ?? .anthropic
        let trimmedProject = claudeVertexProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRegion = claudeVertexRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        let isVertexBaseConfigured = !trimmedProject.isEmpty && !trimmedRegion.isEmpty
        let isAnyVertexModelMissing =
            claudeVertexOpusModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || claudeVertexSonnetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || claudeVertexHaikuModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isVertexConfigured = isVertexBaseConfigured
        let providerOK = provider == .anthropic || (isVertexBaseConfigured && !isAnyVertexModelMissing)

        Divider()
            .padding(.vertical, 2)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: providerOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(providerOK ? Stanford.statusHealthy : Stanford.statusWarn)
                .font(Stanford.ui(12, weight: .semibold))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Provider — \(provider.label)")
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(providerHint(for: provider, configured: isVertexConfigured))
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func providerHint(for provider: ClaudeProvider, configured: Bool) -> String {
        switch provider {
        case .anthropic:
            return "Routes via Anthropic. Run `claude /login` in a terminal if a task fails with “Not logged in”."
        case .vertex:
            if !configured {
                return "Vertex AI is selected but the project ID or region is empty. Open Settings → Claude Provider to fill them in."
            }
            let opus = claudeVertexOpusModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let sonnet = claudeVertexSonnetModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let haiku = claudeVertexHaikuModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if opus.isEmpty || sonnet.isEmpty || haiku.isEmpty {
                return "Routes via GCP project \(claudeVertexProjectID) in \(claudeVertexRegion), but one or more model aliases are empty — Vertex won't recognise plain Anthropic model IDs. Fill the Opus/Sonnet/Haiku aliases in Settings."
            }
            return "Routes via GCP project \(claudeVertexProjectID) in \(claudeVertexRegion) using your Vertex model aliases. Make sure `gcloud auth application-default login` is current."
        }
    }

    private var githubProbeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                githubStatusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text("gh CLI")
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text(githubStatusSummary)
                        .font(Stanford.caption(12))
                        .foregroundStyle(githubStatusColor)
                }
                Spacer()
                Button {
                    Task { await probeGitHub(forceRefresh: true) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(Stanford.ui(11))
                        Text("Re-check")
                            .font(Stanford.caption(12))
                    }
                }
                .disabled(isProbingGitHub)
            }

            if case .healthy(let path, _) = githubStatus {
                Text("Path: \(path)")
                    .font(Stanford.mono(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .textSelection(.enabled)

                Divider().opacity(0.45)

                HStack(spacing: 8) {
                    Image(systemName: githubAuthStatusSymbol)
                        .font(Stanford.ui(13))
                        .foregroundStyle(githubAuthStatusColor)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitHub login")
                            .font(Stanford.caption(11).weight(.semibold))
                            .foregroundStyle(Stanford.black)
                        Text(githubAuthStatusSummary)
                            .font(Stanford.caption(11))
                            .foregroundStyle(githubAuthStatusColor)
                    }
                }
            }
        }
        .padding(14)
        .background(githubStatusColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(githubStatusColor.opacity(0.25), lineWidth: 1)
        )
        .task {
            await probeGitHub(forceRefresh: false)
        }
    }

    private var claudeStatusIcon: some View {
        Group {
            if isProbingClaude {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: claudeStatusSymbol)
                    .font(Stanford.ui(20))
                    .foregroundStyle(claudeStatusColor)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var claudeStatusSymbol: String {
        switch claudeStatus {
        case .healthy: "checkmark.circle.fill"
        case .unauthenticated: "exclamationmark.triangle.fill"
        case .unresponsive: "exclamationmark.octagon.fill"
        case .missingBinary: "xmark.octagon.fill"
        case .none: "circle.dotted"
        }
    }

    private var claudeStatusColor: Color {
        switch claudeStatus {
        case .healthy:         Stanford.paloAltoGreen
        case .unauthenticated: Stanford.poppy
        case .unresponsive:    Stanford.cardinalRed
        case .missingBinary:   Stanford.cardinalRed
        case .none:            Stanford.coolGrey
        }
    }

    private var claudeStatusSummary: String {
        switch claudeStatus {
        case .healthy(_, let version): "Ready — \(version)"
        case .unauthenticated(let detail): detail
        case .unresponsive(let detail): detail
        case .missingBinary: "Not installed on this Mac"
        case .none: isProbingClaude ? "Checking…" : "Not yet checked"
        }
    }

    private var isClaudeHealthy: Bool {
        if case .healthy = claudeStatus { return true }
        return false
    }

    private var githubStatusIcon: some View {
        Group {
            if isProbingGitHub {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: githubStatusSymbol)
                    .font(Stanford.ui(20))
                    .foregroundStyle(githubStatusColor)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var githubStatusSymbol: String {
        if isGitHubHealthy { return "checkmark.circle.fill" }
        switch githubStatus {
        case .healthy: return "exclamationmark.triangle.fill"
        case .unauthenticated: return "exclamationmark.triangle.fill"
        case .unresponsive: return "exclamationmark.octagon.fill"
        case .missingBinary: return "xmark.octagon.fill"
        case .none: return "circle.dotted"
        }
    }

    private var githubAuthStatusSymbol: String {
        switch githubAuthStatus {
        case .healthy: "checkmark.circle.fill"
        case .unauthenticated: "exclamationmark.triangle.fill"
        case .unresponsive: "exclamationmark.triangle.fill"
        case .missingBinary: "xmark.octagon.fill"
        case .none: "circle.dotted"
        }
    }

    private var githubStatusColor: Color {
        if isGitHubHealthy { return Stanford.paloAltoGreen }
        switch githubStatus {
        case .healthy: return Stanford.poppy
        case .unauthenticated: return Stanford.poppy
        case .unresponsive: return Stanford.cardinalRed
        case .missingBinary: return Stanford.cardinalRed
        case .none: return Stanford.coolGrey
        }
    }

    private var githubAuthStatusColor: Color {
        switch githubAuthStatus {
        case .healthy:         Stanford.paloAltoGreen
        case .unauthenticated: Stanford.poppy
        case .unresponsive:    Stanford.poppy
        case .missingBinary:   Stanford.cardinalRed
        case .none:            Stanford.coolGrey
        }
    }

    private var githubStatusSummary: String {
        switch githubStatus {
        case .healthy(_, let version):
            if isGitHubHealthy {
                return "Ready — \(version)"
            }
            return githubAuthStatusSummary
        case .unauthenticated(let detail): return detail
        case .unresponsive(let detail): return detail
        case .missingBinary: return "Not installed on this Mac"
        case .none: return isProbingGitHub ? "Checking…" : "Not yet checked"
        }
    }

    private var githubAuthStatusSummary: String {
        switch githubAuthStatus {
        case .healthy: "Authenticated"
        case .unauthenticated: "Not authenticated"
        case .unresponsive: "Not authenticated"
        case .missingBinary: "Not installed on this Mac"
        case .none: isProbingGitHub ? "Checking login…" : "Login not checked"
        }
    }

    private var isGitHubHealthy: Bool {
        guard case .healthy = githubStatus,
              case .healthy = githubAuthStatus else {
            return false
        }
        return true
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

    private func sectionLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
    }

    private func requiredCapabilityRow(
        _ option: OnboardingCapabilityOption,
        status: String,
        ready: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: option.icon)
                .font(Stanford.ui(15, weight: .semibold))
                .foregroundStyle(ready ? Stanford.paloAltoGreen : Stanford.poppy)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(Stanford.body(13).weight(.medium))
                    .foregroundStyle(Stanford.black)
                Text(status)
                    .font(Stanford.caption(11))
                    .foregroundStyle(ready ? Stanford.paloAltoGreen : Stanford.coolGrey)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("Required")
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(Stanford.paloAltoGreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Stanford.paloAltoGreen.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Stanford.fog.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func configurableCapabilityRow(_ option: OnboardingCapabilityOption) -> some View {
        let packageID = option.packageID
        let isSelected = packageID.map { selectedOnboardingCapabilityIDs.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: option.icon)
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(isSelected ? Stanford.lagunita : Stanford.coolGrey)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(Stanford.body(13).weight(.medium))
                        .foregroundStyle(Stanford.black)
                    Text(option.subtitle)
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.coolGrey)
                        .lineLimit(1)
                }
                Spacer()
                if let packageID {
                    Text(capabilityStatusText(for: packageID))
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(capabilityStatusColor(for: packageID))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(capabilityStatusColor(for: packageID).opacity(0.1))
                        .clipShape(Capsule())
                    Toggle("", isOn: onboardingCapabilityBinding(for: packageID))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                        .accessibilityLabel(option.title)
                }
            }

            if let packageID, isSelected {
                capabilitySetupFields(for: packageID)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(isSelected ? Stanford.lagunita.opacity(0.08) : Stanford.fog.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Stanford.lagunita.opacity(0.22) : Stanford.sandstone.opacity(0.18), lineWidth: 1)
        )
    }

    private func capabilityStatusText(for packageID: String) -> String {
        switch packageID {
        case OnboardingCapabilitySetup.githubPackageID:
            return isGitHubHealthy ? "Ready" : "Needs gh"
        case OnboardingCapabilitySetup.gcloudPackageID:
            let project = capabilityConfiguration.gcpProject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !project.isEmpty { return "Ready" }
            return hasVertexDefaults ? "Can fill" : "Needs project"
        case OnboardingCapabilitySetup.jiraPackageID, OnboardingCapabilitySetup.redcapPackageID:
            return "Needs setup"
        default:
            return "Optional"
        }
    }

    private func capabilityStatusColor(for packageID: String) -> Color {
        switch packageStatusLevel(for: packageID) {
        case .ready: return Stanford.paloAltoGreen
        case .available: return Stanford.lagunita
        case .needsSetup: return Stanford.coolGrey
        }
    }

    private enum CapabilityStatusLevel {
        case ready
        case available
        case needsSetup
    }

    private func packageStatusLevel(for packageID: String) -> CapabilityStatusLevel {
        switch packageID {
        case OnboardingCapabilitySetup.githubPackageID:
            return isGitHubHealthy ? .ready : .needsSetup
        case OnboardingCapabilitySetup.gcloudPackageID:
            let project = capabilityConfiguration.gcpProject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !project.isEmpty { return .ready }
            return hasVertexDefaults ? .available : .needsSetup
        default:
            return .needsSetup
        }
    }

    @ViewBuilder
    private func capabilitySetupFields(for packageID: String) -> some View {
        switch packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            VStack(alignment: .leading, spacing: 8) {
                onboardingTextField("Base URL", prompt: "https://company.atlassian.net", text: $capabilityConfiguration.jiraBaseURL)
                onboardingTextField("Email", prompt: "you@example.com", text: $capabilityConfiguration.jiraEmail)
                onboardingSecureField("API token", prompt: "Stored in Keychain", text: $capabilityConfiguration.jiraAPIToken)
                onboardingTextField("Project keys", prompt: "ENG, OPS", text: $capabilityConfiguration.jiraProjects)
            }
        case OnboardingCapabilitySetup.githubPackageID:
            HStack(spacing: 8) {
                Image(systemName: isGitHubHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Stanford.ui(12))
                    .foregroundStyle(isGitHubHealthy ? Stanford.paloAltoGreen : Stanford.poppy)
                Text(isGitHubHealthy ? "Uses the authenticated gh CLI from the CLI step." : "Run gh auth login, then re-check the CLI step.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
            }
        case OnboardingCapabilitySetup.gcloudPackageID:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Project defaults")
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                        .textCase(.uppercase)
                    Spacer()
                    if hasVertexDefaults {
                        Button("Use Vertex Settings") {
                            applyCapabilityDefaults()
                        }
                        .font(Stanford.caption(11))
                    }
                }
                onboardingTextField("GCP project", prompt: "my-gcp-project", text: $capabilityConfiguration.gcpProject)
                onboardingTextField("Region", prompt: OnboardingCapabilityConfiguration.defaultGCPRegion, text: $capabilityConfiguration.gcpRegion)
                Text("Uses your local gcloud login. Run gcloud auth login outside ASTRA if it is not already authenticated.")
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
            }
        case OnboardingCapabilitySetup.redcapPackageID:
            VStack(alignment: .leading, spacing: 8) {
                onboardingTextField("API URL", prompt: OnboardingCapabilityConfiguration.defaultRedcapAPIURL, text: $capabilityConfiguration.redcapAPIURL)
                onboardingSecureField("API token", prompt: "Stored in Keychain", text: $capabilityConfiguration.redcapAPIToken)
            }
        default:
            EmptyView()
        }
    }

    private func onboardingTextField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(Stanford.coolGrey)
                .textCase(.uppercase)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.ui(12))
        }
    }

    private func onboardingSecureField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(Stanford.coolGrey)
                .textCase(.uppercase)
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.ui(12))
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

    private func readinessSymbol(for state: RuntimeReadinessState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private func readinessColor(for state: RuntimeReadinessState) -> Color {
        switch state {
        case .ready: Stanford.paloAltoGreen
        case .warning: Stanford.poppy
        case .blocked: Stanford.cardinalRed
        }
    }

    private var setupAssistantCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Recommended")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(setupAssistantSummary)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Apply") {
                enableReadyDefaults()
            }
            .font(Stanford.caption(11))
            .tint(Stanford.lagunita)
            .disabled(!hasReadyCapabilityDefaults)
        }
        .padding(10)
        .background(Stanford.lagunita.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Stanford.lagunita.opacity(0.18), lineWidth: 1)
        )
    }

    private var setupAssistantSummary: String {
        var suggestions: [String] = []
        if isGitHubHealthy {
            suggestions.append("GitHub is ready")
        }
        if hasVertexDefaults {
            suggestions.append("GCP can use Vertex settings")
        }
        if suggestions.isEmpty {
            return "No ready defaults found yet."
        }
        return suggestions.joined(separator: ". ") + "."
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if currentStep != .welcome {
                Button("Back") { goBack() }
                    .font(Stanford.body(13))
            }

            if let continueBlocker {
                Label(continueBlocker, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.poppy)
                    .lineLimit(2)
            }

            Spacer()

            if currentStep == .ready {
                Button {
                    hasCompletedOnboarding = true
                    onCreateWorkspace()
                } label: {
                    HStack(spacing: 4) {
                        Text("Create First Workspace")
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
        if let next = Step(rawValue: currentStep.rawValue + 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { currentStep = next }
        }
    }

    private func goBack() {
        if let prev = Step(rawValue: currentStep.rawValue - 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { currentStep = prev }
        }
    }

    private func refreshCLIEnvironment(forceRefresh: Bool) async {
        await probeClaude(forceRefresh: forceRefresh)
        await probeGitHub(forceRefresh: forceRefresh)
        await refreshRuntimeReadiness()
    }

    private func probeClaude(forceRefresh: Bool) async {
        isProbingClaude = true
        defer { isProbingClaude = false }

        if forceRefresh {
            await preflightCache.invalidate(binary: "claude")
        }
        claudeStatus = await preflightCache.status(for: CommonCLIPrerequisites.claude)

        // Opportunistically persist a resolved path so the worker benefits.
        if case .healthy(let path, _) = claudeStatus, claudePath.isEmpty {
            claudePath = path
        }
    }

    private func probeGitHub(forceRefresh: Bool) async {
        isProbingGitHub = true
        defer { isProbingGitHub = false }

        if forceRefresh {
            await preflightCache.invalidate(binary: "gh")
        }

        githubStatus = await preflightCache.status(for: CommonCLIPrerequisites.githubCLI)
        guard case .healthy = githubStatus else {
            githubAuthStatus = nil
            return
        }
        githubAuthStatus = await preflightCache.status(for: CommonCLIPrerequisites.githubAuth)
    }

    private var resolvedWorkspaceRoot: String {
        if !workspacesRoot.isEmpty { return workspacesRoot }
        return AppChannel.current.defaultWorkspacesRoot
    }

    private var selectedOnboardingCapabilityIDs: Set<String> {
        OnboardingCapabilitySetup.selectedPackageIDs(from: onboardingEnabledCapabilityIDsRaw)
    }

    private var selectedOnboardingCapabilitySummary: String {
        let names = OnboardingCapabilitySetup.selectedDisplayNames(from: selectedOnboardingCapabilityIDs)
        return names.isEmpty ? "No optional capabilities selected" : names.joined(separator: ", ")
    }

    private var selectedCapabilitySetupIssues: [String] {
        OnboardingCapabilitySetup.configurableOptions.flatMap { option -> [String] in
            guard let packageID = option.packageID,
                  selectedOnboardingCapabilityIDs.contains(packageID) else {
                return []
            }
            return capabilityConfiguration
                .missingRequirements(for: packageID, githubCLIReady: isGitHubHealthy)
                .map { "\(option.title): \($0)" }
        }
    }

    private var isCoreRuntimeReady: Bool {
        guard let report = runtimeReadinessReport else { return false }
        return !report.checks.contains { $0.state == .blocked }
    }

    private var hasVertexDefaults: Bool {
        !claudeVertexProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !claudeVertexRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasReadyCapabilityDefaults: Bool {
        isGitHubHealthy || hasVertexDefaults
    }

    private var canContinueFromCurrentStep: Bool {
        switch currentStep {
        case .requiredCLIs:
            return isCoreRuntimeReady
        default:
            return true
        }
    }

    private var continueBlocker: String? {
        switch currentStep {
        case .requiredCLIs:
            return isCoreRuntimeReady ? nil : "Finish the runtime checks before continuing."
        default:
            return nil
        }
    }

    private func onboardingCapabilityBinding(for packageID: String) -> Binding<Bool> {
        Binding(
            get: { selectedOnboardingCapabilityIDs.contains(packageID) },
            set: { setOnboardingCapability(packageID, enabled: $0) }
        )
    }

    private func setOnboardingCapability(_ packageID: String, enabled: Bool) {
        var ids = selectedOnboardingCapabilityIDs
        if enabled {
            ids.insert(packageID)
        } else {
            ids.remove(packageID)
        }
        onboardingEnabledCapabilityIDsRaw = OnboardingCapabilitySetup.encode(ids)
    }

    private func applyCapabilityDefaults() {
        _ = capabilityConfiguration.applyEnvironmentDefaults(
            gcpProject: claudeVertexProjectID,
            gcpRegion: claudeVertexRegion
        )
    }

    private func enableReadyDefaults() {
        applyCapabilityDefaults()
        var ids = selectedOnboardingCapabilityIDs
        if isGitHubHealthy {
            ids.insert(OnboardingCapabilitySetup.githubPackageID)
        }
        if !capabilityConfiguration.gcpProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ids.insert(OnboardingCapabilitySetup.gcloudPackageID)
        }
        onboardingEnabledCapabilityIDsRaw = OnboardingCapabilitySetup.encode(ids)
    }

    private func refreshRuntimeReadiness() async {
        isCheckingRuntimeReadiness = true
        defer { isCheckingRuntimeReadiness = false }

        let service = RuntimeReadinessService()
        runtimeReadinessReport = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .claudeCode,
            claudePath: claudePath,
            copilotPath: "",
            claudeProvider: ClaudeProvider(rawValue: claudeProviderRaw) ?? .anthropic,
            vertexProjectID: claudeVertexProjectID,
            vertexRegion: claudeVertexRegion,
            vertexOpusModel: claudeVertexOpusModel,
            vertexSonnetModel: claudeVertexSonnetModel,
            vertexHaikuModel: claudeVertexHaikuModel
        ))
    }

    private func pickWorkspaceRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder to store ASTRA workspaces"
        if panel.runModal() == .OK, let url = panel.url {
            workspacesRoot = url.path
        }
    }
}
