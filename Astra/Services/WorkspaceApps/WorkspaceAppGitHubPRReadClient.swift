import Foundation

/// A read-only GitHub pull-request request derived from a DECLARED `capability.read` source. The page
/// (via `astra.read`) can influence ONLY `state` (validated to a fixed set) and `limit`; the operation
/// and target repo come from the MANIFEST, never from JS — so a page can't redirect the read to an
/// arbitrary repo or a write.
struct WorkspaceAppGitHubPRRequest: Sendable, Equatable {
    /// `listMyPullRequests` (the authenticated user's PRs across repos) or `listRepoPullRequests`
    /// (one declared repo).
    var operation: String
    /// `owner/name`, only for `listRepoPullRequests`, taken from the manifest source (not the page).
    var repo: String?
    /// open | closed | merged | all (already validated).
    var state: String
    var limit: Int
}

/// Transport seam for GitHub PR reads. The real one shells the user's `gh`; tests inject a fake so the
/// suite never touches the network or the user's GitHub account.
protocol WorkspaceAppGitHubPRReading {
    func read(_ request: WorkspaceAppGitHubPRRequest) async throws -> [[String: WorkspaceAppStorageValue]]
}

/// Refuses cleanly when no gh transport is available — never fabricates rows.
struct WorkspaceAppUnavailableGitHubPRTransport: WorkspaceAppGitHubPRReading {
    func read(_ request: WorkspaceAppGitHubPRRequest) async throws -> [[String: WorkspaceAppStorageValue]] {
        throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("github:\(request.operation)")
    }
}

/// The real reader: runs the user's `gh` through `GitService.workspaceAppPullRequestJSON` (a fixed,
/// read-only argument vector) and decodes the `--json` output into scalar rows. `gh` uses the user's
/// own auth — no token ever enters ASTRA or crosses back to the page; only the scalar PR fields do.
struct WorkspaceAppGitHubCLIPRReader: WorkspaceAppGitHubPRReading {
    /// Injection seam: returns the raw `gh --json` stdout for (repo, state, limit). Defaults to the
    /// real GitService transport; tests substitute a canned string.
    var runJSON: (_ repo: String?, _ state: String, _ limit: Int) async throws -> String = { repo, state, limit in
        try await GitService.shared.workspaceAppPullRequestJSON(repo: repo, state: state, limit: limit)
    }

    func read(_ request: WorkspaceAppGitHubPRRequest) async throws -> [[String: WorkspaceAppStorageValue]] {
        let repo = request.operation == "listRepoPullRequests" ? request.repo : nil
        let json = try await runJSON(repo, request.state, request.limit)
        return Self.decodeRows(from: json)
    }

    /// Decode the `gh --json` array into scalar rows. Unknown/absent fields are simply omitted (never
    /// nested objects/arrays — the bridge only carries scalars). `author`/`repository` are flattened to
    /// their login / nameWithOwner so the page gets plain strings.
    static func decodeRows(from json: String) -> [[String: WorkspaceAppStorageValue]] {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array.map { item in
            var row: [String: WorkspaceAppStorageValue] = [:]
            if let n = item["number"] as? NSNumber { row["number"] = .integer(n.int64Value) }
            if let title = item["title"] as? String { row["title"] = .text(title) }
            if let url = item["url"] as? String { row["url"] = .text(url) }
            if let state = item["state"] as? String { row["state"] = .text(state) }
            if let draft = item["isDraft"] as? Bool { row["isDraft"] = .bool(draft) }
            if let updated = item["updatedAt"] as? String { row["updatedAt"] = .text(updated) }
            if let author = item["author"] as? [String: Any], let login = author["login"] as? String {
                row["author"] = .text(login)
            }
            if let repo = item["repository"] as? [String: Any] {
                if let nwo = repo["nameWithOwner"] as? String { row["repository"] = .text(nwo) }
                else if let name = repo["name"] as? String { row["repository"] = .text(name) }
            }
            return row
        }
    }
}

/// Async source client for the `pullRequest.read` contract. Validates the operation + state against
/// fixed sets, takes the target repo from the MANIFEST (never the page), then delegates to the gh
/// transport. Read-only; returns scalar rows only.
struct WorkspaceAppGitHubPRReadClient: WorkspaceAppAsyncCapabilitySourceClient {
    var reader: any WorkspaceAppGitHubPRReading = WorkspaceAppUnavailableGitHubPRTransport()

    static let supportedOperations: Set<String> = ["listMyPullRequests", "listRepoPullRequests"]
    static let allowedStates: Set<String> = ["open", "closed", "merged", "all"]

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        guard requirement.contract == "pullRequest.read",
              binding.provider == "github" || requirement.providerHint == "github" else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(source.id)
        }
        let operation = source.operation ?? requirement.operations.first ?? "listMyPullRequests"
        guard Self.supportedOperations.contains(operation) else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        // The source operation must be one the REQUIREMENT declared (and thus the binding mapped). Else a
        // manifest could declare a narrow op for review (e.g. listRepoPullRequests) but set the source to
        // a broader op (listMyPullRequests) and read every PR the user has — a contract-scope escalation.
        guard requirement.operations.contains(operation) else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        // The repo is MANIFEST-declared (source.projectRef), so a page can't aim the read at a repo the
        // app wasn't built for. `listRepoPullRequests` REQUIRES a valid declared slug.
        var repo: String?
        if operation == "listRepoPullRequests" {
            guard let declared = source.projectRef?.trimmingCharacters(in: .whitespacesAndNewlines),
                  GitService.isValidRepoSlug(declared) else {
                throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
            }
            repo = declared
        }
        // The only page-influenced filter: `state`, validated to the fixed set (defaults to open).
        let requestedState = stringParam(input.parameters["state"]) ?? "open"
        let state = Self.allowedStates.contains(requestedState) ? requestedState : "open"
        return try await reader.read(WorkspaceAppGitHubPRRequest(
            operation: operation, repo: repo, state: state, limit: max(1, input.limit)
        ))
    }

    private func stringParam(_ value: WorkspaceAppStorageValue?) -> String? {
        if case .text(let string) = value { return string }
        return nil
    }
}
