import Foundation
import Testing
@testable import ASTRA
import ASTRACore

private actor GitHubAccessStubRunner: BinaryRunner {
    private var responses: [String: RunResult]
    private var calls: [String] = []

    init(responses: [String: RunResult]) {
        self.responses = responses
    }

    nonisolated func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        await response(path: path, args: args)
    }

    private func response(path: String, args: [String]) -> RunResult {
        let key = Self.key(path: path, args: args)
        calls.append(key)
        return responses[key] ?? .exited(
            code: 127,
            stdout: "",
            stderr: "No response for \(key)"
        )
    }

    func recordedCalls() -> [String] {
        calls
    }

    static func key(path: String, args: [String]) -> String {
        ([path] + args).joined(separator: " ")
    }
}

@Suite("GitHub repository access probe")
struct GitHubRepositoryAccessProbeTests {
    private let ghPath = "/opt/homebrew/bin/gh"
    private let workspace = "/workspace/repo"

    @Test("SAML response becomes an actionable authorization requirement")
    func samlAuthorizationRequired() async {
        let authorizationURL = URL(
            string: "https://github.com/enterprises/stanford-university/sso?authorization_request=ABC_123"
        )!
        let runner = GitHubAccessStubRunner(responses: baseResponses(apiResult: .exited(
            code: 1,
            stdout: """
            HTTP/2.0 403 Forbidden
            X-Github-Sso: required; url=\(authorizationURL.absoluteString)
            """,
            stderr: """
            gh: Resource protected by organization SAML enforcement.
            The 'susom' organization has enabled or enforced SAML SSO.
            """
        )))

        let status = await GitHubRepositoryAccessProbe(
            runner: runner,
            environment: { [:] }
        ).check(ghPath: ghPath, workingDirectory: workspace)

        #expect(status == .samlAuthorizationRequired(
            account: "aandresalvarez",
            repository: "susom/starr-data-lake",
            organization: "susom",
            authorizationURL: authorizationURL
        ))
        #expect(status.healthStatus(executablePath: ghPath) == .authorizationRequired(
            detail: "SAML SSO authorization for GitHub account aandresalvarez is required for the susom organization to access susom/starr-data-lake",
            authorizationURL: authorizationURL
        ))
    }

    @Test("Successful HEAD probe proves repository readiness")
    func repositoryReady() async {
        let runner = GitHubAccessStubRunner(responses: baseResponses(apiResult: .exited(
            code: 0,
            stdout: "HTTP/2.0 200 OK\n",
            stderr: ""
        )))

        let status = await GitHubRepositoryAccessProbe(
            runner: runner,
            environment: { [:] }
        ).check(ghPath: ghPath, workingDirectory: workspace)

        #expect(status == .ready(
            account: "aandresalvarez",
            repository: "susom/starr-data-lake"
        ))
    }

    @Test("Organization SSO URLs are preserved for the authorize action")
    func organizationSSOURLIsPreserved() {
        let url = "https://github.com/orgs/susom/sso?authorization_request=ORG_123"
        #expect(GitHubRepositoryAccessProbe.samlAuthorizationURL(
            in: "X-GitHub-SSO: required; url=\(url)"
        )?.absoluteString == url)
    }

    @Test("Invalid credentials are classified as login required")
    func loginRequired() async {
        let runner = GitHubAccessStubRunner(responses: baseResponses(apiResult: .exited(
            code: 1,
            stdout: "HTTP/2.0 401 Unauthorized\n",
            stderr: "gh: Bad credentials (HTTP 401)"
        )))

        let status = await GitHubRepositoryAccessProbe(
            runner: runner,
            environment: { [:] }
        ).check(ghPath: ghPath, workingDirectory: workspace)

        #expect(status == .loginRequired(
            detail: "GitHub rejected the active aandresalvarez credential"
        ))
    }

    @Test("Repository denial without SAML is a permission requirement")
    func repositoryPermissionRequired() async {
        let runner = GitHubAccessStubRunner(responses: baseResponses(apiResult: .exited(
            code: 1,
            stdout: "HTTP/2.0 403 Forbidden\n",
            stderr: "gh: Resource not accessible by integration (HTTP 403)"
        )))

        let status = await GitHubRepositoryAccessProbe(
            runner: runner,
            environment: { [:] }
        ).check(ghPath: ghPath, workingDirectory: workspace)

        #expect(status == .permissionRequired(
            account: "aandresalvarez",
            repository: "susom/starr-data-lake",
            detail: "Confirm the account, repository membership, and organization authorization."
        ))
    }

    @Test("Transient API failure remains non-blocking and unverified")
    func transientFailureIsUnverified() async {
        let runner = GitHubAccessStubRunner(responses: baseResponses(apiResult: RunResult(
            outcome: .timedOut,
            stdout: "",
            stderr: ""
        )))

        let status = await GitHubRepositoryAccessProbe(
            runner: runner,
            environment: { [:] }
        ).check(ghPath: ghPath, workingDirectory: workspace)

        #expect(status == .unavailable(
            repository: "susom/starr-data-lake",
            detail: "The GitHub API timed out."
        ))
        #expect(status.healthStatus(executablePath: ghPath) == .unverified(
            path: ghPath,
            detail: "Repository access could not be verified for susom/starr-data-lake. The GitHub API timed out."
        ))
    }

    @Test("GitHub CLI errors do not mislabel SAML as signed out")
    func githubCLIErrorClassifiesSAMLSeparately() {
        let message = """
        Resource protected by organization SAML enforcement.
        The 'susom' organization has enabled or enforced SAML SSO.
        To access this repository, visit https://github.com/orgs/susom/sso?authorization_request=ORG_123
        """

        let error = GitHubCLIError.classify(message, repository: "susom/starr-data-lake")

        guard case let .authorizationRequired(organization, repository, authorizationURL) = error else {
            Issue.record("Expected an authorization requirement, got \(error)")
            return
        }
        #expect(organization == "susom")
        #expect(repository == "susom/starr-data-lake")
        #expect(authorizationURL?.absoluteString.hasPrefix("https://github.com/orgs/susom/sso") == true)
        #expect(error.localizedDescription.contains("signed in") == true)
        #expect(error.localizedDescription.contains("gh auth login") == false)
    }

    @Test("Non-repository workspace keeps host login usable without an API target")
    func noWorkspaceRepository() async {
        var responses = baseResponses(apiResult: .exited(code: 0, stdout: "", stderr: ""))
        responses[key(
            "/usr/bin/git",
            ["-C", workspace, "rev-parse", "--is-inside-work-tree"]
        )] = .exited(code: 128, stdout: "", stderr: "not a git repository")
        let runner = GitHubAccessStubRunner(responses: responses)

        let status = await GitHubRepositoryAccessProbe(
            runner: runner,
            environment: { [:] }
        ).check(ghPath: ghPath, workingDirectory: workspace)

        #expect(status == .noWorkspaceRepository(account: "aandresalvarez"))
        #expect(status.healthStatus(executablePath: ghPath) == .unverified(
            path: ghPath,
            detail: "Authenticated as aandresalvarez; no repository target was resolved from this workspace."
        ))
        #expect(await runner.recordedCalls().contains {
            $0.contains(" api ")
        } == false)
    }

    private func baseResponses(apiResult: RunResult) -> [String: RunResult] {
        [
            key(
                "/usr/bin/git",
                ["-C", workspace, "rev-parse", "--is-inside-work-tree"]
            ): .exited(code: 0, stdout: "true\n", stderr: ""),
            key(
                "/usr/bin/git",
                ["-C", workspace, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
            ): .exited(code: 0, stdout: "origin/main\n", stderr: ""),
            key(
                "/usr/bin/git",
                ["-C", workspace, "config", "--get", "remote.origin.url"]
            ): .exited(code: 0, stdout: "git@github.com:susom/starr-data-lake.git\n", stderr: ""),
            key(
                ghPath,
                ["auth", "status", "--hostname", "github.com", "--json", "hosts"]
            ): .exited(
                code: 0,
                stdout: #"{"hosts":{"github.com":[{"login":"aandresalvarez","active":true}]}}"#,
                stderr: ""
            ),
            key(
                ghPath,
                [
                    "api",
                    "--hostname", "github.com",
                    "--method", "HEAD",
                    "--include",
                    "repos/susom/starr-data-lake"
                ]
            ): apiResult
        ]
    }

    private func key(_ path: String, _ args: [String]) -> String {
        GitHubAccessStubRunner.key(path: path, args: args)
    }
}
