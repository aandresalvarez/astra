import Foundation
import ASTRACore

enum GitHubCapabilityLaunchContext {
    static func reviewThreadGuidance(usesCLIRelay: Bool) -> String {
        let request = usesCLIRelay
            ? "run `astra-host-control github -- pr review-threads NUMBER --repo OWNER/REPO`"
            : #"call ASTRA's GitHub tool (`mcp__astra_host__github`) with `{"arguments":["pr","review-threads","NUMBER","--repo","OWNER/REPO"]}`"#
        return """


        For inline PR comments, \(request). This uses the Git panel's host GitHub login and returns resolved and unresolved threads. Use this read first, including when earlier turns reported a connector or shell login failure. Follow reviewThreads.pageInfo.endCursor with --after while hasNextPage is true. For more replies in one thread, use pr thread-comments THREAD_ID --after END_CURSOR on the same tool. If output is truncated, retry the page with a smaller --limit.
        """
    }

    static func appendingProviderGuidance(
        to prompt: String,
        repositoryStatus: HealthStatus?
    ) -> String {
        guard let repositoryStatus else { return prompt }

        let readiness: String
        switch repositoryStatus {
        case .healthy(_, let summary):
            readiness = "ASTRA's repository-specific read probe succeeded: \(summary)."
        case .unverified(_, let detail):
            readiness = "\(detail) Repository and organization access are unverified. Do not describe them as ready, full, or verified until a repository-specific operation succeeds."
        case .unauthenticated(let detail):
            readiness = "GitHub CLI authentication is not ready: \(detail)"
        case .authorizationRequired(let detail, _):
            readiness = "The authenticated account still requires external authorization: \(detail)"
        case .unresponsive(let detail), .notChecked(let detail):
            readiness = "ASTRA could not verify GitHub CLI access: \(detail)"
        case .missingBinary:
            readiness = "GitHub CLI is not installed or executable."
        }

        return prompt + """


        ASTRA GitHub access preflight (authoritative host evidence):
        - \(readiness)
        - `gh auth status` and OAuth scope names describe the active token; they do not prove repository membership, organization SSO authorization, repository access, or write authority.
        - Never claim broad, full, organization, repository, or mutation access beyond the exact operation ASTRA verified.
        - For an explicit owner/repo read request, use ASTRA's read-only host-control GitHub tool and ground the access claim in that repository-specific result.
        - Authentication never grants mutation authority or permission to bypass ASTRA's resolved tools and effective launch policy.
        """
    }
}
