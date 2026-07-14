import SwiftUI
import ASTRACore

/// A first-run runtime picker that presents the runtime registry as one
/// scan-first group. RuntimeSetupModel remains the single owner of probing,
/// installation, sign-in, and selection state.
struct OnboardingRuntimeChooserView: View {
    @ObservedObject var model: RuntimeSetupModel
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings
    @State private var showsAdditionalRuntimes = false
    @State private var expandedInstallLogRuntime: AgentRuntimeID?

    private var orderedRows: [RuntimeProviderRowPresentation] {
        let mapped = AgentRuntimeAdapterRegistry.runtimeIDs.map(row(for:))
        return OnboardingRuntimeListPresentation.orderedRows(
            mapped,
            registryOrder: AgentRuntimeAdapterRegistry.runtimeIDs
        )
    }

    private var primaryRows: [RuntimeProviderRowPresentation] {
        OnboardingRuntimeListPresentation.primaryRows(from: orderedRows)
    }

    private var additionalRows: [RuntimeProviderRowPresentation] {
        OnboardingRuntimeListPresentation.additionalRows(from: orderedRows)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(primaryRows) { presentation in
                runtimeRow(presentation)
                if presentation.id != primaryRows.last?.id || !additionalRows.isEmpty {
                    Divider().opacity(0.52)
                }
            }

            if additionalRows.count == 1, let presentation = additionalRows.first {
                runtimeRow(presentation)
            } else if !additionalRows.isEmpty {
                DisclosureGroup(isExpanded: $showsAdditionalRuntimes) {
                    VStack(spacing: 0) {
                        ForEach(additionalRows) { presentation in
                            Divider().opacity(0.52)
                            runtimeRow(presentation)
                        }
                    }
                } label: {
                    Text("More runtimes (\(additionalRows.count))")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(Stanford.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .accessibilityLabel("More runtimes, \(additionalRows.count)")
            }

            Divider().opacity(0.52)
            recheckFooter
        }
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous)
                .stroke(Stanford.sandstone.opacity(0.34), lineWidth: 1)
        }
    }

    private func runtimeRow(_ presentation: RuntimeProviderRowPresentation) -> some View {
        let blocker = OnboardingRuntimeChooserPresentation.selectedBlocker(
            for: presentation,
            blockers: model.runtimeBlockers
        )
        let subtitle = OnboardingRuntimeChooserPresentation.subtitle(
            for: presentation,
            authSessionStatus: authSessionStatus(for: presentation.id),
            selectedBlocker: blocker
        )
        let installFailure = OnboardingRuntimeChooserPresentation.installFailure(
            for: presentation.id,
            result: model.installResult
        )

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 14) {
                selectionIndicator(for: presentation)

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.readingText)
                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)
                trailingControl(for: presentation, selectedBlocker: blocker)
            }

            if let blocker {
                blockerDetail(blocker)
            }

            if let installFailure {
                installFailureDetail(installFailure, runtime: presentation.id)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(presentation.isSelected ? Stanford.interactive.opacity(0.035) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentation.title), \(subtitle)")
    }

    @ViewBuilder
    private func selectionIndicator(for presentation: RuntimeProviderRowPresentation) -> some View {
        if presentation.state == .checking || presentation.state == .installing || presentation.state == .awaitingSignIn {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
        } else {
            ZStack {
                Circle()
                    .stroke(
                        presentation.isSelected ? Stanford.interactive : Stanford.sandstone.opacity(0.72),
                        lineWidth: 1.5
                    )
                if presentation.isSelected {
                    Circle()
                        .fill(Stanford.interactive)
                        .padding(5)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func trailingControl(
        for presentation: RuntimeProviderRowPresentation,
        selectedBlocker: RuntimeReadinessCheck?
    ) -> some View {
        if let session = model.authSession, session.runtime == presentation.id {
            HStack(spacing: 6) {
                rowButton("Check now") { model.checkAuthNow() }
                    .accessibilityLabel("Check \(presentation.title) sign-in now")
                rowButton("Cancel") { model.cancelSignIn() }
                    .accessibilityLabel("Cancel signing in to \(presentation.title)")
            }
        } else if selectedBlocker != nil {
            Label("Needs setup", systemImage: "exclamationmark.triangle")
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(Stanford.statusWarn)
        } else {
            switch presentation.primaryAction {
            case .use:
                rowButton("Use") { model.select(presentation.id) }
                    .accessibilityLabel("Use \(presentation.title)")
            case .signIn:
                rowButton("Sign in") { model.signIn(presentation.id) }
                    .disabled(model.authSession != nil)
                    .accessibilityLabel("Sign in to \(presentation.title)")
            case .install(let displayCommand):
                rowButton("Install") { model.install(presentation.id) }
                    .disabled(model.installState != nil)
                    .help(displayCommand)
                    .accessibilityLabel("Install \(presentation.title)")
            case .openInstallPage(let url):
                rowButton("Install") { openURL(url) }
                    .help("Open the \(presentation.title) install page")
                    .accessibilityLabel("Open the \(presentation.title) install page")
            case .cancelInstall:
                rowButton("Cancel") { model.cancelInstall() }
                    .accessibilityLabel("Cancel installing \(presentation.title)")
            case .cancelSignIn:
                rowButton("Cancel") { model.cancelSignIn() }
                    .accessibilityLabel("Cancel signing in to \(presentation.title)")
            case .none:
                if presentation.state == .selectedReady {
                    Label("Ready", systemImage: "checkmark.circle")
                        .font(Stanford.body(12).weight(.medium))
                        .foregroundStyle(Stanford.statusHealthy)
                } else if presentation.state == .unverified, presentation.isSelected {
                    Text("Selected")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(Stanford.statusWarn)
                } else if presentation.state == .unresponsive, presentation.isSelected {
                    rowButton("Re-check") { model.refresh(force: true) }
                } else if presentation.state == .checking {
                    Text("Checking")
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.textSecondary)
                }
            }
        }
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Stanford.body(12).weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private var recheckFooter: some View {
        HStack(spacing: 10) {
            Text("Installed a runtime outside ASTRA?")
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.textSecondary)
            Spacer(minLength: 12)
            Button {
                model.refresh(force: true)
            } label: {
                Label(OnboardingRuntimeChooserPresentation.recheckActionTitle, systemImage: "arrow.clockwise")
                    .font(Stanford.caption(11).weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Stanford.interactive)
            .disabled(model.isRefreshing)
            .accessibilityLabel("Re-check installed runtimes")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func authSessionStatus(for runtime: AgentRuntimeID) -> String? {
        guard let session = model.authSession, session.runtime == runtime else { return nil }
        return session.statusText
    }

    private func blockerDetail(_ blocker: RuntimeReadinessCheck) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(blocker.detail)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.readingText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let remediation = blocker.remediation, !remediation.isEmpty {
                Text(remediation)
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Button("Open Runtime Settings") { openSettings() }
                .font(Stanford.caption(11).weight(.medium))
                .buttonStyle(.borderless)
                .accessibilityHint("Opens Settings where runtime provider configuration can be changed")
        }
        .padding(.leading, 38)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(blocker.title): \(blocker.detail)")
    }

    private func installFailureDetail(
        _ failure: OnboardingRuntimeInstallFailurePresentation,
        runtime: AgentRuntimeID
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.summary, systemImage: "exclamationmark.triangle.fill")
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(Stanford.statusError)
            if let detail = failure.detail, !detail.isEmpty {
                Text(detail)
                    .font(Stanford.caption(10))
                    .foregroundStyle(Stanford.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let output = failure.output, !output.isEmpty {
                DisclosureGroup(isExpanded: installLogBinding(for: runtime)) {
                    ScrollView {
                        Text(output)
                            .font(Stanford.mono(10))
                            .foregroundStyle(Stanford.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    .padding(.top, 4)
                } label: {
                    Text("Show install output")
                        .font(Stanford.caption(10).weight(.semibold))
                }
            }
        }
        .padding(.leading, 38)
    }

    private func installLogBinding(for runtime: AgentRuntimeID) -> Binding<Bool> {
        Binding(
            get: { expandedInstallLogRuntime == runtime },
            set: { isExpanded in
                expandedInstallLogRuntime = isExpanded ? runtime : nil
            }
        )
    }

    private func row(for runtime: AgentRuntimeID) -> RuntimeProviderRowPresentation {
        RuntimeProviderListPresentation.row(
            runtime: runtime,
            descriptor: AgentRuntimeAdapterRegistry.descriptor(for: runtime),
            selectedRuntime: model.selectedRuntime,
            status: model.status(for: runtime),
            isProbing: model.probing.contains(runtime),
            installingRuntime: model.installState?.runtime,
            installCommand: model.installPlanDisplayCommand(for: runtime),
            authState: model.authState(for: runtime),
            signingInRuntime: model.authSession?.runtime,
            installPageURL: RuntimeRemediationCatalog.installURL(for: runtime)
        )
    }
}
