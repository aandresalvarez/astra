import Foundation
import ASTRACore

enum GitHubRepositoryAccessStatus: Equatable, Sendable {
    case ready(account: String?, repository: String)
    case noWorkspaceRepository(account: String?)
    case loginRequired(detail: String)
    case samlAuthorizationRequired(
        account: String?,
        repository: String,
        organization: String?,
        authorizationURL: URL?
    )
    case permissionRequired(account: String?, repository: String, detail: String)
    case unavailable(repository: String?, detail: String)

    func healthStatus(executablePath: String) -> HealthStatus {
        switch self {
        case .ready(let account, let repository):
            return .healthy(
                path: executablePath,
                version: Self.readySummary(account: account, repository: repository)
            )
        case .noWorkspaceRepository(let account):
            let principal = account.map { "Authenticated as \($0); " } ?? "GitHub CLI authenticated; "
            return .unverified(
                path: executablePath,
                detail: "\(principal)no repository target was resolved from this workspace."
            )
        case .loginRequired(let detail):
            return .unauthenticated(detail: detail)
        case .samlAuthorizationRequired(let account, let repository, let organization, let authorizationURL):
            let accountDetail = account.map { " for GitHub account \($0)" } ?? ""
            let organizationDetail = organization.map { " for the \($0) organization" } ?? ""
            return .authorizationRequired(
                detail: "SAML SSO authorization\(accountDetail) is required\(organizationDetail) to access \(repository)",
                authorizationURL: authorizationURL
            )
        case .permissionRequired(_, let repository, let detail):
            return .authorizationRequired(
                detail: "The active GitHub account cannot access \(repository). \(detail)",
                authorizationURL: nil
            )
        case .unavailable(let repository, let detail):
            let target = repository.map { " for \($0)" } ?? ""
            return .unverified(
                path: executablePath,
                detail: "Repository access could not be verified\(target). \(detail)"
            )
        }
    }

    private static func readySummary(account: String?, repository: String) -> String {
        account.map { "\($0) · \(repository)" } ?? repository
    }
}

struct GitHubRepositoryAccessProbe: Sendable {
    private struct RepositoryTarget: Equatable, Sendable {
        let host: String
        let owner: String
        let name: String

        var slug: String { "\(owner)/\(name)" }
        var apiPath: String { "repos/\(owner)/\(name)" }
    }

    private struct AuthStatusPayload: Decodable {
        struct Account: Decodable {
            let login: String
            let active: Bool
        }

        let hosts: [String: [Account]]
    }

    private enum RepositoryResolution {
        case target(RepositoryTarget)
        case none
        case failed(String)
    }

    private let runner: any BinaryRunner
    private let environment: @Sendable () -> [String: String]

    init(
        runner: any BinaryRunner = ProcessBinaryRunner(),
        environment: @escaping @Sendable () -> [String: String] = {
            RuntimeProcessEnvironment.enriched(extraVariables: [
                "LC_ALL": "C",
                "LANG": "C",
                "NO_COLOR": "1"
            ])
        }
    ) {
        self.runner = runner
        self.environment = environment
    }

    func check(
        ghPath: String,
        workingDirectory: String
    ) async -> GitHubRepositoryAccessStatus {
        switch await resolveRepository(at: workingDirectory) {
        case .none:
            return .noWorkspaceRepository(account: await activeAccount(ghPath: ghPath, host: "github.com"))
        case .failed(let detail):
            return .unavailable(repository: nil, detail: detail)
        case .target(let target):
            let account = await activeAccount(ghPath: ghPath, host: target.host)
            let result = await runner.run(
                path: ghPath,
                args: [
                    "api",
                    "--hostname", target.host,
                    "--method", "HEAD",
                    "--include",
                    target.apiPath
                ],
                timeout: 12,
                environment: environment()
            )
            if result.isSuccess {
                return .ready(account: account, repository: target.slug)
            }

            let output = [result.stdout, result.stderr].joined(separator: "\n")
            if Self.requiresSAMLAuthorization(output) {
                return .samlAuthorizationRequired(
                    account: account,
                    repository: target.slug,
                    organization: Self.samlOrganization(in: output),
                    authorizationURL: Self.samlAuthorizationURL(in: output)
                )
            }
            if Self.requiresLogin(output) {
                return .loginRequired(
                    detail: account.map { "GitHub rejected the active \($0) credential" }
                        ?? "No valid GitHub CLI credential is active for \(target.host)"
                )
            }
            if Self.hasHTTPStatus(403, in: output) || Self.hasHTTPStatus(404, in: output) {
                return .permissionRequired(
                    account: account,
                    repository: target.slug,
                    detail: "Confirm the account, repository membership, and organization authorization."
                )
            }

            switch result.outcome {
            case .timedOut:
                return .unavailable(repository: target.slug, detail: "The GitHub API timed out.")
            case .cancelled:
                return .unavailable(repository: target.slug, detail: "The check was cancelled.")
            case .launchFailed(let reason):
                return .unavailable(repository: target.slug, detail: reason)
            case .exited(let code):
                let status = Self.httpStatus(in: output).map { " (HTTP \($0))" } ?? ""
                return .unavailable(
                    repository: target.slug,
                    detail: "GitHub CLI exited with status \(code)\(status)."
                )
            }
        }
    }

