import SwiftUI

/// App Studio's "Test" sheet — three ways for a builder to check their app works as expected, all
/// run in the `WorkspaceAppPreviewRunner` sandbox (nothing external/persisted):
///   1. Self-check — auto-exercise every action and classify pass/warn/fail.
///   2. Describe a test — plain English → the model authors an executable check → ASTRA runs it.
///   3. Saved checks — authored checks travel with the app and re-run on demand.
struct WorkspaceAppTestPanelView: View {
    let manifest: WorkspaceAppManifest
    let workspacePath: String
    var onSaveChecks: ([WorkspaceAppCheck]) -> Void
    var onFixIssue: (String) -> Void
    var onDismiss: () -> Void

    @State private var selfCheckReport: WorkspaceAppSelfCheckReport?
    @State private var checks: [WorkspaceAppCheck]
    @State private var checksReport: WorkspaceAppSelfCheckReport?
    @State private var scenario = ""
    @State private var scenarioResult: WorkspaceAppScenarioCheckResult?
    @State private var isGeneratingScenario = false

    init(
        manifest: WorkspaceAppManifest,
        workspacePath: String,
        onSaveChecks: @escaping ([WorkspaceAppCheck]) -> Void,
        onFixIssue: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.manifest = manifest
        self.workspacePath = workspacePath
        self.onSaveChecks = onSaveChecks
        self.onFixIssue = onFixIssue
        self.onDismiss = onDismiss
        _checks = State(initialValue: manifest.checks ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    selfCheckSection
                    scenarioSection
                    savedChecksSection
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppTestPanelView")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(Stanford.ui(18, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Test app")
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(manifest.app.name) · sandbox, nothing is saved")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Done", action: onDismiss)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tier 1

    private var selfCheckSection: some View {
        sectionCard(title: "Self-check", subtitle: "Run every action once on sample data and see what works.") {
            Button(action: { selfCheckReport = WorkspaceAppSelfCheck.autoExercise(manifest: manifest) }) {
                Label("Run self-check", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            if let selfCheckReport {
                reportView(selfCheckReport)
            }
        }
    }

    // MARK: - Tier 3

    private var scenarioSection: some View {
        sectionCard(title: "Describe a test", subtitle: "Plain English → ASTRA writes an executable check and runs it for real.") {
            HStack(spacing: 8) {
                TextField("e.g. after adding one item, the list shows 1 record", text: $scenario)
                    .textFieldStyle(.roundedBorder)
                Button(action: runScenario) {
                    Label("Generate & run", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(scenario.trimmingCharacters(in: .whitespaces).isEmpty || isGeneratingScenario)
            }
            if isGeneratingScenario {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Writing and running the check…")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }
            if let scenarioResult {
                resultRow(scenarioResult.result)
                if let check = scenarioResult.check, !checks.contains(where: { $0.id == check.id }) {
                    Button(action: { saveCheck(check) }) {
                        Label("Save as a check", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.lagunita)
                }
            }
        }
    }

    // MARK: - Tier 2

    private var savedChecksSection: some View {
        sectionCard(title: "Saved checks (\(checks.count))", subtitle: "Travel with the app and re-run after every edit.") {
            if checks.isEmpty {
                Text("No saved checks yet — generate one above and save it.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                Button(action: { checksReport = WorkspaceAppSelfCheck.runChecks(checks, manifest: manifest) }) {
                    Label("Run all checks", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                ForEach(checks) { check in
                    HStack(spacing: 8) {
                        Text(check.label)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button(action: { removeCheck(check) }) {
                            Image(systemName: "trash").font(Stanford.caption(11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                if let checksReport {
                    reportView(checksReport)
                }
            }
        }
    }

    // MARK: - Actions

    private func runScenario() {
        isGeneratingScenario = true
        scenarioResult = nil
        let scenarioText = scenario
        Task {
            let result = await WorkspaceAppScenarioCheckGenerator.generate(
                scenario: scenarioText, manifest: manifest, workspacePath: workspacePath
            )
            await MainActor.run {
                scenarioResult = result
                isGeneratingScenario = false
            }
        }
    }

    private func saveCheck(_ check: WorkspaceAppCheck) {
        checks.append(check)
        onSaveChecks(checks)
    }

    private func removeCheck(_ check: WorkspaceAppCheck) {
        checks.removeAll { $0.id == check.id }
        checksReport = nil
        onSaveChecks(checks)
    }

    // MARK: - Report rendering

    private func reportView(_ report: WorkspaceAppSelfCheckReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(report.headline)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(report.isClean ? Stanford.paloAltoGreen : Stanford.cardinalRed)
            ForEach(report.results) { resultRow($0) }
        }
        .padding(.top, 4)
    }

    private func resultRow(_ result: WorkspaceAppCheckResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusIcon(result.status))
                .font(Stanford.caption(12))
                .foregroundStyle(statusColor(result.status))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.label)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.primary)
                Text(result.detail)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            if result.status == .fail {
                Button(action: { fix(result) }) {
                    Label("Fix", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(Stanford.caption(11))
                .help("Send this failure back to App Studio to repair the app")
            }
        }
    }

    private func fix(_ result: WorkspaceAppCheckResult) {
        onFixIssue(WorkspaceAppTestRepairRequestBuilder.prompt(for: result, manifest: manifest))
    }

    private func statusIcon(_ status: WorkspaceAppCheckStatus) -> String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    private func statusColor(_ status: WorkspaceAppCheckStatus) -> Color {
        switch status {
        case .pass: Stanford.paloAltoGreen
        case .warn: Stanford.poppy
        case .fail: Stanford.cardinalRed
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
