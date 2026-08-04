import Foundation

/// Failure modes for GitHub operations performed through the `gh` CLI.
enum GitHubCLIError: LocalizedError {
    case notInstalled
    case notAuthenticated(String)
    case authorizationRequired(
        organization: String?,
        repository: String?,
        authorizationURL: URL?
    )
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "GitHub CLI (gh) is not installed."
        case let .notAuthenticated(detail):
            return "GitHub CLI is not authenticated. Run `gh auth login`. (\(detail))"
        case let .authorizationRequired(organization, repository, _):
            let organizationText = organization.map { " for the \($0) organization" } ?? ""
            let repositoryText = repository.map { " to access \($0)" } ?? ""
            return "GitHub CLI is signed in, but SAML SSO authorization is required\(organizationText)\(repositoryText). Open Manage Capabilities > GitHub and choose Repair access; ASTRA will refresh and verify the credential."
        case let .commandFailed(detail):
            return detail.isEmpty ? "gh pr create failed." : detail
        }
    }

    static func classify(_ message: String, repository: String? = nil) -> GitHubCLIError {
        if GitHubRepositoryAccessProbe.requiresSAMLAuthorization(message) {
            return .authorizationRequired(
                organization: GitHubRepositoryAccessProbe.samlOrganization(in: message),
                repository: repository,
                authorizationURL: GitHubRepositoryAccessProbe.samlAuthorizationURL(in: message)
            )
        }
        if GitHubRepositoryAccessProbe.requiresLogin(message) {
            return .notAuthenticated(message)
        }
        return .commandFailed(message)
    }
}