    static func requiresSAMLAuthorization(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("x-github-sso: required")
            || normalized.contains("saml enforcement")
            || normalized.contains("saml sso")
    }

    static func requiresLogin(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return hasHTTPStatus(401, in: normalized)
            || normalized.contains("bad credentials")
            || normalized.contains("not logged in")
            || normalized.contains("authentication required")
            || normalized.contains("to authenticate, please run")
    }

    static func samlAuthorizationURL(in output: String) -> URL? {
        firstMatch(
            pattern: #"https://github\.com/(?:enterprises|orgs)/[^\s;"']+/sso\?authorization_request=[A-Za-z0-9_-]+"#,
            in: output
        ).flatMap(URL.init(string:))
    }

    static func samlOrganization(in output: String) -> String? {
        firstCapture(
            pattern: #"(?:The\s+)?['"]([A-Za-z0-9_.-]+)['"]\s+organization"#,
            in: output
        )
    }

    private func resolveRepository(at workingDirectory: String) async -> RepositoryResolution {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let inside = await runGit(
            at: trimmed,
            arguments: ["rev-parse", "--is-inside-work-tree"]
        )
        guard inside.isSuccess,
              inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .none
        }

        let remote: String
        let upstream = await runGit(
            at: trimmed,
            arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        )
        let upstreamValue = upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if upstream.isSuccess,
           let separator = upstreamValue.firstIndex(of: "/"),
           separator != upstreamValue.startIndex {
            remote = String(upstreamValue[..<separator])
        } else {
            let remotes = await runGit(at: trimmed, arguments: ["remote"])
            guard remotes.isSuccess else {
                return .failed("ASTRA could not read the repository remotes.")
            }
            let names = remotes.stdout.split(whereSeparator: \.isNewline).map(String.init)
            guard let selected = names.contains("origin") ? "origin" : names.first else {
                return .none
            }
            remote = selected
        }

        let remoteURL = await runGit(
            at: trimmed,
            arguments: ["config", "--get", "remote.\(remote).url"]
        )
        guard remoteURL.isSuccess else {
            return .failed("ASTRA could not read the \(remote) remote URL.")
        }
        guard let target = Self.repositoryTarget(
            from: remoteURL.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return .none
        }
        return .target(target)
    }

    private func activeAccount(ghPath: String, host: String) async -> String? {
        let result = await runner.run(
            path: ghPath,
            args: ["auth", "status", "--hostname", host, "--json", "hosts"],
            timeout: 5,
            environment: environment()
        )
        guard result.isSuccess,
              let data = result.stdout.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AuthStatusPayload.self, from: data) else {
            return nil
        }
        return payload.hosts[host]?.first(where: \.active)?.login
    }

    private func runGit(at workingDirectory: String, arguments: [String]) async -> RunResult {
        let gitEnvironment = GitLocalEnvironment.scrubbing(environment())
        return await runner.run(
            path: "/usr/bin/git",
            args: ["-C", workingDirectory] + arguments,
            timeout: 5,
            environment: gitEnvironment
        )
    }

    private static func repositoryTarget(from remoteURL: String) -> RepositoryTarget? {
        guard let webURL = GitService.webURLFromRemoteURL(remoteURL),
              let components = URLComponents(string: webURL),
              let host = components.host else {
            return nil
        }
        let path = components.path.split(separator: "/").map(String.init)
        guard path.count == 2 else { return nil }
        let name = path[1].hasSuffix(".git") ? String(path[1].dropLast(4)) : path[1]
        guard !path[0].isEmpty, !name.isEmpty else { return nil }
        let effectiveHost = components.port.map { "\(host):\($0)" } ?? host
        return RepositoryTarget(host: effectiveHost, owner: path[0], name: name)
    }

    private static func hasHTTPStatus(_ status: Int, in output: String) -> Bool {
        httpStatus(in: output) == status
    }

    private static func httpStatus(in output: String) -> Int? {
        firstCapture(pattern: #"HTTP(?:/[0-9.]+)?\s+([0-9]{3})"#, in: output)
            .flatMap(Int.init)
    }

    private static func firstMatch(pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range, in: value) else {
            return nil
        }
        return String(value[swiftRange])
    }

    private static func firstCapture(pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[swiftRange])
    }
}
