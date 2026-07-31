import AppKit
import SwiftUI
import ASTRACore

struct GitHubDeviceCodeView: View {
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GitHub device code")
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                Text(code)
                    .font(Stanford.mono(18).weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("GitHub device code \(code)")
                Button(copied ? "Copied" : "Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .buttonStyle(.bordered)
                Link("Open GitHub", destination: GitHubCLIAuthenticationRefresher.deviceAuthorizationURL)
            }
            Text("Enter this code on the GitHub page. ASTRA will continue automatically after approval.")
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: code) {
            copied = false
        }
    }
}

struct GitHubRepositoryAccessRepairButton: View {
    let workingDirectory: String
    let onReady: @MainActor @Sendable () async -> Void

    @StateObject private var coordinator = GitHubRepositoryAccessRepairCoordinator()

    static func supports(_ prerequisite: CLIPrerequisite, status: HealthStatus?) -> Bool {
        guard prerequisite.contextualCheck == .githubRepositoryAccess,
              case .authorizationRequired = status else {
            return false
        }
        return true
    }

    var body: some View {
        Group {
            if let code = coordinator.state.deviceCode {
                GitHubDeviceCodeView(code: code)
            } else if coordinator.state.isActivelyWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(coordinator.actionTitle) {
                    if coordinator.state.isAwaitingAuthorization {
                        coordinator.verifyNow()
                    } else {
                        coordinator.start(workingDirectory: workingDirectory)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .font(Stanford.caption(11).weight(.semibold))
        .help(coordinator.state.summary ?? "Repair and verify GitHub repository access.")
        .onChange(of: coordinator.state) { _, newState in
            guard case .ready = newState else { return }
            Task {
                await onReady()
                coordinator.reset()
            }
        }
        .onDisappear {
            coordinator.cancel()
        }
    }
}
