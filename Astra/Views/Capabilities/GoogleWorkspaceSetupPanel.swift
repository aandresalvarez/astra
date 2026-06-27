import SwiftUI

struct GoogleWorkspaceSetupPanelActions {
    var connect: (() -> Void)?
    var upgradeScopes: (() -> Void)?
    var reauthorize: (() -> Void)?
    var reconnect: (() -> Void)?
    var retryPreflight: (() -> Void)?
    var reviewApprovals: (() -> Void)?
    var revoke: (() -> Void)?

    static let unavailable = GoogleWorkspaceSetupPanelActions()
}

struct GoogleWorkspaceSetupPanel: View {
    let state: GoogleWorkspaceSetupState
    var actions: GoogleWorkspaceSetupPanelActions = .unavailable

    private var presentation: GoogleWorkspaceSetupPresentation {
        GoogleWorkspaceSetupPresentation.make(state: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 0) {
                summaryRow

                if !presentation.issues.isEmpty {
                    Divider()
                        .padding(.leading, 42)

                    VStack(spacing: 0) {
                        ForEach(Array(presentation.issues.enumerated()), id: \.element.id) { index, issue in
                            issueRow(issue)
                            if index < presentation.issues.count - 1 {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.018))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
        .accessibilityIdentifier("GoogleWorkspaceSetupPanel")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(GoogleWorkspaceSetupPresentation.sectionTitle)
                .font(Stanford.ui(15, weight: .semibold))
                .foregroundStyle(.primary)

            Text(presentation.groupTitle)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 12) {
            CapabilityLeadingIcon(
                systemImage: "externaldrive.connected.to.line.below",
                brand: .googleDrive,
                pointSize: 15
            )
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(GoogleWorkspaceSetupPresentation.summaryTitle)
                    .font(Stanford.body(14).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(presentation.summarySubtitle)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(presentation.summarySubtitle)
            }

            Spacer(minLength: 10)

            if let primaryActionTitle = presentation.primaryActionTitle {
                setupActionButton(
                    title: primaryActionTitle,
                    systemImage: primaryActionIcon(for: primaryActionTitle),
                    action: primaryActionHandler(for: primaryActionTitle)
                )
            }

            if let secondaryActionTitle = presentation.secondaryActionTitle {
                setupActionButton(
                    title: secondaryActionTitle,
                    systemImage: "xmark.circle",
                    role: .destructive,
                    action: actions.revoke
                )
            }
        }
        .frame(minHeight: 52)
    }

    private func issueRow(_ issue: GoogleWorkspaceSetupIssuePresentation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issueIcon(for: issue.kind))
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(issue.kind == .policyDenied ? Stanford.errorRed : Stanford.poppy)
                .frame(width: 30, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.message)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = issue.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(detail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func setupActionButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: (() -> Void)?
    ) -> some View {
        Button(role: role) {
            action?()
        } label: {
            Label(title, systemImage: systemImage)
                .font(Stanford.caption(11).weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(role == .destructive ? Stanford.errorRed : Stanford.lagunita)
        .disabled(action == nil)
        .help(action == nil ? "Google Workspace account setup is not wired in this build." : title)
    }

    private func primaryActionHandler(for title: String) -> (() -> Void)? {
        switch title {
        case "Connect":
            return actions.connect
        case "Upgrade":
            return actions.upgradeScopes
        case "Reauthorize":
            return actions.reauthorize
        case "Reconnect":
            return actions.reconnect
        case "Retry":
            return actions.retryPreflight
        case "Review":
            return actions.reviewApprovals
        default:
            return nil
        }
    }

    private func primaryActionIcon(for title: String) -> String {
        switch title {
        case "Connect", "Reconnect":
            return "link"
        case "Upgrade":
            return "arrow.up.circle"
        case "Reauthorize":
            return "arrow.clockwise"
        case "Retry":
            return "play.circle"
        case "Review":
            return "checklist"
        default:
            return "arrow.right.circle"
        }
    }

    private func issueIcon(for kind: GoogleWorkspaceSetupIssueKind) -> String {
        switch kind {
        case .noAccount:
            return "person.crop.circle.badge.plus"
        case .missingScopes:
            return "scope"
        case .expiredToken:
            return "clock.badge.exclamationmark"
        case .revokedToken:
            return "person.crop.circle.badge.xmark"
        case .mcpUnavailable:
            return "network.slash"
        case .policyDenied:
            return "hand.raised"
        case .writePendingApproval:
            return "checklist"
        }
    }
}
