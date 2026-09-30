import SwiftUI

/// The ADC half of Settings → Runtime → Antigravity: project field, what
/// gcloud's credentials currently say, and one button that signs in (or only
/// switches the quota project when credentials already exist).
struct AntigravityADCSetupPanel: View {
    @ObservedObject var model: AntigravityADCSetupModel
    @Environment(\.openURL) private var openURL

    private static let gcloudInstallURL = URL(string: "https://cloud.google.com/sdk/docs/install")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routes through Google Cloud Application Default Credentials instead of agy's own Google Sign-In. Use this for a Workspace/enterprise Google account that the consumer eligibility check rejects.")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)

            statusLine

            if model.credentialStatus == .gcloudMissing {
                if let url = Self.gcloudInstallURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Install Google Cloud CLI", systemImage: "arrow.up.forward.square")
                    }
                }
            } else {
                TextField("GCP Project ID", text: $model.project, prompt: Text("my-gcp-project"))
                    .disabled(model.isRunning)
                if let issue = model.projectIssue {
                    Text(issue)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.errorRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }

            if let progress = model.progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.black)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let result = model.result, let message = result.message {
                Text(message)
                    .font(Stanford.caption(12))
                    .foregroundStyle(result.isSuccess ? Stanford.statusHealthy : Stanford.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .onAppear { model.refreshStatus() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.credentialStatus {
        case .none:
            EmptyView()
        case .gcloudMissing:
            statusLabel("gcloud not found. Install the Google Cloud CLI to use this route.", symbol: "exclamationmark.triangle", color: Stanford.errorRed)
        case .notSignedIn:
            statusLabel("No Google Cloud credentials yet. Enter a project and sign in.", symbol: "person.crop.circle.badge.questionmark", color: Stanford.coolGrey)
        case .signedIn(let project?):
            statusLabel("Credentials found · billing \(project)", symbol: "checkmark.circle.fill", color: Stanford.statusHealthy)
        case .signedIn(nil):
            statusLabel("Credentials found, but no quota project is set.", symbol: "exclamationmark.circle", color: Stanford.errorRed)
        case .unreadable(let detail):
            statusLabel(detail, symbol: "exclamationmark.triangle", color: Stanford.errorRed)
        }
    }

    private func statusLabel(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text)
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.black)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if model.isRunning {
                Button("Cancel") { model.cancel() }
            } else {
                if model.needsOnlyQuotaProject {
                    Button("Use This Project") { model.applyQuotaProject() }
                        .disabled(!model.canSubmit)
                        .help("Runs gcloud auth application-default set-quota-project.")
                }
                Button {
                    model.signIn()
                } label: {
                    Label(
                        model.credentialStatus == .notSignedIn ? "Sign In with Google Cloud…" : "Sign In Again…",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                .disabled(!model.canSubmit)
                .help("Opens Terminal with gcloud auth application-default login, then sets the quota project.")
            }
        }
    }
}
