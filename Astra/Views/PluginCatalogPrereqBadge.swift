import AppKit
import SwiftUI
import ASTRACore

/// Visual badge for a single CLI prerequisite. Probes via `PreflightCache`
/// on appear, shows ✅ / ⚠️ / ❌ with a short reason, and offers
/// context-aware install help (URL or copy-paste hint) when red/amber.
///
/// The badge is intentionally self-contained: the catalog just iterates a
/// package's `prerequisites` and drops one of these per entry. Status
/// updates flow through the shared `PreflightCache` so adjacent badges
/// probing the same binary reuse one result.
struct PluginCatalogPrereqBadge: View {
    let prerequisite: CLIPrerequisite
    let cache: PreflightCache
    var workingDirectory: String?

    /// Called with the current status whenever it changes. Lets the parent
    /// card aggregate (e.g., disable install if any prereq is red).
    var onStatusChange: ((HealthStatus) -> Void)?

    @State private var status: HealthStatus?
    @State private var isRechecking = false
    @State private var showDetail = false
    @State private var awaitingGenericAuthorization = false
    @StateObject private var githubRepair = GitHubRepositoryAccessRepairCoordinator()

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(prerequisite.displayName)
                        .font(Stanford.caption(12).weight(.medium))
                    if let version = healthyVersion {
                        Text(version)
                            .font(Stanford.caption(10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(statusSummary)
                    .font(Stanford.caption(11))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailingActions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.25), lineWidth: 1)
        )
        .onTapGesture { showDetail = true }
        .popover(isPresented: $showDetail) {
            detailPopover
                .padding(14)
                .frame(width: 320)
        }
        .task(id: "\(prerequisite.id):\(workingDirectory ?? "")") {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard awaitingGenericAuthorization else { return }
            Task {
                await recheck()
                if case .healthy = status {
                    awaitingGenericAuthorization = false
                }
            }
        }
        .onChange(of: githubRepair.state) { _, newState in
            guard case .ready = newState else { return }
            Task {
                await recheck()
                githubRepair.reset()
            }
        }
        .onDisappear {
            githubRepair.cancel()
        }
    }

    // MARK: - Sub-views

    private var statusIcon: some View {
        Group {
            if isRechecking || githubRepair.state.isActivelyWorking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: 16, height: 16)
    }

    private var trailingActions: some View {
        HStack(spacing: 8) {
            if isGitHubRepositoryAuthorization {
                if !githubRepair.state.isActivelyWorking,
                   githubRepair.state.deviceCode == nil {
                    Button(githubRepair.actionTitle) {
                        startOrVerifyGitHubRepair()
                    }
                    .font(Stanford.caption(11).weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(isRechecking)
                }
            } else if authorizationURL != nil {
                Button("Authorize") {
                    openAuthorization()
                }
                .font(Stanford.caption(11).weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(isRechecking)
            }
            Button {
                Task { await recheck() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(Stanford.ui(11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Re-check \(prerequisite.binary)")
            .disabled(isRechecking || githubRepair.state.isInProgress)
        }
    }

    private var detailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                Text(prerequisite.displayName)
                    .font(Stanford.heading(15))
            }
            Text(prerequisite.purpose)
                .font(Stanford.body(13))
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(statusSummary)
                    .font(Stanford.body(13))
                    .foregroundStyle(statusColor)
            }

            if let code = githubRepair.state.deviceCode {
                Divider()
                GitHubDeviceCodeView(code: code)
            }

            if shouldShowInstallHint {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to fix")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(activeHint)
                        .font(Stanford.body(13))
                        .textSelection(.enabled)
                    if let url = prerequisite.installURL {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                Text("Open installation page")
                            }
                            .font(Stanford.body(13))
                        }
                    }
                }
            }

            HStack {
                if isGitHubRepositoryAuthorization {
                    if case .blocked = githubRepair.state {
                        Link("Open GitHub SSO settings", destination: GitHubRepositoryAccessRepairCoordinator.ssoSettingsURL)
                    }
                    Spacer()
                    if !githubRepair.state.isActivelyWorking,
                       githubRepair.state.deviceCode == nil {
                        Button(githubRepair.actionTitle) {
                            startOrVerifyGitHubRepair()
                        }
                    }
                } else if authorizationURL != nil {
                    Button("Authorize SSO") {
                        showDetail = false
                        openAuthorization()
                    }
                    Spacer()
                } else {
                    Spacer()
                }
                Button("Re-check") { Task { await recheck() } }
                    .font(Stanford.body(13))
                    .disabled(isRechecking || githubRepair.state.isInProgress)
            }
        }
    }

    // MARK: - State derivations

    private var statusSymbol: String {
        switch status {
        case .healthy: "checkmark.circle.fill"
        case .unverified: "questionmark.circle.fill"
        case .unauthenticated: "exclamationmark.triangle.fill"
        case .authorizationRequired: "person.badge.key.fill"
        case .unresponsive: "exclamationmark.octagon.fill"
        case .missingBinary: "xmark.octagon.fill"
        case .none: "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch status {
        case .healthy: Stanford.statusHealthy
        case .unverified: Stanford.statusWarn
        case .unauthenticated: Stanford.statusWarn
        case .authorizationRequired: Stanford.statusWarn
        case .unresponsive: Stanford.statusError
        case .missingBinary: Stanford.statusError
        case .none: Stanford.coolGrey
        }
    }

    private var statusSummary: String {
        if isGitHubRepositoryAuthorization,
           let repairSummary = githubRepair.state.summary {
            return repairSummary
        }
        return switch status {
        case .healthy(_, let version): "Ready \(version)"
        case .unverified(_, let detail): detail
        case .unauthenticated(let detail): detail
        case .authorizationRequired(let detail, _): detail
        case .unresponsive(let detail): detail
        case .missingBinary: "Not installed"
        case .none: "Checking..."
        }
    }

    private var healthyVersion: String? {
        switch status {
        case .healthy(_, let version):
            return version
        case .unverified(let path, _):
            return path
        default:
            return nil
        }
    }

    private var shouldShowInstallHint: Bool {
        switch status {
        case .healthy, .unverified, .none: false
        case .unauthenticated, .authorizationRequired, .unresponsive, .missingBinary: true
        }
    }

    private var activeHint: String {
        switch status {
        case .unauthenticated:
            return prerequisite.authHint ?? prerequisite.installHint
        case .authorizationRequired:
            if isGitHubRepositoryAuthorization {
                if let repairSummary = githubRepair.state.summary {
                    return repairSummary
                }
                return "Choose Repair access. ASTRA will authorize the current credential, refresh GitHub CLI if needed, and verify this exact repository. Passwords, MFA, and approval stay in GitHub."
            }
            return "Approve access in the external service, then return to ASTRA."
        default:
            return prerequisite.installHint
        }
    }

    private var authorizationURL: URL? {
        guard case .authorizationRequired(_, let url) = status else { return nil }
        return url
    }

    private var isGitHubRepositoryAuthorization: Bool {
        guard prerequisite.contextualCheck == .githubRepositoryAccess else { return false }
        if case .authorizationRequired = status { return true }
        return githubRepair.state != .idle
    }

    // MARK: - Actions

    private func refresh() async {
        let fresh = await cache.status(
            for: prerequisite,
            workingDirectory: workingDirectory
        )
        status = fresh
        onStatusChange?(fresh)
    }

    private func recheck() async {
        isRechecking = true
        await cache.invalidate(binary: prerequisite.binary)
        await refresh()
        isRechecking = false
        if case .healthy = status {
            githubRepair.reset()
        }
    }

    private func openAuthorization() {
        guard let authorizationURL else { return }
        awaitingGenericAuthorization = NSWorkspace.shared.open(authorizationURL)
    }

    private func startOrVerifyGitHubRepair() {
        showDetail = true
        if githubRepair.state.isAwaitingAuthorization {
            githubRepair.verifyNow()
        } else {
            githubRepair.start(workingDirectory: workingDirectory ?? "")
        }
    }
}

// MARK: - Environment injection

private struct PreflightCacheKey: EnvironmentKey {
    /// Shared default so any view that doesn't explicitly inject one still
    /// gets a working (and cache-reusing, since it's static) cache.
    static let defaultValue: PreflightCache = PreflightCache()
}

extension EnvironmentValues {
    /// App-wide preflight cache. Keep one instance per app run so every
    /// catalog/wizard/settings view shares hits.
    var preflightCache: PreflightCache {
        get { self[PreflightCacheKey.self] }
        set { self[PreflightCacheKey.self] = newValue }
    }
}
