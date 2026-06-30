import AppKit
import SwiftUI

struct GoogleWorkspaceOAuthConfigurationSection: View {
    @Binding var useCustomOAuth: Bool
    @Binding var oauthClientID: String
    @Binding var redirectURI: String

    let presentation: GoogleWorkspaceOAuthSetupPresentation
    let configurationSaved: Bool
    let hasManagedClient: Bool
    let onSaveCustom: () -> Void
    let onUseManaged: () -> Void

    private let googleCloudCredentialsURL = URL(string: "https://console.cloud.google.com/apis/credentials")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch presentation.mode {
            case .managed:
                managedContent
            case .custom, .customRequired:
                customContent
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Label("OAuth configuration", systemImage: "key.fill")
                .font(Stanford.body(13).weight(.semibold))
                .foregroundStyle(Stanford.black)

            Spacer()

            if configurationSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.paloAltoGreen)
            }
        }
    }

    private var managedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(Stanford.paloAltoGreen)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.primaryTitle)
                        .font(Stanford.caption(12).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text("Configured in this ASTRA build")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(presentation.primaryStatus)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(Stanford.paloAltoGreen)
            }

            HStack {
                Button {
                    useCustomOAuth = true
                } label: {
                    Label("Custom Client", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Use an organization-owned Google OAuth client instead of ASTRA managed OAuth.")

                Spacer()
            }
        }
    }

    private var customContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: presentation.mode == .custom ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(presentation.mode == .custom ? Stanford.paloAltoGreen : Stanford.errorRed)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.primaryTitle)
                        .font(Stanford.caption(12).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text("Desktop app client with loopback redirect")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(presentation.primaryStatus)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(presentation.mode == .custom ? Stanford.paloAltoGreen : Stanford.errorRed)
            }

            VStack(alignment: .leading, spacing: 8) {
                setupTextField(
                    title: "OAuth client ID",
                    text: $oauthClientID,
                    placeholder: "client.apps.googleusercontent.com"
                )
                setupTextField(
                    title: "Redirect URI",
                    text: $redirectURI,
                    placeholder: GoogleOAuthConfigurationSettings.defaultRedirectURI
                )
            }

            HStack(spacing: 8) {
                Link(destination: googleCloudCredentialsURL) {
                    Label("Google Cloud", systemImage: "arrow.up.right.square")
                }
                .font(Stanford.caption(11).weight(.medium))

                Button {
                    copy(redirectURI)
                } label: {
                    Label("Redirect URI", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    copy(requiredScopesText)
                } label: {
                    Label("Scopes", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if hasManagedClient {
                    Button {
                        onUseManaged()
                    } label: {
                        Label("ASTRA Managed", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("Save") {
                    onSaveCustom()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Stanford.lagunita)
            }
        }
    }

    private func setupTextField(
        title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.caption(12))
        }
    }

    private var requiredScopesText: String {
        GoogleOAuthScopeNormalizer.normalized(
            GoogleWorkspaceRemoteMCPRegistry.products.flatMap(\.requiredScopes)
        )
        .joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
