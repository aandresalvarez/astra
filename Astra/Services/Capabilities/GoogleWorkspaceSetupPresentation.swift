import Foundation

enum GoogleWorkspaceAccountState: Equatable {
    case none
    case connected(email: String)
    case expired(email: String)
    case revoked(email: String)

    var email: String? {
        switch self {
        case .none:
            return nil
        case .connected(let email), .expired(let email), .revoked(let email):
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

enum GoogleWorkspaceMCPAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

enum GoogleWorkspaceSetupPolicyState: Equatable {
    case allowed
    case denied(messages: [String])

    static func make(decision: CapabilityCatalogDecision) -> GoogleWorkspaceSetupPolicyState {
        guard !decision.hasNonApprovalBlockers else {
            return .denied(messages: decision.blockerMessages)
        }
        return .allowed
    }
}

enum GoogleWorkspaceWriteApprovalState: Equatable {
    case notRequired
    case pending(count: Int)
    case approved
}

struct GoogleWorkspaceSetupState: Equatable {
    var account: GoogleWorkspaceAccountState
    var requiredScopes: [String]
    var grantedScopes: [String]
    var mcpAvailability: GoogleWorkspaceMCPAvailability
    var policy: GoogleWorkspaceSetupPolicyState
    var writeApproval: GoogleWorkspaceWriteApprovalState

    static let requiredWorkspaceScopes = [
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/documents"
    ]

    static let setupUnavailable = GoogleWorkspaceSetupState(
        account: .none,
        requiredScopes: requiredWorkspaceScopes,
        grantedScopes: [],
        mcpAvailability: .unavailable(reason: "Google Workspace remote MCP is not installed in this build."),
        policy: .allowed,
        writeApproval: .notRequired
    )
}

enum GoogleWorkspaceSetupIssueKind: Equatable {
    case noAccount
    case missingScopes
    case expiredToken
    case revokedToken
    case mcpUnavailable
    case policyDenied
    case writePendingApproval
}

enum GoogleWorkspaceSetupAction: Equatable {
    case connect
    case upgradeScopes
    case reauthorize
    case reconnect
    case retryPreflight
    case reviewApprovals

    var title: String {
        switch self {
        case .connect:
            return "Connect"
        case .upgradeScopes:
            return "Upgrade"
        case .reauthorize:
            return "Reauthorize"
        case .reconnect:
            return "Reconnect"
        case .retryPreflight:
            return "Retry"
        case .reviewApprovals:
            return "Review"
        }
    }

    var systemImage: String {
        switch self {
        case .connect, .reconnect:
            return "link"
        case .upgradeScopes:
            return "arrow.up.circle"
        case .reauthorize:
            return "arrow.clockwise"
        case .retryPreflight:
            return "play.circle"
        case .reviewApprovals:
            return "checklist"
        }
    }
}

struct GoogleWorkspaceSetupIssuePresentation: Equatable, Identifiable {
    var kind: GoogleWorkspaceSetupIssueKind
    var message: String
    var detail: String?
    var action: GoogleWorkspaceSetupAction?

    var id: GoogleWorkspaceSetupIssueKind { kind }
    var actionTitle: String? { action?.title }
}

struct GoogleWorkspaceSetupPresentation: Equatable {
    static let sectionTitle = "Google Workspace"
    static let summaryTitle = "Google Workspace"

    var groupTitle: String
    var summarySubtitle: String
    var accountSubtitle: String
    var primaryAction: GoogleWorkspaceSetupAction?
    var secondaryActionTitle: String?
    var issues: [GoogleWorkspaceSetupIssuePresentation]

    var primaryActionTitle: String? { primaryAction?.title }

    static func make(state: GoogleWorkspaceSetupState) -> GoogleWorkspaceSetupPresentation {
        let issues = issues(for: state)
        return GoogleWorkspaceSetupPresentation(
            groupTitle: issues.isEmpty ? "Ready" : "Action needed",
            summarySubtitle: summarySubtitle(for: state, issues: issues),
            accountSubtitle: accountSubtitle(for: state.account),
            primaryAction: issues.first?.action,
            secondaryActionTitle: state.account.email == nil ? nil : "Revoke",
            issues: issues
        )
    }

    private static func issues(for state: GoogleWorkspaceSetupState) -> [GoogleWorkspaceSetupIssuePresentation] {
        if case .denied(let messages) = state.policy {
            return [
                GoogleWorkspaceSetupIssuePresentation(
                    kind: .policyDenied,
                    message: "Google Workspace is blocked by capability policy.",
                    detail: messages.map(trimmed).filter { !$0.isEmpty }.joined(separator: "\n"),
                    action: nil
                )
            ]
        }

        if case .unavailable(let reason) = state.mcpAvailability {
            return [
                GoogleWorkspaceSetupIssuePresentation(
                    kind: .mcpUnavailable,
                    message: "Google Workspace MCP is not ready.",
                    detail: trimmed(reason),
                    action: .retryPreflight
                )
            ]
        }

        switch state.account {
        case .none:
            return [
                GoogleWorkspaceSetupIssuePresentation(
                    kind: .noAccount,
                    message: "Connect a Google account before enabling Workspace tools.",
                    detail: nil,
                    action: .connect
                )
            ]
        case .expired:
            return [
                GoogleWorkspaceSetupIssuePresentation(
                    kind: .expiredToken,
                    message: "Google access expired. Reauthorize to refresh account and scope status.",
                    detail: nil,
                    action: .reauthorize
                )
            ]
        case .revoked:
            return [
                GoogleWorkspaceSetupIssuePresentation(
                    kind: .revokedToken,
                    message: "Google access was revoked. Reconnect the account before using Workspace tools.",
                    detail: nil,
                    action: .reconnect
                )
            ]
        case .connected:
            break
        }

        let missingScopes = missingScopes(required: state.requiredScopes, granted: state.grantedScopes)
        if !missingScopes.isEmpty {
            return [
                GoogleWorkspaceSetupIssuePresentation(
                    kind: .missingScopes,
                    message: "Upgrade Google consent to include the required Workspace scopes.",
                    detail: missingScopes.joined(separator: "\n"),
                    action: .upgradeScopes
                )
            ]
        }

        if case .pending(let count) = state.writeApproval, count > 0 {
            return [
                GoogleWorkspaceSetupIssuePresentation(
                    kind: .writePendingApproval,
                    message: "Review \(count) pending Google write \(count == 1 ? "approval" : "approvals") before destructive actions can run.",
                    detail: nil,
                    action: .reviewApprovals
                )
            ]
        }

        return []
    }

    private static func summarySubtitle(
        for state: GoogleWorkspaceSetupState,
        issues: [GoogleWorkspaceSetupIssuePresentation]
    ) -> String {
        guard let first = issues.first else {
            if let email = state.account.email {
                return "Ready · \(email)"
            }
            return "Ready"
        }

        switch first.kind {
        case .noAccount:
            return "Connect account"
        case .missingScopes:
            return "Missing scope · \(missingScopes(required: state.requiredScopes, granted: state.grantedScopes).count)"
        case .expiredToken:
            return "Token expired"
        case .revokedToken:
            return "Access revoked"
        case .mcpUnavailable:
            return "MCP unavailable"
        case .policyDenied:
            return "Policy denied"
        case .writePendingApproval:
            if case .pending(let count) = state.writeApproval {
                return "Write approval pending · \(count)"
            }
            return "Write approval pending"
        }
    }

    private static func accountSubtitle(for account: GoogleWorkspaceAccountState) -> String {
        account.email ?? "No account connected"
    }

    private static func missingScopes(required: [String], granted: [String]) -> [String] {
        let grantedSet = Set(granted.map(trimmed).filter { !$0.isEmpty })
        return required
            .map(trimmed)
            .filter { !$0.isEmpty && !grantedSet.contains($0) }
            .sorted()
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
