import Foundation

/// GitHub CLI operations whose repository is an explicit reviewed input. These
/// are separate from the Repository panel conveniences that intentionally use
/// the checkout's default gh context.
extension GitService {
    func lookupOpenPullRequest(
        repoPath: String,
        remoteURL: String,
        base: String,
        head: String,
        ghPathOverride: String?
    ) async -> GitHubPullRequestLookupResult {
        guard let repository = Self.githubRepositoryArgument(from: remoteURL) else {
            return .unavailable("The reviewed remote URL is not a valid GitHub repository target.")
        }
        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHead.isEmpty else {
            return .unavailable("Current branch is empty.")
        }
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            return .unavailable("Reviewed base branch is empty.")
        }

        do {
            let output = try await runGitHubCLI(
                at: repoPath,
                arguments: [
                    "pr", "list",
                    "--repo", repository,
                    "--base", trimmedBase,
                    "--head", trimmedHead,
                    "--state", "open",
                    "--json", "number,url,title,isDraft,state",
                    "--limit", "1"
                ],
                label: "gh pr list",
                ghPathOverride: ghPathOverride
            )
            guard let decoded = Self.decodeOpenPullRequestsResult(from: output).value else {
                AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                    "head": trimmedHead,
                    "base": trimmedBase,
                    "repository": repository,
                    "result": "unavailable",
                    "reason": "invalid_json"
                ], level: .warning)
                return .unavailable("GitHub CLI returned PR data ASTRA could not read.")
            }
            if let pullRequest = decoded.first(where: { $0.state.uppercased() == "OPEN" }) ?? decoded.first {
                AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                    "head": trimmedHead,
                    "base": trimmedBase,
                    "repository": repository,
                    "result": "found",
                    "number": "\(pullRequest.number)"
                ], level: .debug)
                return .found(pullRequest)
            }
            AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                "head": trimmedHead,
                "base": trimmedBase,
                "repository": repository,
                "result": "none"
            ], level: .debug)
            return .none
        } catch {
            AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                "head": trimmedHead,
                "base": trimmedBase,
                "repository": repository,
                "result": "unavailable",
                "reason": error.localizedDescription
            ], level: .warning, fieldMaxLength: 240)
            return .unavailable(error.localizedDescription)
        }
    }

    func createPullRequest(
        repoPath: String,
        remoteURL: String,
        base: String,
        head: String,
        title: String,
        body: String,
        isDraft: Bool,
        ghPathOverride: String?
    ) async throws -> String {
        guard let repository = Self.githubRepositoryArgument(from: remoteURL) else {
            throw GitHubCLIError.commandFailed(
                "The reviewed remote URL is not a valid GitHub repository target."
            )
        }
        let normalizedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = [
            "pr", "create",
            "--repo", repository,
            "--base", normalizedBase,
            // The branch was pushed to this same reviewed repository. A plain
            // head is therefore correct and avoids gh's unsupported org:branch
            // form while still skipping all interactive fork/push behavior.
            "--head", head,
            "--title", title,
            "--body", body
        ]
        if isDraft { arguments.append("--draft") }

        do {
            AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                "base": normalizedBase,
                "head": head,
                "repository": repository,
                "draft": isDraft ? "true" : "false",
                "method": "gh"
            ], level: .info)
            let output = try await runGitHubCLI(
                at: repoPath,
                arguments: arguments,
                label: "gh pr create",
                ghPathOverride: ghPathOverride
            )
            guard let url = Self.firstURL(in: output) else {
                throw GitHubCLIError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                "base": normalizedBase,
                "head": head,
                "repository": repository,
                "result": "created",
                "url": url
            ], level: .info, fieldMaxLength: 240)
            return url
        } catch let error as GitHubCLIError {
            logTargetedPullRequestCreateFailure(
                repository: repository,
                base: normalizedBase,
                head: head,
                message: error.localizedDescription
            )
            throw error
        } catch let error as NSError {
            let message = error.localizedDescription
            if let existing = Self.firstURL(in: message) {
                AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                    "base": normalizedBase,
                    "head": head,
                    "repository": repository,
                    "result": "existing",
                    "url": existing
                ], level: .info, fieldMaxLength: 240)
                return existing
            }
            logTargetedPullRequestCreateFailure(
                repository: repository,
                base: normalizedBase,
                head: head,
                message: message
            )
            if message.localizedCaseInsensitiveContains("auth")
                || message.localizedCaseInsensitiveContains("logged") {
                throw GitHubCLIError.notAuthenticated(message)
            }
            throw GitHubCLIError.commandFailed(message)
        }
    }

    private func logTargetedPullRequestCreateFailure(
        repository: String,
        base: String,
        head: String,
        message: String
    ) {
        AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
            "base": base,
            "head": head,
            "repository": repository,
            "result": "failed",
            "detail": message
        ], level: .error, fieldMaxLength: 240)
    }

    /// Converts the reviewed web remote to gh's `[HOST/]OWNER/REPO` contract.
    /// Including the host avoids accidental routing through GH_HOST or another
    /// remote in multi-remote and GitHub Enterprise checkouts.
    static func githubRepositoryArgument(from remoteURL: String) -> String? {
        guard let webURL = webURLFromRemoteURL(remoteURL),
              let components = URLComponents(string: webURL),
              components.scheme == "https" || components.scheme == "http",
              let host = components.host,
              components.query == nil,
              components.fragment == nil else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard path.count == 2 else { return nil }
        let owner = path[0]
        let repository = path[1].hasSuffix(".git") ? String(path[1].dropLast(4)) : path[1]
        let values = [host, owner, repository]
        guard values.allSatisfy({ value in
            !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.controlCharacters.contains(scalar)
            }
        }) else { return nil }
        let effectiveHost = components.port.map { "\(host):\($0)" } ?? host
        return "\(effectiveHost)/\(owner)/\(repository)"
    }

    static func webURLFromRemoteURL(_ rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func dropGitSuffix(_ value: String) -> String {
            value.hasSuffix(".git") ? String(value.dropLast(4)) : value
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard var components = URLComponents(string: trimmed),
                  components.host != nil else { return nil }
            // Remote userinfo is transport configuration, never repository
            // identity. Strip it before the URL can enter proposals, receipts,
            // review UI, task events, logs, or proposal fingerprints.
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            guard let sanitized = components.string else { return nil }
            return dropGitSuffix(sanitized)
        }
        if trimmed.hasPrefix("git@"), let colon = trimmed.firstIndex(of: ":") {
            let hostStart = trimmed.index(trimmed.startIndex, offsetBy: "git@".count)
            let host = trimmed[hostStart..<colon]
            let path = trimmed[trimmed.index(after: colon)...]
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return "https://\(host)/\(dropGitSuffix(String(path)))"
        }
        if let components = URLComponents(string: trimmed),
           components.scheme == "ssh",
           let host = components.host {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { return nil }
            return "https://\(host)/\(dropGitSuffix(path))"
        }
        return nil
    }
}
