import SwiftUI
import ASTRACore

/// Multi-step first-run wizard. Owns its own step state and the
/// completion flag in `@AppStorage`. Drives the Claude-CLI probe up
/// front so the user knows on page one whether their machine is ready,
/// then walks them through workspace setup and a preview of which
/// catalog items are plug-and-play vs. CLI-dependent.
///
/// Visuals follow the Stanford design system (`StanfordTheme.swift`) so
/// the wizard matches the rest of the app — cardinal red for primary
/// actions, lagunita teal for accents, paloAltoGreen / poppy for
/// success/warn states. All font sizes come from the approved Stanford
/// scale; no ad hoc `.title2` / `.callout` shortcuts.
///
/// Steps:
///   0. Welcome — what ASTRA is + what it needs
///   1. Claude CLI — probe + install instructions if missing
///   2. Workspace root — pick where projects live
///   3. Catalog preview — optional extras the user can install later
///   4. Ready — "start your first workspace"
struct OnboardingWizardView: View {
    /// Bound to the enclosing gate (see `AppStorageKeys.hasCompletedOnboarding`).
    /// Toggling true dismisses the wizard.
    @Binding var hasCompletedOnboarding: Bool

    /// Called when the user hits "Create First Workspace" on the final step.
    /// The wrapping ContentView opens the actual workspace-creation sheet.
    var onCreateWorkspace: () -> Void

    /// Optional hook for testing — force a step on init.
    init(
        hasCompletedOnboarding: Binding<Bool>,
        initialStep: Step = .welcome,
        onCreateWorkspace: @escaping () -> Void
    ) {
        self._hasCompletedOnboarding = hasCompletedOnboarding
        self._currentStep = State(initialValue: initialStep)
        self.onCreateWorkspace = onCreateWorkspace
    }

    enum Step: Int, CaseIterable, Identifiable {
        case welcome = 0
        case claudeCLI
        case workspaceRoot
        case catalogPreview
        case ready
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome:        "Welcome to ASTRA"
            case .claudeCLI:      "Claude CLI"
            case .workspaceRoot:  "Workspace Root"
            case .catalogPreview: "Catalog Preview"
            case .ready:          "You're Ready"
            }
        }

        /// Short label shown under each dot in the progress bar. Keep
        /// under ~8 characters so the 5 labels fit without wrapping at
        /// the wizard's 720pt minimum width.
        var progressLabel: String {
            switch self {
            case .welcome:        "Welcome"
            case .claudeCLI:      "Claude"
            case .workspaceRoot:  "Setup"
            case .catalogPreview: "Catalog"
            case .ready:          "Done"
            }
        }
    }

    @Environment(\.preflightCache) private var preflightCache
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("workspacesRoot") private var workspacesRoot = ""
    @State private var currentStep: Step
    @State private var claudeStatus: HealthStatus?
    @State private var isProbingClaude = false

    var body: some View {
        VStack(spacing: 0) {
            progressBar
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
        case .claudeCLI:      claudeStep
        case .workspaceRoot:  workspaceStep
        case .catalogPreview: catalogStep
        case .ready:          readyStep
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "hand.wave.fill",
                title: "Welcome to ASTRA",
                subtitle: "Agent Scheduler for Tasks, Runs, and Automation",
                tint: Stanford.cardinalRed
            )

            bulletList([
                ("square.stack.3d.up.fill", "Queue AI tasks across multiple workspaces"),
                ("puzzlepiece.extension.fill", "Pick skills, connectors, and tools from a catalog"),
                ("checkmark.shield.fill", "We'll verify your Mac is set up before anything runs")
            ])

            calloutBox(
                icon: "info.circle.fill",
                title: "What we'll check",
                body: "This wizard probes the claude CLI, picks a home folder for your workspaces, and previews optional CLIs (gcloud, docker) you might want to install later. It takes less than a minute.",
                tint: Stanford.sky
            )
        }
    }

    private var claudeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "terminal.fill",
                title: "Claude CLI",
                subtitle: "ASTRA drives the claude command to run agents on your code.",
                tint: Stanford.lagunita
            )

            claudeProbeCard

            calloutBox(
                icon: "arrow.down.circle.fill",
                title: "If it's missing or not authenticated",
                body: "Install the Claude CLI from docs.claude.com/en/docs/claude-code/install, then run claude login in a terminal. Hit Re-check below when you're done.",
                tint: Stanford.sky
            )
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

    private var catalogStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "square.grid.2x2.fill",
                title: "Catalog Preview",
                subtitle: "What every workspace gets automatically, plus opt-in extras you can install later.",
                tint: Stanford.lagunita
            )

            // Silent scaffolding — ships with every workspace, no install
            // step. Listed so the user knows tests and safe modes are
            // already there; they won't appear as "installable" in the
            // catalog because they're not optional.
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Built in to every workspace", color: Stanford.paloAltoGreen)
                catalogRow("eye", "Read-Only", "explore without touching files")
                catalogRow("shield", "Safe Bash", "shell access with destructive commands blocked")
                catalogRow("checkmark.seal", "Test Runner", "detects your test framework and runs it")
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Catalog: zero-config add-ons", color: Stanford.lagunita)
                catalogRow("lock.shield.fill", "Security Auditor", "OWASP-style vuln-spotting pass")
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Catalog: needs credentials or a CLI", color: Stanford.poppy)
                catalogRow("list.bullet.clipboard", "Jira / GitHub", "API token")
                catalogRow("cloud.fill", "Google Cloud", "gcloud CLI")
            }

            calloutBox(
                icon: "hand.point.up.left.fill",
                title: "No commitment",
                body: "You don't install anything now. Each catalog package shows a preflight badge so you can see exactly what's missing and fix it before — or after — you install.",
                tint: Stanford.sky
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

    private func catalogRow(_ icon: String, _ name: String, _ caption: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.coolGrey)
                .frame(width: 18)
            Text(name)
                .font(Stanford.body(13).weight(.medium))
                .foregroundStyle(Stanford.black)
            Text(caption)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.coolGrey)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Stanford.fog.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if currentStep != .welcome {
                Button("Back") { goBack() }
                    .font(Stanford.body(13))
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

    private var resolvedWorkspaceRoot: String {
        if !workspacesRoot.isEmpty { return workspacesRoot }
        return AppChannel.current.defaultWorkspacesRoot
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
