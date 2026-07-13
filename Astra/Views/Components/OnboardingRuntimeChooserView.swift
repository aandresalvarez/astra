import SwiftUI
import ASTRACore

/// A first-run runtime picker that presents the runtime registry as one
/// scan-first group. RuntimeSetupModel remains the single owner of probing,
/// installation, sign-in, and selection state.
struct OnboardingRuntimeChooserView: View {
    @ObservedObject var model: RuntimeSetupModel
    @Environment(\.openURL) private var openURL
    @State private var showsAdditionalRuntimes = false

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
        }
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous)
                .stroke(Stanford.sandstone.opacity(0.34), lineWidth: 1)
        }
    }

    private func runtimeRow(_ presentation: RuntimeProviderRowPresentation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                selectionIndicator(for: presentation)

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.readingText)
                    Text(subtitle(for: presentation))
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)
                trailingControl(for: presentation)
            }

            if let result = model.installResult,
               result.runtime == presentation.id,
               !result.succeeded {
                Label(result.summary, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.statusError)
                    .padding(.leading, 42)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(presentation.isSelected ? Stanford.interactive.opacity(0.035) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentation.title), \(subtitle(for: presentation))")
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
    private func trailingControl(for presentation: RuntimeProviderRowPresentation) -> some View {
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

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Stanford.body(12).weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func subtitle(for presentation: RuntimeProviderRowPresentation) -> String {
        switch presentation.state {
        case .selectedReady: "Installed and signed in"
        case .ready: "Installed"
        case .missing: "Not installed"
        case .checking: "Checking installation and sign-in"
        case .installing: "Installing"
        case .awaitingSignIn: "Waiting for sign-in"
        case .unauthenticated: "Installed; sign-in required"
        case .unresponsive: "Installed; not responding"
        case .unknown: "Not checked yet"
        case .unverified: presentation.subtitle
        }
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
